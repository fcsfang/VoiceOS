import Foundation

public struct EnglishPracticeRequest: Sendable {
    public let attemptID: String
    public let snapshot: EnglishPracticeSnapshot
    public let configuration: ModelConfiguration
    public init(attemptID: String, snapshot: EnglishPracticeSnapshot, configuration: ModelConfiguration) {
        self.attemptID = attemptID; self.snapshot = snapshot; self.configuration = configuration
    }
}
public protocol EnglishPracticeModelPort: Sendable {
    var configuration: ModelConfiguration { get }
    func generate(_ request: EnglishPracticeRequest) async throws -> EnglishPracticeResponse
}
public struct EnglishPracticeResponse: Codable, Sendable {
    public let suggestions: [EnglishSuggestionProposal]
    public let comparisons: [EnglishComparisonProposal]
    public let inputTokens: Int?
    public let outputTokens: Int?
    public init(suggestions: [EnglishSuggestionProposal], comparisons: [EnglishComparisonProposal], inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.suggestions = suggestions; self.comparisons = comparisons; self.inputTokens = inputTokens; self.outputTokens = outputTokens
    }
}
public struct ResponsesEnglishPracticePort: EnglishPracticeModelPort {
    public let configuration: ModelConfiguration
    private let endpoint: ResponsesEndpoint
    private let transport: any ModelHTTPTransport
    public init(baseURL: URL, apiKey: String, model: String, transport: any ModelHTTPTransport = DirectModelHTTPTransport()) throws {
        endpoint = try ResponsesEndpoint(baseURL: baseURL, apiKey: apiKey, model: model)
        configuration = ModelConfiguration(provider: endpoint.provider, model: model, promptVersion: "english-practice-v1", schemaVersion: "english-feedback-v1", destination: .cloud)
        self.transport = transport
    }
    public func generate(_ request: EnglishPracticeRequest) async throws -> EnglishPracticeResponse {
        let reply = try await transport.send(try makeRequest(request))
        guard reply.status == 200 else { throw ModelPortFailure.rejected("HTTP \(reply.status)；费用未知，不自动重发") }
        return try Self.parse(reply.body, snapshot: request.snapshot)
    }
    func makeRequest(_ request: EnglishPracticeRequest) throws -> URLRequest {
        let s = request.snapshot
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let sourceDigest = try VoiceOSStore.relevanceHash(encoder.encode(s.context.sources))
        guard request.configuration.provider == configuration.provider, request.configuration.model == configuration.model,
              request.configuration.promptVersion == configuration.promptVersion, request.configuration.schemaVersion == configuration.schemaVersion,
              request.configuration.destination == .cloud, s.destination == .cloud, UUID(uuidString: request.attemptID) != nil,
              s.context.sources.map(\.sourceID) == [s.currentSourceID] + s.priorSourceIDs,
              s.context.sources.allSatisfy({ $0.origin == "user" && $0.speaker == "user" && !$0.localOnly }),
              s.context.contentDigest == sourceDigest else {
            throw ModelPortFailure.rejected("英文练习请求身份、来源或授权不符")
        }
        let sources = s.context.sources.map { ["sourceID": $0.sourceID, "transcriptVersionID": $0.transcriptVersionID, "text": $0.text, "spans": $0.spans.map { ["spanID": $0.id, "textStart": $0.textStart, "textEnd": $0.textEnd] as [String: Any] }] as [String: Any] }
        let input: [String: Any] = ["currentSourceID": s.currentSourceID, "priorSourceIDs": s.priorSourceIDs, "sources": sources]
        let payload: [String: Any] = ["model": configuration.model, "store": false, "reasoning": ["effort": "low"], "max_output_tokens": 2048, "truncation": "disabled", "instructions": Self.instructions,
            "input": [["role": "user", "content": String(decoding: try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]), as: UTF8.self)]],
            "text": ["format": ["type": "json_schema", "name": "voiceos_english_feedback", "strict": true, "schema": Self.schema]]]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]); guard data.count <= 160000 else { throw ModelPortFailure.rejected("英文练习请求超过字节预算") }
        return endpoint.request(body: data, timeout: 60)
    }
    static let instructions = """
    帮用户把这次练习里想表达的意思说得更清楚、更自然。挑出值得反馈的表达，给出贴合语境的英文说法，解释它好在哪里。已有表达中值得保留、可以迁移到其他场景的用法也可以指出。
    每条反馈附练习中的连续原句。可能是转写造成的问题标记 possibleTranscriptIssue。用户选了旧练习时，可用两次练习的原句说明有意义的变化。
    """
    static var schema: [String: Any] {
        func object(_ p: [String: Any]) -> [String: Any] { ["type": "object", "properties": p, "required": p.keys.sorted(), "additionalProperties": false] }
        let ref = object(["sourceID": ["type": "string"], "transcriptVersionID": ["type": "string"], "spanID": ["type": "string"]])
        let evidence = object(["reference": ref, "quote": ["type": "string"]])
        let suggestion = object(["kind": ["type": "string", "enum": ["grammar", "organisation", "reusablePattern"]], "original": evidence, "suggestedText": ["type": "string"], "explanation": ["type": "string"], "possibleTranscriptIssue": ["type": "boolean"]])
        let comparison = object(["kind": ["type": "string", "enum": ["similarIssue", "differentExpression"]], "currentSuggestionIndex": ["type": "integer", "minimum": 0, "maximum": 7], "current": evidence, "prior": evidence, "explanation": ["type": "string"]])
        return object(["suggestions": ["type": "array", "items": suggestion, "maxItems": 8], "comparisons": ["type": "array", "items": comparison, "maxItems": 4]])
    }
    static func parse(_ data: Data, snapshot: EnglishPracticeSnapshot) throws -> EnglishPracticeResponse {
        var input: Int?, output: Int?
        do {
            let envelope = try ResponsesEnvelope.parse(data); input = envelope.inputTokens; output = envelope.outputTokens
            guard envelope.status == .completed, let text = envelope.text, let body = text.data(using: .utf8), let object = try JSONSerialization.jsonObject(with: body) as? [String: Any], Set(object.keys) == ["comparisons", "suggestions"], let raw = try? JSONSerialization.data(withJSONObject: object) else {
                throw ModelPortFailure.rejected("英文反馈未完成或结构不符", inputTokens: input, outputTokens: output)
            }
            let decoded = try JSONDecoder().decode(EnglishFeedbackEnvelope.self, from: raw)
            try VoiceOSStore.validateEnglishProposals(suggestions: decoded.suggestions, comparisons: decoded.comparisons, snapshot: snapshot)
            return EnglishPracticeResponse(suggestions: decoded.suggestions, comparisons: decoded.comparisons, inputTokens: input, outputTokens: output)
        } catch ModelPortFailure.rejected(let reason, let knownInput, let knownOutput) { throw ModelPortFailure.rejected(reason, inputTokens: knownInput ?? input, outputTokens: knownOutput ?? output) }
        catch { throw ModelPortFailure.rejected("英文反馈无法解析或引文不符", inputTokens: input, outputTokens: output) }
    }
}
struct EnglishFeedbackEnvelope: Codable { let suggestions: [EnglishSuggestionProposal]; let comparisons: [EnglishComparisonProposal] }
