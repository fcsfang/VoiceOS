import XCTest
import Foundation
@testable import VoiceOSCore

private struct RejectMedia: MediaInspector {
    func inspect(_ url: URL) async throws -> MediaInfo { throw VoiceOSError("user text must not use media decoding") }
}
private actor TextReminderPort: RemindersPort {
    var items: [ReminderSnapshot] = []
    var creates = 0
    var failCreates=false
    var findCalls=0
    var afterCreate: (@Sendable () async throws -> Void)?
    func installAfterCreate(_ hook: @escaping @Sendable () async throws -> Void) { afterCreate=hook }
    func failFutureCreates() { failCreates=true }
    func completeExisting() { items=items.map { .init(id:$0.id,title:$0.title,completed:true,marker:$0.marker) } }
    func find(calendarID: String, externalID: String?, marker: String) async throws -> [ReminderSnapshot] { findCalls += 1;return items.filter { $0.marker == marker || $0.id == externalID } }
    func create(calendarID: String, title: String, marker: String) async throws {
        creates += 1; items.append(ReminderSnapshot(id: UUID().uuidString, title: title, completed: false, marker: marker))
        try await afterCreate?()
        if failCreates { throw VoiceOSError("lost create receipt") }
    }
}
final class UserExpressionTests: XCTestCase {
    func testConnectorCancellationStopsRefreshBeforeReconciliation() async throws {
        let s = try await store(), port = TextReminderPort()
        _ = try await s.setReminderAccess(calendarID: "fixture", title: "fixture", enabled: true, expectedVersion: 0)
        let id = try await s.recordUserExpression("我会整理开发验证素材，以后也许研究检索。")
        _ = try await s.setSourceLocalOnly(sourceID: id, expectedVersion: 1, localOnly: false)
        let (attempt, p) = try await proposals(s, id)
        _ = try await s.commitLocalClaims(attemptID: attempt, proposals: [p[0]])
        await port.installAfterCreate { throw CancellationError() }
        do { try await s.refreshAuthorizedReminders(expectedAccessVersion: 1, using: port); XCTFail("cancelled refresh") }
        catch is CancellationError {} catch { XCTFail("cancellation was lost: \(error)") }
        let calls = await port.findCalls; XCTAssertEqual(calls, 1)
        let creates = await port.creates; XCTAssertEqual(creates, 1)
        let link = try await s.reminderLinks()[0]
        XCTAssertEqual(link.state, "unknown"); XCTAssertNil(link.remoteCompleted)
    }
    func testRevokedScopeDuringCreateStopsFurtherReadback() async throws {
        let s=try await store(),port=TextReminderPort()
        _=try await s.setReminderAccess(calendarID:"fixture",title:"fixture",enabled:true,expectedVersion:0)
        let id=try await s.recordUserExpression("我会整理开发验证素材，以后也许研究检索。")
        _=try await s.setSourceLocalOnly(sourceID:id,expectedVersion:1,localOnly:false)
        let (attempt,p)=try await proposals(s,id);_=try await s.commitLocalClaims(attemptID:attempt,proposals:[p[0]])
        await port.installAfterCreate { _=try await s.setReminderAccess(calendarID:"fixture",title:"fixture",enabled:false,expectedVersion:1) }
        do { try await s.refreshAuthorizedReminders(expectedAccessVersion:1,using:port);XCTFail() } catch {}
        let calls=await port.findCalls;XCTAssertEqual(calls,1) // preflight only
        let links=try await s.reminderLinks();XCTAssertEqual(links.first?.state,"unknown")
    }
    func testFailedNewCreateDoesNotStarveExistingCompletionFeedback() async throws {
        let s=try await store(),port=TextReminderPort()
        _=try await s.setReminderAccess(calendarID:"fixture",title:"fixture",enabled:true,expectedVersion:0)
        func addTask(_ command: String) async throws {
            let id=try await s.recordUserExpression("我会整理开发验证素材，以后也许研究检索。",commandID:command)
            _=try await s.setSourceLocalOnly(sourceID:id,expectedVersion:1,localOnly:false)
            let (attempt,p)=try await proposals(s,id)
            _=try await s.commitLocalClaims(attemptID:attempt,proposals:[p[0]])
        }
        try await addTask("first")
        try await s.refreshAuthorizedReminders(expectedAccessVersion:1,using:port)
        let links=try await s.reminderLinks(),first=try XCTUnwrap(links.first)
        await port.completeExisting();await port.failFutureCreates()
        try await addTask("second")
        do { try await s.refreshAuthorizedReminders(expectedAccessVersion:1,using:port);XCTFail() } catch {}
        let actions=try await s.actions(includeHistory:true)
        XCTAssertEqual(actions.first { $0.id==first.actionID }?.state,"completed")
        let history=try await s.actionHistory(actionID:first.actionID)
        XCTAssertEqual(history.last?.actor,"external")
        try await s.refreshAuthorizedReminders(expectedAccessVersion:1,using:port)
        let creates=await port.creates;XCTAssertEqual(creates,2)
        let claims=try await s.candidateClaims();XCTAssertTrue(claims.allSatisfy { $0.evidenceState == "unverified" })
    }
    private var base: URL!
    override func setUpWithError() throws { base = FileManager.default.temporaryDirectory.appendingPathComponent("expression-tests-" + UUID().uuidString); try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: base) }
    private func store(_ name: String = "db") async throws -> VoiceOSStore {
        let s = try VoiceOSStore(root: base.appendingPathComponent(name), inspector: RejectMedia()); try await s.recover(); return s
    }
    private func proposals(_ s: VoiceOSStore, _ id: String) async throws -> (String,[ClaimProposal]) {
        let c = try await s.prepareLocalTranscriptContext(sourceIDs: [id]); let input = c.sources[0]
        let context = try await s.persistLocalContext(c)
        let attempt = try await s.reserveLocalModelAttempt(contextID: context, model: "fixture", promptVersion: "v2", schemaVersion: "v2")
        let refs = [ClaimReference(sourceID: id, transcriptVersionID: input.transcriptVersionID, spanID: input.spans[0].id)]
        return (attempt,[
            ClaimProposal(statement: "我会整理开发验证素材", ownership: .userTentative, references: refs, action: ExtractedAction(title: "整理开发验证素材", kind: .task, quote: "我会整理开发验证素材", autoSend: true)),
            ClaimProposal(statement: "以后也许研究检索", ownership: .userTentative, references: refs, action: ExtractedAction(title: "研究检索", kind: .opportunity, quote: "以后也许研究检索")),
            ClaimProposal(statement: "AI 建议做检索对照", ownership: .aiCandidate, references: refs, action: ExtractedAction(title: "做检索对照", kind: .aiSuggestion, quote: "研究检索"))])
    }
    func testAuthoredTextIdentityOriginalReceiptAndRoundTrip() async throws {
        let s = try await store(); let text = "我会整理开发验证素材，以后也许研究检索。🧠"
        let id = try await s.recordUserExpression(text, commandID: "one")
        let replay = try await s.recordUserExpression(text, commandID: "one"); XCTAssertEqual(id,replay)
        do { _ = try await s.recordUserExpression("changed", commandID: "one"); XCTFail() } catch {}
        for invalid in ["  ",String(repeating:"中", count:4001)] { do { _ = try await s.recordUserExpression(invalid); XCTFail() } catch {} }
        let sources = try await s.sources(); XCTAssertEqual(sources.count,1); XCTAssertEqual(sources[0].origin,"user"); XCTAssertEqual(sources[0].speaker,"user"); XCTAssertEqual(sources[0].kind,"user_text"); XCTAssertTrue(sources[0].localOnly); XCTAssertEqual(sources[0].transcript,text); XCTAssertEqual(sources[0].jobState,"completed")
        let (attempt, p) = try await proposals(s,id); let ids = try await s.commitLocalClaims(attemptID: attempt, proposals: p)
        XCTAssertEqual(ids.count,3); let replayIDs = try await s.commitLocalClaims(attemptID: attempt, proposals:p); XCTAssertEqual(ids,replayIDs)
        let actions = try await s.actions(); XCTAssertEqual(actions.count,3); XCTAssertEqual(actions.filter(\.autoSend).count,1)
        let package = base.appendingPathComponent("package"); try await s.exportPackage(to: package,includeMedia:true)
        let target = base.appendingPathComponent("restored"); try await VoiceOSStore.restorePackage(from:package,to:target,inspector:RejectMedia())
        let restored = try VoiceOSStore(root: target,inspector:RejectMedia()); try await restored.recover()
        let rc = try await restored.prepareLocalTranscriptContext(sourceIDs:[id]); XCTAssertEqual(rc.sources[0].text,text); XCTAssertEqual(rc.sources[0].origin,"user")
        let ra = try await restored.actions(); XCTAssertEqual(Set(ra.map(\.id)),Set(actions.map(\.id)))
        let rv = try XCTUnwrap(sources[0].transcriptVersionID); _ = try await s.correctTranscript(sourceID:id,expectedVersionID:rv,text:"这项行动已被更正")
        let frozen = try await s.actions(includeHistory:true); XCTAssertTrue(frozen.allSatisfy { $0.validity == "frozen" })
    }
    func testForgedOwnershipQuotesAndActivationRejectAtomically() async throws {
        let s = try await store(); let id = try await s.recordUserExpression("我会整理开发验证素材，以后也许研究检索。")
        let (_, originals) = try await proposals(s,id); let refs = originals[0].references
        let invalid = [
            ClaimProposal(statement:"错误归属",ownership:.external,references:refs),
            ClaimProposal(statement:"错误原话",ownership:.userTentative,references:refs,action:ExtractedAction(title:"不存在",kind:.task,quote:"凭空的原话",autoSend:true)),
            ClaimProposal(statement:"错误激活",ownership:.userTentative,references:refs,action:ExtractedAction(title:"研究",kind:.opportunity,quote:"研究检索",autoSend:true)),
            ClaimProposal(statement:"冒充承诺",ownership:.aiCandidate,references:refs,action:ExtractedAction(title:"整理",kind:.task,quote:"整理开发验证素材",autoSend:true))]
        for bad in invalid {
            let (attempt, _) = try await proposals(s,id)
            do { _ = try await s.commitLocalClaims(attemptID:attempt,proposals:[originals[0],bad]); XCTFail() } catch {}
        }
        let (attempt, _) = try await proposals(s,id)
        do { _ = try await s.commitLocalClaims(attemptID:attempt,proposals:Array(repeating: originals[0],count:33)); XCTFail() } catch {}
        let claims = try await s.candidateClaims(); let actions = try await s.actions(); XCTAssertTrue(claims.isEmpty); XCTAssertTrue(actions.isEmpty)
        let snapshot = try await s.prepareLocalTranscriptContext(sourceIDs:[id]); let input = snapshot.sources[0]
        let external = ContextTranscript(sourceID: id, sourceVersionID:input.sourceVersionID,transcriptVersionID:input.transcriptVersionID,origin:"external",speaker:"unknown",localOnly:true,text:input.text,spans:input.spans)
        XCTAssertThrowsError(try VoiceOSStore.validateProposals([originals[0]],context:LocalTranscriptContext(sources:[external],scalarBudget:4000,contentDigest:"fixture")))
    }
    func testAutonomousOrdinaryTaskRequiresScopeAndTextGrantAndNeverResendsOldSource() async throws {
        let s = try await store(); let id = try await s.recordUserExpression("我会整理开发验证素材，以后也许研究检索。")
        let (first,p) = try await proposals(s,id); _ = try await s.commitLocalClaims(attemptID:first,proposals:p)
        let port = TextReminderPort(); _ = try await s.setReminderAccess(calendarID:"fixture",title:"fixture",enabled:true,expectedVersion:0)
        try await s.activateExtractedTasks(expectedAccessVersion:1,using:port); let before = await port.creates; XCTAssertEqual(before,0)
        _ = try await s.setSourceLocalOnly(sourceID:id,expectedVersion:1,localOnly:false)
        let (second,p2) = try await proposals(s,id); _ = try await s.commitLocalClaims(attemptID:second,proposals:p2)
        try await s.activateExtractedTasks(expectedAccessVersion:1,using:port); try await s.activateExtractedTasks(expectedAccessVersion:1,using:port)
        let once = await port.creates; XCTAssertEqual(once,1)
        let loaded = try await s.sources(); let source = try XCTUnwrap(loaded.first); _ = try await s.correctTranscript(sourceID:id,expectedVersionID:source.transcriptVersionID!,text:"我会整理开发验证素材，以后也许研究检索。已校对")
        let (third,p3) = try await proposals(s,id); _ = try await s.commitLocalClaims(attemptID:third,proposals:p3)
        try await s.activateExtractedTasks(expectedAccessVersion:1,using:port); let after = await port.creates; XCTAssertEqual(after,1)
        _ = try await s.setReminderAccess(calendarID:"fixture",title:"fixture",enabled:false,expectedVersion:1)
        do { try await s.activateExtractedTasks(expectedAccessVersion:1,using:port); XCTFail() } catch {}
    }
    func testExplicitSpokenTaskActivatesWhenModelIsConservative() async throws {
        let s = try await store()
        let text = "明确计划接下来完成整理开发验证素材。"
        let id = try await s.recordUserExpression(text)
        _ = try await s.setSourceLocalOnly(sourceID:id,expectedVersion:1,localOnly:false)
        let context = try await s.prepareLocalTranscriptContext(sourceIDs:[id]), input = context.sources[0]
        let persisted = try await s.persistLocalContext(context)
        let attempt = try await s.reserveLocalModelAttempt(contextID:persisted,model:"fixture",promptVersion:"v2",schemaVersion:"v2")
        let ref = ClaimReference(sourceID:id,transcriptVersionID:input.transcriptVersionID,spanID:input.spans[0].id)
        _ = try await s.commitLocalClaims(attemptID:attempt,proposals:[.init(statement:text,ownership:.userTentative,references:[ref],action:.init(title:"完成整理开发验证素材",kind:.task,quote:text,autoSend:false))])
        _ = try await s.setReminderAccess(calendarID:"fixture",title:"fixture",enabled:true,expectedVersion:0)
        let port = TextReminderPort(); try await s.activateExtractedTasks(expectedAccessVersion:1,using:port)
        let creates = await port.creates; XCTAssertEqual(creates,1)
    }
    func testMoreThanThreeUserTasksActivateWithoutDevelopmentCap() async throws {
        let s = try await store()
        let text = "我会整理开发验证素材。"
        let id = try await s.recordUserExpression(text)
        _ = try await s.setSourceLocalOnly(sourceID:id,expectedVersion:1,localOnly:false)
        let context = try await s.prepareLocalTranscriptContext(sourceIDs:[id]), input = context.sources[0]
        let persisted = try await s.persistLocalContext(context)
        let attempt = try await s.reserveLocalModelAttempt(contextID:persisted,model:"fixture",promptVersion:"v2",schemaVersion:"v2")
        let ref = ClaimReference(sourceID:id,transcriptVersionID:input.transcriptVersionID,spanID:input.spans[0].id)
        let proposals = ["整理", "开发", "验证", "素材"].map { title in
            ClaimProposal(statement:"明确任务：\(title)",ownership:.userTentative,references:[ref],action:.init(title:title,kind:.task,quote:text,autoSend:false))
        }
        _ = try await s.commitLocalClaims(attemptID:attempt,proposals:proposals)
        _ = try await s.setReminderAccess(calendarID:"fixture",title:"fixture",enabled:true,expectedVersion:0)
        let port = TextReminderPort(); try await s.activateExtractedTasks(expectedAccessVersion:1,using:port)
        let count = await port.creates; XCTAssertEqual(count,4)
    }
    func testReminderActivationIgnoresUnlinkedHistoricalBatch() async throws {
        let s = try await store()
        let text = "我会整理开发验证素材。"
        let id = try await s.recordUserExpression(text)
        _ = try await s.setSourceLocalOnly(sourceID: id, expectedVersion: 1, localOnly: false)
        let context = try await s.prepareLocalTranscriptContext(sourceIDs: [id]), input = context.sources[0]
        let ref = ClaimReference(sourceID: id, transcriptVersionID: input.transcriptVersionID, spanID: input.spans[0].id)
        func commitTask(_ title: String) async throws {
            let persisted = try await s.persistLocalContext(context)
            let attempt = try await s.reserveLocalModelAttempt(contextID: persisted, model: "fixture", promptVersion: "v2", schemaVersion: "v2")
            _ = try await s.commitLocalClaims(attemptID: attempt, proposals: [
                .init(statement: "明确任务：\(title)", ownership: .userTentative, references: [ref], action: .init(title: title, kind: .task, quote: text))
            ])
        }
        try await commitTask("旧批次任务")
        try await commitTask("最新批次任务")
        _ = try await s.setReminderAccess(calendarID: "fixture", title: "fixture", enabled: true, expectedVersion: 0)
        let port = TextReminderPort()
        try await s.activateExtractedTasks(expectedAccessVersion: 1, using: port)
        let creates = await port.creates
        XCTAssertEqual(creates, 1)
        let links = try await s.reminderLinks()
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links[0].remoteTitle, "最新批次任务")
    }
    func testMigrationRejectsMissingExtractedActionEvenWithNewFileDigest() async throws {
        let s = try await store(); let id = try await s.recordUserExpression("我会整理开发验证素材，以后也许研究检索。")
        let (attempt,p) = try await proposals(s,id); _ = try await s.commitLocalClaims(attemptID:attempt,proposals:p)
        let package = base.appendingPathComponent("bad-package"); try await s.exportPackage(to:package)
        let file = package.appendingPathComponent("actions.jsonl"); try Data().write(to:file)
        let mf = package.appendingPathComponent("manifest.json"); var m = try JSONSerialization.jsonObject(with:Data(contentsOf:mf)) as! [String:Any]
        var counts = m["counts"] as! [String:Int]; counts["actions"] = 0; m["counts"] = counts
        var files = m["files"] as! [[String:Any]]; let i = files.firstIndex { $0["path"] as? String == "actions.jsonl" }!; let hash = try DurableFiles.hash(file); files[i]["sha256"] = hash.1; files[i]["bytes"] = hash.0; m["files"] = files
        try JSONSerialization.data(withJSONObject:m).write(to:mf)
        let target = base.appendingPathComponent("must-not-exist")
        do { try await VoiceOSStore.restorePackage(from:package,to:target,inspector:RejectMedia()); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("行动提取")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath:target.path))
    }
}
