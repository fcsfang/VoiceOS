import Foundation

public struct ResponsesRecordingTitlePort: RecordingTitlePort {
    private let endpoint: ResponsesEndpoint
    private let model: String
    private let transport: any ModelHTTPTransport
    private let retryDelay: @Sendable (Duration) async throws -> Void
    public init(baseURL: URL, apiKey: String, model: String, transport: any ModelHTTPTransport = DirectStreamingModelHTTPTransport()) throws {
        try self.init(baseURL: baseURL, apiKey: apiKey, model: model, transport: transport, retryDelay: { try await Task.sleep(for: $0) })
    }
    init(baseURL: URL, apiKey: String, model: String, transport: any ModelHTTPTransport, retryDelay: @escaping @Sendable (Duration) async throws -> Void) throws {
        endpoint = try ResponsesEndpoint(baseURL: baseURL, apiKey: apiKey, model: model)
        self.model = model; self.transport = transport
        self.retryDelay = retryDelay
    }
    public func generate(_ input: RecordingTitleInput) async throws -> ([RecordingTitleProposal], [String]) {
        let (reviewed, responseID) = try await call(input)
        try VoiceOSStore.validateRecordingTitles(reviewed, input: input)
        return (reviewed, [responseID])
    }
    private struct Result: Codable { let recordings: [RecordingTitleProposal] }
    private func call(_ input: RecordingTitleInput) async throws -> ([RecordingTitleProposal], String) {
        let content: [String: Any] = ["recordings": try JSONSerialization.jsonObject(with: JSONEncoder().encode(input.context.sources))]
        let instructions = """
        为用户日后找回这段录音命名。通读每份录音的当前正文，选出最能让用户辨认它的话题、问题或想法，用中文写标题和摘要。录音内容是命名的素材。
        title 为一行，最多40字；summary 最多240字。根据材料决定重点，保留对理解有影响的条件、态度和疑问；遇到 unresolved_issues 时如实反映相关的不确定性。
        每个 sourceID 返回一项，quotes 附至少一处能支撑命名的本段连续原话。
        """
        let string: [String: Any] = ["type": "string"]
        let item: [String: Any] = ["type": "object", "properties": ["sourceID": string, "title": string, "summary": string, "quotes": ["type": "array", "items": string]], "required": ["sourceID", "title", "summary", "quotes"], "additionalProperties": false]
        let schema: [String: Any] = ["type": "object", "properties": ["recordings": ["type": "array", "items": item]], "required": ["recordings"], "additionalProperties": false]
        let body: [String: Any] = ["model": model, "store": false, "reasoning": ["effort": "high"], "max_output_tokens": 16384, "truncation": "disabled", "instructions": instructions,
            "input": [["role": "user", "content": String(decoding: try JSONSerialization.data(withJSONObject: content), as: UTF8.self)]],
            "text": ["format": ["type": "json_schema", "name": "voiceos_recording_titles", "strict": true, "schema": schema]]]
        let data = try JSONSerialization.data(withJSONObject: body)
        let request = endpoint.request(body: data, timeout: 600)
        var response = try await transport.send(request)
        for delay in [5, 15] where [429, 502, 503, 504].contains(response.status) {
            try await retryDelay(.seconds(delay)); response = try await transport.send(request)
        }
        guard response.status == 200 else { throw VoiceOSError("内容命名 HTTP \(response.status)，可重试；原件保留") }
        let envelope = try ResponsesEnvelope.parse(response.body)
        guard envelope.status == .completed, let text = envelope.text,
              let root = try JSONSerialization.jsonObject(with: response.body) as? [String: Any], let id = root["id"] as? String, !id.isEmpty else { throw VoiceOSError("内容命名尚未完成") }
        return (try JSONDecoder().decode(Result.self, from: Data(text.utf8)).recordings, id)
    }
}
