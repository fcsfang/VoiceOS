import XCTest
import Foundation
@testable import VoiceOSCore

private actor OutcomeHTTP:ModelHTTPTransport {
    let response:ModelHTTPReply
    var calls=0
    init(status:Int=200,body:Data) { response=ModelHTTPReply(status:status,body:body) }
    func send(_ request:URLRequest) async throws -> ModelHTTPReply { calls += 1;return response }
}
final class ResponsesOutcomeTests:XCTestCase {
    func port(_ transport:any ModelHTTPTransport=DirectModelHTTPTransport()) throws -> ResponsesOutcomePort {
        try ResponsesOutcomePort(baseURL:URL(string:"https://api.chiyi.cc/v1")!,apiKey:"test-secret",model:"gpt-6.1-sol",transport:transport)
    }
    func snapshot(local:Bool=false,state:String="ended",plan:Bool=true) throws -> ConversationOutcomeSnapshot {
        let texts=["合成历史：条件尚未验证。","我会整理开发验证素材。","我现在不打算阅读论文。我会校验迁移资料。"]
        let sources=texts.map { text in ContextTranscript(sourceID:UUID().uuidString,sourceVersionID:UUID().uuidString,transcriptVersionID:UUID().uuidString,origin:"user",speaker:"user",localOnly:local,text:text,spans:[TranscriptSpan(textStart:0,textEnd:text.unicodeScalars.count)]) }
        let e=JSONEncoder();e.outputFormatting=[.sortedKeys]
        let context=LocalTranscriptContext(sources:sources,scalarBudget:8000,contentDigest:VoiceOSStore.relevanceHash(try e.encode(sources)))
        let turns=sources.dropFirst().map { ConversationTurnReference(turnID:UUID().uuidString,sourceID:$0.sourceID,transcriptVersionID:$0.transcriptVersionID) }
        let input=PreparedConversationInput(conversationID:UUID().uuidString,conversationVersion:4,contextID:UUID().uuidString,historySourceIDs:[sources[0].sourceID],userTurns:turns,destination:.cloud)
        let replies=try turns.enumerated().map { index,turn -> ConversationOutcomeReply in
            let parts=[DiscussionPart(kind:.aiSuggestion,text:index == 0 ? "合成AI旧分析：比较反例，尚未验证。":"合成最后AI：另有方案，尚未决定。")]
            return ConversationOutcomeReply(attemptID:UUID().uuidString,replyToTurnID:turn.turnID,state:"completed",validity:"current",digest:VoiceOSStore.relevanceHash(try e.encode(parts)),parts:parts)
        }
        let prior=[OutcomePriorResult(attemptID:UUID().uuidString,producerSequence:1,kind:"personal_understanding",state:"completed",contextID:UUID().uuidString,resultDigest:"known",coveredTurnIDs:[turns[0].turnID],claimIDs:[UUID().uuidString],replyAttemptID:nil,replyPartIndex:nil),OutcomePriorResult(attemptID:UUID().uuidString,producerSequence:2,kind:"ai_paragraph",state:"completed",contextID:UUID().uuidString,resultDigest:"known",coveredTurnIDs:[],claimIDs:[UUID().uuidString],replyAttemptID:replies[0].attemptID,replyPartIndex:0)]
        let reuse=ConversationOutcomeReusePlan(conversationID:input.conversationID,conversationVersion:4,personalTargets:[turns[1]],priorResults:prior)
        return .init(input:input,sessionState:state,context:context,replies:replies,reusePlan:plan ? reuse:nil)
    }
    func valid(_ s:ConversationOutcomeSnapshot) -> [String:Any] {
        let source=s.context.sources[2],reply=s.replies[1]
        return ["proposals":[
            ["statement":"我会校验迁移资料","ownership":"user_tentative","sourceEvidence":[["reference":["sourceID":source.sourceID,"transcriptVersionID":source.transcriptVersionID,"spanID":source.spans[0].id],"quote":"我会校验迁移资料"]],"replyEvidence":[],"action":["title":"校验迁移资料","kind":"task","quote":"我会校验迁移资料","autoSend":true]],
            ["statement":"合成AI新分析：多个方案仍需比较。","ownership":"ai_candidate","sourceEvidence":[],"replyEvidence":[["attemptID":reply.attemptID,"partIndex":0,"quote":reply.parts[0].text]],"action":NSNull()]
        ]]
    }
    func response(_ value:Any,status:String="completed",part:String="output_text") throws -> Data {
        let text=String(decoding:try JSONSerialization.data(withJSONObject:value),as:UTF8.self)
        return try JSONSerialization.data(withJSONObject:["status":status,"usage":["input_tokens":10,"output_tokens":20],"output":[["type":"message","role":"assistant","status":"completed","content":[["type":part,"text":text]]]]])
    }
    func testRequestKeepsAllSourcesAndLastAIAndRestrictsNewTargetsWithoutPrivateMetadata() throws {
        let s=try snapshot(),p=try port(),http=try p.makeRequest(.init(attemptID:UUID().uuidString,snapshot:s,configuration:p.configuration))
        let body=try XCTUnwrap(http.httpBody),root=try XCTUnwrap(JSONSerialization.jsonObject(with:body) as? [String:Any]),messages=root["input"] as! [[String:Any]]
        XCTAssertEqual(http.url?.path,"/v1/responses");XCTAssertEqual(http.timeoutInterval,60);XCTAssertEqual(root["store"] as? Bool,false);XCTAssertEqual(root["truncation"] as? String,"disabled");XCTAssertEqual(root["max_output_tokens"] as? Int,2048)
        XCTAssertNil(root["tools"]);XCTAssertNil(root["previous_response_id"]);XCTAssertNil(root["conversation"])
        let input=try XCTUnwrap(JSONSerialization.jsonObject(with:Data((messages[0]["content"] as! String).utf8)) as? [String:Any]),timeline=input["timeline"] as! [[String:Any]]
        XCTAssertEqual((input["sources"] as! [Any]).count,3);XCTAssertEqual(timeline.map { $0["role"] as! String },["user","assistant","user","assistant"])
        XCTAssertEqual((input["newPersonalTargets"] as! [Any]).count,1);XCTAssertEqual((input["alreadyRetainedAIParagraphs"] as! [Any]).count,1)
        for source in s.context.sources { XCTAssertTrue(String(decoding:body,as:UTF8.self).contains(source.text)) }
        XCTAssertTrue(String(decoding:body,as:UTF8.self).contains(s.replies[1].parts[0].text))
        for field in ["test-secret","sourceVersionID","localOnly","producerSequence","contextID","startMS","endMS"] { XCTAssertFalse(String(decoding:body,as:UTF8.self).contains(field)) }
        func check(_ value:Any) {
            if let object=value as? [String:Any] {
                if object["type"] as? String == "object",let properties=object["properties"] as? [String:Any] { XCTAssertEqual(object["additionalProperties"] as? Bool,false);XCTAssertEqual(Set(object["required"] as! [String]),Set(properties.keys)) }
                for nested in object.values { check(nested) }
            } else if let array=value as? [Any] { for item in array { check(item) } }
        }
        check(ResponsesOutcomePort.schema)
    }
    func testLocalActiveOrMissingPlanRefuseBeforeTransport() async throws {
        for s in [try snapshot(local:true),try snapshot(state:"active"),try snapshot(plan:false)] {
            let http=OutcomeHTTP(body:Data()),p=try port(http)
            do { _=try await p.extract(.init(attemptID:UUID().uuidString,snapshot:s,configuration:p.configuration));XCTFail() } catch {}
            let calls=await http.calls;XCTAssertEqual(calls,0)
        }
    }
    func testValidResponsePreservesDualEvidenceRolesActionsAndUsage() throws {
        let s=try snapshot(),r=try ResponsesOutcomePort.parse(response(valid(s)),snapshot:s)
        XCTAssertEqual(r.proposals.count,2);XCTAssertEqual(r.proposals[0].action?.title,"校验迁移资料");XCTAssertEqual(r.proposals[1].ownership,.aiCandidate);XCTAssertEqual(r.proposals[1].replyEvidence[0].attemptID,s.replies[1].attemptID);XCTAssertEqual(r.inputTokens,10);XCTAssertEqual(r.outputTokens,20)
    }
    func testUnknownFieldsBadQuotesUsedTargetsAndExactAICopiesAreRejectedWithUsage() throws {
        let s=try snapshot()
        for mode in ["extra","missing-action","invented-quote","consumed-user","duplicate-ai","bad-index","spoof-role"] {
            var value=valid(s),rows=value["proposals"] as! [[String:Any]]
            switch mode {
            case "extra":rows[0]["deadline"]="invented"
            case "missing-action":rows[0].removeValue(forKey:"action")
            case "invented-quote":var refs=rows[0]["sourceEvidence"] as! [[String:Any]];refs[0]["quote"]="不存在的引文";rows[0]["sourceEvidence"]=refs
            case "consumed-user":let source=s.context.sources[1];rows[0]["sourceEvidence"]=[["reference":["sourceID":source.sourceID,"transcriptVersionID":source.transcriptVersionID,"spanID":source.spans[0].id],"quote":source.text]];rows[0]["action"]=NSNull()
            case "duplicate-ai":rows[1]["statement"]=s.replies[0].parts[0].text;rows[1]["replyEvidence"]=[["attemptID":s.replies[0].attemptID,"partIndex":0,"quote":s.replies[0].parts[0].text]]
            case "bad-index":rows[1]["replyEvidence"]=[["attemptID":s.replies[1].attemptID,"partIndex":9,"quote":s.replies[1].parts[0].text]]
            default:rows[1]["ownership"]="user_tentative"
            }
            value["proposals"]=rows
            do { _=try ResponsesOutcomePort.parse(response(value),snapshot:s);XCTFail(mode) }
            catch ModelPortFailure.rejected(_,let input,let output) { XCTAssertEqual(input,10);XCTAssertEqual(output,20) }
        }
    }
    func testRefusalIncompleteAndToolsCannotBecomeOutcomes() throws {
        let s=try snapshot()
        for (status,part) in [("incomplete","output_text"),("completed","refusal")] {
            let r=try ResponsesOutcomePort.parse(response(valid(s),status:status,part:part),snapshot:s);XCTAssertTrue(r.proposals.isEmpty);XCTAssertEqual(r.outputTokens,20)
        }
        let tool=try JSONSerialization.data(withJSONObject:["status":"completed","usage":["input_tokens":10,"output_tokens":20],"output":[["type":"function_call"]]])
        do { _=try ResponsesOutcomePort.parse(tool,snapshot:s);XCTFail() }
        catch ModelPortFailure.rejected(_,let input,let output) { XCTAssertEqual(input,10);XCTAssertEqual(output,20) }
    }
    func testHTTPFailuresSendOnceAndNeverEchoServerData() async throws {
        let s=try snapshot()
        for status in [302,401,429,503] {
            let http=OutcomeHTTP(status:status,body:Data("private-server-body".utf8)),p=try port(http)
            do { _=try await p.extract(.init(attemptID:UUID().uuidString,snapshot:s,configuration:p.configuration));XCTFail() }
            catch ModelPortFailure.rejected(let reason,_,_) { XCTAssertFalse(reason.contains("private-server-body")) }
            let calls=await http.calls;XCTAssertEqual(calls,1)
        }
    }
    func testForgedDigestFrozenReplyAndMalformedRetainedParagraphRefuseSafely() throws {
        let s=try snapshot(),p=try port(),plan=try XCTUnwrap(s.reusePlan)
        let wrongContext=LocalTranscriptContext(sources:s.context.sources,scalarBudget:8000,contentDigest:"wrong")
        let invalidPrior=OutcomePriorResult(attemptID:UUID().uuidString,producerSequence:1,kind:"ai_paragraph",state:"completed",contextID:UUID().uuidString,resultDigest:nil,coveredTurnIDs:[],claimIDs:[UUID().uuidString],replyAttemptID:nil,replyPartIndex:nil)
        let badPlan=ConversationOutcomeReusePlan(conversationID:plan.conversationID,conversationVersion:plan.conversationVersion,personalTargets:plan.personalTargets,priorResults:[invalidPrior])
        let frozen=ConversationOutcomeReply(attemptID:s.replies[1].attemptID,replyToTurnID:s.replies[1].replyToTurnID,state:"completed",validity:"frozen",digest:s.replies[1].digest,parts:s.replies[1].parts)
        for input in [ConversationOutcomeSnapshot(input:s.input,sessionState:s.sessionState,context:wrongContext,replies:s.replies,reusePlan:plan),ConversationOutcomeSnapshot(input:s.input,sessionState:s.sessionState,context:s.context,replies:s.replies,reusePlan:badPlan),ConversationOutcomeSnapshot(input:s.input,sessionState:s.sessionState,context:s.context,replies:[s.replies[0],frozen],reusePlan:plan)] {
            XCTAssertThrowsError(try p.makeRequest(.init(attemptID:UUID().uuidString,snapshot:input,configuration:p.configuration)))
        }
    }
    func testValidUsageFieldSurvivesInvalidOtherFieldWithoutAcceptingResponse() throws {
        let s=try snapshot()
        for (input,output,expectedInput,expectedOutput) in [(10 as Any,true as Any,10 as Int?,nil as Int?),(true as Any,20 as Any,nil as Int?,20 as Int?)] {
            let data=try JSONSerialization.data(withJSONObject:["status":"completed","usage":["input_tokens":input,"output_tokens":output],"output":[]])
            do { _=try ResponsesOutcomePort.parse(data,snapshot:s);XCTFail() }
            catch ModelPortFailure.rejected(_,let actualInput,let actualOutput) { XCTAssertEqual(actualInput,expectedInput);XCTAssertEqual(actualOutput,expectedOutput) }
        }
    }
    func testUnknownReplyStaysStatusMetadataWithoutInventedAssistantText() throws {
        let s=try snapshot(),p=try port(),last=s.replies[1]
        let unknown=ConversationOutcomeReply(attemptID:last.attemptID,replyToTurnID:last.replyToTurnID,state:"unknown",validity:"current",digest:nil,parts:[])
        let input=ConversationOutcomeSnapshot(input:s.input,sessionState:s.sessionState,context:s.context,replies:[s.replies[0],unknown],reusePlan:s.reusePlan)
        let http=try p.makeRequest(.init(attemptID:UUID().uuidString,snapshot:input,configuration:p.configuration))
        let root=try XCTUnwrap(JSONSerialization.jsonObject(with:try XCTUnwrap(http.httpBody)) as? [String:Any]),messages=root["input"] as! [[String:Any]]
        let body=try XCTUnwrap(JSONSerialization.jsonObject(with:Data((messages[0]["content"] as! String).utf8)) as? [String:Any]),timeline=body["timeline"] as! [[String:Any]]
        XCTAssertEqual(timeline.last?["role"] as? String,"reply_status");XCTAssertEqual(timeline.last?["state"] as? String,"unknown");XCTAssertTrue((timeline.last?["parts"] as! [Any]).isEmpty)
    }

}
