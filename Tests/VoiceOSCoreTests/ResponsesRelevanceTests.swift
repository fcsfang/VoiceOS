import XCTest
import Foundation
@testable import VoiceOSCore

private actor RelevanceHTTP: ModelHTTPTransport {
    let reply: ModelHTTPReply
    var calls = 0
    init(_ status: Int = 200, body: Data) { reply = ModelHTTPReply(status:status,body:body) }
    func send(_ request: URLRequest) async throws -> ModelHTTPReply { calls += 1; return reply }
}
final class ResponsesRelevanceTests: XCTestCase {
    func port(_ transport: any ModelHTTPTransport = DirectModelHTTPTransport()) throws -> ResponsesRelevancePort {
        try ResponsesRelevancePort(baseURL:URL(string:"https://api.chiyi.cc/v1")!,apiKey:"test-secret",model:"gpt-6.1-sol",transport:transport)
    }
    func snapshot(local: Bool = false) throws -> RelevanceSnapshot {
        let source = UUID().uuidString, version = UUID().uuidString, text = "原文中的条件并未满足。"
        let d = RetrievalDocument(id:source+":"+version+":0",sourceID:source,sourceVersionID:UUID().uuidString,transcriptVersionID:version,policyVersion:1,spanID:UUID().uuidString,textStart:0,textEnd:text.unicodeScalars.count,text:text,name:"private-name",createdAt:"private-date",origin:"user",localOnly:local)
        let candidates = [RetrievalHit(document:d,method:"exact",score:1)], queryID = UUID(), query = "哪些条件？"
        let digest = try VoiceOSStore.relevanceDigest(query:query,queryID:queryID,candidates:candidates,destination:.cloud,cloudQueryAllowed:true,scalarBudget:4000)
        return RelevanceSnapshot(id:UUID().uuidString,queryID:queryID,query:query,destination:.cloud,cloudQueryAllowed:true,candidates:candidates,scalarBudget:4000,contentDigest:digest)
    }
    func response(_ value: Any, status: String = "completed", part: String = "output_text", usage: [String:Any] = ["input_tokens":15,"output_tokens":9]) throws -> Data {
        let text = String(decoding:try JSONSerialization.data(withJSONObject:value),as:UTF8.self)
        return try JSONSerialization.data(withJSONObject:["status":status,"usage":usage,"output":[["type":"message","role":"assistant","status":"completed","content":[["type":part,"text":text]]]]])
    }
    func testBoundedPayloadOmitsPrivateMetadataAndConstrainsIDs() throws {
        let p = try port(), s = try snapshot()
        let http = try p.makeRequest(RelevanceModelRequest(attemptID:UUID().uuidString,snapshot:s,configuration:p.configuration))
        XCTAssertEqual(http.httpMethod,"POST"); XCTAssertEqual(http.url?.path,"/v1/responses")
        let body = try XCTUnwrap(http.httpBody), text = String(decoding:body,as:UTF8.self)
        for omitted in ["test-secret","private-name","private-date","tools","audio"] { XCTAssertFalse(text.contains(omitted)) }
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with:body) as? [String:Any])
        XCTAssertEqual(root["store"] as? Bool,false); XCTAssertEqual(root["max_output_tokens"] as? Int,1024)
        let input = try XCTUnwrap((root["input"] as? String)?.data(using:.utf8))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with:input) as? [String:Any])
        XCTAssertEqual(Set(payload.keys),["query","candidates"])
        let candidates = payload["candidates"] as! [[String:Any]]
        XCTAssertEqual(Set(candidates[0].keys),["id","origin","text"])
    }
    func testPrivateCandidateDeniedBeforeTransport() async throws {
        let http = RelevanceHTTP(body:try response(["candidate_ids":[]])), p = try port(http), s = try snapshot(local:true)
        do { _ = try await p.select(RelevanceModelRequest(attemptID:UUID().uuidString,snapshot:s,configuration:p.configuration)); XCTFail() } catch {}
        let calls = await http.calls; XCTAssertEqual(calls,0)
    }
    func testResultOnlyAcceptsUniqueSentIDsAndRetainsUsageOnFailure() throws {
        let s = try snapshot(), id = s.candidates[0].id
        let result = try ResponsesRelevancePort.parse(response(["candidate_ids":[id]]),snapshot:s)
        XCTAssertEqual(result.selection?.candidateIDs,[id]); XCTAssertEqual(result.inputTokens,15)
        for value: [String:Any] in [["candidate_ids":["invented"]],["candidate_ids":[id,id]],["candidate_ids":[],"claims":[]],["candidate_ids":true]] {
            do { _ = try ResponsesRelevancePort.parse(response(value),snapshot:s); XCTFail() }
            catch ModelPortFailure.rejected(_,let input,let output) { XCTAssertEqual(input,15); XCTAssertEqual(output,9) }
        }
    }
    func testIncompleteRefusalAndMalformedUsageHaveNoAcceptedSelection() throws {
        let s = try snapshot()
        for (status,part) in [("incomplete","output_text"),("completed","refusal")] {
            let result = try ResponsesRelevancePort.parse(response(["candidate_ids":[]],status:status,part:part),snapshot:s)
            XCTAssertNil(result.selection); XCTAssertEqual(result.outputTokens,9)
        }
        for value: Any in [true,-1,1.5,"15"] { XCTAssertThrowsError(try ResponsesRelevancePort.parse(response(["candidate_ids":[]],usage:["input_tokens":value]),snapshot:s)) }
        let tool = try JSONSerialization.data(withJSONObject:["status":"completed","output":[["type":"function_call"]]])
        XCTAssertThrowsError(try ResponsesRelevancePort.parse(tool,snapshot:s))
    }
    func testHTTPFailuresAreOneRequestWithoutServerBodyLeak() async throws {
        for status in [302,401,429,503] {
            let http = RelevanceHTTP(status,body:Data("private-server-body".utf8)), p = try port(http), s = try snapshot()
            do { _ = try await p.select(RelevanceModelRequest(attemptID:UUID().uuidString,snapshot:s,configuration:p.configuration)); XCTFail() }
            catch ModelPortFailure.rejected(let reason,_,_) { XCTAssertFalse(reason.contains("private-server-body")) }
            let calls = await http.calls; XCTAssertEqual(calls,1)
        }
    }
    func testInvalidEndpointAndCredentialAreRejected() throws {
        for address in ["http://api.chiyi.cc/v1","https://api.chiyi.cc:443/v1","https://api.chiyi.cc/v1?x=1","https://evil.test/v1"] {
            XCTAssertThrowsError(try ResponsesRelevancePort(baseURL:URL(string:address)!,apiKey:"test",model:"test"))
        }
        XCTAssertThrowsError(try ResponsesRelevancePort(baseURL:URL(string:"https://api.chiyi.cc/v1")!,apiKey:"bad\r\nkey",model:"test"))
    }
}
