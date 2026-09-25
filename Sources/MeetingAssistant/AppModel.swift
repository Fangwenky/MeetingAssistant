import AppKit
import Combine
import Foundation
import MeetingAssistantCore
import UniformTypeIdentifiers

enum ModelLoadState: Equatable {
    case notLoaded
    case loading
    case ready
    case failed(String)

    var label: String {
        switch self {
        case .notLoaded: "尚未下载"
        case .loading: "正在下载并加载模型…"
        case .ready: "模型已就绪"
        case let .failed(message): "加载失败：\(message)"
        }
    }
}

struct LiveTranscript: Sendable {
    var text: String
    var startTime: TimeInterval
}

private struct AudioPacket: Sendable {
    var samples: [Float]
    var capturedAt: TimeInterval
    var barrier: CheckedContinuation<Void, Never>? = nil
}

@MainActor
final class AppModel: ObservableObject {
    @Published var meetings: [MeetingRecord] = []
    @Published var document: MeetingDocument?
    @Published var partialText: [SpeakerSource: LiveTranscript] = [:]
    @Published var availableApplications: [CapturableApplication] = []
    @Published var modelState: ModelLoadState = .notLoaded
    @Published var isStartingMeeting = false
    @Published var isAnalyzing = false
    @Published var isAnswering = false
    @Published var isFinalizing = false
    @Published var isMicrophoneEnabled = false
    @Published var errorMessage: String?
    @Published var analysisError: String?
    @Published var settingsStatus: String?
    @Published var capturePermissions = CapturePermissionSnapshot(
        screenRecordingGranted: false,
        microphoneGranted: false
    )

    private let store: MeetingStore
    private let capture = AudioCaptureService()
    private let llmClient = LLMClient()
    private var mineTranscriber: WhisperChannelTranscriber?
    private var othersTranscriber: WhisperChannelTranscriber?
    private var meetingStartUptime: TimeInterval = 0
    private var activeMeetingID: UUID?
    private var analysisTask: Task<Void, Never>?
    private var analysisGate = AnalysisRequestGate()
    private var refinedSegmentIDs: Set<UUID> = []
    private var audioArchive: AudioReviewArchive?
    private var mineContinuation: AsyncStream<AudioPacket>.Continuation?
    private var othersContinuation: AsyncStream<AudioPacket>.Continuation?
    private var mineConsumer: Task<Void, Never>?
    private var othersConsumer: Task<Void, Never>?
    private var reportedArchiveError = false
    private var nextRefinementAttempt = Date.distantPast

