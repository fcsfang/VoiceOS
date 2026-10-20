import XCTest
import Foundation
@testable import VoiceOSCore

private actor DiscussionHTTP: ModelHTTPTransport {
    let response:ModelHTTPReply
    var calls=0
    init(status:Int = 200,body:Data) { response=ModelHTTPReply(status:status,body:body) }
    func send(_ request:URLRequest) async throws -> ModelHTTPReply { calls += 1;return response }
}
final class ResponsesDiscussionTests:XCTestCase {
    func port(_ transport:any ModelHTTPTransport = DirectModelHTTPTransport()) throws -> ResponsesDiscussionPort {
        try ResponsesDiscussionPort(baseURL:URL(string:"https://api.chiyi.cc/v1")!,apiKey:"test-secret",model:"gpt-6.1-sol",transport:transport)
    }
    func snapshot(local:Bool = false) throws -> DiscussionSnapshot {
        let sources=(0..<3).map { index -> ContextTranscript in
            let text="合成原文\(index)：条件尚未满足。"
            return ContextTranscript(sourceID:UUID().uuidString,sourceVersionID:UUID().uuidString,transcriptVersionID:UUID().uuidString,origin:"user",speaker:"user",localOnly:local,text:text,spans:[TranscriptSpan(textStart:0,textEnd:text.unicodeScalars.count)])
        }
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let context=LocalTranscriptContext(sources:sources,scalarBudget:8000,contentDigest:VoiceOSStore.relevanceHash(try encoder.encode(sources)))
        let turns=sources.dropFirst().map { ConversationTurnReference(turnID:UUID().uuidString,sourceID:$0.sourceID,transcriptVersionID:$0.transcriptVersionID) }
        let input=PreparedConversationInput(conversationID:UUID().uuidString,conversationVersion:3,contextID:UUID().uuidString,historySourceIDs:[sources[0].sourceID],userTurns:turns,destination:.cloud)
        let parts=[DiscussionPart(kind:.aiSuggestion,text:"合成先前AI建议：比较反例。")]
        let prior=DiscussionPriorReply(attemptID:UUID().uuidString,replyToTurnID:turns[0].turnID,digest:VoiceOSStore.relevanceHash(try encoder.encode(parts)),parts:parts)
        return DiscussionSnapshot(input:input,context:context,priorReplies:[prior])
    }
    func response(_ value:Any,status:String = "completed",part:String = "output_text") throws -> Data {
        let text=String(decoding:try JSONSerialization.data(withJSONObject:value),as:UTF8.self)
        return try JSONSerialization.data(withJSONObject:["status":status,"usage":["input_tokens":10,"output_tokens":20],"output":[["type":"message","role":"assistant","status":"completed","content":[["type":part,"text":text]]]]])
    }
    func valid(_ context:LocalTranscriptContext) -> [String:Any] {
        let source=context.sources[0]
        return ["parts":[["kind":"quotation","text":source.text,"references":[["sourceID":source.sourceID,"transcriptVersionID":source.transcriptVersionID,"spanID":source.spans[0].id]]], ["kind":"ai_suggestion","text":"这是AI提出的待检验解释。","references":[]]]]
    }
    func testPayloadPreservesRolesAndSourceCatalogOnceWithoutPrivateMetadata() throws {
        let p=try port(),s=try snapshot(),http=try p.makeRequest(DiscussionModelRequest(attemptID:UUID().uuidString,snapshot:s,configuration:p.configuration))
        XCTAssertEqual(http.url?.path,"/v1/responses");XCTAssertEqual(http.httpMethod,"POST");XCTAssertEqual(http.timeoutInterval,60)
        let body=try XCTUnwrap(http.httpBody),root=try XCTUnwrap(JSONSerialization.jsonObject(with:body) as? [String:Any])
        XCTAssertEqual(root["store"] as? Bool,false);XCTAssertEqual(root["truncation"] as? String,"disabled");XCTAssertEqual(root["max_output_tokens"] as? Int,2048)
        let messages=root["input"] as! [[String:Any]]
        XCTAssertEqual(messages.map { $0["role"] as! String },["user","user","assistant","user"])
        let catalog=try XCTUnwrap(JSONSerialization.jsonObject(with:Data((messages[0]["content"] as! String).utf8)) as? [String:Any])
        let sources=catalog["sources"] as! [[String:Any]];XCTAssertEqual(sources.count,3)
        XCTAssertEqual(Set(sources[0].keys),["sourceID","transcriptVersionID","origin","speaker","text","spans"])
        for field in ["test-secret","sourceVersionID","localOnly","startMS","endMS"] { XCTAssertFalse(String(decoding:body,as:UTF8.self).contains(field)) }
        XCTAssertNil(root["tools"]);XCTAssertNil(root["previous_response_id"]);XCTAssertNil(root["conversation"])
    }
    func testLocalSourceRefusedBeforeTransport() async throws {
        let s=try snapshot(local:true),transport=DiscussionHTTP(body:Data()),p=try port(transport)
        do { _=try await p.reply(DiscussionModelRequest(attemptID:UUID().uuidString,snapshot:s,configuration:p.configuration));XCTFail() } catch {}
        let calls=await transport.calls;XCTAssertEqual(calls,0)
    }
    func testStrictReplyParsesQuoteAndAIIdentityAndPreservesKnownUsageOnRejection() throws {
        let s=try snapshot(),result=try ResponsesDiscussionPort.parse(response(valid(s.context)),context:s.context)
        XCTAssertEqual(result.parts.count,2);XCTAssertEqual(result.inputTokens,10);XCTAssertEqual(result.parts[1].kind,.aiSuggestion)
        let source=s.context.sources[0]
        let invalid:[[String:Any]] = [
            ["parts":[],"task":"invented"],
            ["parts":[["kind":"quotation","text":"invented","references":[["sourceID":source.sourceID,"transcriptVersionID":source.transcriptVersionID,"spanID":source.spans[0].id]]]]],
            ["parts":[["kind":"user","text":"AI伪装用户","references":[]]]],
            ["parts":[["kind":"ai_suggestion","text":"AI建议","references":[],"autoSend":true]]],
            ["parts":[["kind":"ai_suggestion","text":"AI建议","references":[["sourceID":"foreign","transcriptVersionID":source.transcriptVersionID,"spanID":source.spans[0].id]]]]]
        ]
        for value in invalid {
            do { _=try ResponsesDiscussionPort.parse(response(value),context:s.context);XCTFail() }
            catch ModelPortFailure.rejected(_,let input,let output) { XCTAssertEqual(input,10);XCTAssertEqual(output,20) }
        }
    }
    func testIncompleteRefusalAndToolsNeverBecomeReplies() throws {
        let s=try snapshot()
        for (status,part) in [("incomplete","output_text"),("completed","refusal")] {
            let result=try ResponsesDiscussionPort.parse(response(valid(s.context),status:status,part:part),context:s.context)
            XCTAssertTrue(result.parts.isEmpty);XCTAssertEqual(result.outputTokens,20)
        }
        let tool=try JSONSerialization.data(withJSONObject:["status":"completed","output":[["type":"function_call"]]])
        XCTAssertThrowsError(try ResponsesDiscussionPort.parse(tool,context:s.context))
    }
    func testHTTPFailureSendsOnceAndDoesNotExposeServerContent() async throws {
        for status in [302,401,429,503] {
            let s=try snapshot(),transport=DiscussionHTTP(status:status,body:Data("private-server-body".utf8)),p=try port(transport)
            do { _=try await p.reply(DiscussionModelRequest(attemptID:UUID().uuidString,snapshot:s,configuration:p.configuration));XCTFail() }
            catch ModelPortFailure.rejected(let reason,_,_) { XCTAssertFalse(reason.contains("private-server-body")) }
            let calls=await transport.calls;XCTAssertEqual(calls,1)
        }
    }
    func testForgedInputDigestAndConfigurationRejected() throws {
        let s=try snapshot(),p=try port()
        let forged=DiscussionSnapshot(input:s.input,context:LocalTranscriptContext(sources:s.context.sources,scalarBudget:8000,contentDigest:"invalid"),priorReplies:s.priorReplies)
        XCTAssertThrowsError(try p.makeRequest(DiscussionModelRequest(attemptID:UUID().uuidString,snapshot:forged,configuration:p.configuration)))
        let wrong=ModelConfiguration(provider:p.configuration.provider,model:"wrong",promptVersion:p.configuration.promptVersion,schemaVersion:p.configuration.schemaVersion,destination:.cloud)
        XCTAssertThrowsError(try p.makeRequest(DiscussionModelRequest(attemptID:UUID().uuidString,snapshot:s,configuration:wrong)))
    }
}
