import XCTest
@testable import VoiceOSCore

private struct AssociationHTTPInspector: MediaInspector {
    func inspect(_ url: URL) async throws -> MediaInfo { throw VoiceOSError("text only") }
}
private struct AssociationHTTPRetrieval: LocalRetrievalPort {
    func rank(query: String, documents: [RetrievalDocument], semantic: Bool) async throws -> [RetrievalMatch] { documents.map { .init(documentID: $0.id, score: 1, method: "exact") } }
}
private actor AssociationHTTPTransport: ModelHTTPTransport {
    let reply: ModelHTTPReply
    var calls = 0
    init(_ reply: ModelHTTPReply) { self.reply = reply }
    func send(_ request: URLRequest) async throws -> ModelHTTPReply { calls += 1; return reply }
}
final class ResponsesExpressionAssociationTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    func fixture() async throws -> (VoiceOSStore, ExpressionAssociationSnapshot) {
        let store = try VoiceOSStore(root: root, inspector: AssociationHTTPInspector()); try await store.recover()
        let old = try await store.recordUserExpression("旧表达：有哪些反例限制猜想？"), current = try await store.recordUserExpression("新表达：我想寻找猜想的反例。")
        for id in [old, current] { _ = try await store.setSourceLocalOnly(sourceID: id, expectedVersion: 1, localOnly: false) }
        let hits = try await store.retrieve("反例", using: AssociationHTTPRetrieval()).hits.filter { $0.document.sourceID != current }
        return (store, try await store.prepareExpressionAssociation(currentSourceID: current, candidates: hits, destination: .cloud))
    }
    func port(_ transport: any ModelHTTPTransport = DirectModelHTTPTransport()) throws -> ResponsesExpressionAssociationPort { try .init(baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: "synthetic-secret", model: "gpt-6.1-sol", transport: transport) }
    func proposal(_ snapshot: ExpressionAssociationSnapshot) -> [String: Any] {
        let s = snapshot.current.sources[0]
        return ["candidateID": snapshot.candidates[0].id, "current": ["reference": ["sourceID": s.sourceID, "transcriptVersionID": s.transcriptVersionID, "spanID": s.spans[0].id], "quote": s.text], "historicalQuote": snapshot.candidates[0].document.text, "relation": "sameQuestion", "reason": "两次表达都在寻找限制猜想的反例。"]
    }
    func response(_ items: [[String: Any]], status: String = "completed", part: String = "output_text") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["status": status, "usage": ["input_tokens": 14, "output_tokens": 9], "output": [["type": "message", "role": "assistant", "status": "completed", "content": [["type": part, "text": String(decoding: JSONSerialization.data(withJSONObject: ["proposals": items]), as: UTF8.self)]]]]])
    }
    func testRequestContainsFullTextStrictSchemaNoToolsOrAudio() async throws {
        let (_, s) = try await fixture(), p = try port()
        let request = try p.makeRequest(.init(attemptID: UUID().uuidString, snapshot: s, configuration: p.configuration))
        let bytes = try XCTUnwrap(request.httpBody), body = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(request.httpMethod, "POST"); XCTAssertEqual(request.timeoutInterval, 60)
        XCTAssertEqual(body["store"] as? Bool, false); XCTAssertEqual(body["truncation"] as? String, "disabled"); XCTAssertNil(body["tools"]); XCTAssertNil(body["audio"])
        let format = (body["text"] as? [String: Any])?["format"] as? [String: Any]
        XCTAssertEqual(format?["strict"] as? Bool, true)
        let inputs = try XCTUnwrap(body["input"] as? [[String: Any]]), content = try XCTUnwrap(inputs[0]["content"] as? String)
        XCTAssertTrue(content.contains(s.current.sources[0].text)); XCTAssertTrue(content.contains(s.candidates[0].document.text)); XCTAssertFalse(content.contains("synthetic-secret"))
    }
    func testRequestRejectsLocalDestinationAndMismatchedConfigurationWithoutSending() async throws {
        let (store, cloud) = try await fixture(), p = try port()
        let local = try await store.prepareExpressionAssociation(currentSourceID: cloud.current.sources[0].sourceID, candidates: cloud.candidates)
        XCTAssertThrowsError(try p.makeRequest(.init(attemptID: UUID().uuidString, snapshot: local, configuration: p.configuration)))
        XCTAssertThrowsError(try p.makeRequest(.init(attemptID: "invalid", snapshot: cloud, configuration: p.configuration)))
        let config = ModelConfiguration(provider: p.configuration.provider, model: "different", promptVersion: p.configuration.promptVersion, schemaVersion: p.configuration.schemaVersion, destination: .cloud)
        XCTAssertThrowsError(try p.makeRequest(.init(attemptID: UUID().uuidString, snapshot: cloud, configuration: config)))
    }
    func testValidAndEmptyResponsePreserveUsage() async throws {
        let (_, snapshot) = try await fixture()
        let result = try ResponsesExpressionAssociationPort.parse(response([proposal(snapshot)]), snapshot: snapshot)
        XCTAssertEqual(result.proposals.count, 1); XCTAssertEqual(result.inputTokens, 14); XCTAssertEqual(result.outputTokens, 9)
        let empty = try ResponsesExpressionAssociationPort.parse(response([]), snapshot: snapshot); XCTAssertTrue(empty.proposals.isEmpty)
    }
    func testRefusalIncompleteAndInvalidQuotesRetainKnownUsage() async throws {
        let (_, s) = try await fixture()
        var invalid = proposal(s); invalid["historicalQuote"] = "不存在的原句"
        var extra = proposal(s); extra["createTask"] = true
        var inventedRelation = proposal(s); inventedRelation["relation"] = "contradictionProven"
        for bytes in [try response([], status: "incomplete"), try response([], part: "refusal"), try response([invalid]), try response([extra]), try response([inventedRelation])] {
            do { _ = try ResponsesExpressionAssociationPort.parse(bytes, snapshot: s); XCTFail("invalid result") }
            catch ModelPortFailure.rejected(_, let input, let output) { XCTAssertEqual(input, 14); XCTAssertEqual(output, 9) }
        }
    }
    func testHTTPFailureAndDurableReplaySendOnce() async throws {
        let (store, snapshot) = try await fixture(), transport = AssociationHTTPTransport(.init(status: 429, body: Data())), p = try port(transport)
        do { _ = try await store.performExpressionAssociation(snapshot, using: p); XCTFail("HTTP failure") } catch {}
        let record = try await store.performExpressionAssociation(snapshot, using: p)
        XCTAssertEqual(record.state, "unknown"); XCTAssertTrue(record.proposals.isEmpty)
        let calls = await transport.calls; XCTAssertEqual(calls, 1)
    }
}
