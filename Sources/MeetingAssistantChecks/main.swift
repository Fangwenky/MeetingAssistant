import Foundation
import MeetingAssistantCore

@main
struct MeetingAssistantChecks {
    static func main() async throws {
        precondition(TranscriptAlgorithms.removeOverlap(previous: "今天讨论产品发布", from: "产品发布计划") == "计划")
        precondition(TranscriptAlgorithms.removeOverlap(previous: "hello world", from: "hello world").isEmpty)
        precondition(TranscriptAlgorithms.removeOverlap(previous: "讨论 MainFlow", from: "Main Flow 的效果") == "的效果")
        precondition(TranscriptAlgorithms.stablePrefixLength(
            previous: ["今天", "讨论", "MainFlow"],
            current: ["今天", "讨论", "MeanFlow", "方法"]
        ) == 2)

        let old = TranscriptSegment(id: MockRevisionURLProtocol.targetID, startTime: 0, endTime: 3, source: .others, text: "数据库迁移安排在周五", isFinal: true)
        let recent = TranscriptSegment(startTime: 1_000, endTime: 1_003, source: .me, text: "现在讨论发布", isFinal: true)
        let context = TranscriptAlgorithms.context(question: "数据库什么时候迁移？", transcript: [old, recent])
        precondition(context.contains(old.text) && context.contains(recent.text))

        var gate = AnalysisRequestGate()
        precondition(gate.beginIfNeeded(segments: [old]).count == 1)
        precondition(gate.beginIfNeeded(segments: [old, recent]).isEmpty)
        gate.finish(lastProcessedSegmentID: old.id)
        precondition(gate.beginIfNeeded(segments: [old, recent]) == [recent])
        gate.finish(lastProcessedSegmentID: recent.id)
        let late = TranscriptSegment(startTime: 2, endTime: 4, source: .me, text: "补到前面的发言", isFinal: true)
        precondition(gate.beginIfNeeded(segments: [old, late, recent]) == [late])

        let parsed = try AnalysisParser.parse(
            """
            ```json
            {"summary":"确定发布计划","decisions":["周五上线"],"actionItems":[{"task":"完成测试","owner":"小王","due":"周四"}],"risks":[]}
            ```
            """,
            lastProcessedSegmentID: recent.id
        )
        precondition(parsed.actionItems.first?.owner == "小王")

        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(rootURL: root)
        let meeting = MeetingRecord(title: "测试会议", captureScope: .allSystemAudio, category: "项目 A")
        let legacyEncoder = JSONEncoder()
        var legacyJSON = try JSONSerialization.jsonObject(with: legacyEncoder.encode(meeting)) as! [String: Any]
        legacyJSON.removeValue(forKey: "category")
        let legacyRecord = try JSONDecoder().decode(
            MeetingRecord.self,
            from: JSONSerialization.data(withJSONObject: legacyJSON)
        )
        precondition(legacyRecord.category == nil)
        _ = try await store.create(meeting)
        try await store.append(old, meetingID: meeting.id)
        try await store.append(QuestionAnswer(question: "结论？", answer: "待定", status: .completed), meetingID: meeting.id)
        let loaded = try await store.load(meeting.id)
        precondition(loaded.transcript == [old])
        var revised = old
        revised.text = "数据库迁移定在周五"
        try await store.append(revised, meetingID: meeting.id)
        let revisedLoad = try await store.load(meeting.id)
        precondition(revisedLoad.transcript == [revised])
        try await store.replaceTranscript([recent, revised], meetingID: meeting.id)
        let replacedLoad = try await store.load(meeting.id)
        precondition(replacedLoad.transcript == [revised, recent])
        precondition(loaded.record.category == "项目 A")
        let markdown = try await store.markdown(for: meeting.id)
        precondition(markdown.contains("其他人：数据库迁移定在周五"))
        let srtURL = root.appending(path: "transcript.srt")
        try await store.exportTranscript(for: meeting.id, to: srtURL, as: .srt)
        let srt = try String(contentsOf: srtURL, encoding: .utf8)
        precondition(srt.contains("00:00:00,000 --> 00:00:03,000"))

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockAnalysisURLProtocol.self]
        let client = LLMClient(session: URLSession(configuration: sessionConfiguration))
        let llmConfiguration = LLMConfiguration(baseURL: URL(string: "https://example.test/v1")!, model: "test-model")
        let analysis = try await client.analyze(
            configuration: llmConfiguration,
            apiKey: "secret",
            previous: .init(),
            newSegments: [old]
        )
        precondition(analysis.summary == "测试摘要")
        let revisionSession = URLSessionConfiguration.ephemeral
        revisionSession.protocolClasses = [MockRevisionURLProtocol.self]
        let revisionClient = LLMClient(session: URLSession(configuration: revisionSession))
        let corrections = try await revisionClient.refineTranscript(
            configuration: llmConfiguration,
            apiKey: "secret",
            context: [],
            targets: [old]
        )
        precondition(corrections[old.id] == "数据库迁移定在周五")
        let streamConfiguration = URLSessionConfiguration.ephemeral
        streamConfiguration.protocolClasses = [MockStreamURLProtocol.self]
        let streamClient = LLMClient(session: URLSession(configuration: streamConfiguration))
        let stream = try await streamClient.answerStream(
            configuration: llmConfiguration,
            apiKey: "secret",
            question: "结论？",
            analysis: analysis,
            transcript: [old],
            history: []
        )
        var streamedAnswer = ""
        for try await chunk in stream { streamedAnswer += chunk }
        precondition(streamedAnswer == "测试答案")

        print("All MeetingAssistant checks passed")
    }
}

private final class MockRevisionURLProtocol: URLProtocol, @unchecked Sendable {
    static let targetID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let uuid = Self.targetID.uuidString
        let content = #"{"segments":[{"id":"\#(uuid)","text":"数据库迁移定在周五"}]}"#
        let responseBody = try! JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["content": content]]]
        ])
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class MockAnalysisURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let payload = #"{"choices":[{"message":{"content":"{\"summary\":\"测试摘要\",\"decisions\":[],\"actionItems\":[],\"risks\":[]}"}}]}"#
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class MockStreamURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let payload = "data: {\"choices\":[{\"delta\":{\"content\":\"测试答案\"}}]}\n\ndata: [DONE]\n\n"
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
