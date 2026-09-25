import Foundation

public enum SpeakerSource: String, Codable, Sendable, CaseIterable {
    case me
    case others

    public var displayName: String {
        switch self {
        case .me: "我"
        case .others: "其他人"
        }
    }
}

public enum MeetingStatus: String, Codable, Sendable {
    case active
    case paused
    case finished
}

public enum CaptureScope: Codable, Sendable, Equatable {
    case allSystemAudio
    case application(name: String, bundleIdentifier: String?, processID: Int32)

    public var displayName: String {
        switch self {
        case .allSystemAudio:
            "全部系统声音"
        case let .application(name, _, _):
            name
        }
    }
}

public struct MeetingRecord: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var title: String
    public var startedAt: Date
    public var endedAt: Date?
    public var captureScope: CaptureScope
    public var status: MeetingStatus
    public var category: String?

    public init(
        id: UUID = UUID(),
        title: String,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        captureScope: CaptureScope,
        status: MeetingStatus = .active,
        category: String? = nil
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.captureScope = captureScope
        self.status = status
        self.category = category
    }
}

public struct TranscriptSegment: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var source: SpeakerSource
    public var text: String
    public var isFinal: Bool

    public init(
        id: UUID = UUID(),
        startTime: TimeInterval,
        endTime: TimeInterval,
        source: SpeakerSource,
        text: String,
        isFinal: Bool
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.source = source
        self.text = text
        self.isFinal = isFinal
    }
}

public struct ActionItem: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var task: String
    public var owner: String?
    public var due: String?

    public init(id: UUID = UUID(), task: String, owner: String? = nil, due: String? = nil) {
        self.id = id
        self.task = task
        self.owner = owner
        self.due = due
    }

    private enum CodingKeys: String, CodingKey { case task, owner, due }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        task = try container.decode(String.self, forKey: .task)
        owner = try container.decodeIfPresent(String.self, forKey: .owner)
        due = try container.decodeIfPresent(String.self, forKey: .due)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(task, forKey: .task)
        try container.encodeIfPresent(owner, forKey: .owner)
        try container.encodeIfPresent(due, forKey: .due)
    }
}

public struct AnalysisSnapshot: Codable, Sendable, Equatable {
    public var summary: String
    public var decisions: [String]
    public var actionItems: [ActionItem]
    public var risks: [String]
    public var updatedAt: Date
    public var lastProcessedSegmentID: UUID?
    public var diagnosticResponse: String?

    public init(
        summary: String = "",
        decisions: [String] = [],
        actionItems: [ActionItem] = [],
        risks: [String] = [],
        updatedAt: Date = .distantPast,
        lastProcessedSegmentID: UUID? = nil,
        diagnosticResponse: String? = nil
    ) {
        self.summary = summary
        self.decisions = decisions
        self.actionItems = actionItems
        self.risks = risks
        self.updatedAt = updatedAt
        self.lastProcessedSegmentID = lastProcessedSegmentID
        self.diagnosticResponse = diagnosticResponse
    }
}

public enum QuestionStatus: String, Codable, Sendable {
    case streaming
    case completed
    case failed
}

public struct QuestionAnswer: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var question: String
    public var answer: String
    public var createdAt: Date
    public var status: QuestionStatus

    public init(
        id: UUID = UUID(),
        question: String,
        answer: String = "",
        createdAt: Date = Date(),
        status: QuestionStatus = .streaming
    ) {
        self.id = id
        self.question = question
        self.answer = answer
        self.createdAt = createdAt
        self.status = status
    }
}

public struct LLMConfiguration: Codable, Sendable, Equatable {
    public var baseURL: URL
    public var model: String

    public init(baseURL: URL, model: String) {
        self.baseURL = baseURL
        self.model = model
    }

    public var chatCompletionsURL: URL {
        let normalized = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: normalized + "/chat/completions")!
    }
}

public struct MeetingDocument: Sendable, Equatable {
    public var record: MeetingRecord
    public var transcript: [TranscriptSegment]
    public var analysis: AnalysisSnapshot
    public var questions: [QuestionAnswer]

    public init(
        record: MeetingRecord,
        transcript: [TranscriptSegment] = [],
        analysis: AnalysisSnapshot = .init(),
        questions: [QuestionAnswer] = []
    ) {
        self.record = record
        self.transcript = transcript
        self.analysis = analysis
        self.questions = questions
    }
}
