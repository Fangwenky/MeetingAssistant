import Foundation

public actor LLMClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func analyze(
        configuration: LLMConfiguration,
        apiKey: String,
        previous: AnalysisSnapshot,
        newSegments: [TranscriptSegment]
    ) async throws -> AnalysisSnapshot {
        let previousData = try JSONEncoder().encode(previous)
        let previousJSON = String(decoding: previousData, as: UTF8.self)
        let transcript = newSegments.map(TranscriptAlgorithms.format).joined(separator: "\n")
        let messages = [
            ChatMessage(role: "system", content: Self.analysisSystemPrompt),
            ChatMessage(
                role: "user",
                content: """
                上一次分析：
                \(previousJSON)

                新增转写：
                \(transcript)
                """
            ),
        ]
        let request = try makeRequest(
            configuration: configuration,
            apiKey: apiKey,
            messages: messages,
            stream: false
        )
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        let envelope = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = envelope.choices.first?.message.content else {
            throw LLMError.emptyResponse
        }
        do {
            return try AnalysisParser.parse(
                content,
                lastProcessedSegmentID: newSegments.last?.id
            )
        } catch {
            throw LLMError.invalidAnalysis(raw: String(content.prefix(2_000)), underlying: error)
        }
    }

    public func refineTranscript(
        configuration: LLMConfiguration,
        apiKey: String,
        context: [TranscriptSegment],
        targets: [TranscriptSegment]
    ) async throws -> [UUID: String] {
        guard !targets.isEmpty else { return [:] }
        let contextText = context.map(TranscriptAlgorithms.format).joined(separator: "\n")
        let targetText = targets.map { "\($0.id.uuidString) | \(TranscriptAlgorithms.format($0))" }.joined(separator: "\n")
        let messages = [
            ChatMessage(role: "system", content: Self.refinementSystemPrompt),
            ChatMessage(role: "user", content: "前文（仅供参考）：\n\(contextText)\n\n需要校订的片段：\n\(targetText)")
        ]
        let request = try makeRequest(configuration: configuration, apiKey: apiKey, messages: messages, stream: false)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        let envelope = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = envelope.choices.first?.message.content else { throw LLMError.emptyResponse }
        let cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = cleaned.firstIndex(of: "{"), let end = cleaned.lastIndex(of: "}") else {
            throw LLMError.invalidTranscriptRevision
        }
        let payload = Data(cleaned[start...end].utf8)
        guard let revisions = try? JSONDecoder().decode(TranscriptRevisionResponse.self, from: payload) else {
            throw LLMError.invalidTranscriptRevision
        }
        let targetsByID = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0) })
        var result: [UUID: String] = [:]
        for revision in revisions.segments {
            guard let id = UUID(uuidString: revision.id), let original = targetsByID[id] else { continue }
            let text = revision.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= max(30, original.text.count * 2) else { continue }
            result[id] = text
        }
        return result
    }

    public func answerStream(
        configuration: LLMConfiguration,
        apiKey: String,
        question: String,
        analysis: AnalysisSnapshot,
        transcript: [TranscriptSegment],
        history: [QuestionAnswer]
    ) throws -> AsyncThrowingStream<String, Error> {
        let analysisData = try JSONEncoder().encode(analysis)
        let context = TranscriptAlgorithms.context(question: question, transcript: transcript)
        var messages = [
            ChatMessage(role: "system", content: Self.questionSystemPrompt),
            ChatMessage(
                role: "system",
                content: "当前分析：\n\(String(decoding: analysisData, as: UTF8.self))\n\n会议转写：\n\(context)"
            ),
        ]
        for item in history.suffix(3) {
            messages.append(ChatMessage(role: "user", content: item.question))
            messages.append(ChatMessage(role: "assistant", content: item.answer))
        }
        messages.append(ChatMessage(role: "user", content: question))
        let request = try makeRequest(
            configuration: configuration,
            apiKey: apiKey,
            messages: messages,
            stream: true
        )
        let session = self.session

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse,
                          (200..<300).contains(http.statusCode) else {
                        throw LLMError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1, "")
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let event = try? JSONDecoder().decode(StreamResponse.self, from: data),
                              let delta = event.choices.first?.delta.content,
                              !delta.isEmpty else { continue }
                        continuation.yield(delta)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func testConnection(configuration: LLMConfiguration, apiKey: String) async throws {
        let request = try makeRequest(
            configuration: configuration,
            apiKey: apiKey,
            messages: [ChatMessage(role: "user", content: "只回答 OK")],
            stream: false
        )
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
    }

    private func makeRequest(
        configuration: LLMConfiguration,
        apiKey: String,
        messages: [ChatMessage],
        stream: Bool
    ) throws -> URLRequest {
        guard !configuration.model.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw LLMError.missingModel
        }
        var request = URLRequest(url: configuration.chatCompletionsURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(
            ChatRequest(model: configuration.model, messages: messages, stream: stream)
        )
        return request
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw LLMError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMError.httpStatus(http.statusCode, String(decoding: data.prefix(2_000), as: UTF8.self))
        }
    }

    private static let analysisSystemPrompt = """
    你是会议分析助手。根据上一次分析和新增转写，返回更新后的完整分析。
    只返回 JSON，不要 Markdown 代码块，格式必须是：
    {"summary":"简洁滚动摘要","decisions":["已确认的决策"],"actionItems":[{"task":"待办","owner":null,"due":null}],"risks":["风险或未决问题"]}
    不要猜测；没有内容的数组返回 []。保留仍有效的既有信息，合并重复项。
    """

    private static let questionSystemPrompt = """
    你是会议内问答助手。只能依据提供的会议转写和分析回答；找不到依据时明确说“会议记录中没有足够信息”。回答简洁，引用相关发言时间。
    """

    private static let refinementSystemPrompt = """
    你是会议转写校订员。依据前后文修正明显错字、断句、专有名词和重复词，不得增添未说出的事实或改变说话人、时间顺序。听不到原音频，不能确定的内容保持原文。每个输入片段保留原 ID，只返回 JSON：{"segments":[{"id":"UUID","text":"校订后的文字"}]}。不要代码块或解释。
    """
}

private struct TranscriptRevisionResponse: Decodable {
    struct Revision: Decodable { var id: String; var text: String }
    var segments: [Revision]
}

private struct ChatMessage: Codable, Sendable {
    var role: String
    var content: String
}

private struct ChatRequest: Codable, Sendable {
    var model: String
    var messages: [ChatMessage]
    var stream: Bool
}

private struct ChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { var content: String }
        var message: Message
    }
    var choices: [Choice]
}

private struct StreamResponse: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable { var content: String? }
        var delta: Delta
    }
    var choices: [Choice]
}

public enum LLMError: LocalizedError {
    case missingModel
    case invalidResponse
    case emptyResponse
    case httpStatus(Int, String)
    case invalidAnalysis(raw: String, underlying: Error)
    case invalidTranscriptRevision

    public var errorDescription: String? {
        switch self {
        case .missingModel: "请先配置模型名称"
        case .invalidResponse: "API 返回了无效响应"
        case .emptyResponse: "API 没有返回内容"
        case let .httpStatus(code, body): "API 请求失败（HTTP \(code)）：\(body)"
        case let .invalidAnalysis(_, error): "分析结果格式错误：\(error.localizedDescription)"
        case .invalidTranscriptRevision: "转写校订格式错误，已保留原文"
        }
    }

    public var diagnosticResponse: String? {
        if case let .invalidAnalysis(raw, _) = self { return raw }
        return nil
    }
}
