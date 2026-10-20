import XCTest
import Foundation
@testable import VoiceOSCore

private struct DerivationInspector:MediaInspector {
    func inspect(_ url:URL) async throws -> MediaInfo { throw VoiceOSError("text fixture") }
}
private actor DerivationDiscussion:DiscussionModelPort {
    let configuration=ModelConfiguration(provider:"synthetic",model:"discussion",promptVersion:"v1",schemaVersion:"v1",destination:.local)
    let cited:Bool
    var calls=0
    init(cited:Bool=false) { self.cited=cited }
    func reply(_ request:DiscussionModelRequest) async throws -> DiscussionModelResponse {
        calls += 1
        let source=request.snapshot.context.sources[0],ref=ClaimReference(sourceID:source.sourceID,transcriptVersionID:source.transcriptVersionID,spanID:source.spans[0].id)
        return DiscussionModelResponse(status:.completed,parts:[DiscussionPart(kind:.quotation,text:source.text,references:[ref]),DiscussionPart(kind:.aiSuggestion,text:"合成AI猜想：可以检查反例，尚未验证，不表示个人承诺。",references:cited ? [ref] : [])],inputTokens:9,outputTokens:5)
    }
}
final class DiscussionCandidateDerivationTests:XCTestCase {
    var base:URL!
    override func setUpWithError() throws { base=FileManager.default.temporaryDirectory.appendingPathComponent("discussion-derivation-"+UUID().uuidString) }
    override func tearDownWithError() throws { if FileManager.default.fileExists(atPath:base.path) { try FileManager.default.removeItem(at:base) } }
    func store(_ name:String="root",checkpoint:@escaping @Sendable (SaveCheckpoint) throws -> Void={_ in}) async throws -> VoiceOSStore {
        let s=try VoiceOSStore(root:base.appendingPathComponent(name),inspector:DerivationInspector(),checkpoint:checkpoint);try await s.recover();return s
    }
    private func setup(_ s:VoiceOSStore,cited:Bool=false) async throws -> (PreparedConversationInput,String,DerivationDiscussion) {
        let source=try await s.recordUserExpression("合成历史猜想：条件没有验证。")
        let id=try await s.beginConversation(sourceIDs:[source])
        let turn=try await s.recordUserExpression("合成个人追问：如何检验反例？")
        _=try await s.appendConversationUserSource(conversationID:id,sourceID:turn,expectedVersion:1)
        let input=try await s.prepareConversationInput(id:id,expectedVersion:2,destination:.local),port=DerivationDiscussion(cited:cited)
        let attempt=try await s.performConversationReply(input,using:port)
        return (input,attempt,port)
    }
    func testExplicitLocalCopyPreservesAIIdentityAnchorAndNeverCallsOrActs() async throws {
        let s=try await store(),(input,attempt,port)=try await setup(s)
        try await s.endConversation(id:input.conversationID,expectedVersion:2)
        let before=try await s.sources(),claim=try await s.retainDiscussionAICandidate(attemptID:attempt,partIndex:1,commandID:"keep")
        let again=try await s.retainDiscussionAICandidate(attemptID:attempt,partIndex:1,commandID:"another")
        XCTAssertEqual(claim,again)
        let claims=try await s.candidateClaims(),origins=try await s.discussionClaimOrigins(),actions=try await s.actions(),models=try await s.modelAttempts(),after=try await s.sources(),calls=await port.calls
        XCTAssertEqual(calls,1);XCTAssertEqual(before.map(\.id),after.map(\.id));XCTAssertEqual(before.map(\.transcript),after.map(\.transcript))
        XCTAssertEqual(claims.count,1);XCTAssertEqual(claims[0].ownership,"ai_candidate");XCTAssertEqual(claims[0].reviewState,"pending");XCTAssertEqual(claims[0].evidenceState,"unverified")
        XCTAssertEqual(claims[0].references[0].sourceID,input.userTurns.last?.sourceID)
        XCTAssertEqual(origins.count,1);XCTAssertEqual(origins[0].referenceKind,"context_anchor");XCTAssertEqual(origins[0].conversationID,input.conversationID)
        XCTAssertEqual(models.count,1);XCTAssertEqual(models[0].executionKind,"discussion_derivation");XCTAssertEqual(models[0].billingState,"not_applicable");XCTAssertNil(models[0].usage);XCTAssertTrue(actions.isEmpty)
        do { _=try await s.retainDiscussionAICandidate(attemptID:attempt,partIndex:0);XCTFail() } catch {}
        do { _=try await s.retainDiscussionAICandidate(attemptID:attempt,partIndex:0,commandID:"keep");XCTFail() } catch {}
    }
    func testActualModelCitationAndAnyInputCorrectionFreezeEvenUncitedHistory() async throws {
        for cited in [false,true] {
            let s=try await store(cited ? "cited":"anchor"),(input,attempt,_)=try await setup(s,cited:cited)
            let claim=try await s.retainDiscussionAICandidate(attemptID:attempt,partIndex:1)
            let action=try await s.createAction(claimID:claim,expectedClaimReviewVersion:0,title:"AI待核对建议",kind:.aiSuggestion,intentActor:.ai)
            let origins=try await s.discussionClaimOrigins();XCTAssertEqual(origins[0].referenceKind,cited ? "model_citation":"context_anchor")
            let entry=try await s.conversationHistorySources(conversationID:input.conversationID)[0]
            _=try await s.correctTranscript(sourceID:entry.sourceID,expectedVersionID:entry.transcriptVersionID,text:"合成历史更正")
            let frozen=try await s.candidateClaims(includeFrozen:true),models=try await s.modelAttempts()
            XCTAssertEqual(frozen[0].validity,"frozen");XCTAssertEqual(models[0].contextState,"stale")
            let receipt=try await s.retainDiscussionAICandidate(attemptID:attempt,partIndex:1);XCTAssertEqual(receipt,claim)
            let active=try await s.candidateClaims();XCTAssertTrue(active.isEmpty)
            let impact=try await s.correctionActionImpacts().first { $0.action.id == action }
            XCTAssertEqual(impact?.roots.map(\.sourceID),[entry.sourceID])
        }
    }
    func testLaterConversationTurnDoesNotBecomeEarlierReplyDependency() async throws {
        let s=try await store(),(input,attempt,_)=try await setup(s)
        let claim=try await s.retainDiscussionAICandidate(attemptID:attempt,partIndex:1)
        let action=try await s.createAction(claimID:claim,expectedClaimReviewVersion:0,title:"AI待核对建议",kind:.aiSuggestion,intentActor:.ai)
        let later=try await s.recordUserExpression("后续另一个问题。")
        _=try await s.appendConversationUserSource(conversationID:input.conversationID,sourceID:later,expectedVersion:2)
        let version=try await s.transcriptHistory(sourceID:later)[0].id
        _=try await s.correctTranscript(sourceID:later,expectedVersionID:version,text:"后续问题更正。")
        let impacts=try await s.correctionActionImpacts()
        XCTAssertFalse(impacts.contains { $0.action.id == action })
    }
    func testFrozenParentCannotCreateNewCandidateAndPolicyFreezesWholeInput() async throws {
        let s=try await store(),(input,attempt,_)=try await setup(s)
        let entry=try await s.conversationHistorySources(conversationID:input.conversationID)[0]
        _=try await s.setSourceLocalOnly(sourceID:entry.sourceID,expectedVersion:1,localOnly:false)
        do { _=try await s.retainDiscussionAICandidate(attemptID:attempt,partIndex:1);XCTFail() } catch {}
        let models=try await s.modelAttempts(),claims=try await s.candidateClaims(includeFrozen:true);XCTAssertTrue(models.isEmpty);XCTAssertTrue(claims.isEmpty)
    }
    func testAllThreeInterruptedBoundariesResumeOnlyExplicitlyAndKeepSingleIdentity() async throws {
        for point in [SaveCheckpoint.discussionCandidateReserved,.discussionCandidateUncommitted,.discussionCandidateCommitted] {
            var attempt="",convo=""
            do {
                let s=try await store(point.rawValue,checkpoint:{ if $0 == point { throw VoiceOSError("injected interruption") } }),result=try await setup(s)
                convo=result.0.conversationID;attempt=result.1
                do { _=try await s.retainDiscussionAICandidate(attemptID:attempt,partIndex:1,commandID:"keep");XCTFail() } catch {}
            }
            let s=try await store(point.rawValue),before=try await s.discussionClaimDerivations(conversationID:convo),claims=try await s.candidateClaims()
            XCTAssertEqual(before.count,1);XCTAssertEqual(claims.count,point == .discussionCandidateCommitted ? 1:0)
            let id=try await s.retainDiscussionAICandidate(attemptID:attempt,partIndex:1,commandID:"keep")
            let again=try await s.retainDiscussionAICandidate(attemptID:attempt,partIndex:1),all=try await s.candidateClaims(),models=try await s.modelAttempts(),actions=try await s.actions()
            XCTAssertEqual(id,again);XCTAssertEqual(all.count,1);XCTAssertEqual(models.count,1);XCTAssertTrue(actions.isEmpty)
        }
    }
    func testReviewAndPortableRoundTripKeepOriginalAIParagraphAndFrozenProvenance() async throws {
        let s=try await store(),(input,attempt,_)=try await setup(s),claim=try await s.retainDiscussionAICandidate(attemptID:attempt,partIndex:1)
        _=try await s.reviewClaim(claimID:claim,expectedVersion:0,action:.endorse)
        _=try await s.reviewClaim(claimID:claim,expectedVersion:1,action:.correct,statement:"合成更正：反例尚需验证",ownership:.userTentative,note:"明确更正归属")
        let package=base.appendingPathComponent("package")
        try await s.exportPackage(to:package,includeMedia:true)
        try await VoiceOSStore.restorePackage(from:package,to:base.appendingPathComponent("restored"),inspector:DerivationInspector())
        let r=try await store("restored"),claims=try await r.candidateClaims(includeFrozen:true),history=try await r.claimReviewHistory(claimID:claim),origins=try await r.discussionClaimDerivations(conversationID:input.conversationID),actions=try await r.actions(),models=try await r.modelAttempts()
        XCTAssertEqual(claims[0].id,claim);XCTAssertEqual(claims[0].validity,"frozen");XCTAssertEqual(claims[0].ownership,"user_tentative")
        XCTAssertEqual(history[0].ownership,"ai_candidate");XCTAssertEqual(history.count,3);XCTAssertEqual(origins[0].claimID,claim);XCTAssertTrue(actions.isEmpty);XCTAssertEqual(models[0].billingState,"not_applicable")
        let replay=try await r.retainDiscussionAICandidate(attemptID:attempt,partIndex:1);XCTAssertEqual(replay,claim)
    }
    func testPendingPortableRestoreNeverResumesFrozenDiscussion() async throws {
        let s=try await store(checkpoint:{ if $0 == .discussionCandidateReserved { throw VoiceOSError("interrupted") } }),(_,attempt,_)=try await setup(s)
        do { _=try await s.retainDiscussionAICandidate(attemptID:attempt,partIndex:1);XCTFail() } catch {}
        let package=base.appendingPathComponent("package")
        try await s.exportPackage(to:package)
        try await VoiceOSStore.restorePackage(from:package,to:base.appendingPathComponent("restored"),inspector:DerivationInspector())
        let r=try await store("restored")
        do { _=try await r.retainDiscussionAICandidate(attemptID:attempt,partIndex:1);XCTFail() } catch {}
        let claims=try await r.candidateClaims(includeFrozen:true);XCTAssertTrue(claims.isEmpty)
    }
    func testPortableTamperingCannotRelabelLocalCopyOrRewriteOriginalAndProvenance() async throws {
        let s=try await store(),(_,attempt,_)=try await setup(s)
        _=try await s.retainDiscussionAICandidate(attemptID:attempt,partIndex:1)
        for kind in ["missing_relation","wrong_part","fake_citation","fake_model","user_ownership"] {
            let package=base.appendingPathComponent(kind),target=base.appendingPathComponent(kind+"-restored")
            try await s.exportPackage(to:package)
            let table=kind == "fake_model" ? "model_attempts" : (kind == "user_ownership" ? "claims" : "discussion_claim_derivations")
            let file=package.appendingPathComponent(table+".jsonl")
            var rows=try String(contentsOf:file,encoding:.utf8).split(separator:"\n").map { try XCTUnwrap(JSONSerialization.jsonObject(with:Data($0.utf8)) as? [String:Any]) }
            switch kind {
            case "missing_relation": rows=[]
            case "wrong_part": rows[0]["part_index"]=0
            case "fake_citation": rows[0]["reference_kind"]="model_citation"
            case "fake_model": rows[0]["execution_kind"]="model_request"
            default: rows[0]["ownership"]="user_tentative"
            }
            var data=Data()
            for row in rows { data.append(try JSONSerialization.data(withJSONObject:row,options:[.sortedKeys]));data.append(10) }
            try data.write(to:file)
            let manifest=package.appendingPathComponent("manifest.json")
            var m=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:manifest)) as? [String:Any]),files=m["files"] as! [[String:Any]]
            let index=files.firstIndex { $0["path"] as? String == table+".jsonl" }!,hash=try DurableFiles.hash(file)
            files[index]["bytes"]=hash.0;files[index]["sha256"]=hash.1;m["files"]=files
            try JSONSerialization.data(withJSONObject:m).write(to:manifest)
            do { try await VoiceOSStore.restorePackage(from:package,to:target,inspector:DerivationInspector());XCTFail(kind) } catch {}
            XCTAssertFalse(FileManager.default.fileExists(atPath:target.path))
        }
    }

    func testPolicyChangeOfUncitedEntryFreezesRetainedAnchor() async throws {
        let s=try await store(),(input,attempt,_)=try await setup(s)
        _=try await s.retainDiscussionAICandidate(attemptID:attempt,partIndex:1)
        let entry=try await s.conversationHistorySources(conversationID:input.conversationID)[0]
        _=try await s.setSourceLocalOnly(sourceID:entry.sourceID,expectedVersion:1,localOnly:false)
        let claims=try await s.candidateClaims(includeFrozen:true),models=try await s.modelAttempts()
        XCTAssertEqual(claims[0].validity,"frozen");XCTAssertEqual(models[0].contextState,"stale")
    }
    func testLocalDerivationDoesNotConsumePersonalUnderstandingIdentity() async throws {
        let s=try await store(),(input,attempt,_)=try await setup(s)
        _=try await s.retainDiscussionAICandidate(attemptID:attempt,partIndex:1)
        let turn=try XCTUnwrap(input.userTurns.last)
        let port=DerivationUnderstanding()
        _=try await s.understandConversationUserTurn(conversationID:input.conversationID,turnID:turn.turnID,using:port)
        let models=try await s.modelAttempts(sourceID:turn.sourceID),calls=await port.calls
        XCTAssertEqual(calls,1);XCTAssertEqual(Set(models.map(\.executionKind)),["model_request","discussion_derivation"])
    }

}

private actor DerivationUnderstanding:ModelPort {
    let configuration=ModelConfiguration(provider:"synthetic",model:"understanding",promptVersion:"v1",schemaVersion:"v1",destination:.local)
    var calls=0
    func generate(_ request:ModelRequest) async throws -> ModelResponse { calls += 1;return ModelResponse(status:.completed,claims:[]) }
}
