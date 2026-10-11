import XCTest
@testable import VoiceOSCore

private struct ReuseInspector:MediaInspector {
    func inspect(_ url:URL) async throws -> MediaInfo { throw VoiceOSError("text fixture") }
}
private struct ReuseDiscussion:DiscussionModelPort {
    let configuration=ModelConfiguration(provider:"synthetic",model:"discussion",promptVersion:"v1",schemaVersion:"v1",destination:.local)
    func reply(_ request:DiscussionModelRequest) async throws -> DiscussionModelResponse {
        .init(status:.completed,parts:[.init(kind:.aiSuggestion,text:"合成AI：可比较迁移反例，尚未验证。")])
    }
}
private struct ReusePersonal:ModelPort {
    let mode:String
    var configuration:ModelConfiguration { .init(provider:"synthetic",model:mode,promptVersion:"v1",schemaVersion:"v1",destination:.local) }
    func generate(_ request:ModelRequest) async throws -> ModelResponse {
        if mode == "unknown" { throw VoiceOSError("synthetic unknown") }
        if mode == "rejected" { throw ModelPortFailure.rejected("synthetic",inputTokens:1,outputTokens:1) }
        let source=request.context.sources[0]
        let proposal=ClaimProposal(statement:source.text,ownership:.userTentative,references:[.init(sourceID:source.sourceID,transcriptVersionID:source.transcriptVersionID,spanID:source.spans[0].id)],action:.init(title:"整理开发验证素材",kind:.task,quote:source.text,autoSend:true))
        return .init(status:.completed,claims:mode == "empty" ? []:[proposal])
    }
}
final class ConversationOutcomeReuseTests:XCTestCase {
    var root:URL!
    override func setUpWithError() throws { root=FileManager.default.temporaryDirectory.appendingPathComponent("reuse-plan-"+UUID().uuidString) }
    override func tearDownWithError() throws { if FileManager.default.fileExists(atPath:root.path) { try FileManager.default.removeItem(at:root) } }
    func setup(_ name:String="root") async throws -> (VoiceOSStore,ConversationOutcomeSnapshot) {
        let s=try VoiceOSStore(root:root.appendingPathComponent(name),inspector:ReuseInspector());try await s.recover()
        let old=try await s.recordUserExpression("合成历史：不要把待验证猜想当事实。"),first=try await s.recordUserExpression("我会整理开发验证素材。"),second=try await s.recordUserExpression("我会校验迁移资料。")
        let id=try await s.beginConversation(sourceIDs:[old]);_=try await s.appendConversationUserSource(conversationID:id,sourceID:first,expectedVersion:1)
        let input=try await s.prepareConversationInput(id:id,expectedVersion:2,destination:.local);_=try await s.performConversationReply(input,using:ReuseDiscussion())
        _=try await s.appendConversationUserSource(conversationID:id,sourceID:second,expectedVersion:2);try await s.endConversation(id:id,expectedVersion:3)
        return (s,try await s.prepareConversationOutcome(id:id,expectedVersion:4,destination:.local))
    }
    func personal(_ snapshot:ConversationOutcomeSnapshot,index:Int) -> ConversationOutcomeProposal {
        let turn=snapshot.input.userTurns[index],source=snapshot.context.sources.first { $0.sourceID == turn.sourceID }!
        return .init(statement:source.text,ownership:.userTentative,sourceEvidence:[.init(reference:.init(sourceID:source.sourceID,transcriptVersionID:source.transcriptVersionID,spanID:source.spans[0].id),quote:source.text)])
    }
    func testPlanningIsReadOnlyAndKeepsWholeHistoryAndAllUnprocessedTargets() async throws {
        let (s,snapshot)=try await setup(),first=try await s.conversationOutcomeReusePlan(for:snapshot),second=try await s.conversationOutcomeReusePlan(for:snapshot)
        XCTAssertEqual(first.personalTargets,snapshot.input.userTurns);XCTAssertTrue(first.priorResults.isEmpty)
        XCTAssertEqual(try VoiceOSStore.relevanceJSON(first),try VoiceOSStore.relevanceJSON(second))
        let models=try await s.modelAttempts(),claims=try await s.candidateClaims(),actions=try await s.actions()
        XCTAssertTrue(models.isEmpty);XCTAssertTrue(claims.isEmpty);XCTAssertTrue(actions.isEmpty)
        XCTAssertEqual(snapshot.context.sources.count,3);XCTAssertEqual(snapshot.replies.count,1)
    }
    func testExistingPersonalIdentityExcludesOnlyItsVersionAndPreservesReviewAndTask() async throws {
        let (s,snapshot)=try await setup(),ids=try await s.understandSource(sourceID:snapshot.input.userTurns[0].sourceID,using:ReusePersonal(mode:"normal"))
        let plan=try await s.conversationOutcomeReusePlan(for:snapshot),action=try await s.actions()[0]
        XCTAssertEqual(plan.personalTargets,[snapshot.input.userTurns[1]]);XCTAssertEqual(plan.priorResults[0].claimIDs,ids);XCTAssertEqual(plan.priorResults[0].coveredTurnIDs,[snapshot.input.userTurns[0].turnID])
        _=try await s.setActionState(actionID:action.id,expectedVersion:1,state:.completed)
        _=try await s.reviewClaim(claimID:ids[0],expectedVersion:0,action:.reject)
        try await s.validateConversationOutcomeReusePlan(plan,snapshot:snapshot)
        let claims=try await s.candidateClaims(includeFrozen:true),actions=try await s.actions(includeHistory:true)
        XCTAssertEqual(claims[0].reviewState,"rejected");XCTAssertEqual(actions[0].id,action.id);XCTAssertEqual(actions[0].version,2);XCTAssertEqual(actions[0].state,"completed")
        XCTAssertThrowsError(try VoiceOSStore.validateReusableConversationOutcomeProposals([personal(snapshot,index:0)],snapshot:snapshot,plan:plan))
        try VoiceOSStore.validateReusableConversationOutcomeProposals([personal(snapshot,index:1)],snapshot:snapshot,plan:plan)
    }
    func testEmptyUnknownAndRejectedAreConsumedWithoutInventingCandidatesOrResending() async throws {
        for mode in ["empty","unknown","rejected"] {
            let (s,snapshot)=try await setup(mode)
            do { _=try await s.understandSource(sourceID:snapshot.input.userTurns[0].sourceID,using:ReusePersonal(mode:mode));XCTAssertEqual(mode,"empty") } catch { XCTAssertNotEqual(mode,"empty") }
            let plan=try await s.conversationOutcomeReusePlan(for:snapshot),models=try await s.modelAttempts(),claims=try await s.candidateClaims(),actions=try await s.actions()
            XCTAssertEqual(plan.personalTargets.count,1);XCTAssertEqual(plan.priorResults.count,1);XCTAssertTrue(plan.priorResults[0].claimIDs.isEmpty)
            XCTAssertEqual(plan.priorResults[0].state,mode == "empty" ? "completed":mode);XCTAssertEqual(models.count,1);XCTAssertTrue(claims.isEmpty);XCTAssertTrue(actions.isEmpty)
        }
    }
    func testStandaloneAIIdentityDoesNotConsumePersonalTargetsAndRejectsExactCopy() async throws {
        let (s,snapshot)=try await setup(),reply=snapshot.replies[0],id=try await s.retainDiscussionAICandidate(attemptID:reply.attemptID,partIndex:0)
        _=try await s.reviewClaim(claimID:id,expectedVersion:0,action:.reject)
        let plan=try await s.conversationOutcomeReusePlan(for:snapshot)
        XCTAssertEqual(plan.personalTargets,snapshot.input.userTurns);XCTAssertEqual(plan.priorResults.count,1);XCTAssertEqual(plan.priorResults[0].claimIDs,[id])
        let evidence=OutcomeReplyEvidence(attemptID:reply.attemptID,partIndex:0,quote:reply.parts[0].text)
        let copy=ConversationOutcomeProposal(statement:reply.parts[0].text,ownership:.aiCandidate,sourceEvidence:[],replyEvidence:[evidence])
        XCTAssertThrowsError(try VoiceOSStore.validateReusableConversationOutcomeProposals([copy],snapshot:snapshot,plan:plan))
        let interpretation=ConversationOutcomeProposal(statement:"合成AI新分析：迁移校验仍缺反例。",ownership:.aiCandidate,sourceEvidence:[],replyEvidence:[evidence])
        try VoiceOSStore.validateReusableConversationOutcomeProposals([personal(snapshot,index:1),interpretation],snapshot:snapshot,plan:plan)
        let claims=try await s.candidateClaims(includeFrozen:true),actions=try await s.actions();XCTAssertEqual(claims.count,1);XCTAssertEqual(claims[0].reviewState,"rejected");XCTAssertTrue(actions.isEmpty)
    }
    func testNewProducerBetweenPlanAndAcceptanceInvalidatesPlan() async throws {
        let (s,snapshot)=try await setup(),plan=try await s.conversationOutcomeReusePlan(for:snapshot)
        _=try await s.understandSource(sourceID:snapshot.input.userTurns[0].sourceID,using:ReusePersonal(mode:"empty"))
        do { try await s.validateConversationOutcomeReusePlan(plan,snapshot:snapshot);XCTFail() } catch {}
        let fresh=try await s.conversationOutcomeReusePlan(for:snapshot)
        _=try await s.retainDiscussionAICandidate(attemptID:snapshot.replies[0].attemptID,partIndex:0)
        do { try await s.validateConversationOutcomeReusePlan(fresh,snapshot:snapshot);XCTFail() } catch {}
    }
    func testInFlightPersonalRequestAndSourcePolicyChangeCannotUseOldPlan() async throws {
        let (s,snapshot)=try await setup(),plan=try await s.conversationOutcomeReusePlan(for:snapshot),source=snapshot.input.userTurns[0].sourceID
        let context=try await s.prepareLocalTranscriptContext(sourceIDs:[source]),id=try await s.persistLocalContext(context)
        _=try await s.reserveLocalModelAttempt(contextID:id,model:"synthetic",promptVersion:"v1",schemaVersion:"v1")
        do { _=try await s.conversationOutcomeReusePlan(for:snapshot);XCTFail() } catch {}
        _=try await s.setSourceLocalOnly(sourceID:source,expectedVersion:1,localOnly:false)
        do { try await s.validateConversationOutcomeReusePlan(plan,snapshot:snapshot);XCTFail() } catch {}
    }
    func testRestoredDiscussionCannotTurnHistoryIntoNewTargets() async throws {
        let (s,snapshot)=try await setup();_=try await s.understandSource(sourceID:snapshot.input.userTurns[0].sourceID,using:ReusePersonal(mode:"empty"))
        let plan=try await s.conversationOutcomeReusePlan(for:snapshot),package=root.appendingPathComponent("package"),restored=root.appendingPathComponent("restored")
        try await s.exportPackage(to:package);try await VoiceOSStore.restorePackage(from:package,to:restored,inspector:ReuseInspector())
        let r=try VoiceOSStore(root:restored,inspector:ReuseInspector());try await r.recover()
        do { try await r.validateConversationOutcomeReusePlan(plan,snapshot:snapshot);XCTFail() } catch {}
        let models=try await r.modelAttempts();XCTAssertEqual(models.count,1)
    }
    func testProducerOrderSurvivesRestoreAndNewWorkFollowsHistoricalIdentities() async throws {
        let (s,snapshot)=try await setup()
        _=try await s.understandSource(sourceID:snapshot.input.userTurns[0].sourceID,using:ReusePersonal(mode:"empty"))
        let ai=try await s.retainDiscussionAICandidate(attemptID:snapshot.replies[0].attemptID,partIndex:0)
        _=try await s.understandSource(sourceID:snapshot.input.userTurns[1].sourceID,using:ReusePersonal(mode:"empty"))
        let before=try await s.modelAttempts(),plan=try await s.conversationOutcomeReusePlan(for:snapshot)
        XCTAssertEqual(Set(before.map(\.producerSequence)),[1,2,3]);XCTAssertEqual(plan.priorResults.first(where: { $0.claimIDs == [ai] })?.producerSequence,2)
        _=try await s.retainDiscussionAICandidate(attemptID:snapshot.replies[0].attemptID,partIndex:0)
        let package=root.appendingPathComponent("ordered-package"),restored=root.appendingPathComponent("ordered-restored")
        try await s.exportPackage(to:package);try await VoiceOSStore.restorePackage(from:package,to:restored,inspector:ReuseInspector())
        let r=try VoiceOSStore(root:restored,inspector:ReuseInspector());try await r.recover()
        let after=try await r.modelAttempts()
        XCTAssertEqual(Dictionary(uniqueKeysWithValues:before.map { ($0.id,$0.producerSequence) }),Dictionary(uniqueKeysWithValues:after.map { ($0.id,$0.producerSequence) }))
        let fresh=try await r.recordUserExpression("合成新表达：需要检验恢复后顺序。")
        _=try await r.understandSource(sourceID:fresh,using:ReusePersonal(mode:"empty"))
        let records=try await r.modelAttempts();XCTAssertEqual(Set(records.map(\.producerSequence)),[1,2,3,4])
    }
    func testUnknownProducerKeepsItsPositionAndDoesNotReuseItForNewRequest() async throws {
        let (s,snapshot)=try await setup()
        do { _=try await s.understandSource(sourceID:snapshot.input.userTurns[0].sourceID,using:ReusePersonal(mode:"unknown"));XCTFail() } catch {}
        _=try await s.understandSource(sourceID:snapshot.input.userTurns[1].sourceID,using:ReusePersonal(mode:"empty"))
        let records=try await s.modelAttempts()
        XCTAssertEqual(records.first(where: { $0.state == "unknown" })?.producerSequence,1)
        XCTAssertEqual(records.first(where: { $0.state == "completed" })?.producerSequence,2)
    }
    func rewriteSequencePackage(_ package:URL,mode:String) throws {
        let file=package.appendingPathComponent("model_attempts.jsonl")
        var rows=try String(contentsOf:file,encoding:.utf8).split(separator:"\n").map { try XCTUnwrap(JSONSerialization.jsonObject(with:Data($0.utf8)) as? [String:Any]) }
        if mode == "legacy" || mode == "missing" { for i in rows.indices { rows[i].removeValue(forKey:"producer_sequence") } }
        if mode == "duplicate" { for i in rows.indices { rows[i]["producer_sequence"]=1 } }
        if mode == "negative" { rows[0]["producer_sequence"] = -1 }
        if mode == "text" { rows[0]["producer_sequence"] = "invalid-order" }
        var data=Data();for row in rows { data.append(try JSONSerialization.data(withJSONObject:row));data.append(10) };try data.write(to:file)
        let manifest=package.appendingPathComponent("manifest.json")
        var m=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:manifest)) as? [String:Any]),files=m["files"] as! [[String:Any]]
        let index=try XCTUnwrap(files.firstIndex { $0["path"] as? String == "model_attempts.jsonl" }),hash=try DurableFiles.hash(file)
        files[index]["bytes"]=hash.0;files[index]["sha256"]=hash.1;m["files"]=files
        if mode == "legacy" { m["version"]=17;m["databaseSchema"]=18 }
        try JSONSerialization.data(withJSONObject:m).write(to:manifest)
    }
    func testLegacyPackageBuildsRetrospectiveBaselineWithoutChangingModelIdentity() async throws {
        let (s,snapshot)=try await setup()
        _=try await s.understandSource(sourceID:snapshot.input.userTurns[0].sourceID,using:ReusePersonal(mode:"empty"))
        _=try await s.retainDiscussionAICandidate(attemptID:snapshot.replies[0].attemptID,partIndex:0)
        let before=try await s.modelAttempts(),package=root.appendingPathComponent("legacy"),restored=root.appendingPathComponent("legacy-restored")
        try await s.exportPackage(to:package);try rewriteSequencePackage(package,mode:"legacy")
        try await VoiceOSStore.restorePackage(from:package,to:restored,inspector:ReuseInspector())
        let r=try VoiceOSStore(root:restored,inspector:ReuseInspector());try await r.recover()
        let after=try await r.modelAttempts()
        XCTAssertEqual(Set(after.map(\.id)),Set(before.map(\.id)));XCTAssertEqual(Set(after.map(\.producerSequence)),[1,2])
    }
    func testNewPackageCannotRepairMissingDuplicateNegativeOrTextOrderAfterRehash() async throws {
        let (s,snapshot)=try await setup()
        _=try await s.understandSource(sourceID:snapshot.input.userTurns[0].sourceID,using:ReusePersonal(mode:"empty"))
        _=try await s.retainDiscussionAICandidate(attemptID:snapshot.replies[0].attemptID,partIndex:0)
        for mode in ["missing","duplicate","negative","text"] {
            let package=root.appendingPathComponent(mode),target=root.appendingPathComponent(mode+"-restored")
            try await s.exportPackage(to:package);try rewriteSequencePackage(package,mode:mode)
            do { try await VoiceOSStore.restorePackage(from:package,to:target,inspector:ReuseInspector());XCTFail(mode) } catch {}
            XCTAssertFalse(FileManager.default.fileExists(atPath:target.path))
        }
    }

}
