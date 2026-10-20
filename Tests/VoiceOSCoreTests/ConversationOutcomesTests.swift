import XCTest
import Foundation
@testable import VoiceOSCore

private struct DurableOutcomeInspector:MediaInspector {
    func inspect(_ url:URL) async throws -> MediaInfo { throw VoiceOSError("text fixture") }
}
private actor DurableOutcomePort:ConversationOutcomePort {
    let configuration=ModelConfiguration(provider:"synthetic",model:"outcome",promptVersion:"v1",schemaVersion:"v1",destination:.local)
    let mode:String
    let callback:(@Sendable (ConversationOutcomeRequest) async throws -> Void)?
    var calls=0
    init(_ mode:String="valid",callback:(@Sendable (ConversationOutcomeRequest) async throws -> Void)?=nil) { self.mode=mode;self.callback=callback }
    func extract(_ request:ConversationOutcomeRequest) async throws -> ConversationOutcomeResponse {
        calls += 1
        if let callback { try await callback(request) }
        if mode == "unknown" { throw VoiceOSError("synthetic timeout") }
        if mode == "rejected" { throw ModelPortFailure.rejected("synthetic",inputTokens:7,outputTokens:2) }
        let turn=request.snapshot.input.userTurns.last!,s=request.snapshot.context.sources.first { $0.sourceID == turn.sourceID }!,ref=ClaimReference(sourceID:s.sourceID,transcriptVersionID:s.transcriptVersionID,spanID:s.spans[0].id)
        let original=OutcomeSourceEvidence(reference:ref,quote:"我会整理开发验证素材"),reply=request.snapshot.replies.last!
        let ai=OutcomeReplyEvidence(attemptID:reply.attemptID,partIndex:0,quote:reply.parts[0].text)
        let personal=ConversationOutcomeProposal(statement:"我会整理开发验证素材",ownership:.userTentative,sourceEvidence:[original],action:ExtractedAction(title:"整理开发验证素材",kind:.task,quote:original.quote,autoSend:true))
        let suggestion=ConversationOutcomeProposal(statement:ai.quote,ownership:mode == "spoof" ? .userTentative:.aiCandidate,sourceEvidence:[],replyEvidence:[ai],action:ExtractedAction(title:"阅读论文",kind:.aiSuggestion,quote:"阅读论文"))
        return ConversationOutcomeResponse(status:mode == "refused" ? .refused:.completed,proposals:mode == "empty" ? []:[personal,suggestion],inputTokens:12,outputTokens:mode == "negative" ? -1:6)
    }
}
private struct DurableOutcomeDiscussion:DiscussionModelPort {
    let configuration=ModelConfiguration(provider:"synthetic",model:"discussion",promptVersion:"v1",schemaVersion:"v1",destination:.local)
    func reply(_ request:DiscussionModelRequest) async throws -> DiscussionModelResponse {
        DiscussionModelResponse(status:.completed,parts:[.init(kind:.aiSuggestion,text:"合成AI建议：可以阅读论文，尚未验证，不代表用户承诺。")])
    }
}
final class ConversationOutcomesTests:XCTestCase {
    var base:URL!
    override func setUpWithError() throws { base=FileManager.default.temporaryDirectory.appendingPathComponent("durable-outcomes-"+UUID().uuidString) }
    override func tearDownWithError() throws { if FileManager.default.fileExists(atPath:base.path) { try FileManager.default.removeItem(at:base) } }
    func store(_ name:String="root",checkpoint:@escaping @Sendable (SaveCheckpoint) throws -> Void={_ in}) async throws -> VoiceOSStore { let s=try VoiceOSStore(root:base.appendingPathComponent(name),inspector:DurableOutcomeInspector(),checkpoint:checkpoint);try await s.recover();return s }
    func setup(_ s:VoiceOSStore,end:Bool=true) async throws -> ConversationOutcomeSnapshot {
        let history=try await s.recordUserExpression("合成旧猜想：条件尚未验证。"),source=try await s.recordUserExpression("合成个人：我会整理开发验证素材。我现在不打算阅读论文。")
        let id=try await s.beginConversation(sourceIDs:[history]);_=try await s.appendConversationUserSource(conversationID:id,sourceID:source,expectedVersion:1)
        let input=try await s.prepareConversationInput(id:id,expectedVersion:2,destination:.local);_=try await s.performConversationReply(input,using:DurableOutcomeDiscussion())
        if end { try await s.endConversation(id:id,expectedVersion:2) }
        return try await s.prepareConversationOutcome(id:id,expectedVersion:end ? 3:2,destination:.local)
    }
    func testAtomicMixedResultKeepsAIProvenanceAndOnlyPersonalTask() async throws {
        let s=try await store(),input=try await setup(s),port=DurableOutcomePort()
        let ids=try await s.performConversationOutcome(input,using:port),claims=try await s.candidateClaims(),actions=try await s.actions(),receipts=try await s.conversationOutcomes(conversationID:input.input.conversationID)
        let origins=try await s.conversationOutcomeOrigins();XCTAssertEqual(Set(origins.map(\.referenceKind)),["source_citation","context_anchor"]);XCTAssertEqual(Set(origins.map(\.claimID)),Set(ids))
        XCTAssertEqual(ids.count,2);XCTAssertEqual(claims.count,2);XCTAssertEqual(Set(claims.map(\.ownership)),["ai_candidate","user_tentative"])
        XCTAssertTrue(claims.allSatisfy { $0.reviewState == "pending" && $0.evidenceState == "unverified" })
        XCTAssertEqual(actions.count,1);XCTAssertEqual(actions[0].title,"整理开发验证素材");XCTAssertTrue(actions[0].autoSend);XCTAssertEqual(actions[0].intentActor,"user")
        XCTAssertEqual(receipts[0].claimIDs,ids);XCTAssertEqual(receipts[0].proposals[1].replyEvidence[0].attemptID,input.replies[0].attemptID)
        XCTAssertEqual(receipts[0].proposals[1].action?.kind,.aiSuggestion);XCTAssertEqual(receipts[0].usage,["input_tokens":12,"output_tokens":6])
        do { _=try await s.performConversationOutcome(input,using:port);XCTFail() } catch {}
        let calls=await port.calls;XCTAssertEqual(calls,1)
    }
    func testActiveConversationCannotExtractAndUnknownCannotReprepareOrChangePortToResend() async throws {
        let s=try await store(),active=try await setup(s,end:false),port=DurableOutcomePort()
        do { _=try await s.performConversationOutcome(active,using:port);XCTFail() } catch {}
        let before=await port.calls;XCTAssertEqual(before,0)
        try await s.endConversation(id:active.input.conversationID,expectedVersion:2)
        let input=try await s.prepareConversationOutcome(id:active.input.conversationID,expectedVersion:3,destination:.local),unknown=DurableOutcomePort("unknown")
        do { _=try await s.performConversationOutcome(input,using:unknown);XCTFail() } catch {}
        let reprepare=try await s.prepareConversationOutcome(id:active.input.conversationID,expectedVersion:3,destination:.local)
        do { _=try await s.performConversationOutcome(reprepare,using:port);XCTFail() } catch {}
        let rows=try await s.conversationOutcomes(conversationID:active.input.conversationID),calls=await port.calls;XCTAssertEqual(calls,0);XCTAssertEqual(rows[0].state,"unknown");XCTAssertTrue(rows[0].claimIDs.isEmpty)
    }
    func testRefusalSpoofNegativeAndKnownRejectionNeverCommitAndKeepKnownUsage() async throws {
        for mode in ["refused","spoof","negative","rejected"] {
            let s=try await store(mode),input=try await setup(s)
            do { _=try await s.performConversationOutcome(input,using:DurableOutcomePort(mode));XCTFail(mode) } catch {}
            let rows=try await s.conversationOutcomes(conversationID:input.input.conversationID),claims=try await s.candidateClaims(),actions=try await s.actions()
            XCTAssertEqual(rows[0].state,"rejected");XCTAssertTrue(claims.isEmpty);XCTAssertTrue(actions.isEmpty)
            if mode == "rejected" { XCTAssertEqual(rows[0].usage,["input_tokens":7,"output_tokens":2]) }
        }
    }
    func testCorrectionDuringAwaitRejectsMixedResultAndAction() async throws {
        let s=try await store(),input=try await setup(s)
        let port=DurableOutcomePort(callback:{ request in
            let source=request.snapshot.context.sources[0]
            _=try await s.correctTranscript(sourceID:source.sourceID,expectedVersionID:source.transcriptVersionID,text:"合成历史更正")
        })
        do { _=try await s.performConversationOutcome(input,using:port);XCTFail() } catch {}
        let rows=try await s.conversationOutcomes(conversationID:input.input.conversationID),claims=try await s.candidateClaims(includeFrozen:true),actions=try await s.actions(includeHistory:true)
        XCTAssertEqual(rows[0].state,"rejected");XCTAssertEqual(rows[0].validity,"frozen");XCTAssertTrue(claims.isEmpty);XCTAssertTrue(actions.isEmpty);XCTAssertEqual(rows[0].usage,["input_tokens":12,"output_tokens":6])
    }
    func testReservationAndAtomicInterruptionRecoverWithoutCallingAgain() async throws {
        for point in [SaveCheckpoint.outcomeReserved,.outcomeUncommitted,.outcomeCommitted] {
            var id=""
            do {
                let s=try await store(point.rawValue,checkpoint:{ if $0 == point { throw VoiceOSError("interrupted") } }),input=try await setup(s)
                id=input.input.conversationID
                do { _=try await s.performConversationOutcome(input,using:DurableOutcomePort());XCTFail() } catch {}
            }
            let s=try await store(point.rawValue),rows=try await s.conversationOutcomes(conversationID:id),claims=try await s.candidateClaims(),actions=try await s.actions()
            XCTAssertEqual(rows.count,1);XCTAssertEqual(rows[0].state,point == .outcomeCommitted ? "completed":(point == .outcomeReserved ? "unknown":"rejected"))
            XCTAssertEqual(claims.count,point == .outcomeCommitted ? 2:0);XCTAssertEqual(actions.count,point == .outcomeCommitted ? 1:0)
            let input=try await s.prepareConversationOutcome(id:id,expectedVersion:3,destination:.local),port=DurableOutcomePort()
            do { _=try await s.performConversationOutcome(input,using:port);XCTFail() } catch {}
            let calls=await port.calls;XCTAssertEqual(calls,0)
        }
    }
    func testEmptyResultIsDurableCompleteAndGenericCommitCheckpointCannotReportNoCandidatesAfterCommit() async throws {
        let empty=try await store("empty"),input=try await setup(empty)
        let ids=try await empty.performConversationOutcome(input,using:DurableOutcomePort("empty"));XCTAssertTrue(ids.isEmpty)
        let rows=try await empty.conversationOutcomes(conversationID:input.input.conversationID);XCTAssertEqual(rows[0].state,"completed")
        let s=try await store("post-commit",checkpoint:{ if $0 == .claimsCommitted { throw VoiceOSError("after commit") } }),i=try await setup(s)
        let committed=try await s.performConversationOutcome(i,using:DurableOutcomePort());XCTAssertEqual(committed.count,2)
    }
    func testPortableIdentityAIQuotesAndActionsSurviveAndFreeze() async throws {
        let s=try await store(),input=try await setup(s),ids=try await s.performConversationOutcome(input,using:DurableOutcomePort())
        let action=try await s.actions()[0]
        _=try await s.setActionState(actionID:action.id,expectedVersion:1,state:.completed)
        let feedbackSource=try await s.recordActionFeedback(actionID:action.id,expectedVersion:2,kind:.outcome,text:"合成验证：仅流程完成，技术猜想没有验证。")
        let original=try await s.conversationOutcomes(conversationID:input.input.conversationID)[0],package=base.appendingPathComponent("package")
        try await s.exportPackage(to:package,includeMedia:true)
        try await VoiceOSStore.restorePackage(from:package,to:base.appendingPathComponent("restored"),inspector:DurableOutcomeInspector())
        let r=try await store("restored"),rows=try await r.conversationOutcomes(conversationID:input.input.conversationID),claims=try await r.candidateClaims(includeFrozen:true),actions=try await r.actions(includeHistory:true)
        XCTAssertEqual(rows[0].id,original.id);XCTAssertEqual(rows[0].claimIDs,ids);XCTAssertEqual(rows[0].validity,"frozen");XCTAssertEqual(rows[0].usage,original.usage)
        let feedback=try await r.actionFeedback(actionID:action.id)
        XCTAssertEqual(feedback[0].sourceID,feedbackSource);XCTAssertEqual(feedback[0].actionVersion,2);XCTAssertEqual(actions[0].state,"completed");XCTAssertEqual(actions[0].version,2)
        XCTAssertTrue(claims.allSatisfy { $0.evidenceState == "unverified" && $0.reviewState == "pending" })
        XCTAssertEqual(try VoiceOSStore.relevanceJSON(rows[0].proposals),try VoiceOSStore.relevanceJSON(original.proposals));XCTAssertTrue(claims.allSatisfy { $0.validity == "frozen" });XCTAssertTrue(actions.allSatisfy { $0.validity == "frozen" })
    }
    func testPolicyChangeDuringAwaitAndConcurrentDuplicateCannotCommitOrResend() async throws {
        let s=try await store(),input=try await setup(s),fresh=DurableOutcomePort()
        let port=DurableOutcomePort(callback:{ request in
            do { _=try await s.performConversationOutcome(request.snapshot,using:fresh);XCTFail("concurrent duplicate") } catch {}
            let source=request.snapshot.context.sources[0]
            _=try await s.setSourceLocalOnly(sourceID:source.sourceID,expectedVersion:1,localOnly:false)
        })
        do { _=try await s.performConversationOutcome(input,using:port);XCTFail() } catch {}
        let calls=await fresh.calls,claims=try await s.candidateClaims(includeFrozen:true);XCTAssertEqual(calls,0);XCTAssertTrue(claims.isEmpty)
    }
    func testPortableRehashedTamperingCannotOmitAIOrInventPersonalProvenance() async throws {
        let s=try await store(),input=try await setup(s);_=try await s.performConversationOutcome(input,using:DurableOutcomePort())
        for kind in ["omit_ai","omit_personal","alter_ai_quote","omit_relation"] {
            let package=base.appendingPathComponent(kind),target=base.appendingPathComponent(kind+"-restored")
            try await s.exportPackage(to:package)
            let file=package.appendingPathComponent("conversation_outcome_attempts.jsonl")
            var rows=try String(contentsOf:file,encoding:.utf8).split(separator:"\n").map { try XCTUnwrap(JSONSerialization.jsonObject(with:Data($0.utf8)) as? [String:Any]) }
            if kind == "omit_relation" { rows=[] }
            else if kind == "alter_ai_quote" {
                var proposals=try XCTUnwrap(JSONSerialization.jsonObject(with:Data((rows[0]["result_json"] as! String).utf8)) as? [[String:Any]])
                var refs=proposals[1]["replyEvidence"] as! [[String:Any]];refs[0]["quote"]="伪造AI引文";proposals[1]["replyEvidence"]=refs
                let data=try JSONSerialization.data(withJSONObject:proposals,options:[.sortedKeys]);rows[0]["result_json"]=String(decoding:data,as:UTF8.self);rows[0]["result_digest"]=VoiceOSStore.relevanceHash(data)
            } else {
                var snapshot=try XCTUnwrap(JSONSerialization.jsonObject(with:Data((rows[0]["snapshot_json"] as! String).utf8)) as? [String:Any])
                if kind == "omit_ai" { snapshot["replies"]=[] }
                else { var i=snapshot["input"] as! [String:Any];i["userTurns"]=[];snapshot["input"]=i }
                let data=try JSONSerialization.data(withJSONObject:snapshot,options:[.sortedKeys]);rows[0]["snapshot_json"]=String(decoding:data,as:UTF8.self);rows[0]["snapshot_digest"]=VoiceOSStore.relevanceHash(data)
            }
            var data=Data();for row in rows { data.append(try JSONSerialization.data(withJSONObject:row));data.append(10) };try data.write(to:file)
            let manifest=package.appendingPathComponent("manifest.json")
            var m=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:manifest)) as? [String:Any]),files=m["files"] as! [[String:Any]]
            let index=files.firstIndex { $0["path"] as? String == "conversation_outcome_attempts.jsonl" }!,hash=try DurableFiles.hash(file)
            files[index]["bytes"]=hash.0;files[index]["sha256"]=hash.1;m["files"]=files
            try JSONSerialization.data(withJSONObject:m).write(to:manifest)
            do { try await VoiceOSStore.restorePackage(from:package,to:target,inspector:DurableOutcomeInspector());XCTFail(kind) } catch {}
            XCTAssertFalse(FileManager.default.fileExists(atPath:target.path))
        }
    }

    func testExactAIParagraphAlreadyInOutcomeIsReusedWithoutResetOrNewDerivation() async throws {
        let s=try await store(),input=try await setup(s),ids=try await s.performConversationOutcome(input,using:DurableOutcomePort())
        _=try await s.reviewClaim(claimID:ids[1],expectedVersion:0,action:.reject)
        let reused=try await s.retainDiscussionAICandidate(attemptID:input.replies[0].attemptID,partIndex:0)
        XCTAssertEqual(reused,ids[1])
        let claims=try await s.candidateClaims(includeFrozen:true),derivations=try await s.discussionClaimDerivations(conversationID:input.input.conversationID),models=try await s.modelAttempts()
        XCTAssertEqual(claims.count,2);XCTAssertEqual(claims.first(where: { $0.id == reused })?.reviewState,"rejected");XCTAssertTrue(derivations.isEmpty);XCTAssertEqual(models.count,1)
    }
    func testExistingStandaloneCandidateBlocksRequestAndCopyDuringAwaitRejectsDuplicateOutcome() async throws {
        let s=try await store("before"),input=try await setup(s),port=DurableOutcomePort()
        _=try await s.retainDiscussionAICandidate(attemptID:input.replies[0].attemptID,partIndex:0)
        do { _=try await s.performConversationOutcome(input,using:port);XCTFail() } catch {}
        let calls=await port.calls;XCTAssertEqual(calls,0)
        let r=try await store("during"),i=try await setup(r)
        let waiting=DurableOutcomePort(callback:{ request in _=try await r.retainDiscussionAICandidate(attemptID:request.snapshot.replies[0].attemptID,partIndex:0) })
        do { _=try await r.performConversationOutcome(i,using:waiting);XCTFail() } catch {}
        let claims=try await r.candidateClaims(),actions=try await r.actions(),rows=try await r.conversationOutcomes(conversationID:i.input.conversationID)
        XCTAssertEqual(claims.count,1);XCTAssertTrue(actions.isEmpty);XCTAssertEqual(rows[0].state,"rejected")
    }

    func testPreviouslyUnderstoodPersonalVersionBlocksMixedRequestBeforeDuplicateAction() async throws {
        let s=try await store(),input=try await setup(s),source=input.input.userTurns[0].sourceID
        let personal=try await s.prepareLocalTranscriptContext(sourceIDs:[source]),context=try await s.persistLocalContext(personal)
        let ordinary=try await s.reserveLocalModelAttempt(contextID:context,model:"fixture",promptVersion:"v1",schemaVersion:"v1")
        _=try await s.commitLocalClaims(attemptID:ordinary,proposals:[])
        let port=DurableOutcomePort()
        do { _=try await s.performConversationOutcome(input,using:port);XCTFail() } catch {}
        let calls=await port.calls,outcomes=try await s.conversationOutcomes(conversationID:input.input.conversationID),actions=try await s.actions()
        XCTAssertEqual(calls,0);XCTAssertTrue(outcomes.isEmpty);XCTAssertTrue(actions.isEmpty)
    }

    func testOutcomeReservationAndCompletionBlockSingleSourceReunderstandingWithoutNewCalls() async throws {
        let s=try await store(),input=try await setup(s),personal=DurablePersonalOutcomePort(),source=input.input.userTurns[0].sourceID
        let port=DurableOutcomePort(callback:{ _ in
            do { _=try await s.understandSource(sourceID:source,using:personal);XCTFail("duplicate during wait") } catch {}
        })
        _=try await s.performConversationOutcome(input,using:port)
        do { _=try await s.understandSource(sourceID:source,using:personal);XCTFail("duplicate after commit") } catch {}
        let calls=await personal.calls,models=try await s.modelAttempts(),actions=try await s.actions()
        XCTAssertEqual(calls,0);XCTAssertEqual(models.count,1);XCTAssertEqual(actions.count,1)
    }

}

private actor DurablePersonalOutcomePort:ModelPort {
    let configuration=ModelConfiguration(provider:"synthetic_personal",model:"personal",promptVersion:"v1",schemaVersion:"v1",destination:.local)
    var calls=0
    func generate(_ request:ModelRequest) async throws -> ModelResponse { calls += 1;return ModelResponse(status:.completed,claims:[]) }
}
