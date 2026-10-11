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
        if mode == "legacy" {
            m["version"]=17;m["databaseSchema"]=18
            var counts = m["counts"] as! [String: Any]; counts.removeValue(forKey: "english_feedback_attempts"); m["counts"] = counts
            files.removeAll { ($0["path"] as? String) == "english_feedback_attempts.jsonl" }
            try? FileManager.default.removeItem(at: package.appendingPathComponent("english_feedback_attempts.jsonl"))
            m["files"] = files
        }
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

    func reusable(_ s:VoiceOSStore,_ snapshot:ConversationOutcomeSnapshot) async throws -> ConversationOutcomeSnapshot {
        try await s.prepareReusableConversationOutcome(id:snapshot.input.conversationID,expectedVersion:4,destination:.local)
    }
    func testDurableReuseKeepsPriorReviewAndCompletedTaskAndCreatesOnlyFreshPersonalTask() async throws {
        let (s,original)=try await setup()
        let first=try await s.understandSource(sourceID:original.input.userTurns[0].sourceID,using:ReusePersonal(mode:"normal")),action=try await s.actions()[0]
        _=try await s.setActionState(actionID:action.id,expectedVersion:1,state:.completed)
        let ai=try await s.retainDiscussionAICandidate(attemptID:original.replies[0].attemptID,partIndex:0)
        _=try await s.reviewClaim(claimID:ai,expectedVersion:0,action:.reject)
        let snapshot=try await reusable(s,original),port=ReusableOutcomePort(),ids=try await s.performConversationOutcome(snapshot,using:port)
        let records=try await s.conversationOutcomes(conversationID:original.input.conversationID),claims=try await s.candidateClaims(includeFrozen:true),actions=try await s.actions(includeHistory:true)
        XCTAssertEqual(Set(records[0].priorClaimIDs),Set(first+[ai]));XCTAssertEqual(records[0].claimIDs,ids);XCTAssertEqual(ids.count,2);XCTAssertEqual(claims.count,4)
        XCTAssertEqual(claims.first(where: { $0.id == ai })?.reviewState,"rejected");XCTAssertEqual(actions.count,2)
        XCTAssertEqual(actions.first(where: { $0.id == action.id })?.version,2);XCTAssertEqual(actions.first(where: { $0.id == action.id })?.state,"completed")
        XCTAssertEqual(actions.filter { $0.title == "校验迁移资料" }.count,1)
        let package=root.appendingPathComponent("reuse-package"),restored=root.appendingPathComponent("reuse-restored")
        try await s.exportPackage(to:package);try await VoiceOSStore.restorePackage(from:package,to:restored,inspector:ReuseInspector())
        let r=try VoiceOSStore(root:restored,inspector:ReuseInspector());try await r.recover()
        let after=try await r.conversationOutcomes(conversationID:original.input.conversationID)[0]
        XCTAssertEqual(after.id,records[0].id);XCTAssertEqual(after.priorClaimIDs,records[0].priorClaimIDs);XCTAssertEqual(after.claimIDs,ids);XCTAssertEqual(after.validity,"frozen")
        do { _=try await s.performConversationOutcome(snapshot,using:port);XCTFail() } catch {}
        let calls=await port.calls;XCTAssertEqual(calls,1)
    }
    func testAllConsumedPersonalVersionsStillAllowFreshAIAnalysisWithoutNewPersonalTasks() async throws {
        let (s,original)=try await setup()
        for turn in original.input.userTurns { _=try await s.understandSource(sourceID:turn.sourceID,using:ReusePersonal(mode:"empty")) }
        let snapshot=try await reusable(s,original);XCTAssertTrue(try XCTUnwrap(snapshot.reusePlan).personalTargets.isEmpty)
        _=try await s.performConversationOutcome(snapshot,using:ReusableOutcomePort())
        let claims=try await s.candidateClaims(),actions=try await s.actions(),rows=try await s.conversationOutcomes(conversationID:original.input.conversationID)
        XCTAssertEqual(claims.count,1);XCTAssertEqual(claims[0].ownership,"ai_candidate");XCTAssertTrue(actions.isEmpty);XCTAssertTrue(rows[0].priorClaimIDs.isEmpty)
    }
    func testPlanChangesBeforeSendAndDuringAwaitRejectRatherThanDuplicate() async throws {
        let (s,original)=try await setup("before-reuse"),snapshot=try await reusable(s,original),port=ReusableOutcomePort()
        _=try await s.retainDiscussionAICandidate(attemptID:original.replies[0].attemptID,partIndex:0)
        do { _=try await s.performConversationOutcome(snapshot,using:port);XCTFail() } catch {}
        let calls=await port.calls;XCTAssertEqual(calls,0)
        let (r,other)=try await setup("during-reuse"),input=try await reusable(r,other)
        let waiting=ReusableOutcomePort(callback:{ request in _=try await r.retainDiscussionAICandidate(attemptID:request.snapshot.replies[0].attemptID,partIndex:0) })
        do { _=try await r.performConversationOutcome(input,using:waiting);XCTFail() } catch {}
        let claims=try await r.candidateClaims(),actions=try await r.actions(),rows=try await r.conversationOutcomes(conversationID:other.input.conversationID)
        XCTAssertEqual(claims.count,1);XCTAssertTrue(actions.isEmpty);XCTAssertEqual(rows[0].state,"rejected");XCTAssertEqual(rows[0].usage,["input_tokens":10,"output_tokens":5])
        try await r.exportPackage(to:root.appendingPathComponent("late-package"))
        try await VoiceOSStore.restorePackage(from:root.appendingPathComponent("late-package"),to:root.appendingPathComponent("late-restored"),inspector:ReuseInspector())
    }
    func testDuplicateConsumedUserAndExactAIParagraphAreRejectedWithNoNewTask() async throws {
        for mode in ["duplicate-user","duplicate-ai"] {
            let (s,original)=try await setup(mode)
            _=try await s.understandSource(sourceID:original.input.userTurns[0].sourceID,using:ReusePersonal(mode:"normal"))
            _=try await s.retainDiscussionAICandidate(attemptID:original.replies[0].attemptID,partIndex:0)
            let input=try await reusable(s,original)
            do { _=try await s.performConversationOutcome(input,using:ReusableOutcomePort(mode:mode));XCTFail() } catch {}
            let claims=try await s.candidateClaims(),actions=try await s.actions();XCTAssertEqual(claims.count,2);XCTAssertEqual(actions.count,1)
        }
    }
    func testRehashedReuseDirectoryCannotOmitPriorProducerOrReenableConsumedTarget() async throws {
        let (s,original)=try await setup();_=try await s.understandSource(sourceID:original.input.userTurns[0].sourceID,using:ReusePersonal(mode:"normal"))
        let input=try await reusable(s,original);_=try await s.performConversationOutcome(input,using:ReusableOutcomePort())
        for mode in ["omit-prior","reenable-target","downgrade"] {
            let package=root.appendingPathComponent(mode),target=root.appendingPathComponent(mode+"-restored")
            try await s.exportPackage(to:package)
            let file=package.appendingPathComponent("conversation_outcome_attempts.jsonl")
            var row=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:Any])
            var snapshot=try XCTUnwrap(JSONSerialization.jsonObject(with:Data((row["snapshot_json"] as! String).utf8)) as? [String:Any]),plan=snapshot["reusePlan"] as! [String:Any]
            if mode == "omit-prior" { plan["priorResults"]=[] }
            else if mode == "reenable-target" { plan["personalTargets"]=(snapshot["input"] as! [String:Any])["userTurns"] }
            snapshot["reusePlan"]=plan
            let data=try JSONSerialization.data(withJSONObject:snapshot,options:[.sortedKeys]);row["snapshot_json"]=String(decoding:data,as:UTF8.self);row["snapshot_digest"]=VoiceOSStore.relevanceHash(data)
            var encoded=try JSONSerialization.data(withJSONObject:row);encoded.append(10);try encoded.write(to:file)
            let manifest=package.appendingPathComponent("manifest.json")
            var m=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:manifest)) as? [String:Any]),files=m["files"] as! [[String:Any]]
            let index=try XCTUnwrap(files.firstIndex { $0["path"] as? String == "conversation_outcome_attempts.jsonl" }),hash=try DurableFiles.hash(file)
            files[index]["bytes"]=hash.0;files[index]["sha256"]=hash.1;m["files"]=files
            if mode == "downgrade" { m["version"]=17;m["databaseSchema"]=18 }
            try JSONSerialization.data(withJSONObject:m).write(to:manifest)
            do { try await VoiceOSStore.restorePackage(from:package,to:target,inspector:ReuseInspector());XCTFail(mode) } catch {}
            XCTAssertFalse(FileManager.default.fileExists(atPath:target.path))
        }
    }
    func testLaterProducerDoesNotRetroactivelyChangeTheReservedHistoricalDirectory() async throws {
        let (s,original)=try await setup();_=try await s.understandSource(sourceID:original.input.userTurns[0].sourceID,using:ReusePersonal(mode:"empty"))
        let input=try await reusable(s,original);_=try await s.performConversationOutcome(input,using:ReusableOutcomePort())
        let context=try await s.prepareLocalTranscriptContext(sourceIDs:[original.input.userTurns[0].sourceID]),id=try await s.persistLocalContext(context)
        _=try await s.generateClaims(contextID:id,using:ReusePersonal(mode:"empty"))
        let package=root.appendingPathComponent("later-package"),target=root.appendingPathComponent("later-restored")
        try await s.exportPackage(to:package);try await VoiceOSStore.restorePackage(from:package,to:target,inspector:ReuseInspector())
        let r=try VoiceOSStore(root:target,inspector:ReuseInspector());try await r.recover()
        let rows=try await r.conversationOutcomes(conversationID:original.input.conversationID)
        XCTAssertEqual(rows[0].state,"completed");XCTAssertEqual(rows[0].claimIDs.count,2)
    }
    func testExtraPriorDependencyFreezesSharedOutcomeEvenWhenConversationEntryStaysCurrent() async throws {
        let (s,original)=try await setup(),extra=try await s.recordUserExpression("合成其他依据：有待验证。")
        let context=try await s.prepareLocalTranscriptContext(sourceIDs:[original.input.userTurns[0].sourceID,extra]),id=try await s.persistLocalContext(context)
        _=try await s.generateClaims(contextID:id,using:ReusePersonal(mode:"normal"))
        let input=try await reusable(s,original);_=try await s.performConversationOutcome(input,using:ReusableOutcomePort())
        let reusedSource=original.input.userTurns[0].sourceID
        let next=try await s.beginConversation(sourceIDs:[reusedSource])
        _=try await s.appendConversationUserSource(conversationID:next,sourceID:reusedSource,expectedVersion:1)
        let nextInput=try await s.prepareConversationInput(id:next,expectedVersion:2,destination:.local)
        _=try await s.performConversationReply(nextInput,using:ReuseDiscussion());try await s.endConversation(id:next,expectedVersion:2)
        let shared=try await s.prepareReusableConversationOutcome(id:next,expectedVersion:3,destination:.local)
        _=try await s.performConversationOutcome(shared,using:ReusableOutcomePort())
        let sources=try await s.sources(),version=try XCTUnwrap(sources.first(where: { $0.id == extra })?.transcriptVersionID)
        _=try await s.correctTranscript(sourceID:extra,expectedVersionID:version,text:"合成其他依据已更正。")
        let session=try await s.conversation(id:original.input.conversationID),rows=try await s.conversationOutcomes(conversationID:session.id),claims=try await s.candidateClaims(includeFrozen:true)
        XCTAssertEqual(session.validity,"current");XCTAssertEqual(rows[0].validity,"frozen")
        let nextRows=try await s.conversationOutcomes(conversationID:next)
        XCTAssertEqual(nextRows[0].validity,"frozen")
        XCTAssertTrue(nextRows[0].claimIDs.allSatisfy { id in claims.first(where: { $0.id == id })?.validity == "frozen" })
        XCTAssertTrue(rows[0].claimIDs.allSatisfy { id in claims.first(where: { $0.id == id })?.validity == "frozen" })
        let package=root.appendingPathComponent("dependency-package"),target=root.appendingPathComponent("dependency-restored")
        try await s.exportPackage(to:package);try await VoiceOSStore.restorePackage(from:package,to:target,inspector:ReuseInspector())
    }

}

