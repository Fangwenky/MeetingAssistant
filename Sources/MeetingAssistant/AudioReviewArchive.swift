import Foundation
import MeetingAssistantCore

/// Unlinked scratch files retain audio only while this process is alive.
actor AudioReviewArchive {
    private var handles: [SpeakerSource: FileHandle] = [:]
    private let sampleRate = 16_000

    init() throws {
        for source in SpeakerSource.allCases {
            let url = FileManager.default.temporaryDirectory.appending(path: "MeetingAssistant-\(UUID().uuidString).pcm")
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let handle = try FileHandle(forUpdating: url)
            try FileManager.default.removeItem(at: url)
            handles[source] = handle
        }
    }

    func append(_ samples: [Float], source: SpeakerSource, capturedAt: TimeInterval) throws {
        guard let handle = handles[source], !samples.isEmpty else { return }
        var time = capturedAt.bitPattern.littleEndian
        var count = UInt32(samples.count).littleEndian
        let pcm = samples.map { sample in
            Int16((max(-1, min(1, sample)) * 32_767).rounded()).littleEndian
        }
        try withUnsafeBytes(of: &time) { try handle.write(contentsOf: $0) }
        try withUnsafeBytes(of: &count) { try handle.write(contentsOf: $0) }
        try pcm.withUnsafeBytes { try handle.write(contentsOf: $0) }
    }

    func review(source: SpeakerSource, with transcriber: WhisperChannelTranscriber, meetingStart: TimeInterval) async throws -> [TranscriptSegment] {
        guard let handle = handles[source] else { return [] }
        try handle.seek(toOffset: 0)
        var samples: [Float] = []
        var bufferStart: TimeInterval?
        var output: [TranscriptSegment] = []
        let windowCount = sampleRate * 20
        let strideCount = sampleRate * 18
        var acceptedThrough: TimeInterval = -.infinity

        while true {
            let header = try handle.read(upToCount: 12) ?? Data()
            if header.isEmpty { break }
            guard header.count == 12 else { throw ArchiveError.truncated }
            let timeBits = UInt64(littleEndian: header.prefix(8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) })
            let count = Int(UInt32(littleEndian: header.dropFirst(8).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
            guard count > 0, count <= 1_000_000 else { throw ArchiveError.truncated }
            let data = try handle.read(upToCount: count * 2) ?? Data()
            guard data.count == count * 2 else { throw ArchiveError.truncated }
            let end = Double(bitPattern: timeBits)
            let chunkStart = end - Double(count) / Double(sampleRate)
            if let start = bufferStart, chunkStart - (start + Double(samples.count) / Double(sampleRate)) > 0.3 {
                if !samples.isEmpty {
                    if hasSpeech(samples) {
                        let words = try await transcriber.review(samples: samples, startTime: max(0, start - meetingStart))
                        output += words.filter { $0.startTime >= acceptedThrough - 0.08 }
                    }
                }
                samples.removeAll(keepingCapacity: true)
                bufferStart = nil
                acceptedThrough = -.infinity
            }
            if bufferStart == nil { bufferStart = chunkStart }
            let pcm: [Int16] = data.withUnsafeBytes { raw in
                (0..<count).map { Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self)) }
            }
            samples.append(contentsOf: pcm.map { Float($0) / 32_767 })
            while samples.count >= windowCount, let start = bufferStart {
                let cutoff = start - meetingStart + 19
                let window = Array(samples.prefix(windowCount))
                if hasSpeech(window) {
                    let words = try await transcriber.review(samples: window, startTime: max(0, start - meetingStart))
                    output += words.filter { $0.startTime >= acceptedThrough - 0.08 && $0.startTime < cutoff }
                }
                acceptedThrough = cutoff
                samples.removeFirst(strideCount)
                bufferStart = start + 18
            }
        }
        if let start = bufferStart, !samples.isEmpty {
            if hasSpeech(samples) {
                let words = try await transcriber.review(samples: samples, startTime: max(0, start - meetingStart))
                output += words.filter { $0.startTime >= acceptedThrough - 0.08 }
            }
        }
        return output.sorted { $0.startTime < $1.startTime }
    }

    private func hasSpeech(_ samples: [Float]) -> Bool {
        for start in stride(from: 0, to: samples.count, by: sampleRate) {
            let part = samples[start..<min(start + sampleRate, samples.count)]
            let energy = part.reduce(Float.zero) { $0 + $1 * $1 } / Float(part.count)
            if sqrt(energy) >= 0.004 { return true }
        }
        return false
    }

    func close() {
        for handle in handles.values { try? handle.close() }
        handles.removeAll()
    }
}

private enum ArchiveError: LocalizedError {
    case truncated
    var errorDescription: String? { "临时音频不完整，无法执行全程复核" }
}
