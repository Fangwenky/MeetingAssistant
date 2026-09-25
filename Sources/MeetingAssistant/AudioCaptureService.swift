@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import CoreGraphics
@preconcurrency import ScreenCaptureKit
import Foundation
import MeetingAssistantCore

struct CapturePermissionSnapshot: Equatable, Sendable {
    var screenRecordingGranted: Bool
    var microphoneGranted: Bool

    var allGranted: Bool { screenRecordingGranted && microphoneGranted }
}

struct CapturableApplication: Identifiable, Hashable, Sendable {
    var id: Int32 { processID }
    var name: String
    var bundleIdentifier: String?
    var processID: Int32

    var scope: CaptureScope {
        .application(name: name, bundleIdentifier: bundleIdentifier, processID: processID)
    }
}

final class AudioCaptureService: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    typealias SampleHandler = @Sendable (SpeakerSource, [Float], TimeInterval) -> Void
    typealias ErrorHandler = @Sendable (Error) -> Void

    private let systemQueue = DispatchQueue(label: "MeetingAssistant.system-audio", qos: .userInitiated)
    private let microphoneQueue = DispatchQueue(label: "MeetingAssistant.microphone", qos: .userInitiated)
    private let systemConverter = AudioSampleConverter()
    private let microphoneConverter = AudioSampleConverter()
    private let stateLock = NSLock()
    private var stream: SCStream?
    private var isPaused = false
    private var sampleHandler: SampleHandler?
    private var errorHandler: ErrorHandler?
    private var presentationTimeOffset: TimeInterval?

    func permissionSnapshot() -> CapturePermissionSnapshot {
        CapturePermissionSnapshot(
            screenRecordingGranted: CGPreflightScreenCaptureAccess(),
            microphoneGranted: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        )
    }

    func requestPermissions() async -> CapturePermissionSnapshot {
        _ = requestScreenRecordingPermission()
        _ = await requestMicrophonePermission()
        return permissionSnapshot()
    }

    func availableApplications() async throws -> [CapturableApplication] {
        guard requestScreenRecordingPermission() else { throw CaptureError.screenRecordingPermissionDenied }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        return content.applications
            .filter { $0.processID != getpid() && !$0.applicationName.isEmpty }
            .map {
                CapturableApplication(
                    name: $0.applicationName,
                    bundleIdentifier: $0.bundleIdentifier,
                    processID: $0.processID
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func requestMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    private func requestScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
    }

    func start(
        scope: CaptureScope,
        captureMicrophone: Bool,
        onSamples: @escaping SampleHandler,
        onError: @escaping ErrorHandler
    ) async throws {
        guard requestScreenRecordingPermission() else { throw CaptureError.screenRecordingPermissionDenied }
        if captureMicrophone {
            guard await requestMicrophonePermission() else { throw CaptureError.microphonePermissionDenied }
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw CaptureError.noDisplay }
        let filter: SCContentFilter
        switch scope {
        case .allSystemAudio:
            let excluded = content.applications.filter { $0.processID == getpid() }
            filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
        case let .application(_, _, processID):
            guard let application = content.applications.first(where: { $0.processID == processID }) else {
                throw CaptureError.applicationUnavailable
            }
            filter = SCContentFilter(display: display, including: [application], exceptingWindows: [])
        }

        let configuration = makeConfiguration(captureMicrophone: captureMicrophone)

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: systemQueue)
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: microphoneQueue)
        stateLock.withLock {
            self.stream = stream
            self.sampleHandler = onSamples
            self.errorHandler = onError
            isPaused = false
            presentationTimeOffset = nil
        }
        try await stream.startCapture()
    }

    func setMicrophoneEnabled(_ enabled: Bool) async throws {
        if enabled {
            guard await requestMicrophonePermission() else { throw CaptureError.microphonePermissionDenied }
        }
        guard let stream = stateLock.withLock({ self.stream }) else { return }
        try await stream.updateConfiguration(makeConfiguration(captureMicrophone: enabled))
    }

    func setPaused(_ paused: Bool) {
        stateLock.withLock { isPaused = paused }
        if paused {
            systemQueue.sync {}
            microphoneQueue.sync {}
        }
    }

    func stop() async {
        let stream = stateLock.withLock {
            let current = self.stream
            self.stream = nil
            sampleHandler = nil
            return current
        }
        try? await stream?.stopCapture()
        systemQueue.sync {}
        microphoneQueue.sync {}
    }

    private func makeConfiguration(captureMicrophone: Bool) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.captureMicrophone = captureMicrophone
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 1
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3
        return configuration
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        let (paused, handler) = stateLock.withLock { (isPaused, sampleHandler) }
        guard !paused, let handler else { return }
        do {
            let capturedAt = captureEndTime(sampleBuffer)
            switch outputType {
            case .audio:
                let samples = try systemConverter.convert(sampleBuffer)
                if !samples.isEmpty { handler(.others, samples, capturedAt) }
            case .microphone:
                let samples = try microphoneConverter.convert(sampleBuffer)
                if !samples.isEmpty { handler(.me, samples, capturedAt) }
            default:
                break
            }
        } catch {
            let errorHandler = stateLock.withLock { self.errorHandler }
            errorHandler?(error)
        }
    }

    private func captureEndTime(_ buffer: CMSampleBuffer) -> TimeInterval {
        let presentation = CMSampleBufferGetPresentationTimeStamp(buffer)
        guard presentation.isValid, presentation.isNumeric else {
            return ProcessInfo.processInfo.systemUptime
        }
        let seconds = CMTimeGetSeconds(presentation)
        guard seconds.isFinite else { return ProcessInfo.processInfo.systemUptime }
        let offset = stateLock.withLock { () -> TimeInterval in
            if let presentationTimeOffset { return presentationTimeOffset }
            let value = ProcessInfo.processInfo.systemUptime - seconds
            presentationTimeOffset = value
            return value
        }
        let duration = CMTimeGetSeconds(CMSampleBufferGetDuration(buffer))
        return seconds + offset + (duration.isFinite && duration > 0 ? duration : 0)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let handler = stateLock.withLock { errorHandler }
        handler?(error)
    }
}

enum CaptureError: LocalizedError {
    case screenRecordingPermissionDenied
    case microphonePermissionDenied
    case noDisplay
    case applicationUnavailable

    var errorDescription: String? {
        switch self {
        case .screenRecordingPermissionDenied: "没有屏幕与系统音频录制权限。授权后请重新启动 MeetingAssistant"
        case .microphonePermissionDenied: "没有麦克风权限，请在系统设置中允许访问"
        case .noDisplay: "找不到可捕获的显示器"
        case .applicationUnavailable: "选择的会议应用已退出，请重新选择"
        }
    }
}
