import XCTest
@testable import VoiceOSCore

final class ResponsesEnglishPracticeTests: XCTestCase {
    func snapshot(cloud: Bool = true) throws -> EnglishPracticeSnapshot {
        let text = "The model have two layers."
        let source = ContextTranscript(sourceID: "source", sourceVersionID: "version", transcriptVersionID: "transcript", origin: "user", speaker: "user", localOnly: !cloud, text: text, spans: [TranscriptSpan(id: "00000000-0000-0000-0000-000000000001", textStart: 0, textEnd: text.unicodeScalars.count)])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let context = LocalTranscriptContext(sources: [source], scalarBudget: 4000, contentDigest: try VoiceOSStore.relevanceHash(encoder.encode([source])))
        return EnglishPracticeSnapshot(id: UUID().uuidString, currentSourceID: "source", priorSourceIDs: [], destination: cloud ? .cloud : .local, context: context, contentDigest: try VoiceOSStore.englishPracticeDigest("source", [], cloud ? .cloud : .local, context))
    }
    func port() throws -> ResponsesEnglishPracticePort { try ResponsesEnglishPracticePort(baseURL: URL(string: "https://api.chiyi.cc/v1")!, apiKey: "test-key", model: "gpt-6.1-sol") }
    func testRequestContainsTextOnlyStrictSchemaAndNoAudio() throws {
        let p = try port(), s = try snapshot(), r = EnglishPracticeRequest(attemptID: UUID().uuidString, snapshot: s, configuration: p.configuration)
        let request = try p.makeRequest(r); let body = try XCTUnwrap(request.httpBody); let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(root["store"] as? Bool, false); XCTAssertNil(root["audio"]); XCTAssertNil(root["tools"])
        let text = try XCTUnwrap(root["text"] as? [String: Any]); let format = try XCTUnwrap(text["format"] as? [String: Any]); XCTAssertEqual(format["strict"] as? Bool, true)
        XCTAssertEqual((format["schema"] as? [String: Any])?["additionalProperties"] as? Bool, false)
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("The model have two layers."))
    }
    func testCloudRequestRejectsLocalSourceAndInvalidAttempt() throws {
        let p = try port(); XCTAssertThrowsError(try p.makeRequest(.init(attemptID: UUID().uuidString, snapshot: try snapshot(cloud: false), configuration: p.configuration)))
        XCTAssertThrowsError(try p.makeRequest(.init(attemptID: "not-uuid", snapshot: try snapshot(), configuration: p.configuration)))
    }
    func testParserRejectsUnverifiableSuggestionAndAcceptsUsageOnlyOnValidResult() throws {
        let s = try snapshot(); let ref = ["sourceID": "source", "transcriptVersionID": "transcript", "spanID": "00000000-0000-0000-0000-000000000001"] as [String: Any]
        let valid: [String: Any] = ["suggestions": [["kind": "grammar", "original": ["reference": ref, "quote": "The model have two layers."], "suggestedText": "The model has two layers.", "explanation": "Use has with a singular subject.", "possibleTranscriptIssue": false]], "comparisons": []]
        let suggestion = EnglishSuggestionProposal(kind: .grammar, original: .init(reference: .init(sourceID: "source", transcriptVersionID: "transcript", spanID: "00000000-0000-0000-0000-000000000001"), quote: "The model have two layers."), suggestedText: "The model has two layers.", explanation: "Use has with a singular subject.")
        try VoiceOSStore.validateEnglishProposals(suggestions: [suggestion], comparisons: [], snapshot: s)
        let fixtureData = try JSONSerialization.data(withJSONObject: ["status": "completed", "usage": ["input_tokens": 12, "output_tokens": 8], "output": [["type": "message", "role": "assistant", "status": "completed", "content": [["type": "output_text", "text": String(decoding: try validData(valid), as: UTF8.self)]]]]])
        let payload = try JSONSerialization.data(withJSONObject: valid)
        XCTAssertNoThrow(try JSONDecoder().decode(EnglishFeedbackEnvelope.self, from: payload))
        let result = try ResponsesEnglishPracticePort.parse(fixtureData, snapshot: s); XCTAssertEqual(result.suggestions.count, 1); XCTAssertEqual(result.inputTokens, 12)
        let invalid = valid.merging(["suggestions": [["kind": "grammar", "original": ["reference": ref, "quote": "invented"], "suggestedText": "x", "explanation": "x", "possibleTranscriptIssue": false]]]) { _, new in new }
        let invalidData = try JSONSerialization.data(withJSONObject: ["status": "completed", "output": [["type": "message", "role": "assistant", "status": "completed", "content": [["type": "output_text", "text": String(decoding: validData(invalid), as: UTF8.self)]]]]])
        XCTAssertThrowsError(try ResponsesEnglishPracticePort.parse(invalidData, snapshot: s))
    }
    private func validData(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
}
