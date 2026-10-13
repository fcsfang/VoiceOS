import XCTest
import Foundation
import CryptoKit
@testable import VoiceOSCore

private struct CompensationInspector: MediaInspector {
    func inspect(_ url: URL) async throws -> MediaInfo { throw VoiceOSError("text fixture") }
}
private final class CompensationFault: @unchecked Sendable {
    private let lock = NSLock()
    private let target: SaveCheckpoint
    private var fired = false
    init(_ target: SaveCheckpoint) { self.target = target }
    func hit(_ point: SaveCheckpoint) throws {
        lock.lock(); defer { lock.unlock() }
        if point == target && !fired { fired = true; throw VoiceOSError("injected compensation window") }
    }
}
private actor CompensationPort: RemindersSchedulingPort {
    var item: ReminderSnapshot?
    var writes = 0
    var creates = 0
    var loseReceipt = false
    var failRead = false
    var duplicate = false
    var findHook: (@Sendable () async throws -> Void)?
    var updateHook: (@Sendable () async throws -> Void)?
    var savedHook: (@Sendable () async throws -> Void)?
    func configure(loseReceipt: Bool = false, find: (@Sendable () async throws -> Void)? = nil,
                   update: (@Sendable () async throws -> Void)? = nil, saved: (@Sendable () async throws -> Void)? = nil) {
        self.loseReceipt = loseReceipt; findHook = find; updateHook = update; savedHook = saved
    }
    func create(calendarID: String,title: String,marker: String) async throws {
        creates += 1; item = .init(id: "compensation-item",title: title,completed: false,marker: marker,dueDate: .some(.none))
    }
    func find(calendarID: String,externalID: String?,marker: String) async throws -> [ReminderSnapshot] {
        let hook = findHook; findHook = nil; try await hook?()
        if failRead { throw VoiceOSError("read failure") }
        return item.map { duplicate ? [$0,$0] : [$0] } ?? []
    }
    func updateDue(calendarID: String,expected: ReminderSnapshot,desired: ReminderDueDate,
                   authorize: @escaping @Sendable () async throws -> Void) async throws {
        let hook = updateHook; updateHook = nil; try await hook?()
        try await authorize()
        guard item == expected, !duplicate else { throw VoiceOSError("preflight drift") }
        _ = try desired.writableComponents()
        writes += 1
        item = .init(id: expected.id,title: expected.title,completed: expected.completed,marker: expected.marker,dueDate: desired)
        let saved = savedHook; savedHook = nil; try await saved?()
        if loseReceipt { throw VoiceOSError("save receipt lost") }
    }
    func edit(due: ReminderDueDate? = nil,title: String? = nil,completed: Bool? = nil,id: String? = nil) {
        let old = item!; item = .init(id: id ?? old.id,title: title ?? old.title,completed: completed ?? old.completed,marker: old.marker,dueDate: due ?? old.dueDate)
    }
    func setReadFailure(_ value: Bool) { failRead = value }
    func setDuplicate(_ value: Bool) { duplicate = value }
}
final class ReminderCompensationTests: XCTestCase {
    private var base: URL!
    private let due = ReminderDueDate.dateOnly(localDate: "2026-10-16",timeZone: "Asia/Shanghai")
    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("compensation-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: base,withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: base) }
    private func fixture(checkpoint: @escaping @Sendable (SaveCheckpoint) throws -> Void = { _ in },
                         authority: ScheduleAuthority = .aiFlexible, correct: Bool = true) async throws -> (VoiceOSStore,CompensationPort,String,String,String,ReminderLink) {
        let store = try VoiceOSStore(root: base.appendingPathComponent(UUID().uuidString),inspector: CompensationInspector(),checkpoint: checkpoint)
        try await store.recover()
        let text = "我要整理研究资料。", source = try await store.recordUserExpression(text)
        _ = try await store.setSourceLocalOnly(sourceID: source,expectedVersion: 1,localOnly: false)
        let context = try await store.prepareLocalTranscriptContext(sourceIDs: [source]), input = context.sources[0]
        let contextID = try await store.persistLocalContext(context)
        let attempt = try await store.reserveLocalModelAttempt(contextID: contextID,model: "fixture",promptVersion: "v1",schemaVersion: "v1")
        let claims = try await store.commitLocalClaims(attemptID: attempt,proposals: [
            .init(statement: text,ownership: .userTentative,references: [.init(sourceID: source,transcriptVersionID: input.transcriptVersionID,spanID: input.spans[0].id)],action: .init(title: "整理研究资料",kind: .task,quote: text))
        ])
        _ = try await store.setReminderAccess(calendarID: "compensation",title: "compensation",enabled: true,expectedVersion: 0)
        let port = CompensationPort(); try await store.activateExtractedTasks(expectedAccessVersion: 1,using: port)
        let action = try await store.actions()[0], link = try await store.reminderLinks()[0]
        let intent = try await store.recordActionSchedule(actionID: action.id,expectedActionVersion: 1,expectedScheduleVersion: 0,
                                                        proposal: .init(due: due,authority: authority,rawExpression: "安排资料整理",anchorEventTime: Date(timeIntervalSince1970: 1791820800)),
                                                        actor: authority == .aiFlexible ? .ai : .user,anchorTimeZone: "Asia/Shanghai",baseObservationID: link.lastObservationID,expectedAccessVersion: 1)
        var grant: String?
        if authority == .userCommitment {
            let effect = try await store.prepareReminderScheduleEffect(intentID: intent,expectedObservationID: link.lastObservationID!,expectedAccessVersion: 1)
            grant = try await store.confirmReminderSchedule(intentID: intent,expectedObservationID: link.lastObservationID!,expectedAccessVersion: 1,displayedEffectDigest: effect.digest,actor: .user)
        }
        _ = try await store.executeReminderSchedule(intentID: intent,expectedObservationID: link.lastObservationID!,expectedAccessVersion: 1,grantID: grant,using: port)
        if correct { try await correctClaim(store,claims[0]) }
        return (store,port,action.id,claims[0],source,try await store.reminderLinks()[0])
    }
    private func correctClaim(_ store: VoiceOSStore,_ claim: String, version: Int = 0, statement: String = "我暂时不整理研究资料。") async throws {
        _ = try await store.reviewClaim(claimID: claim,expectedVersion: version,action: .correct,statement: statement,note: "更正原意")
    }
    private func plan(_ store: VoiceOSStore,_ action: String, command: String = "plan") async throws -> ReminderCompensationPlan {
        let impact = try await store.correctionActionImpacts().first { $0.action.id == action }!
        let id = try await store.recordReminderCompensationPlan(actionID: action,expectedImpactDigest: impact.digest,expectedAccessVersion: 1,commandID: command)
        return try await store.reminderCompensationPlans().first { $0.id == id }!
    }
    private func approve(_ store: VoiceOSStore,_ plan: ReminderCompensationPlan, command: String = "approve") async throws -> String {
        try await store.confirmReminderCompensation(planID: plan.id,displayedEffectDigest: plan.digest,actor: .user,commandID: command)
    }
    private func execute(_ store: VoiceOSStore,_ port: CompensationPort,_ plan: ReminderCompensationPlan,_ grant: String, command: String = "execute") async throws -> String {
        try await store.executeReminderCompensation(planID: plan.id,grantID: grant,using: port,commandID: command)
    }
    func testPlanAndApprovalDoNotWriteAndExecutionPreservesFrozenActionAndFacts() async throws {
        let (store,port,action,_,_,link) = try await fixture()
        await port.edit(title: "人工改过的标题")
        try await store.readReminder(linkID: link.id,calendarID: link.calendarID,using: port,expectedAccessVersion: 1)
        let p = try await plan(store,action)
        XCTAssertEqual(p.desired,ReminderDueDate.none); XCTAssertEqual(p.before.title,"人工改过的标题")
        let originalWrites = await port.writes; XCTAssertEqual(originalWrites,1)
        do { _ = try await store.confirmReminderCompensation(planID: p.id,displayedEffectDigest: p.digest,actor: .ai); XCTFail("AI approval") } catch {}
        do { _ = try await execute(store,port,p,"no-grant"); XCTFail("missing grant") } catch {}
        let grant = try await approve(store,p)
        let beforeWrites = await port.writes; XCTAssertEqual(beforeWrites,1)
        let op = try await execute(store,port,p,grant)
        let record = try await store.reminderCompensationOperations()[0]
        XCTAssertEqual(record.id,op); XCTAssertEqual(record.state,.confirmed)
        let impact = try await store.correctionActionImpacts()[0]
        XCTAssertTrue(impact.summary.contains("已记录期限补偿")); XCTAssertFalse(impact.summary.contains("尚未执行补偿"))
        let item = await port.item; XCTAssertEqual(item?.dueDate,.some(.none)); XCTAssertEqual(item?.title,"人工改过的标题"); XCTAssertFalse(item!.completed)
        let a = try await store.actions(includeHistory: true)[0]; XCTAssertEqual(a.validity,"frozen"); XCTAssertEqual(a.state,"open"); XCTAssertEqual(a.version,1)
        let feedback = try await store.actionFeedback(actionID: action); XCTAssertTrue(feedback.isEmpty)
        let valid = try await store.integrityCheck(); XCTAssertTrue(valid)
    }
    func testRepeatingCommandsOrChangingCommandNeverRepeatsEffect() async throws {
        let (store,port,action,_,_,_) = try await fixture()
        let p = try await plan(store,action), repeated = try await plan(store,action,command: "another-plan")
        XCTAssertEqual(p.id,repeated.id)
        let grant = try await approve(store,p), replay = try await approve(store,p)
        XCTAssertEqual(grant,replay)
        let op = try await execute(store,port,p,grant)
        let repeatedOp = try await execute(store,port,p,grant,command: "another-execute"); XCTAssertEqual(op,repeatedOp)
        let writes = await port.writes; XCTAssertEqual(writes,2)
        do { _ = try await execute(store,port,p,"another-grant"); XCTFail("changed grant") } catch {}
    }
    func testExplicitCommitmentAndHumanDueChangesCannotInferCompensation() async throws {
        let (pledged,_,action,_,_,_) = try await fixture(authority: .userCommitment)
        do { _ = try await plan(pledged,action); XCTFail("pledge compensation") } catch {}
        let (store,port,ai,_,_,link) = try await fixture()
        await port.edit(due: .dateOnly(localDate: "2026-10-18",timeZone: "Asia/Shanghai"))
        try await store.readReminder(linkID: link.id,calendarID: link.calendarID,using: port,expectedAccessVersion: 1)
        do { _ = try await plan(store,ai); XCTFail("human deadline") } catch {}
        await port.edit(due: due)
        try await store.readReminder(linkID: link.id,calendarID: link.calendarID,using: port,expectedAccessVersion: 1)
        do { _ = try await plan(store,ai); XCTFail("human deadline returned") } catch {}
    }
    func testSourceCorrectionCanPlanButPrivacyFreezingAloneCannot() async throws {
        let (store,_,action,_,source,_) = try await fixture(correct: false)
        let history = try await store.transcriptHistory(sourceID: source)
        _ = try await store.correctTranscript(sourceID: source,expectedVersionID: history[0].id,text: "我不要整理研究资料。")
        let p = try await plan(store,action); XCTAssertEqual(p.rootIDs.count,1)
        let (privacy,_,privateAction,_,privateSource,_) = try await fixture(correct: false)
        _ = try await privacy.setSourceLocalOnly(sourceID: privateSource,expectedVersion: 2,localOnly: true)
        let impacts = try await privacy.correctionActionImpacts(); XCTAssertTrue(impacts.isEmpty)
        do { _ = try await privacy.recordReminderCompensationPlan(actionID: privateAction,expectedImpactDigest: "fabricated",expectedAccessVersion: 1); XCTFail("privacy is not error") } catch {}
    }
    func testPlanStopsIfDisplayedFieldsOrSourcePolicyChangeBeforeApproval() async throws {
        let (store,port,action,_,_,link) = try await fixture()
        let p = try await plan(store,action)
        await port.edit(title: "另一个人工标题")
        try await store.readReminder(linkID: link.id,calendarID: link.calendarID,using: port,expectedAccessVersion: 1)
        do { _ = try await approve(store,p); XCTFail("stale display") } catch {}
        let new = try await plan(store,action,command: "new-plan"); XCTAssertNotEqual(new.digest,p.digest)
        let (restricted,_,other,_,source,_) = try await fixture()
        let privatePlan = try await plan(restricted,other)
        _ = try await restricted.setSourceLocalOnly(sourceID: source,expectedVersion: 2,localOnly: true)
        do { _ = try await approve(restricted,privatePlan); XCTFail("policy changed") } catch {}
    }
    func testPreflightFieldDriftIsRecordedWithoutCompensationWrite() async throws {
        let (store,port,action,_,_,_) = try await fixture()
        let p = try await plan(store,action), grant = try await approve(store,p)
        await port.edit(title: "保存前人工修改")
        _ = try await execute(store,port,p,grant)
        let op = try await store.reminderCompensationOperations()[0]
        XCTAssertEqual(op.state,.conflict); XCTAssertFalse(op.attempted)
        let writes = await port.writes; XCTAssertEqual(writes,1)
    }
    func testRevocationAtConnectorBarrierStopsWriteAndCannotBeReapproved() async throws {
        let (store,port,action,_,_,_) = try await fixture()
        let p = try await plan(store,action), grant = try await approve(store,p)
        await port.configure(update: {
            _ = try await store.revokeReminderCompensation(grantID: grant,reason: "不补偿了",actor: .user,commandID: "revoke")
        })
        do { _ = try await execute(store,port,p,grant); XCTFail("revoked") } catch {}
        let writes = await port.writes; XCTAssertEqual(writes,1)
        do { _ = try await approve(store,p,command: "new-approval"); XCTFail("revocation resurrected") } catch {}
        let replay = try await approve(store,p); XCTAssertEqual(replay,grant)
        let grants = try await store.reminderCompensationGrants(); XCTAssertTrue(grants[0].revoked); XCTAssertFalse(grants[0].eligibleForExecution)
    }
    func testRevocationAfterSaveAllowsReadOnlyReconciliationWithoutUndo() async throws {
        let (store,port,action,_,_,_) = try await fixture()
        let p = try await plan(store,action), grant = try await approve(store,p)
        await port.configure(saved: { _ = try await store.revokeReminderCompensation(grantID: grant,reason: "停止后续写入",actor: .user) })
        do { _ = try await execute(store,port,p,grant); XCTFail("revoked after save") } catch {}
        let op = try await store.reminderCompensationOperations()[0]; XCTAssertEqual(op.state,.unknown); XCTAssertTrue(op.saveAcknowledged)
        try await store.reconcileReminderCompensation(operationID: op.id,expectedAccessVersion: 1,using: port)
        let final = try await store.reminderCompensationOperations()[0]; XCTAssertEqual(final.state,.confirmed)
        let writes = await port.writes; XCTAssertEqual(writes,2)
        let valid = try await store.integrityCheck(); XCTAssertTrue(valid)
    }
    func testLostReceiptObservedTargetAndRepeatedReadNeverRewrites() async throws {
        let (store,port,action,_,_,_) = try await fixture()
        let p = try await plan(store,action), grant = try await approve(store,p)
        await port.configure(loseReceipt: true)
        do { _ = try await execute(store,port,p,grant); XCTFail("lost receipt") } catch {}
        let op = try await store.reminderCompensationOperations()[0]
        await port.setReadFailure(true)
        do { try await store.reconcileReminderCompensation(operationID: op.id,expectedAccessVersion: 1,using: port); XCTFail("failed read") } catch {}
        await port.setReadFailure(false)
        try await store.reconcileReminderCompensation(operationID: op.id,expectedAccessVersion: 1,using: port)
        let observed = try await store.reminderCompensationOperations()[0]; XCTAssertEqual(observed.state,.observed)
        let impact = try await store.correctionActionImpacts()[0]
        XCTAssertTrue(impact.summary.contains("写入归属未确认")); XCTAssertFalse(impact.summary.contains("尚未执行补偿"))
        _ = try await execute(store,port,p,grant,command: "replay")
        let writes = await port.writes; XCTAssertEqual(writes,2)
        let valid = try await store.integrityCheck(); XCTAssertTrue(valid)
    }
    func testOrdinaryReadAtomicallyRecoversUnknownCompensation() async throws {
        let (store,port,action,_,_,link) = try await fixture()
        let p = try await plan(store,action), grant = try await approve(store,p)
        await port.configure(loseReceipt: true)
        do { _ = try await execute(store,port,p,grant); XCTFail("lost receipt") } catch {}
        try await store.readReminder(linkID: link.id,calendarID: link.calendarID,using: port,expectedAccessVersion: 1)
        let observed = try await store.reminderCompensationOperations()[0]; XCTAssertEqual(observed.state,.observed)
        let writes = await port.writes; XCTAssertEqual(writes,2)
    }
    func testPermissionChangedDuringPreflightBlocksWithoutWrite() async throws {
        let (store,port,action,_,_,_) = try await fixture()
        let p = try await plan(store,action), grant = try await approve(store,p)
        await port.configure(find: { _ = try await store.setReminderAccess(calendarID: "compensation",title: "compensation",enabled: false,expectedVersion: 1) })
        do { _ = try await execute(store,port,p,grant); XCTFail("permission changed") } catch {}
        let op = try await store.reminderCompensationOperations()[0]; XCTAssertEqual(op.state,.blocked); XCTAssertFalse(op.attempted)
        let writes = await port.writes; XCTAssertEqual(writes,1)
    }
    func testCopiedMarkerCannotTakeOverCompensationIdentity() async throws {
        let (store,port,action,_,_,_) = try await fixture()
        let p = try await plan(store,action), grant = try await approve(store,p)
        await port.configure(loseReceipt: true)
        do { _ = try await execute(store,port,p,grant); XCTFail("lost receipt") } catch {}
        let op = try await store.reminderCompensationOperations()[0]
        await port.edit(id: "copied-task")
        try await store.reconcileReminderCompensation(operationID: op.id,expectedAccessVersion: 1,using: port)
        let conflict = try await store.reminderCompensationOperations()[0]; XCTAssertEqual(conflict.state,.conflict)
        let writes = await port.writes; XCTAssertEqual(writes,2)
    }
    func testPlanAndApprovalCommitWindowsAreAtomicAndReplayable() async throws {
        for point in [SaveCheckpoint.compensationPlanUncommitted,.compensationPlanCommitted,.compensationGrantUncommitted,.compensationGrantCommitted] {
            let fault = CompensationFault(point)
            let (store,port,action,_,_,_) = try await fixture(checkpoint: { try fault.hit($0) })
            let isPlan = point == .compensationPlanUncommitted || point == .compensationPlanCommitted
            if isPlan {
                do { _ = try await plan(store,action); XCTFail("plan window") } catch {}
                let records = try await store.reminderCompensationPlans(); XCTAssertEqual(records.count,point == .compensationPlanCommitted ? 1 : 0)
                _ = try await plan(store,action)
            } else {
                let p = try await plan(store,action)
                do { _ = try await approve(store,p); XCTFail("approval window") } catch {}
                let grants = try await store.reminderCompensationGrants(); XCTAssertEqual(grants.count,point == .compensationGrantCommitted ? 1 : 0)
                _ = try await approve(store,p)
            }
            let writes = await port.writes; XCTAssertEqual(writes,1)
            let valid = try await store.integrityCheck(); XCTAssertTrue(valid)
        }
    }
    func testReadReceiptWindowsKeepObservationAndEffectTogether() async throws {
        for point in [SaveCheckpoint.compensationOperationUncommitted,.compensationOperationCommitted] {
            let fault = CompensationFault(point)
            let (store,port,action,_,_,_) = try await fixture(checkpoint: { try fault.hit($0) })
            let p = try await plan(store,action), grant = try await approve(store,p)
            do { _ = try await execute(store,port,p,grant); XCTFail("receipt window") } catch {}
            let op = try await store.reminderCompensationOperations()[0]
            XCTAssertEqual(op.state,point == .compensationOperationCommitted ? .confirmed : .unknown)
            if op.state == .unknown { try await store.reconcileReminderCompensation(operationID: op.id,expectedAccessVersion: 1,using: port) }
            let final = try await store.reminderCompensationOperations()[0]; XCTAssertEqual(final.state,.confirmed)
            let valid = try await store.integrityCheck(); XCTAssertTrue(valid)
        }
    }
    func testVersion38PackageKeepsFrozenPlanGrantOperationAndRevocation() async throws {
        let (store,port,action,_,_,_) = try await fixture()
        let p = try await plan(store,action), grant = try await approve(store,p)
        _ = try await execute(store,port,p,grant)
        _ = try await store.revokeReminderCompensation(grantID: grant,reason: "撤回后续许可",actor: .user)
        let package = base.appendingPathComponent("v38-package")
        try await store.exportPackage(to: package,includeMedia: true)
        XCTAssertEqual(try VoiceOSStore.packageSummary(at: package).version,38)
        let root = base.appendingPathComponent("v38-restored")
        try await VoiceOSStore.restorePackage(from: package,to: root,inspector: CompensationInspector())
        let restored = try VoiceOSStore(root: root,inspector: CompensationInspector()); try await restored.recover()
        let plans = try await restored.reminderCompensationPlans(); XCTAssertEqual(plans[0].id,p.id); XCTAssertEqual(plans[0].validity,"frozen"); XCTAssertFalse(plans[0].eligibleForConfirmation)
        let grants = try await restored.reminderCompensationGrants(); XCTAssertTrue(grants[0].revoked); XCTAssertEqual(grants[0].validity,"frozen")
        let ops = try await restored.reminderCompensationOperations(); XCTAssertEqual(ops[0].state,.confirmed); XCTAssertEqual(ops[0].validity,"frozen")
        let access = try await restored.reminderAccess(); XCTAssertNil(access)
        let valid = try await restored.integrityCheck(); XCTAssertTrue(valid)
    }
    func testContinuousTwoScheduleChainRestoresOriginalDueRatherThanIntermediateDate() async throws {
        let (store,port,action,claim,_,link) = try await fixture(correct: false)
        let second = try await store.recordActionSchedule(actionID: action,expectedActionVersion: 1,expectedScheduleVersion: 1,
                                                        proposal: .init(due: .dateOnly(localDate: "2026-10-18",timeZone: "Asia/Shanghai"),authority: .aiFlexible,rawExpression: "重新安排资料整理",anchorEventTime: Date(timeIntervalSince1970: 1791820800)),
                                                        actor: .ai,anchorTimeZone: "Asia/Shanghai",baseObservationID: link.lastObservationID,expectedAccessVersion: 1)
        _ = try await store.executeReminderSchedule(intentID: second,expectedObservationID: link.lastObservationID!,expectedAccessVersion: 1,using: port)
        try await correctClaim(store,claim)
        let p = try await plan(store,action); XCTAssertEqual(p.operationIDs.count,2); XCTAssertEqual(p.desired,ReminderDueDate.none)
        let grant = try await approve(store,p); _ = try await execute(store,port,p,grant)
        let item = await port.item; XCTAssertEqual(item?.dueDate,.some(.none))
        let valid = try await store.integrityCheck(); XCTAssertTrue(valid)
    }
    func testObservedOriginalScheduleCannotCreateCompensationPlan() async throws {
        let (store,_,action,_,_,_) = try await fixture()
        let root = await store.root, db = try Database(root.appendingPathComponent("voiceos.sqlite"))
        // An otherwise identical historical receipt without an acknowledgement.
        try db.execute("UPDATE reminder_schedule_operations SET state='observed',save_acknowledged=0")
        do { _ = try await plan(store,action); XCTFail("unattributed original effect") } catch {}
        let valid = try await store.integrityCheck(); XCTAssertTrue(valid)
    }
    func testNewCorrectionDuringAwaitInvalidatesAlreadyApprovedEffect() async throws {
        let (store,port,action,claim,_,_) = try await fixture()
        let p = try await plan(store,action), grant = try await approve(store,p)
        await port.configure(update: { _ = try await store.reviewClaim(claimID: claim,expectedVersion: 1,action: .correct,statement: "只整理已有索引，不开始研究。",note: "进一步澄清") })
        do { _ = try await execute(store,port,p,grant); XCTFail("correction drift") } catch {}
        let writes = await port.writes; XCTAssertEqual(writes,1)
        let op = try await store.reminderCompensationOperations()[0]; XCTAssertEqual(op.state,.unknown)
    }
    func testCancelledPreflightKeepsCancellationTypeAndNeverWrites() async throws {
        let (store,port,action,_,_,_) = try await fixture()
        let p = try await plan(store,action), grant = try await approve(store,p)
        await port.configure(find: { throw CancellationError() })
        do { _ = try await execute(store,port,p,grant); XCTFail("cancelled read") }
        catch { XCTAssertTrue(error is CancellationError) }
        let op = try await store.reminderCompensationOperations()[0]; XCTAssertEqual(op.state,.blocked); XCTAssertFalse(op.attempted)
        let writes = await port.writes; XCTAssertEqual(writes,1)
    }
    func testDispatchAndSaveWindowsNeverRetryAndRecoverOnlyByReading() async throws {
        for point in [SaveCheckpoint.compensationOperationReserved,.compensationOperationAttempted,.compensationOperationSaved] {
            let fault = CompensationFault(point)
            let (store,port,action,_,_,_) = try await fixture(checkpoint: { try fault.hit($0) })
            let p = try await plan(store,action), grant = try await approve(store,p)
            do { _ = try await execute(store,port,p,grant); XCTFail("operation window") } catch {}
            let op = try await store.reminderCompensationOperations()[0]
            XCTAssertEqual(op.state,point == .compensationOperationReserved ? .blocked : .unknown)
            let before = await port.writes
            _ = try await execute(store,port,p,grant,command: "replay")
            let after = await port.writes; XCTAssertEqual(after,before)
            if op.attempted { try await store.reconcileReminderCompensation(operationID: op.id,expectedAccessVersion: 1,using: port) }
            let final = try await store.reminderCompensationOperations()[0]
            XCTAssertEqual(final.state,point == .compensationOperationSaved ? .confirmed : (op.attempted ? .conflict : .blocked))
            let valid = try await store.integrityCheck(); XCTAssertTrue(valid)
        }
    }
    func testRevocationCommitWindowsRollbackOrPreserveImmutableReceipt() async throws {
        for point in [SaveCheckpoint.compensationRevocationUncommitted,.compensationRevocationCommitted] {
            let fault = CompensationFault(point)
            let (store,port,action,_,_,_) = try await fixture(checkpoint: { try fault.hit($0) })
            let p = try await plan(store,action), grant = try await approve(store,p)
            do { _ = try await store.revokeReminderCompensation(grantID: grant,reason: "撤回",actor: .user,commandID: "revoke"); XCTFail("revocation window") } catch {}
            let grants = try await store.reminderCompensationGrants(); XCTAssertEqual(grants[0].revoked,point == .compensationRevocationCommitted)
            _ = try await store.revokeReminderCompensation(grantID: grant,reason: "撤回",actor: .user,commandID: "revoke")
            let final = try await store.reminderCompensationGrants(); XCTAssertTrue(final[0].revoked)
            let writes = await port.writes; XCTAssertEqual(writes,1)
            let valid = try await store.integrityCheck(); XCTAssertTrue(valid)
        }
    }
    func testRehashedPackageCannotReplaceDerivedCompensationTarget() async throws {
        let (store,_,action,_,_,_) = try await fixture()
        let p = try await plan(store,action)
        let package = base.appendingPathComponent("forged-target")
        try await store.exportPackage(to: package,includeMedia: true)
        let file = package.appendingPathComponent("reminder_compensation_plans.jsonl")
        var row = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String:Any]
        row["desired_json"] = try VoiceOSStore.scheduleJSON(ReminderDueDate.dateOnly(localDate: "2026-10-20",timeZone: "Asia/Shanghai"))
        let strings = row.mapValues { value in value as? String ?? String(describing: value) }
        row["effect_digest"] = try VoiceOSStore.compensationDigest(strings,calendarID: "compensation")
        var data = try JSONSerialization.data(withJSONObject: row,options: [.sortedKeys]); data.append(10); try data.write(to: file)
        let manifestFile = package.appendingPathComponent("manifest.json")
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestFile)) as! [String:Any]
        var files = manifest["files"] as! [[String:Any]]
        let entry = try XCTUnwrap(files.firstIndex { $0["path"] as? String == file.lastPathComponent })
        files[entry]["bytes"] = data.count; files[entry]["sha256"] = SHA256.hash(data: data).map { String(format: "%02x",$0) }.joined()
        manifest["files"] = files; try JSONSerialization.data(withJSONObject: manifest).write(to: manifestFile)
        let root = base.appendingPathComponent("forged-target-restored")
        do { try await VoiceOSStore.restorePackage(from: package,to: root,inspector: CompensationInspector()); XCTFail("arbitrary compensation target") }
        catch { XCTAssertTrue(error.localizedDescription.contains("补偿目标")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path)); XCTAssertEqual(p.desired,ReminderDueDate.none)
    }
    func testSchema37UpgradePreservesNonemptyOrdinaryHistory() async throws {
        let (store,_,_,_,_,_) = try await fixture()
        let root = await store.root, db = try Database(root.appendingPathComponent("voiceos.sqlite"))
        for table in ["reminder_compensation_operations","reminder_compensation_revocations","reminder_compensation_grants","reminder_compensation_plans"] { try db.execute("DROP TABLE \(table)") }
        let tables = try db.query("SELECT name FROM sqlite_master WHERE type='table'").compactMap { $0["name"] }
        let before = try Dictionary(uniqueKeysWithValues: tables.map { ($0,try db.query("SELECT * FROM \($0) ORDER BY id")) })
        try db.execute("PRAGMA user_version=37")
        let upgraded = try Database(root.appendingPathComponent("voiceos.sqlite"))
        XCTAssertEqual(try upgraded.query("PRAGMA user_version").first?["user_version"],"38")
        for table in tables { XCTAssertEqual(try upgraded.query("SELECT * FROM \(table) ORDER BY id"),before[table]) }
        let valid = try await store.integrityCheck(); XCTAssertTrue(valid)
    }
}
