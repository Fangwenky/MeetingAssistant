import Foundation
import MeetingAssistantCore
@preconcurrency import WhisperKit

struct TranscriptionEvent: Sendable {
    var source: SpeakerSource
    var text: String
    var startTime: TimeInterval
    var endTime: TimeInterval
    var isFinal: Bool
}

actor WhisperChannelTranscriber {
    typealias EventHandler = @Sendable (TranscriptionEvent) async -> Void
    typealias ErrorHandler = @Sendable (Error) -> Void

    private struct Job: Sendable {
        var samples: [Float]
        var startTime: TimeInterval
        var endTime: TimeInterval
        var utteranceID: Int
        var isFinal: Bool
    }

    private struct RecognizedWord: Sendable {
        var text: String
        var startTime: TimeInterval
        var endTime: TimeInterval

        var normalized: String {
            let value = text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .joined()
            return value.isEmpty ? text.trimmingCharacters(in: .whitespacesAndNewlines) : value
        }
    }

    private struct RecognitionState: Sendable {
        var committedThrough: TimeInterval
        var previousWords: [RecognizedWord] = []
    }

    private let source: SpeakerSource
    private let whisper: WhisperKit
    private let eventHandler: EventHandler
    private let errorHandler: ErrorHandler
    private let sampleRate = 16_000
    private let voiceThreshold: Float = 0.006
    private let trailingSilenceSamples = 16_000 * 8 / 10
    // A bounded window keeps each live decode cheaper than the incoming audio.
    private let rollingWindowSamples = 16_000 * 10
    private let partialIntervalSamples = 16_000
    private let preRollLimit = 16_000 * 3 / 10
    private let revisionHorizon: TimeInterval = 2.5
    private let minimumStableCharacters = 10

    private var preRoll: [Float] = []
    private var utterance: [Float] = []
    private var currentUtteranceID: Int?
    private var nextUtteranceID = 0
    private var recognitionStates: [Int: RecognitionState] = [:]
    private var latestCaptureTime: TimeInterval = 0
    private var silenceSamples = 0
    private var samplesSinceLastDecode = 0
    private var inferenceRunning = false
    private var pendingFinals: [Job] = []
    private var pendingPartial: Job?
    private var recentConfirmedText = ""

    init(
        source: SpeakerSource,
        whisper: WhisperKit,
        eventHandler: @escaping EventHandler,
        errorHandler: @escaping ErrorHandler
    ) {
        self.source = source
        self.whisper = whisper
        self.eventHandler = eventHandler
        self.errorHandler = errorHandler
    }

    func append(_ samples: [Float], capturedAt: TimeInterval) {
        guard !samples.isEmpty else { return }
        latestCaptureTime = capturedAt
        let rms = Self.rms(samples)
        let hasVoice = rms >= voiceThreshold

        if utterance.isEmpty {
            if !hasVoice {
                appendPreRoll(samples)
                return
            }
            utterance = preRoll + samples
            nextUtteranceID += 1
            currentUtteranceID = nextUtteranceID
            let startTime = max(0, capturedAt - Double(utterance.count) / Double(sampleRate))
            recognitionStates[nextUtteranceID] = RecognitionState(committedThrough: startTime)
            preRoll.removeAll(keepingCapacity: true)
            silenceSamples = 0
            samplesSinceLastDecode = utterance.count
        } else {
            utterance.append(contentsOf: samples)
            samplesSinceLastDecode += samples.count
            silenceSamples = hasVoice ? 0 : silenceSamples + samples.count
        }

        if utterance.count > rollingWindowSamples + partialIntervalSamples {
            utterance.removeFirst(utterance.count - rollingWindowSamples)
        }

        if silenceSamples >= trailingSilenceSamples {
            enqueueFinal()
        } else if samplesSinceLastDecode >= partialIntervalSamples {
            samplesSinceLastDecode = 0
            enqueueLatestPartial()
        }
    }

    func finish() async {
        if !utterance.isEmpty { enqueueFinal() }
        pendingPartial = nil
        while inferenceRunning || !pendingFinals.isEmpty {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    func review(samples: [Float], startTime: TimeInterval) async throws -> [TranscriptSegment] {
        guard !samples.isEmpty else { return [] }
        let options = DecodingOptions(
            language: "zh", temperature: 0, usePrefillPrompt: false,
            detectLanguage: false, skipSpecialTokens: true,
            withoutTimestamps: false, wordTimestamps: true
        )
        let results = try await whisper.transcribe(audioArray: samples, decodeOptions: options)
        return results.flatMap { result in
            result.allWords.map { word in
                TranscriptSegment(
                    startTime: startTime + TimeInterval(word.start),
                    endTime: startTime + TimeInterval(word.end),
                    source: source,
                    text: word.word,
                    isFinal: true
                )
            }
        }.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    func reset() {
        preRoll.removeAll(keepingCapacity: true)
        utterance.removeAll(keepingCapacity: true)
        currentUtteranceID = nil
        latestCaptureTime = 0
        silenceSamples = 0
        samplesSinceLastDecode = 0
        recognitionStates.removeAll(keepingCapacity: true)
        pendingFinals.removeAll(keepingCapacity: true)
        pendingPartial = nil
        recentConfirmedText = ""
    }

    private func enqueueFinal() {
        guard !utterance.isEmpty, let utteranceID = currentUtteranceID else { return }
        let keepTrailing = min(silenceSamples, sampleRate / 5)
        let removeCount = max(0, silenceSamples - keepTrailing)
        let finalSamples = removeCount > 0 ? Array(utterance.dropLast(removeCount)) : utterance
        let endTime = latestCaptureTime - Double(removeCount) / Double(sampleRate)
        let job = Job(
            samples: finalSamples,
            startTime: max(0, endTime - Double(finalSamples.count) / Double(sampleRate)),
            endTime: endTime,
            utteranceID: utteranceID,
            isFinal: true
        )
        utterance.removeAll(keepingCapacity: true)
        currentUtteranceID = nil
        silenceSamples = 0
        samplesSinceLastDecode = 0
        if pendingPartial?.utteranceID == utteranceID { pendingPartial = nil }
        if inferenceRunning {
            pendingFinals.append(job)
        } else {
            start(job)
        }
    }

    private func enqueueLatestPartial() {
        guard let utteranceID = currentUtteranceID, !utterance.isEmpty else { return }
        let job = Job(
            samples: utterance,
            startTime: max(0, latestCaptureTime - Double(utterance.count) / Double(sampleRate)),
            endTime: latestCaptureTime,
            utteranceID: utteranceID,
            isFinal: false
        )
        if inferenceRunning {
            pendingPartial = job
        } else {
            start(job)
        }
    }

    private func start(_ job: Job) {
        inferenceRunning = true
        Task { await decode(job) }
    }

    private func decode(_ job: Job) async {
        do {
            let prompt = String(recentConfirmedText.suffix(160))
            let options = DecodingOptions(
                language: "zh",
                temperature: 0,
                usePrefillPrompt: true,
                detectLanguage: false,
                skipSpecialTokens: true,
                withoutTimestamps: false,
                wordTimestamps: true,
                windowClipTime: job.isFinal ? 0.1 : 0.5,
                promptTokens: prompt.isEmpty ? nil : whisper.tokenizer?.encode(text: prompt)
            )
            let results = try await whisper.transcribe(audioArray: job.samples, decodeOptions: options)
            let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            let words = results.flatMap(\.allWords).map {
                RecognizedWord(
                    text: $0.word,
                    startTime: job.startTime + TimeInterval($0.start),
                    endTime: job.startTime + TimeInterval($0.end)
                )
            }
            await apply(words: words, fallbackText: text, to: job)
        } catch {
            errorHandler(error)
        }
        inferenceRunning = false
        if !pendingFinals.isEmpty {
            let next = pendingFinals.removeFirst()
            start(next)
        } else if let next = pendingPartial {
            pendingPartial = nil
            start(next)
        }
    }

    private func apply(words: [RecognizedWord], fallbackText: String, to job: Job) async {
        guard var state = recognitionStates[job.utteranceID] else { return }
        if words.isEmpty, !job.isFinal {
            await eventHandler(TranscriptionEvent(
                source: source,
                text: fallbackText,
                startTime: job.startTime,
                endTime: job.endTime,
                isFinal: false
            ))
            return
        }
        let currentWords = words.filter { $0.endTime > state.committedThrough + 0.05 }

        if job.isFinal {
            let finalWords = currentWords.isEmpty ? state.previousWords.filter {
                $0.endTime > state.committedThrough + 0.05
            } : currentWords
            let finalText = joined(finalWords).isEmpty && state.committedThrough <= job.startTime + 0.1
                ? fallbackText : joined(finalWords)
            if !finalText.isEmpty { remember(finalText) }
            if !finalText.isEmpty {
                await eventHandler(TranscriptionEvent(
                    source: source,
                    text: finalText,
                    startTime: finalWords.first?.startTime ?? job.startTime,
                    endTime: finalWords.last?.endTime ?? job.endTime,
                    isFinal: true
                ))
            }
            recognitionStates.removeValue(forKey: job.utteranceID)
            return
        }

        let commonCount = TranscriptAlgorithms.stablePrefixLength(
            previous: state.previousWords.map(\.normalized),
            current: currentWords.map(\.normalized)
        )
        let stableDeadline = job.endTime - revisionHorizon
        let oldEnoughCount = currentWords.prefix { $0.endTime <= stableDeadline }.count
        var stableCount = min(commonCount, oldEnoughCount)
        // A shifted rolling window may no longer share a textual prefix. Do not
        // strand a long utterance until its oldest audio falls out of the window.
        if job.endTime - state.committedThrough > 5 {
            stableCount = oldEnoughCount
        }
        let stableCharacters = joined(Array(currentWords.prefix(stableCount))).count
        let stableDuration = currentWords.prefix(stableCount).last.map { $0.endTime - state.committedThrough } ?? 0
        if stableCharacters < minimumStableCharacters && stableDuration < 6 {
            stableCount = 0
        }

        if stableCount > 0 {
            let stableWords = Array(currentWords.prefix(stableCount))
            let stableText = joined(stableWords)
            state.committedThrough = stableWords.last?.endTime ?? state.committedThrough
            remember(stableText)
            await eventHandler(TranscriptionEvent(
                source: source,
                text: stableText,
                startTime: stableWords.first?.startTime ?? job.startTime,
                endTime: stableWords.last?.endTime ?? job.endTime,
                isFinal: true
            ))
        }

        let remaining = Array(currentWords.dropFirst(stableCount))
        state.previousWords = remaining
        recognitionStates[job.utteranceID] = state
        await eventHandler(TranscriptionEvent(
            source: source,
            text: joined(remaining),
            startTime: remaining.first?.startTime ?? job.endTime,
            endTime: remaining.last?.endTime ?? job.endTime,
            isFinal: false
        ))
    }

    private func joined(_ words: [RecognizedWord]) -> String {
        words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func remember(_ text: String) {
        guard !text.isEmpty else { return }
        recentConfirmedText = String((recentConfirmedText + " " + text).suffix(240))
    }

    private func appendPreRoll(_ samples: [Float]) {
        preRoll.append(contentsOf: samples)
        if preRoll.count > preRollLimit {
            preRoll.removeFirst(preRoll.count - preRollLimit)
        }
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Float.zero) { $0 + $1 * $1 }
        return sqrt(sum / Float(samples.count))
    }
}

enum WhisperPipelineFactory {
    static let modelName = "openai_whisper-large-v3-v20240930_turbo_632MB"

    static func make(
        downloadBase: URL,
        eventHandler: @escaping WhisperChannelTranscriber.EventHandler,
        errorHandler: @escaping WhisperChannelTranscriber.ErrorHandler
    ) async throws -> (mine: WhisperChannelTranscriber, others: WhisperChannelTranscriber) {
        try FileManager.default.createDirectory(at: downloadBase, withIntermediateDirectories: true)
        let first = try await WhisperKit(WhisperKitConfig(
            model: modelName,
            downloadBase: downloadBase,
            verbose: false,
            prewarm: true,
            load: true,
            download: true
        ))
        guard let modelFolder = first.modelFolder else { throw WhisperSetupError.missingModelFolder }
        let second = try await WhisperKit(WhisperKitConfig(
            modelFolder: modelFolder.path,
            tokenizerFolder: first.tokenizerFolder,
            verbose: false,
            prewarm: false,
            load: true,
            download: false
        ))
        return (
            WhisperChannelTranscriber(source: .me, whisper: first, eventHandler: eventHandler, errorHandler: errorHandler),
            WhisperChannelTranscriber(source: .others, whisper: second, eventHandler: eventHandler, errorHandler: errorHandler)
        )
    }
}

enum WhisperSetupError: LocalizedError {
    case missingModelFolder

    var errorDescription: String? { "模型下载完成后没有找到模型目录" }
}