    var isMeetingActive: Bool { activeMeetingID != nil }
    var categories: [String] {
        Array(Set(meetings.compactMap(\.category).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    init() {
        do {
            store = try MeetingStore()
        } catch {
            fatalError("Unable to initialize MeetingStore: \(error)")
        }
        Task { await bootstrap() }
    }

    private func bootstrap() async {
        refreshCapturePermissions()
        do {
            var records = try await store.list()
            for index in records.indices where records[index].status != .finished {
                records[index].status = .finished
                records[index].endedAt = records[index].endedAt ?? Date()
                try await store.update(records[index])
            }
            meetings = records
            if let first = records.first { document = try await store.load(first.id) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reloadHistory() async {
        do {
            meetings = try await store.list()
            if document == nil, let first = meetings.first {
                document = try await store.load(first.id)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectMeeting(_ id: UUID?) async {
        guard activeMeetingID == nil, let id else { return }
        do {
            document = try await store.load(id)
            analysisGate = AnalysisRequestGate(lastProcessedSegmentID: document?.analysis.lastProcessedSegmentID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadAvailableApplications() async {
        do {
            availableApplications = try await capture.availableApplications()
            refreshCapturePermissions()
        } catch {
            refreshCapturePermissions()
            errorMessage = "无法读取可捕获应用：\(error.localizedDescription)"
        }
    }

    func refreshCapturePermissions() {
        capturePermissions = capture.permissionSnapshot()
    }

    func requestCapturePermissions() async {
        capturePermissions = await capture.requestPermissions()
        if !capturePermissions.allGranted {
            settingsStatus = "请在系统设置中允许访问；屏幕录制授权后可能需要重新启动应用"
        }
    }

    func prepareModel() async {
        guard mineTranscriber == nil, modelState != .loading else { return }
        modelState = .loading
        do {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first!
                .appending(path: "MeetingAssistant/Models", directoryHint: .isDirectory)
            let pipelines = try await WhisperPipelineFactory.make(
                downloadBase: base,
                eventHandler: { [weak self] event in
                    await self?.handle(event)
                },
                errorHandler: { [weak self] error in
                    Task { @MainActor [weak self] in
                        self?.errorMessage = "本地转写失败：\(error.localizedDescription)"
                    }
                }
            )
            mineTranscriber = pipelines.mine
            othersTranscriber = pipelines.others
            modelState = .ready
        } catch {
            modelState = .failed(error.localizedDescription)
            errorMessage = "模型加载失败：\(error.localizedDescription)"
        }
    }

    func startMeeting(title: String, scope: CaptureScope, captureMicrophone: Bool) async {
        guard activeMeetingID == nil else { return }
        isStartingMeeting = true
        defer { isStartingMeeting = false }
        await prepareModel()
        guard modelState == .ready,
              let mineTranscriber,
              let othersTranscriber else { return }
        await mineTranscriber.reset()
        await othersTranscriber.reset()

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = MeetingRecord(
            title: trimmedTitle.isEmpty ? defaultMeetingTitle() : trimmedTitle,
            captureScope: scope
        )
        do {
            document = try await store.create(record)
            activeMeetingID = record.id
            meetingStartUptime = ProcessInfo.processInfo.systemUptime
            partialText = [:]
            analysisGate = AnalysisRequestGate()
            refinedSegmentIDs = []
            let archive = try AudioReviewArchive()
            audioArchive = archive
            reportedArchiveError = false
            nextRefinementAttempt = .distantPast
            let (mineStream, mineSink) = AsyncStream<AudioPacket>.makeStream()
            let (othersStream, othersSink) = AsyncStream<AudioPacket>.makeStream()
            mineContinuation = mineSink
            othersContinuation = othersSink
            mineConsumer = Task.detached { [weak self] in
                for await packet in mineStream {
                    if let barrier = packet.barrier { barrier.resume(); continue }
                    do {
                        try await archive.append(packet.samples, source: .me, capturedAt: packet.capturedAt)
                    } catch {
                        await self?.reportArchiveError(error.localizedDescription)
                    }
                    await mineTranscriber.append(packet.samples, capturedAt: packet.capturedAt)
                }
            }
            othersConsumer = Task.detached { [weak self] in
                for await packet in othersStream {
                    if let barrier = packet.barrier { barrier.resume(); continue }
                    do {
                        try await archive.append(packet.samples, source: .others, capturedAt: packet.capturedAt)
                    } catch {
                        await self?.reportArchiveError(error.localizedDescription)
                    }
                    await othersTranscriber.append(packet.samples, capturedAt: packet.capturedAt)
                }
            }
            try await capture.start(
                scope: scope,
                captureMicrophone: captureMicrophone,
                onSamples: { source, samples, capturedAt in
                    let packet = AudioPacket(samples: samples, capturedAt: capturedAt)
                    if source == .me {
                        mineSink.yield(packet)
                    } else {
                        othersSink.yield(packet)
                    }
                },
                onError: { [weak self] error in
                    Task { @MainActor [weak self] in
                        self?.errorMessage = "音频采集已停止：\(error.localizedDescription)"
                    }
                }
            )
            isMicrophoneEnabled = captureMicrophone
            refreshCapturePermissions()
            await reloadHistory()
            startAnalysisLoop()
        } catch {
            await stopAudioConsumers()
            await audioArchive?.close()
            audioArchive = nil
            isMicrophoneEnabled = false
            refreshCapturePermissions()
            activeMeetingID = nil
            if var failedRecord = document?.record {
                failedRecord.status = .finished
                failedRecord.endedAt = Date()
                try? await store.update(failedRecord)
                document?.record = failedRecord
            }
            errorMessage = "无法开始会议：\(error.localizedDescription)"
        }
    }

    func togglePause() async {
        guard var current = document?.record, current.id == activeMeetingID else { return }
        if current.status == .paused {
            capture.setPaused(false)
            if isMicrophoneEnabled {
                do {
                    try await capture.setMicrophoneEnabled(true)
                } catch {
                    isMicrophoneEnabled = false
                    errorMessage = "无法开启麦克风：\(error.localizedDescription)"
                }
            }
            current.status = .active
        } else {
            capture.setPaused(true)
            if isMicrophoneEnabled { try? await capture.setMicrophoneEnabled(false) }
            await drainAudioConsumers()
            async let mine: Void = mineTranscriber?.finish() ?? ()
            async let others: Void = othersTranscriber?.finish() ?? ()
            _ = await (mine, others)
            await mineTranscriber?.reset()
            await othersTranscriber?.reset()
            current.status = .paused
        }
        document?.record = current
        try? await store.update(current)
    }

    func toggleMicrophone() async {
        guard let current = document?.record,
              current.id == activeMeetingID,
              current.status == .active else { return }
        let shouldEnable = !isMicrophoneEnabled
        do {
            if shouldEnable { await mineTranscriber?.reset() }
            try await capture.setMicrophoneEnabled(shouldEnable)
            isMicrophoneEnabled = shouldEnable
            if !shouldEnable {
                await drainAudioConsumers()
                await mineTranscriber?.finish()
                await mineTranscriber?.reset()
                partialText[.me] = nil
            }
            refreshCapturePermissions()
        } catch {
            isMicrophoneEnabled = false
            refreshCapturePermissions()
            errorMessage = "无法开启麦克风：\(error.localizedDescription)"
        }
    }

    func endMeeting() async {
        guard var current = document?.record, current.id == activeMeetingID else { return }
        guard !isFinalizing else { return }
        isFinalizing = true
        defer { isFinalizing = false }
        let previousAnalysisTask = analysisTask
        previousAnalysisTask?.cancel()
        analysisTask = nil
        await capture.stop()
        await stopAudioConsumers()
        async let mine: Void = mineTranscriber?.finish() ?? ()
        async let others: Void = othersTranscriber?.finish() ?? ()
        _ = await (mine, others)
        await previousAnalysisTask?.value
        while isAnalyzing {
            try? await Task.sleep(for: .milliseconds(100))
        }
        await reviewEntireMeeting()
        await audioArchive?.close()
        audioArchive = nil
        await refineNewTranscript(force: true)
        await runFinalAnalysis()
        current.status = .finished
        current.endedAt = Date()
        document?.record = current
        try? await store.update(current)
        activeMeetingID = nil
        isMicrophoneEnabled = false
        partialText = [:]
        await mineTranscriber?.reset()
        await othersTranscriber?.reset()
        await reloadHistory()
    }

    private func stopAudioConsumers() async {
        mineContinuation?.finish()
        othersContinuation?.finish()
        mineContinuation = nil
        othersContinuation = nil
        await mineConsumer?.value
        await othersConsumer?.value
        mineConsumer = nil
        othersConsumer = nil
    }

    private func drainAudioConsumers() async {
        if let mineContinuation {
            await withCheckedContinuation { continuation in
                mineContinuation.yield(AudioPacket(samples: [], capturedAt: 0, barrier: continuation))
            }
        }
        if let othersContinuation {
            await withCheckedContinuation { continuation in
                othersContinuation.yield(AudioPacket(samples: [], capturedAt: 0, barrier: continuation))
            }
        }
    }

    private func reportArchiveError(_ message: String) {
        guard !reportedArchiveError else { return }
        reportedArchiveError = true
        errorMessage = "临时音频写入失败，全程复核可能不可用；实时转写仍继续：\(message)"
    }

    func renameCurrentMeeting(_ title: String) async {
        guard let current = document?.record else { return }
        await updateMeeting(current.id, title: title, category: current.category)
    }

    func updateMeeting(_ id: UUID, title: String, category: String?) async {
        guard var current = meetings.first(where: { $0.id == id }) ?? (document?.record.id == id ? document?.record : nil) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        current.title = trimmed
        let trimmedCategory = category?.trimmingCharacters(in: .whitespacesAndNewlines)
        current.category = trimmedCategory?.isEmpty == false ? trimmedCategory : nil
        if document?.record.id == id { document?.record = current }
        do {
            try await store.update(current)
            await reloadHistory()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func moveMeetingToTrash(_ id: UUID) async {
        guard id != activeMeetingID else {
            errorMessage = "请先结束会议，再删除记录"
            return
        }
        do {
            try await store.moveToTrash(id)
            if document?.record.id == id { document = nil }
            await reloadHistory()
        } catch {
            errorMessage = "无法将会议移到废纸篓：\(error.localizedDescription)"
        }
    }

    func moveMeetings(_ ids: Set<UUID>, toCategory category: String?) async {
        let trimmed = category?.trimmingCharacters(in: .whitespacesAndNewlines)
        let destination = trimmed?.isEmpty == false ? trimmed : nil
        do {
            for var meeting in meetings where ids.contains(meeting.id) {
                meeting.category = destination
                try await store.update(meeting)
                if document?.record.id == meeting.id { document?.record = meeting }
            }
            await reloadHistory()
        } catch {
            errorMessage = "无法移动会议记录：\(error.localizedDescription)"
        }
    }

    func moveMeetingsToTrash(_ ids: Set<UUID>) async {
        guard activeMeetingID.map({ !ids.contains($0) }) ?? true else {
            errorMessage = "请先结束会议，再删除记录"
            return
        }
        do {
            for id in ids { try await store.moveToTrash(id) }
            if let currentID = document?.record.id, ids.contains(currentID) { document = nil }
            await reloadHistory()
        } catch {
            errorMessage = "无法将会议移到废纸篓：\(error.localizedDescription)"
        }
    }

    func runAnalysis(force: Bool = false) async {
        guard !isFinalizing, !analysisGate.isRunning else { return }
        guard let currentDocument = document else { return }
        let newSegments = analysisGate.beginIfNeeded(segments: currentDocument.transcript, force: force)
        guard !newSegments.isEmpty else {
            analysisGate.fail()
            return
        }
        guard let configuration = configuredLLM(), !KeychainStore.readAPIKey().isEmpty else {
            analysisGate.fail()
            if force || analysisError == nil { analysisError = "请先在设置中配置分析 API" }
            return
        }
        isAnalyzing = true
        defer { isAnalyzing = false }
        do {
            let result = try await llmClient.analyze(
                configuration: configuration,
                apiKey: KeychainStore.readAPIKey(),
                previous: currentDocument.analysis,
                newSegments: newSegments
            )
            if var latest = document, latest.record.id == currentDocument.record.id {
                latest.analysis = result
                document = latest
            }
            analysisGate.finish(lastProcessedSegmentID: result.lastProcessedSegmentID)
            analysisError = nil
            try await store.save(result, meetingID: currentDocument.record.id)
        } catch {
            analysisGate.fail()
            analysisError = error.localizedDescription
            if let diagnostic = (error as? LLMError)?.diagnosticResponse {
                if var latest = document, latest.record.id == currentDocument.record.id {
                    latest.analysis.diagnosticResponse = diagnostic
                    document = latest
                    try? await store.save(latest.analysis, meetingID: latest.record.id)
                }
            }
        }
    }

    private func runFinalAnalysis() async {
        guard let latest = document, !latest.transcript.isEmpty else { return }
        guard let configuration = configuredLLM(), !KeychainStore.readAPIKey().isEmpty else {
            analysisError = "请先在设置中配置分析 API；本地转写已保存"
            return
        }
        isAnalyzing = true
        defer { isAnalyzing = false }
        var snapshot = AnalysisSnapshot()
        let segments = latest.transcript
        for start in stride(from: 0, to: segments.count, by: 30) {
            let batch = Array(segments[start..<min(start + 30, segments.count)])
            do {
                snapshot = try await llmClient.analyze(
                    configuration: configuration,
                    apiKey: KeychainStore.readAPIKey(),
                    previous: snapshot,
                    newSegments: batch
                )
                try await store.save(snapshot, meetingID: latest.record.id)
                if var current = document, current.record.id == latest.record.id {
                    current.analysis = snapshot
                    document = current
                }
            } catch {
                analysisError = "会议结束分析未完成：\(error.localizedDescription)"
                analysisGate = AnalysisRequestGate(lastProcessedSegmentID: snapshot.lastProcessedSegmentID)
                return
            }
        }
        analysisGate = AnalysisRequestGate(lastProcessedSegmentID: snapshot.lastProcessedSegmentID)
        analysisError = nil
    }

    private func refineNewTranscript(force: Bool = false) async {
        guard force || Date() >= nextRefinementAttempt else { return }
        guard let configuration = configuredLLM(), !KeychainStore.readAPIKey().isEmpty else { return }
        let apiKey = KeychainStore.readAPIKey()
        repeat {
            guard let snapshot = document else { return }
            let targets = Array(snapshot.transcript.filter { !refinedSegmentIDs.contains($0.id) }.prefix(20))
            guard !targets.isEmpty else { return }
            let firstTargetTime = targets[0].startTime
            let context = Array(snapshot.transcript.filter { $0.startTime < firstTargetTime }.suffix(5))
            do {
                let revisions = try await llmClient.refineTranscript(
                    configuration: configuration,
                    apiKey: apiKey,
                    context: context,
                    targets: targets
                )
                guard var latest = document, latest.record.id == snapshot.record.id else { return }
                for index in latest.transcript.indices {
                    let id = latest.transcript[index].id
                    guard let corrected = revisions[id], corrected != latest.transcript[index].text else { continue }
                    latest.transcript[index].text = corrected
                    try await store.append(latest.transcript[index], meetingID: latest.record.id)
                }
                document = latest
                refinedSegmentIDs.formUnion(targets.map(\.id))
                nextRefinementAttempt = .distantPast
            } catch {
                analysisError = "转写语义校订暂不可用，已保留本地原文：\(error.localizedDescription)"
                nextRefinementAttempt = Date().addingTimeInterval(60)
                return
            }
        } while force
    }

    private func reviewEntireMeeting() async {
        guard !reportedArchiveError else { return }
        guard let archive = audioArchive,
              let mineTranscriber, let othersTranscriber,
              var latest = document else { return }
        var replacements: [SpeakerSource: [TranscriptSegment]] = [:]
        for (source, transcriber) in [(SpeakerSource.me, mineTranscriber), (.others, othersTranscriber)] {
            do {
                let words = try await archive.review(source: source, with: transcriber, meetingStart: meetingStartUptime)
                let reviewed = Self.groupReviewedWords(words)
                let existing = latest.transcript.filter { $0.source == source }
                let oldLength = existing.reduce(0) { $0 + $1.text.count }
                let newLength = reviewed.reduce(0) { $0 + $1.text.count }
                if !reviewed.isEmpty && (oldLength == 0 ||
                    (newLength >= oldLength / 2 && newLength <= oldLength * 5 / 2)) {
                    replacements[source] = reviewed
                }
            } catch {
                errorMessage = "\(source.displayName)的全程复核失败，已保留实时转写：\(error.localizedDescription)"
            }
        }
        guard !replacements.isEmpty else { return }
        latest.transcript = latest.transcript.filter { replacements[$0.source] == nil }
            + replacements.values.flatMap { $0 }
        latest.transcript.sort { $0.startTime < $1.startTime }
        do {
            try await store.replaceTranscript(latest.transcript, meetingID: latest.record.id)
            document = latest
            refinedSegmentIDs = []
        } catch {
            errorMessage = "全程复核结果保存失败，已保留实时转写：\(error.localizedDescription)"
        }
    }

    private static func groupReviewedWords(_ words: [TranscriptSegment]) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        var current: TranscriptSegment?
        for word in words.sorted(by: { $0.startTime < $1.startTime }) {
            if var segment = current,
               segment.source == word.source,
               word.startTime - segment.endTime < 0.9,
               word.endTime - segment.startTime < 12,
               segment.text.count < 150 {
                segment.text += word.text
                segment.endTime = max(segment.endTime, word.endTime)
                current = segment
            } else {
                if var segment = current {
                    segment.text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !segment.text.isEmpty { result.append(segment) }
                }
                current = word
            }
        }
        if var segment = current {
            segment.text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !segment.text.isEmpty { result.append(segment) }
        }
        return result
    }

    func ask(_ question: String) async {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isAnswering, var currentDocument = document else { return }
        guard let configuration = configuredLLM(), !KeychainStore.readAPIKey().isEmpty else {
            errorMessage = "请先在设置中配置分析 API"
            return
        }
        var item = QuestionAnswer(question: question)
        currentDocument.questions.append(item)
        document = currentDocument
        isAnswering = true
        defer { isAnswering = false }

        do {
            let stream = try await llmClient.answerStream(
                configuration: configuration,
                apiKey: KeychainStore.readAPIKey(),
                question: question,
                analysis: currentDocument.analysis,
                transcript: currentDocument.transcript,
                history: Array(currentDocument.questions.dropLast())
            )
            for try await chunk in stream {
                item.answer += chunk
                updateQuestion(item)
            }
            item.status = .completed
        } catch {
            item.status = .failed
            if item.answer.isEmpty { item.answer = "请求失败：\(error.localizedDescription)" }
        }
        updateQuestion(item)
        try? await store.append(item, meetingID: currentDocument.record.id)
    }

    func testAPI(baseURL: String, model: String, apiKey: String) async {
        guard let configuration = makeConfiguration(baseURL: baseURL, model: model) else {
            settingsStatus = "Base URL 或模型名无效"
            return
        }
        settingsStatus = "正在测试…"
        do {
            try await llmClient.testConnection(configuration: configuration, apiKey: apiKey)
            settingsStatus = "连接成功"
        } catch {
            settingsStatus = error.localizedDescription
        }
    }

    func saveAPISettings(baseURL: String, model: String, apiKey: String) {
        guard makeConfiguration(baseURL: baseURL, model: model) != nil else {
            settingsStatus = "Base URL 或模型名无效"
            return
        }
        UserDefaults.standard.set(baseURL, forKey: "llm.baseURL")
        UserDefaults.standard.set(model, forKey: "llm.model")
        do {
            try KeychainStore.saveAPIKey(apiKey)
            settingsStatus = "设置已保存"
        } catch {
            settingsStatus = error.localizedDescription
        }
    }

    func exportCurrentMeeting() async {
        guard let record = document?.record else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = sanitizedFilename(record.title) + ".md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try await store.exportMarkdown(for: record.id, to: url)
        } catch {
            errorMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    func exportTranscript(as format: TranscriptExportFormat) async {
        guard let record = document?.record else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = format == .srt
            ? [UTType(filenameExtension: "srt") ?? .plainText] : [.plainText]
        let suffix = format == .srt ? ".srt" : ".txt"
        panel.nameFieldStringValue = sanitizedFilename(record.title) + suffix
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try await store.exportTranscript(for: record.id, to: url, as: format)
        } catch {
            errorMessage = "转写导出失败：\(error.localizedDescription)"
        }
    }

    func openPrivacySettings(_ pane: PrivacySettingsPane) {
        let anchor = switch pane {
        case .screenRecording: "Privacy_ScreenCapture"
        case .microphone: "Privacy_Microphone"
        }
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
        NSWorkspace.shared.open(url)
    }

    private func handle(_ event: TranscriptionEvent) async {
        guard var currentDocument = document,
              currentDocument.record.id == activeMeetingID else { return }
        let start = max(0, event.startTime - meetingStartUptime)
        let end = max(start, event.endTime - meetingStartUptime)
        if !event.isFinal {
            partialText[event.source] = LiveTranscript(text: event.text, startTime: start)
            return
        }
        let previous = currentDocument.transcript
            .filter { $0.source == event.source && $0.endTime <= start + 0.2 }
            .max(by: { $0.endTime < $1.endTime })
        let text = TranscriptAlgorithms.removeOverlap(
            previous: previous.flatMap { start - $0.endTime < 3 ? $0.text : nil },
            from: event.text
        )
        partialText[event.source] = nil
        guard !text.isEmpty else { return }
        let segment = TranscriptSegment(
            startTime: start,
            endTime: end,
            source: event.source,
            text: text,
            isFinal: true
        )
        currentDocument.transcript.append(segment)
        currentDocument.transcript.sort { $0.startTime < $1.startTime }
        document = currentDocument
        do {
            try await store.append(segment, meetingID: currentDocument.record.id)
        } catch {
            errorMessage = "保存转写失败：\(error.localizedDescription)"
        }
    }

    private func updateQuestion(_ item: QuestionAnswer) {
        guard var current = document,
              let index = current.questions.firstIndex(where: { $0.id == item.id }) else { return }
        current.questions[index] = item
        document = current
    }

    private func startAnalysisLoop() {
        analysisTask?.cancel()
        analysisTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                await self?.refineNewTranscript()
                tick += 1
                if tick.isMultiple(of: 3) { await self?.runAnalysis() }
            }
        }
    }

    private func configuredLLM() -> LLMConfiguration? {
        makeConfiguration(
            baseURL: UserDefaults.standard.string(forKey: "llm.baseURL") ?? "https://api.openai.com/v1",
            model: UserDefaults.standard.string(forKey: "llm.model") ?? ""
        )
    }

    private func makeConfiguration(baseURL: String, model: String) -> LLMConfiguration? {
        guard let url = URL(string: baseURL),
              let scheme = url.scheme,
              ["http", "https"].contains(scheme),
              url.host != nil,
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return LLMConfiguration(baseURL: url, model: model.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func defaultMeetingTitle() -> String {
        "会议 \(Date().formatted(date: .abbreviated, time: .shortened))"
    }

    private func sanitizedFilename(_ value: String) -> String {
        value.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }
}

enum PrivacySettingsPane {
    case screenRecording
    case microphone
}
