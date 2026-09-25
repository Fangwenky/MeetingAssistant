import Foundation

public actor MeetingStore {
    public let rootURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(rootURL: URL? = nil) throws {
        let base = rootURL ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appending(path: "MeetingAssistant/Meetings", directoryHint: .isDirectory)
        self.rootURL = base
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    @discardableResult
    public func create(_ record: MeetingRecord) throws -> MeetingDocument {
        let directory = meetingDirectory(record.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try write(record, to: directory.appending(path: "metadata.json"))
        try write(AnalysisSnapshot(), to: directory.appending(path: "analysis.json"))
        return MeetingDocument(record: record)
    }

    public func update(_ record: MeetingRecord) throws {
        try write(record, to: meetingDirectory(record.id).appending(path: "metadata.json"))
    }

    public func moveToTrash(_ id: UUID) throws {
        let directory = meetingDirectory(id)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.trashItem(at: directory, resultingItemURL: nil)
    }

    public func append(_ segment: TranscriptSegment, meetingID: UUID) throws {
        guard segment.isFinal else { return }
        try appendLine(segment, to: meetingDirectory(meetingID).appending(path: "transcript.jsonl"))
    }

    public func replaceTranscript(_ segments: [TranscriptSegment], meetingID: UUID) throws {
        let lineEncoder = JSONEncoder()
        lineEncoder.dateEncodingStrategy = .iso8601
        lineEncoder.outputFormatting = [.sortedKeys]
        let lines = try segments.filter(\.isFinal).map { try lineEncoder.encode($0) + Data([0x0A]) }
        try lines.reduce(into: Data()) { $0.append($1) }
            .write(to: meetingDirectory(meetingID).appending(path: "transcript.jsonl"), options: .atomic)
    }

    public func save(_ analysis: AnalysisSnapshot, meetingID: UUID) throws {
        try write(analysis, to: meetingDirectory(meetingID).appending(path: "analysis.json"))
    }

    public func append(_ question: QuestionAnswer, meetingID: UUID) throws {
        try appendLine(question, to: meetingDirectory(meetingID).appending(path: "qa.jsonl"))
    }

    public func list() throws -> [MeetingRecord] {
        let directories = try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return directories.compactMap { directory in
            try? read(MeetingRecord.self, from: directory.appending(path: "metadata.json"))
        }.sorted { $0.startedAt > $1.startedAt }
    }

    public func load(_ id: UUID) throws -> MeetingDocument {
        let directory = meetingDirectory(id)
        let record = try read(MeetingRecord.self, from: directory.appending(path: "metadata.json"))
        let revisions = try readLines(TranscriptSegment.self, from: directory.appending(path: "transcript.jsonl"))
        var transcriptByID: [UUID: TranscriptSegment] = [:]
        for segment in revisions { transcriptByID[segment.id] = segment }
        let transcript = Array(transcriptByID.values)
        let analysis = (try? read(AnalysisSnapshot.self, from: directory.appending(path: "analysis.json"))) ?? .init()
        let questions = try readLines(QuestionAnswer.self, from: directory.appending(path: "qa.jsonl"))
        return MeetingDocument(
            record: record,
            transcript: transcript.sorted { $0.startTime < $1.startTime },
            analysis: analysis,
            questions: questions
        )
    }

    public func markdown(for id: UUID) throws -> String {
        let document = try load(id)
        let date = document.record.startedAt.formatted(date: .long, time: .shortened)
        var lines = [
            "# \(document.record.title)",
            "",
            "- 时间：\(date)",
            "- 音频范围：\(document.record.captureScope.displayName)",
            "- 分类：\(document.record.category ?? "未分类")",
            "",
            "## 摘要",
            "",
            document.analysis.summary.isEmpty ? "暂无" : document.analysis.summary,
            "",
            "## 决策",
            "",
        ]
        lines.append(contentsOf: bullets(document.analysis.decisions))
        lines += ["", "## 待办", ""]
        lines.append(contentsOf: document.analysis.actionItems.isEmpty ? ["- 暂无"] : document.analysis.actionItems.map {
            let owner = $0.owner.map { "（负责人：\($0)）" } ?? ""
            let due = $0.due.map { "（截止：\($0)）" } ?? ""
            return "- \($0.task)\(owner)\(due)"
        })
        lines += ["", "## 风险", ""]
        lines.append(contentsOf: bullets(document.analysis.risks))
        lines += ["", "## 转写", ""]
        lines.append(contentsOf: document.transcript.map { "- \(TranscriptAlgorithms.format($0))" })
        lines += ["", "## 问答", ""]
        if document.questions.isEmpty {
            lines.append("暂无")
        } else {
            for item in document.questions {
                lines += ["### 问：\(item.question)", "", item.answer, ""]
            }
        }
        return lines.joined(separator: "\n")
    }

    public func exportMarkdown(for id: UUID, to destination: URL) throws {
        try Data(markdown(for: id).utf8).write(to: destination, options: .atomic)
    }

    public func exportTranscript(for id: UUID, to destination: URL, as format: TranscriptExportFormat) throws {
        let segments = try load(id).transcript
        let content: String
        switch format {
        case .plainText:
            content = segments.map(TranscriptAlgorithms.format).joined(separator: "\n")
        case .srt:
            content = segments.enumerated().map { index, segment in
                let start = Self.srtTime(segment.startTime)
                let end = Self.srtTime(max(segment.endTime, segment.startTime + 0.5))
                return "\(index + 1)\n\(start) --> \(end)\n\(segment.source.displayName)：\(segment.text)"
            }.joined(separator: "\n\n")
        }
        try Data(content.utf8).write(to: destination, options: .atomic)
    }

    private static func srtTime(_ interval: TimeInterval) -> String {
        let milliseconds = max(0, Int((interval * 1_000).rounded()))
        return String(format: "%02d:%02d:%02d,%03d", milliseconds / 3_600_000,
                      (milliseconds / 60_000) % 60, (milliseconds / 1_000) % 60,
                      milliseconds % 1_000)
    }

    private func meetingDirectory(_ id: UUID) -> URL {
        rootURL.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try decoder.decode(type, from: Data(contentsOf: url))
    }

    private func appendLine<T: Encodable>(_ value: T, to url: URL) throws {
        let lineEncoder = JSONEncoder()
        lineEncoder.dateEncodingStrategy = .iso8601
        lineEncoder.outputFormatting = [.sortedKeys]
        var data = try lineEncoder.encode(value)
        data.append(0x0A)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    private func readLines<T: Decodable>(_ type: T.Type, from url: URL) throws -> [T] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let contents = try String(contentsOf: url, encoding: .utf8)
        return contents.split(whereSeparator: \.isNewline).compactMap {
            try? decoder.decode(type, from: Data($0.utf8))
        }
    }

    private func bullets(_ values: [String]) -> [String] {
        values.isEmpty ? ["- 暂无"] : values.map { "- \($0)" }
    }
}

public enum TranscriptExportFormat: Sendable, Equatable {
    case plainText
    case srt
}
