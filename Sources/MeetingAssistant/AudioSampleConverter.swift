@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import Foundation

final class AudioSampleConverter: @unchecked Sendable {
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!
    private var sourceFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    func convert(_ sampleBuffer: CMSampleBuffer) throws -> [Float] {
        guard sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer),
              let description = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return []
        }
        let inputFormat = AVAudioFormat(cmAudioFormatDescription: description)
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount) else {
            return []
        }
        inputBuffer.frameLength = frameCount
        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: inputBuffer.mutableAudioBufferList
        )
        guard copyStatus == noErr else { throw AudioConversionError.copyFailed(copyStatus) }

        if sourceFormat != inputFormat {
            sourceFormat = inputFormat
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        }
        guard let converter else { throw AudioConversionError.unsupportedFormat }
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(ceil(Double(frameCount) * ratio)) + 32
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
            throw AudioConversionError.unsupportedFormat
        }

        let inputState = InputState()
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outputStatus in
            if inputState.supplied {
                outputStatus.pointee = .noDataNow
                return nil
            }
            inputState.supplied = true
            outputStatus.pointee = .haveData
            return inputBuffer
        }
        guard status != .error, conversionError == nil,
              let channel = outputBuffer.floatChannelData?[0] else {
            throw conversionError ?? AudioConversionError.unsupportedFormat
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(outputBuffer.frameLength)))
    }
}

private final class InputState: @unchecked Sendable {
    var supplied = false
}

enum AudioConversionError: LocalizedError {
    case copyFailed(OSStatus)
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case let .copyFailed(status): "读取音频缓冲失败（\(status)）"
        case .unsupportedFormat: "不支持当前音频格式"
        }
    }
}