private actor ReusableOutcomePort:ConversationOutcomePort {
    let configuration=ModelConfiguration(provider:"synthetic_reuse",model:"outcome",promptVersion:"v1",schemaVersion:"v1",destination:.local)
    let mode:String
    let callback:(@Sendable (ConversationOutcomeRequest) async throws -> Void)?
    var calls=0
    init(mode:String="normal",callback:(@Sendable (ConversationOutcomeRequest) async throws -> Void)?=nil) { self.mode=mode;self.callback=callback }
    func extract(_ request:ConversationOutcomeRequest) async throws -> ConversationOutcomeResponse {
        calls += 1;if let callback { try await callback(request) }
        let plan=try XCTUnwrap(request.snapshot.reusePlan),reply=request.snapshot.replies[0]
        var proposals:[ConversationOutcomeProposal]=[]
        if let turn=mode == "duplicate-user" ? request.snapshot.input.userTurns.first : plan.personalTargets.first {
            let source=try XCTUnwrap(request.snapshot.context.sources.first { $0.sourceID == turn.sourceID })
            proposals.append(.init(statement:source.text,ownership:.userTentative,sourceEvidence:[.init(reference:.init(sourceID:source.sourceID,transcriptVersionID:source.transcriptVersionID,spanID:source.spans[0].id),quote:source.text)],action:.init(title:mode == "duplicate-user" ? "整理开发验证素材":"校验迁移资料",kind:.task,quote:source.text,autoSend:true)))
        }
        proposals.append(.init(statement:mode == "duplicate-ai" ? reply.parts[0].text:"合成AI新成果：迁移仍需测试反例。",ownership:.aiCandidate,sourceEvidence:[],replyEvidence:[.init(attemptID:reply.attemptID,partIndex:0,quote:reply.parts[0].text)]))
        return .init(status:.completed,proposals:proposals,inputTokens:10,outputTokens:5)
    }
}
