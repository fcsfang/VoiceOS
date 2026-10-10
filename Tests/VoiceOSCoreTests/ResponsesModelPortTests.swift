import XCTest
import Foundation
@testable import VoiceOSCore

private actor HTTPFixture: ModelHTTPTransport {
    let reply: ModelHTTPReply
    var calls = 0
    init(_ status: Int, _ body: Data) { reply = ModelHTTPReply(status: status, body: body) }
    func send(_ request: URLRequest) async throws -> ModelHTTPReply { calls += 1; return reply }
}
final class ResponsesModelPortTests: XCTestCase {
    private func port(_ transport: any ModelHTTPTransport = DirectModelHTTPTransport()) throws -> ResponsesModelPort {
        try ResponsesModelPort(baseURL: URL(string: "https://api.chiyi.cc/v1")!, apiKey: "test-secret", model: "gpt-6.1-sol", transport: transport)
    }
    private func request(_ port: ResponsesModelPort, localOnly: Bool = false, text: String = "外部测试资料") -> ModelRequest {
        let input = ContextTranscript(sourceID: UUID().uuidString, sourceVersionID: UUID().uuidString, transcriptVersionID: UUID().uuidString, origin: "external", speaker: "unknown", localOnly: localOnly, text: text, spans: [TranscriptSpan(textStart: 0, textEnd: text.unicodeScalars.count)])
        return ModelRequest(attemptID: UUID().uuidString, context: LocalTranscriptContext(sources: [input], scalarBudget: 4000, contentDigest: "test"), configuration: port.configuration)
    }
    private func response(_ claims: [[String: Any]] = [], status: String = "completed", partType: String = "output_text", usage: [String: Any] = ["input_tokens": 10, "output_tokens": 5]) throws -> Data {
        let text = String(decoding: try JSONSerialization.data(withJSONObject: ["claims": claims]), as: UTF8.self)
        return try JSONSerialization.data(withJSONObject: ["status": status, "usage": usage, "output": [["type": "message", "role": "assistant", "status": "completed", "content": [["type": partType, "text": text]]]]])
    }
    func testPayloadIsBoundedTextOnlyAndUsesStrictSchema() throws {
        let p = try port(); let http = try p.makeRequest(request(p))
        XCTAssertEqual(http.url?.absoluteString, "https://api.chiyi.cc/v1/responses")
        XCTAssertEqual(http.httpMethod, "POST")
        let body = try XCTUnwrap(http.httpBody)
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("test-secret"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["store"] as? Bool, false); XCTAssertNil(json["tools"])
        XCTAssertEqual(json["max_output_tokens"] as? Int, 2048)
        let input = try XCTUnwrap((json["input"] as? String)?.data(using: .utf8))
        let sources = try XCTUnwrap((JSONSerialization.jsonObject(with: input) as? [String: Any])?["sources"] as? [[String: Any]])
        XCTAssertEqual(Set(sources[0].keys), ["sourceID", "transcriptVersionID", "origin", "speaker", "text", "spans"])
        let format = ((json["text"] as? [String: Any])?["format"] as? [String: Any])
        XCTAssertEqual(format?["strict"] as? Bool, true)
        XCTAssertThrowsError(try p.makeRequest(request(p, localOnly: true)))
        XCTAssertThrowsError(try p.makeRequest(request(p, text: String(repeating: "中", count: 4001))))
    }
    func testEndpointAndHeaderInjectionRejected() throws {
        for value in ["http://api.chiyi.cc/v1", "https://api.chiyi.cc.evil.test/v1", "https://api.chiyi.cc/v1?x=1", "https://a@api.chiyi.cc/v1", "https://api.chiyi.cc/v2", "https://api.chiyi.cc:443/v1"] {
            XCTAssertThrowsError(try ResponsesModelPort(baseURL: URL(string: value)!, apiKey: "test", model: "test"))
        }
        XCTAssertThrowsError(try ResponsesModelPort(baseURL: URL(string: "https://api.chiyi.cc/v1")!, apiKey: "test\r\nInjected: bad", model: "test"))
    }
    func testCompletedClaimsParseAndUnknownFieldsReject() throws {
        let ref = ["sourceID": UUID().uuidString, "transcriptVersionID": UUID().uuidString, "spanID": UUID().uuidString]
        let claim: [String: Any] = ["statement": "外部说法", "ownership": "external", "references": [ref]]
        let parsed = try ResponsesModelPort.parse(response([claim]))
        XCTAssertEqual(parsed.claims.count, 1); XCTAssertEqual(parsed.inputTokens, 10)
        var extra = claim; extra["userConfirmed"] = true
        do { _ = try ResponsesModelPort.parse(response([extra])); XCTFail("must reject") }
        catch ModelPortFailure.rejected(_, let input, let output) { XCTAssertEqual(input, 10); XCTAssertEqual(output, 5) }
        extra = claim; extra["ownership"] = "user"
        XCTAssertThrowsError(try ResponsesModelPort.parse(response([extra])))
        extra = claim; extra["references"] = [["sourceID": "invented", "transcriptVersionID": "invented", "spanID": "invented"]]
        XCTAssertThrowsError(try ResponsesModelPort.parse(response([extra])))
    }
    func testIncompleteRefusalAndUnknownUsage() throws {
        let incomplete = try ResponsesModelPort.parse(response(status: "incomplete"))
        XCTAssertEqual(incomplete.status, .incomplete); XCTAssertEqual(incomplete.outputTokens, 5)
        XCTAssertEqual(try ResponsesModelPort.parse(response(partType: "refusal")).status, .refused)
        let missing = try ResponsesModelPort.parse(response(usage: [:]))
        XCTAssertNil(missing.inputTokens); XCTAssertNil(missing.outputTokens)
        for value: Any in [true, -1, 1.5, "10"] { XCTAssertThrowsError(try ResponsesModelPort.parse(response(usage: ["input_tokens": value]))) }
        XCTAssertThrowsError(try ResponsesModelPort.parse(response(status: "queued")))
    }
    func testMalformedAndToolResponsesRejected() throws {
        XCTAssertThrowsError(try ResponsesModelPort.parse(Data("broken".utf8)))
        XCTAssertThrowsError(try ResponsesModelPort.parse(Data(repeating: 32, count: 262145)))
        let tool = try JSONSerialization.data(withJSONObject: ["status": "completed", "output": [["type": "function_call"]]])
        XCTAssertThrowsError(try ResponsesModelPort.parse(tool))
    }
    func testHTTPFailuresNeverRetryOrExposeServerBody() async throws {
        for status in [302, 401, 429, 503] {
            let fixture = HTTPFixture(status, Data("server-body-secret".utf8)); let p = try port(fixture)
            do { _ = try await p.generate(request(p)); XCTFail("must reject") }
            catch ModelPortFailure.rejected(let reason, _, _) { XCTAssertTrue(reason.contains(String(status))); XCTAssertFalse(reason.contains("server-body-secret")) }
            let calls = await fixture.calls; XCTAssertEqual(calls, 1)
        }
    }
    func testLocalOnlyDeniedBeforeHTTPTransport() async throws {
        let fixture = HTTPFixture(200, try response()); let p = try port(fixture)
        do { _ = try await p.generate(request(p, localOnly: true)); XCTFail("must reject") } catch {}
        let calls = await fixture.calls; XCTAssertEqual(calls, 0)
    }
}
