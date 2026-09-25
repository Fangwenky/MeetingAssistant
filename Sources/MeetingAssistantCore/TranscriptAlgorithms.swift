import Foundation

public enum TranscriptAlgorithms {
    public static func stablePrefixLength(previous: [String], current: [String]) -> Int {
        var count = 0
        for (left, right) in zip(previous, current) {
            guard left == right else { break }
            count += 1
        }
        return count
    }

    public static func removeOverlap(previous: String?, from candidate: String) -> String {
        let candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let previousValue = previous else { return candidate }
        let previous = previousValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !previous.isEmpty, !candidate.isEmpty else { return candidate }
        if previous == candidate || previous.hasSuffix(candidate) { return "" }
        if candidate.hasPrefix(previous) {
            return String(candidate.dropFirst(previous.count)).trimmingCharacters(in: .whitespaces)
        }

        let previousCharacters = Array(previous)
        let candidateCharacters = Array(candidate)
        let maximum = min(previousCharacters.count, candidateCharacters.count)
        guard maximum >= 2 else { return candidate }

        for length in stride(from: maximum, through: 2, by: -1) {
            if previousCharacters.suffix(length).elementsEqual(candidateCharacters.prefix(length)) {
                return String(candidateCharacters.dropFirst(length)).trimmingCharacters(in: .whitespaces)
            }
        }
        let previousNormalized = normalized(previous).map(\.0)
        let candidateNormalized = normalized(candidate)
        let candidateLetters = candidateNormalized.map(\.0)
        let normalizedMaximum = min(previousNormalized.count, candidateLetters.count)
        if normalizedMaximum >= 3 {
            for length in stride(from: normalizedMaximum, through: 3, by: -1) {
                if previousNormalized.suffix(length).elementsEqual(candidateLetters.prefix(length)) {
                    let consumedCharacterIndex = candidateNormalized[length - 1].1
                    return String(candidateCharacters.dropFirst(consumedCharacterIndex + 1))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return candidate
    }

    private static func normalized(_ text: String) -> [(Character, Int)] {
        Array(text).enumerated().flatMap { index, character in
            character.lowercased().filter { $0.isLetter || $0.isNumber }.map { ($0, index) }
        }
    }

    public static func context(
        question: String,
        transcript: [TranscriptSegment],
        recentWindow: TimeInterval = 15 * 60,
        olderLimit: Int = 10
    ) -> String {
        let finalSegments = transcript.filter(\.isFinal).sorted { $0.startTime < $1.startTime }
        guard let latestTime = finalSegments.last?.endTime else { return "" }
        let cutoff = max(0, latestTime - recentWindow)
        let recent = finalSegments.filter { $0.endTime >= cutoff }
        let recentIDs = Set(recent.map(\.id))
        let queryTerms = searchTerms(in: question)

        let older = finalSegments
            .filter { !recentIDs.contains($0.id) }
            .map { segment in
                let terms = searchTerms(in: segment.text)
                return (segment, queryTerms.intersection(terms).count)
            }
            .filter { $0.1 > 0 }
            .sorted {
                if $0.1 == $1.1 { return $0.0.startTime > $1.0.startTime }
                return $0.1 > $1.1
            }
            .prefix(olderLimit)
            .map(\.0)
            .sorted { $0.startTime < $1.startTime }

        return (older + recent).map(format).joined(separator: "\n")
    }

    public static func format(_ segment: TranscriptSegment) -> String {
        "[\(timestamp(segment.startTime))] \(segment.source.displayName)：\(segment.text)"
    }

    public static func timestamp(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    private static func searchTerms(in text: String) -> Set<String> {
        let lowered = text.lowercased()
        let words = lowered
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
        let cjk = Array(lowered.unicodeScalars.filter {
            (0x3400...0x9FFF).contains(Int($0.value))
        }).map(String.init)
        let bigrams = zip(cjk, cjk.dropFirst()).map { $0 + $1 }
        return Set(words + cjk + bigrams)
    }
}

public struct AnalysisRequestGate: Sendable {
    public private(set) var isRunning = false
    public private(set) var lastProcessedSegmentID: UUID?
    private var processedIDs: Set<UUID> = []
    private var pendingIDs: Set<UUID> = []
    private var initializedFromCursor = false

    public init(lastProcessedSegmentID: UUID? = nil) {
        self.lastProcessedSegmentID = lastProcessedSegmentID
    }

    public mutating func beginIfNeeded(segments: [TranscriptSegment], force: Bool = false) -> [TranscriptSegment] {
        guard !isRunning else { return [] }
        let finalSegments = segments.filter(\.isFinal)
        if !initializedFromCursor {
            if let id = lastProcessedSegmentID,
               let index = finalSegments.firstIndex(where: { $0.id == id }) {
                processedIDs.formUnion(finalSegments.prefix(index + 1).map(\.id))
            }
            initializedFromCursor = true
        }
        let newSegments = finalSegments.filter { !processedIDs.contains($0.id) }
        guard !newSegments.isEmpty || force else { return [] }
        isRunning = true
        pendingIDs = Set(newSegments.map(\.id))
        return newSegments
    }

    public mutating func finish(lastProcessedSegmentID: UUID?) {
        isRunning = false
        processedIDs.formUnion(pendingIDs)
        pendingIDs.removeAll()
        if let lastProcessedSegmentID { self.lastProcessedSegmentID = lastProcessedSegmentID }
    }

    public mutating func fail() {
        isRunning = false
        pendingIDs.removeAll()
    }
}
