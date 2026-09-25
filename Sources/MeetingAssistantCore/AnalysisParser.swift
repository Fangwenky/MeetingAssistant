import Foundation

public enum AnalysisParser {
    private struct Payload: Decodable {
        var summary: String
        var decisions: [String]
        var actionItems: [ActionItem]
        var risks: [String]
    }

    public static func parse(
        _ response: String,
        lastProcessedSegmentID: UUID?,
        now: Date = Date()
    ) throws -> AnalysisSnapshot {
        guard let start = response.firstIndex(of: "{"),
              let end = response.lastIndex(of: "}") else {
            throw ParsingError.noJSONObject
        }
        let data = Data(response[start...end].utf8)
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return AnalysisSnapshot(
            summary: payload.summary,
            decisions: payload.decisions,
            actionItems: payload.actionItems,
            risks: payload.risks,
            updatedAt: now,
            lastProcessedSegmentID: lastProcessedSegmentID
        )
    }

    public enum ParsingError: LocalizedError {
        case noJSONObject

        public var errorDescription: String? { "模型响应中没有找到 JSON 对象" }
    }
}
