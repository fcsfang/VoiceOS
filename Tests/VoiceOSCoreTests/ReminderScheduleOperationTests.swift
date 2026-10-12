import XCTest
import Foundation
import CryptoKit
@testable import VoiceOSCore

private struct OperationInspector: MediaInspector {
    func inspect(_ url: URL) async throws -> MediaInfo { throw VoiceOSError("text fixture") }
}
private final class OperationFault: @unchecked Sendable {
    private let lock = NSLock()
    private let target: SaveCheckpoint
    private var fired = false
    init(_ target: SaveCheckpoint) { self.target = target }
    func hit(_ point: SaveCheckpoint) throws {
        lock.lock(); defer { lock.unlock() }
        if point == target && !fired { fired = true; throw VoiceOSError("injected persistence window") }
    }
}
private actor OperationPort: RemindersSchedulingPort {
    var item: ReminderSnapshot?
    var writes = 0
    var updates = 0
    var creates = 0
    var reads = 0
    var failRead = false
    var duplicates = false
    var loseSaveReceipt = false
    var failPostRead = false
    var findHook: (@Sendable () async throws -> Void)?
    var updateHook: (@Sendable () async throws -> Void)?
    var savedHook: (@Sendable () async throws -> Void)?
    func configure(find: (@Sendable () async throws -> Void)? = nil,
                   update: (@Sendable () async throws -> Void)? = nil, saved: (@Sendable () async throws -> Void)? = nil,
                   loseReceipt: Bool = false, postReadFailure: Bool = false) {
        findHook = find; updateHook = update; savedHook = saved; loseSaveReceipt = loseReceipt; failPostRead = postReadFailure
    }
    func create(calendarID: String, title: String, marker: String) async throws {
        creates += 1
        item = .init(id: "operation-item", title: title, completed: false, marker: marker, dueDate: .some(.none))
    }
    func find(calendarID: String, externalID: String?, marker: String) async throws -> [ReminderSnapshot] {
        reads += 1
        let hook = findHook; findHook = nil; try await hook?()
        if failRead { throw VoiceOSError("read failed") }
        return item.map { duplicates ? [$0,$0] : [$0] } ?? []
    }
    func updateDue(calendarID: String, expected: ReminderSnapshot, desired: ReminderDueDate,
                   authorize: @escaping @Sendable () async throws -> Void) async throws {
        updates += 1
        let hook = updateHook; updateHook = nil; try await hook?()
        try await authorize()
        guard item == expected, !duplicates else { throw VoiceOSError("connector preflight drift") }
        _ = try desired.writableComponents()
        item = .init(id: expected.id, title: expected.title, completed: expected.completed, marker: expected.marker, dueDate: desired)
        writes += 1
        let after = savedHook; savedHook = nil; try await after?()
        if failPostRead { failRead = true }
        if loseSaveReceipt { throw VoiceOSError("save succeeded, receipt lost") }
    }
    func edit(due: ReminderDueDate? = nil, title: String? = nil, completed: Bool? = nil, marker: String? = nil, id: String? = nil) {
        let old = item!
        item = .init(id: id ?? old.id, title: title ?? old.title, completed: completed ?? old.completed,
                     marker: marker ?? old.marker, dueDate: due ?? old.dueDate)
    }
    func setReadFailure(_ value: Bool) { failRead = value }
    func setDuplicate(_ value: Bool) { duplicates = value }
    func remove() { item = nil }
    func unknownDue() {
        let old = item!
        item = .init(id: old.id, title: old.title, completed: old.completed, marker: old.marker, dueDate: nil)
    }
}

final class ReminderScheduleOperationTests: XCTestCase {
    private var base: URL!
    private let desired = ReminderDueDate.dateOnly(localDate: "2026-10-14", timeZone: "Asia/Shanghai")
    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("schedule-operation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: base) }
    private func fixture(checkpoint: @escaping @Sendable (SaveCheckpoint) throws -> Void = { _ in }) async throws -> (VoiceOSStore, OperationPort, String, String, ReminderLink) {
        let store = try VoiceOSStore(root: base.appendingPathComponent(UUID().uuidString), inspector: OperationInspector(), checkpoint: checkpoint)
        try await store.recover()
        let text = "我会整理开发验证资料。"
        let source = try await store.recordUserExpression(text)
        _ = try await store.setSourceLocalOnly(sourceID: source, expectedVersion: 1, localOnly: false)
        let context = try await store.prepareLocalTranscriptContext(sourceIDs: [source]), input = context.sources[0]
        let contextID = try await store.persistLocalContext(context)
        let attempt = try await store.reserveLocalModelAttempt(contextID: contextID, model: "fixture", promptVersion: "v1", schemaVersion: "v1")
        _ = try await store.commitLocalClaims(attemptID: attempt, proposals: [
            .init(statement: text, ownership: .userTentative,
                  references: [.init(sourceID: source, transcriptVersionID: input.transcriptVersionID, spanID: input.spans[0].id)],
                  action: .init(title: "整理验证资料", kind: .task, quote: text))
        ])
        _ = try await store.setReminderAccess(calendarID: "fixture", title: "fixture", enabled: true, expectedVersion: 0)
        let port = OperationPort(); try await store.activateExtractedTasks(expectedAccessVersion: 1, using: port)
        let action = try await store.actions()[0]
        return (store, port, action.id, source, try await store.reminderLinks()[0])
    }
    private func intent(_ store: VoiceOSStore, _ actionID: String, _ link: ReminderLink,
                        authority: ScheduleAuthority = .aiFlexible, due: ReminderDueDate? = nil, version: Int = 0) async throws -> String {
        try await store.recordActionSchedule(actionID: actionID, expectedActionVersion: 1, expectedScheduleVersion: version,
                                            proposal: .init(due: due ?? desired, authority: authority, rawExpression: "安排资料整理", anchorEventTime: Date(timeIntervalSince1970: 1791820800)),
                                            actor: authority == .aiFlexible ? .ai : .user, anchorTimeZone: "Asia/Shanghai",
                                            baseObservationID: link.lastObservationID, expectedAccessVersion: 1)
    }
    private func execute(_ store: VoiceOSStore, _ port: OperationPort, _ intent: String, _ link: ReminderLink, command: String = "execute") async throws -> String {
        try await store.executeReminderSchedule(intentID: intent, expectedObservationID: link.lastObservationID!, expectedAccessVersion: 1, using: port, commandID: command)
    }
    private func effect(_ store: VoiceOSStore, _ intent: String, _ link: ReminderLink) async throws -> ReminderScheduleEffect {
        try await store.prepareReminderScheduleEffect(intentID: intent, expectedObservationID: link.lastObservationID!, expectedAccessVersion: 1)
    }
    private func approve(_ store: VoiceOSStore, _ effect: ReminderScheduleEffect, command: String = "approve") async throws -> String {
        try await store.confirmReminderSchedule(intentID: effect.intentID, expectedObservationID: effect.observationID,
                                               expectedAccessVersion: effect.accessVersion, displayedEffectDigest: effect.digest,
                                               actor: .user, commandID: command)
    }
    private func executeApproved(_ store: VoiceOSStore, _ port: OperationPort, _ effect: ReminderScheduleEffect, _ grant: String) async throws -> String {
        try await store.executeReminderSchedule(intentID: effect.intentID, expectedObservationID: effect.observationID,
                                               expectedAccessVersion: effect.accessVersion, grantID: grant, using: port, commandID: "approved-execute")
    }
    func testConcreteUserApprovalIsRequiredAndDoesNotItselfWrite() async throws {
        let (store, port, action, _, link) = try await fixture()
        let plan = try await intent(store, action, link, authority: .userCommitment)
        let displayed = try await effect(store, plan, link)
        XCTAssertEqual(displayed.before.dueDate, .some(.none)); XCTAssertEqual(displayed.desired, desired)
        do { _ = try await store.confirmReminderSchedule(intentID: plan, expectedObservationID: displayed.observationID,
                                                         expectedAccessVersion: 1, displayedEffectDigest: displayed.digest, actor: .ai); XCTFail("AI approval") } catch {}
        do { _ = try await execute(store, port, plan, link); XCTFail("no grant") } catch {}
        let grant = try await approve(store, displayed)
        let writesBefore = await port.writes; XCTAssertEqual(writesBefore, 0)
        let receipt = try await approve(store, displayed); XCTAssertEqual(receipt, grant)
        let op = try await executeApproved(store, port, displayed, grant)
        let replay = try await executeApproved(store, port, displayed, grant); XCTAssertEqual(replay, op)
        let records = try await store.reminderScheduleOperations(); XCTAssertEqual(records[0].state, .confirmed)
        let writes = await port.writes; XCTAssertEqual(writes, 1)
        let feedback = try await store.actionFeedback(actionID: action); XCTAssertTrue(feedback.isEmpty)
        let valid = try await store.integrityCheck(); XCTAssertTrue(valid)
    }
    func testStaleDisplayedEffectDigestCannotBeApproved() async throws {
        let (store, port, action, _, link) = try await fixture()
        let plan = try await intent(store, action, link, authority: .userCommitment)
        let displayed = try await effect(store, plan, link)
        await port.edit(title: "人工更改标题")
        try await store.readReminder(linkID: link.id, calendarID: link.calendarID, using: port, expectedAccessVersion: 1)
        let latest = try await store.reminderLinks()[0]
        do { _ = try await approve(store, displayed); XCTFail("stale observation") } catch {}
        let newEffect = try await effect(store, plan, latest)
        XCTAssertNotEqual(newEffect.digest, displayed.digest)
        do { _ = try await store.confirmReminderSchedule(intentID: plan, expectedObservationID: newEffect.observationID,
                                                         expectedAccessVersion: 1, displayedEffectDigest: displayed.digest, actor: .user); XCTFail("old digest new observation") } catch {}
        let grants = try await store.reminderScheduleGrants(); XCTAssertTrue(grants.isEmpty)
    }
    func testGrantCannotAuthorizeAnotherIntentOrScope() async throws {
        let (store, port, action, _, link) = try await fixture()
        let first = try await intent(store, action, link, authority: .userCommitment)
        let displayed = try await effect(store, first, link)
        let grant = try await approve(store, displayed)
        let new = try await intent(store, action, link, authority: .userCommitment, due: .dateOnly(localDate: "2026-10-18", timeZone: "Asia/Shanghai"), version: 1)
        do { _ = try await store.executeReminderSchedule(intentID: new, expectedObservationID: displayed.observationID, expectedAccessVersion: 1, grantID: grant, using: port); XCTFail("grant reused") } catch {}
        _ = try await store.setReminderAccess(calendarID: "another", title: "another", enabled: true, expectedVersion: 1)
        do { _ = try await executeApproved(store, port, displayed, grant); XCTFail("scope changed") } catch {}
        let writes = await port.writes; XCTAssertEqual(writes, 0)
    }
    func testExplicitApprovalCanRemoveManualDeadlineWithoutChangingTitle() async throws {
        let (store, port, action, _, initial) = try await fixture()
        await port.edit(due: desired, title: "用户自己的标题")
        try await store.readReminder(linkID: initial.id, calendarID: initial.calendarID, using: port, expectedAccessVersion: 1)
        let link = try await store.reminderLinks()[0]
        let plan = try await intent(store, action, link, due: ReminderDueDate.none)
        let displayed = try await effect(store, plan, link)
        let grant = try await approve(store, displayed)
        _ = try await executeApproved(store, port, displayed, grant)
        let remote = await port.item; XCTAssertEqual(remote?.dueDate, .some(.none)); XCTAssertEqual(remote?.title, "用户自己的标题")
        let valid = try await store.integrityCheck(); XCTAssertTrue(valid)
    }
    func testGrantRevocationCannotBeUndoneByCommandReplayOrDifferentCommand() async throws {
        let (store, port, action, _, link) = try await fixture()
        let plan = try await intent(store, action, link, authority: .userCommitment)
        let displayed = try await effect(store, plan, link), grant = try await approve(store, displayed)
        let revoke = try await store.revokeReminderScheduleGrant(grantID: grant, reason: "改变主意", actor: .user, commandID: "revoke")
        let repeated = try await store.revokeReminderScheduleGrant(grantID: grant, reason: "改变主意", actor: .user, commandID: "revoke")
        XCTAssertEqual(repeated, revoke)
        let replay = try await approve(store, displayed); XCTAssertEqual(replay, grant)
        do { _ = try await approve(store, displayed, command: "new-approval"); XCTFail("revoked reapproval") } catch {}
        do { _ = try await executeApproved(store, port, displayed, grant); XCTFail("revoked effect") } catch {}
        let grants = try await store.reminderScheduleGrants(); XCTAssertTrue(grants[0].revoked); XCTAssertFalse(grants[0].eligibleForExecution)
        let updates = await port.updates; XCTAssertEqual(updates, 0)
    }
    func testAwaitedGrantRevocationAndSourceFreezeStopBeforeExternalSave() async throws {
        for mode in ["preflight","connector","source"] {
            let (store, port, action, source, link) = try await fixture()
            let plan = try await intent(store, action, link, authority: .userCommitment)
            let displayed = try await effect(store, plan, link), grant = try await approve(store, displayed)
            let hook: @Sendable () async throws -> Void = {
                if mode == "source" { _ = try await store.setSourceLocalOnly(sourceID: source, expectedVersion: 2, localOnly: true) }
                else { _ = try await store.revokeReminderScheduleGrant(grantID: grant, reason: "写前撤回", actor: .user) }
            }
            if mode == "preflight" { await port.configure(find: hook) }
            else { await port.configure(update: hook) }
            do { _ = try await executeApproved(store, port, displayed, grant); XCTFail("invalidated") } catch {}
            let writes = await port.writes; XCTAssertEqual(writes, 0)
            let op = try await store.reminderScheduleOperations()[0]
            XCTAssertEqual(op.state, mode == "preflight" ? .blocked : .unknown)
        }
    }
    func testGrantRevokedAfterSaveOnlyRecoversObservedEffect() async throws {
        let (store, port, action, _, link) = try await fixture()
        let plan = try await intent(store, action, link, authority: .userCommitment)
        let displayed = try await effect(store, plan, link), grant = try await approve(store, displayed)
        await port.configure(saved: { _ = try await store.revokeReminderScheduleGrant(grantID: grant, reason: "派发后撤回", actor: .user) })
        do { _ = try await executeApproved(store, port, displayed, grant); XCTFail("revoked after save") } catch {}
        let unknown = try await store.reminderScheduleOperations()[0]; XCTAssertEqual(unknown.state, .unknown)
        try await store.reconcileReminderSchedule(operationID: unknown.id, expectedAccessVersion: 1, using: port)
        let recovered = try await store.reminderScheduleOperations()[0]; XCTAssertEqual(recovered.state, .confirmed)
        let writes = await port.writes; XCTAssertEqual(writes, 1)
        let valid = try await store.integrityCheck(); XCTAssertTrue(valid)
    }
    func testFreshExternalDriftInvalidatesApprovedEffectWithoutWriting() async throws {
        let (store, port, action, _, link) = try await fixture()
        let plan = try await intent(store, action, link, authority: .userCommitment)
        let displayed = try await effect(store, plan, link), grant = try await approve(store, displayed)
        let manual = ReminderDueDate.dateOnly(localDate: "2026-10-19", timeZone: "Asia/Shanghai")
        await port.edit(due: manual)
        _ = try await executeApproved(store, port, displayed, grant)
        let writes = await port.writes; XCTAssertEqual(writes, 0)
        let ops = try await store.reminderScheduleOperations(); XCTAssertEqual(ops[0].state, .conflict)
        let remote = await port.item; XCTAssertEqual(remote?.dueDate, manual)
    }
    func testGrantAndRevocationPersistenceWindowsAreAtomicAndReplayable() async throws {
        for point in [SaveCheckpoint.scheduleGrantUncommitted, .scheduleGrantCommitted, .scheduleGrantRevocationUncommitted, .scheduleGrantRevocationCommitted] {
            let fault = OperationFault(point)
            let (store, _, action, _, link) = try await fixture { try fault.hit($0) }
            let plan = try await intent(store, action, link, authority: .userCommitment)
            let displayed = try await effect(store, plan, link)
            if point == .scheduleGrantUncommitted || point == .scheduleGrantCommitted {
                do { _ = try await approve(store, displayed); XCTFail("window") } catch {}
                let rows = try await store.reminderScheduleGrants(); XCTAssertEqual(rows.count, point == .scheduleGrantCommitted ? 1 : 0)
                _ = try await approve(store, displayed)
            } else {
                let grant = try await approve(store, displayed)
                do { _ = try await store.revokeReminderScheduleGrant(grantID: grant, reason: "撤回", actor: .user, commandID: "revoke"); XCTFail("revoke window") } catch {}
                let rows = try await store.reminderScheduleGrants(); XCTAssertEqual(rows[0].revoked, point == .scheduleGrantRevocationCommitted)
                _ = try await store.revokeReminderScheduleGrant(grantID: grant, reason: "撤回", actor: .user, commandID: "revoke")
            }
            let valid = try await store.integrityCheck(); XCTAssertTrue(valid)
        }
    }
    func testGrantPackagePreservesRevokedReceiptAndNeverRestoresPermission() async throws {
        let (store, port, action, _, link) = try await fixture()
        let plan = try await intent(store, action, link, authority: .userCommitment)
        let displayed = try await effect(store, plan, link), grant = try await approve(store, displayed)
        _ = try await executeApproved(store, port, displayed, grant)
        _ = try await store.revokeReminderScheduleGrant(grantID: grant, reason: "停止后续使用", actor: .user)
        let package = base.appendingPathComponent("grant-package")
        try await store.exportPackage(to: package, includeMedia: true)
        XCTAssertEqual(try VoiceOSStore.packageSummary(at: package).version, 36)
        let root = base.appendingPathComponent("grant-restored")
        try await VoiceOSStore.restorePackage(from: package, to: root, inspector: OperationInspector())
        let restored = try VoiceOSStore(root: root, inspector: OperationInspector()); try await restored.recover()
        let grants = try await restored.reminderScheduleGrants(); XCTAssertEqual(grants[0].id, grant)
        XCTAssertTrue(grants[0].revoked); XCTAssertEqual(grants[0].validity, "frozen"); XCTAssertFalse(grants[0].eligibleForExecution)
        let ops = try await restored.reminderScheduleOperations(); XCTAssertEqual(ops[0].state, .confirmed); XCTAssertEqual(ops[0].validity, "frozen")
        let access = try await restored.reminderAccess(); XCTAssertNil(access)
        let valid = try await restored.integrityCheck(); XCTAssertTrue(valid)
    }
    func testUnusedGrantRestoresFrozenEvenWithNewConnectionPermission() async throws {
        let (store, port, action, _, link) = try await fixture()
        let plan = try await intent(store, action, link, authority: .userCommitment)
        let displayed = try await effect(store, plan, link), grant = try await approve(store, displayed)
        let package = base.appendingPathComponent("unused-grant")
        try await store.exportPackage(to: package, includeMedia: true)
        XCTAssertEqual(try VoiceOSStore.packageSummary(at: package).version, 36)
        let root = base.appendingPathComponent("unused-restored")
        try await VoiceOSStore.restorePackage(from: package, to: root, inspector: OperationInspector())
        let restored = try VoiceOSStore(root: root, inspector: OperationInspector()); try await restored.recover()
        _ = try await restored.setReminderAccess(calendarID: "fixture", title: "fixture", enabled: true, expectedVersion: 0)
        do { _ = try await executeApproved(restored, port, displayed, grant); XCTFail("frozen grant") } catch {}
        let writes = await port.writes; XCTAssertEqual(writes, 0)
    }
    func testRehashedImportantOperationCannotStripItsGrant() async throws {
        let (store, port, action, _, link) = try await fixture()
        let plan = try await intent(store, action, link, authority: .userCommitment)
        let displayed = try await effect(store, plan, link), grant = try await approve(store, displayed)
        _ = try await executeApproved(store, port, displayed, grant)
        let package = base.appendingPathComponent("stripped-grant")
        try await store.exportPackage(to: package, includeMedia: true)
        let file = package.appendingPathComponent("reminder_schedule_operations.jsonl")
        var row = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String:Any]
        row.removeValue(forKey: "grant_id")
        row["input_fingerprint"] = try VoiceOSStore.scheduleOperationHash(intentID: plan, observationID: displayed.observationID, accessVersion: 1, grantID: nil)
        var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]); data.append(10); try data.write(to: file)
        let manifestFile = package.appendingPathComponent("manifest.json")
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestFile)) as! [String:Any]
        var files = manifest["files"] as! [[String:Any]]
        let index = try XCTUnwrap(files.firstIndex { $0["path"] as? String == file.lastPathComponent })
        files[index]["bytes"] = data.count; files[index]["sha256"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        manifest["files"] = files; try JSONSerialization.data(withJSONObject: manifest).write(to: manifestFile)
        let root = base.appendingPathComponent("stripped-restored")
        do { try await VoiceOSStore.restorePackage(from: package, to: root, inspector: OperationInspector()); XCTFail("important operation without grant") }
        catch { XCTAssertTrue(error.localizedDescription.contains("确认")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
    func testSchema35UpgradePreservesExistingOperationHistory() async throws {
        let (store, port, action, _, link) = try await fixture()
        let plan = try await intent(store, action, link)
        _ = try await execute(store, port, plan, link)
        let root = await store.root, db = try Database(root.appendingPathComponent("voiceos.sqlite"))
        try db.execute("ALTER TABLE reminder_schedule_operations DROP COLUMN grant_id")
        try db.execute("DROP TABLE reminder_schedule_grant_revocations"); try db.execute("DROP TABLE reminder_schedule_grants")
        let tables = try db.query("SELECT name FROM sqlite_master WHERE type='table'").compactMap { $0["name"] }
        let before = try Dictionary(uniqueKeysWithValues: tables.map { ($0, try db.query("SELECT * FROM \($0) ORDER BY id")) })
        try db.execute("PRAGMA user_version=35")
        let upgraded = try Database(root.appendingPathComponent("voiceos.sqlite"))
        XCTAssertEqual(try upgraded.query("PRAGMA user_version").first?["user_version"], "36")
        for table in tables { XCTAssertEqual(try upgraded.query("SELECT * FROM \(table) ORDER BY id"), before[table]) }
        let valid = try await store.integrityCheck(); XCTAssertTrue(valid)
    }
    func testSuccessfulWritePreservesManualTitleAndHasIndependentHistory() async throws {
        let (store, port, actionID, _, initial) = try await fixture()
        await port.edit(title: "用户改过的标题")
        try await store.readReminder(linkID: initial.id, calendarID: initial.calendarID, using: port, expectedAccessVersion: 1)
        let link = try await store.reminderLinks()[0]
        let schedule = try await intent(store, actionID, link)
        let id = try await execute(store, port, schedule, link)
        let op = try await store.reminderScheduleOperations()[0]
        XCTAssertEqual(op.id, id); XCTAssertEqual(op.state, .confirmed); XCTAssertTrue(op.saveAcknowledged)
        let remote = await port.item; XCTAssertEqual(remote?.title, "用户改过的标题"); XCTAssertEqual(remote?.dueDate, desired)
        let action = try await store.actions()[0]; XCTAssertEqual(action.state, "open"); XCTAssertEqual(action.version, 1)
        let feedback = try await store.actionFeedback(actionID: actionID); XCTAssertTrue(feedback.isEmpty)
        let claims = try await store.candidateClaims(); XCTAssertEqual(claims[0].evidenceState, "unverified")
        let integrity = try await store.integrityCheck(); XCTAssertTrue(integrity)
        // The receipt alone does not make the external date freely AI-owned.
        let nextLink = try await store.reminderLinks()[0]
        let next = try await intent(store, actionID, nextLink, due: .dateOnly(localDate: "2026-10-15", timeZone: "Asia/Shanghai"), version: 1)
        let preview = try await store.previewReminderSchedule(intentID: next, expectedAccessVersion: 1)
        XCTAssertEqual(preview.disposition, .requiresConfirmation)
    }
    func testDuplicateCommandOrIntentNeverRepeatsWrite() async throws {
        let (store, port, action, _, link) = try await fixture()
        let plan = try await intent(store, action, link)
        let id = try await execute(store, port, plan, link)
        let replay = try await execute(store, port, plan, link); XCTAssertEqual(replay, id)
        let otherCommand = try await execute(store, port, plan, link, command: "another"); XCTAssertEqual(otherCommand, id)
        do { _ = try await store.executeReminderSchedule(intentID: plan, expectedObservationID: "different", expectedAccessVersion: 1, using: port, commandID: "execute"); XCTFail("changed effect") } catch {}
        let writes = await port.writes, creates = await port.creates; XCTAssertEqual(writes, 1); XCTAssertEqual(creates, 1)
    }
    func testFreshPreflightDriftMissingAndDuplicatesNeverWrite() async throws {
        for mode in ["date","title","marker","identity","missing","duplicate"] {
            let (store, port, action, _, link) = try await fixture()
            let plan = try await intent(store, action, link)
            switch mode {
            case "date": await port.edit(due: .dateOnly(localDate: "2026-10-16", timeZone: "Asia/Shanghai"))
            case "title": await port.edit(title: "刚刚人工更名")
            case "marker": await port.edit(marker: "removed-marker")
            case "identity": await port.edit(id: "different-item")
            case "missing": await port.remove()
            default: await port.setDuplicate(true)
            }
            _ = try await execute(store, port, plan, link)
            let op = try await store.reminderScheduleOperations()[0]; XCTAssertEqual(op.state, .conflict, mode)
            XCTAssertFalse(op.attempted); let writes = await port.writes; XCTAssertEqual(writes, 0)
            let valid = try await store.integrityCheck(); XCTAssertTrue(valid)
        }
    }
    func testAwaitedPreflightRevocationLocalEditAndFreezeStopDispatch() async throws {
        for mode in ["grant","complete","source","newIntent","newBatch","cancel"] {
            let (store, port, action, source, link) = try await fixture()
            let plan = try await intent(store, action, link)
            await port.configure(find: {
                switch mode {
                case "grant": _ = try await store.setReminderAccess(calendarID: "fixture", title: "fixture", enabled: false, expectedVersion: 1)
                case "complete": _ = try await store.setActionState(actionID: action, expectedVersion: 1, state: .completed)
                case "source": _ = try await store.setSourceLocalOnly(sourceID: source, expectedVersion: 2, localOnly: true)
                case "newIntent":
                    _ = try await store.recordActionSchedule(actionID: action, expectedActionVersion: 1, expectedScheduleVersion: 1,
                                                            proposal: .init(due: .none, authority: .aiFlexible, rawExpression: "新安排", anchorEventTime: Date()),
                                                            actor: .ai, anchorTimeZone: "Asia/Shanghai")
                case "newBatch":
                    let context = try await store.prepareLocalTranscriptContext(sourceIDs: [source])
                    let contextID = try await store.persistLocalContext(context)
                    let attempt = try await store.reserveLocalModelAttempt(contextID: contextID, model: "fixture", promptVersion: "v1", schemaVersion: "v1")
                    _ = try await store.commitLocalClaims(attemptID: attempt, proposals: [])
                default: throw CancellationError()
                }
            })
            do { _ = try await execute(store, port, plan, link); XCTFail("stale dispatch " + mode) } catch {}
            let op = try await store.reminderScheduleOperations()[0]; XCTAssertEqual(op.state, .blocked, mode)
            let updates = await port.updates; XCTAssertEqual(updates, 0, mode)
        }
    }
    func testConnectorFinalBarrierRejectsRevocationAndExternalDrift() async throws {
        for mode in ["grant","source","title"] {
            let (store, port, action, source, link) = try await fixture()
            let plan = try await intent(store, action, link)
            await port.configure(update: {
                if mode == "grant" { _ = try await store.setReminderAccess(calendarID: "fixture", title: "fixture", enabled: false, expectedVersion: 1) }
                else if mode == "source" { _ = try await store.setSourceLocalOnly(sourceID: source, expectedVersion: 2, localOnly: true) }
                else { await port.edit(title: "保存前人工更名") }
            })
            do { _ = try await execute(store, port, plan, link); XCTFail("final barrier") } catch {}
            let op = try await store.reminderScheduleOperations()[0]; XCTAssertEqual(op.state, .unknown); XCTAssertTrue(op.attempted)
            let writes = await port.writes; XCTAssertEqual(writes, 0)
            _ = try await execute(store, port, plan, link)
            let updates = await port.updates; XCTAssertEqual(updates, 1)
        }
    }
    func testSaveReceiptLostUsesReadOnlyRecoveryWithoutAssigningAiAuthorship() async throws {
        let (store, port, action, _, link) = try await fixture()
        let plan = try await intent(store, action, link)
        await port.configure(loseReceipt: true)
        do { _ = try await execute(store, port, plan, link); XCTFail("receipt lost") } catch {}
        let unknown = try await store.reminderScheduleOperations()[0]; XCTAssertEqual(unknown.state, .unknown); XCTAssertFalse(unknown.saveAcknowledged)
        _ = try await execute(store, port, plan, link)
        // Ordinary authorized reconciliation reuses its one fresh read.
        let beforeReads = await port.reads
        try await store.reconcileReminders(expectedAccessVersion: 1, using: port)
        let afterReads = await port.reads; XCTAssertEqual(afterReads, beforeReads + 1)
        let recovered = try await store.reminderScheduleOperations()[0]; XCTAssertEqual(recovered.state, .observed)
        let writes = await port.writes; XCTAssertEqual(writes, 1)
        let valid = try await store.integrityCheck(); XCTAssertTrue(valid)
    }
    func testAcknowledgedSaveWithFailedReadRecoversWithoutRewriting() async throws {
        let (store, port, action, _, link) = try await fixture()
        let plan = try await intent(store, action, link)
        await port.configure(postReadFailure: true)
        do { _ = try await execute(store, port, plan, link); XCTFail("read failed") } catch {}
        var op = try await store.reminderScheduleOperations()[0]; XCTAssertEqual(op.state, .unknown); XCTAssertTrue(op.saveAcknowledged)
        do { try await store.reconcileReminderSchedule(operationID: op.id, expectedAccessVersion: 1, using: port); XCTFail("still failed") } catch {}
        await port.setReadFailure(false)
        try await store.reconcileReminderSchedule(operationID: op.id, expectedAccessVersion: 1, using: port)
        op = try await store.reminderScheduleOperations()[0]; XCTAssertEqual(op.state, .confirmed)
        let writes = await port.writes; XCTAssertEqual(writes, 1)
    }
    func testDifferentReadbackIsConflictAndKeepsHumanChange() async throws {
        let (store, port, action, _, link) = try await fixture()
        let plan = try await intent(store, action, link)
        await port.configure(loseReceipt: true)
        do { _ = try await execute(store, port, plan, link) } catch {}
        let human = ReminderDueDate.dateOnly(localDate: "2026-10-20", timeZone: "Asia/Shanghai")
        await port.edit(due: human)
        let op = try await store.reminderScheduleOperations()[0]
        try await store.reconcileReminderSchedule(operationID: op.id, expectedAccessVersion: 1, using: port)
        let read = try await store.reminderScheduleOperations()[0]; XCTAssertEqual(read.state, .conflict)
        let remote = await port.item; XCTAssertEqual(remote?.dueDate, human)
        let writes = await port.writes; XCTAssertEqual(writes, 1)
    }
    func testImportantDeadlineAndUnrepresentableInstantNeverReserveOrWrite() async throws {
        for mode in ["commitment","fraction","fold"] {
            let (store, port, action, _, link) = try await fixture()
            let due: ReminderDueDate = mode == "fraction" ? .instant(utc: "2026-10-13T08:00:00.125Z", timeZone: "Asia/Shanghai") : mode == "fold" ? .instant(utc: "2026-11-01T05:30:00.000Z", timeZone: "America/New_York") : desired
            let plan = try await intent(store, action, link, authority: mode == "commitment" ? .userCommitment : .aiFlexible, due: due)
            do { _ = try await execute(store, port, plan, link); XCTFail("not freely writable") } catch {}
            let ops = try await store.reminderScheduleOperations(); XCTAssertTrue(ops.isEmpty)
            let writes = await port.writes; XCTAssertEqual(writes, 0)
        }
        for due in [ReminderDueDate.none, desired, .dateOnly(localDate: "2026-10-14", timeZone: nil), .instant(utc: "2026-10-13T08:00:00.000Z", timeZone: "Asia/Shanghai")] {
            XCTAssertEqual(ReminderDueDate.reading(try due.writableComponents()), due)
        }
    }
    func testPersistenceWindowsNeverResendAndPreserveCommittedReceipt() async throws {
        for point in [SaveCheckpoint.scheduleOperationReserved, .scheduleOperationAttempted, .scheduleOperationSaved, .scheduleOperationUncommitted, .scheduleOperationCommitted] {
            let fault = OperationFault(point)
            let (store, port, action, _, link) = try await fixture { try fault.hit($0) }
            let plan = try await intent(store, action, link)
            do { _ = try await execute(store, port, plan, link); XCTFail("injected") } catch {}
            let op = try await store.reminderScheduleOperations()[0]
            XCTAssertEqual(op.state, point == .scheduleOperationReserved ? .blocked : point == .scheduleOperationCommitted ? .confirmed : .unknown)
            let expectedWrites = (point == .scheduleOperationReserved || point == .scheduleOperationAttempted) ? 0 : 1
            let beforeWrites = await port.writes; XCTAssertEqual(beforeWrites, expectedWrites)
            if point == .scheduleOperationUncommitted {
                let latest = try await store.reminderLinks()[0]
                XCTAssertEqual(latest.lastObservationID, link.lastObservationID)
                XCTAssertEqual(latest.remoteDueDate, .some(.none))
            }
            _ = try await execute(store, port, plan, link)
            if op.attempted && op.state != .confirmed { try await store.reconcileReminderSchedule(operationID: op.id, expectedAccessVersion: 1, using: port) }
            let afterWrites = await port.writes; XCTAssertEqual(afterWrites, expectedWrites)
            let valid = try await store.integrityCheck(); XCTAssertTrue(valid)
        }
    }
    func testAutomaticRecoveryRollsBackObservationAndReceiptTogether() async throws {
        let fault = OperationFault(.scheduleOperationUncommitted)
        let (store, port, action, _, link) = try await fixture { try fault.hit($0) }
        let plan = try await intent(store, action, link)
        await port.configure(loseReceipt: true)
        do { _ = try await execute(store, port, plan, link) } catch {}
        do { try await store.reconcileReminders(expectedAccessVersion: 1, using: port); XCTFail("injected recovery transaction") } catch {}
        let pending = try await store.reminderScheduleOperations()[0]; XCTAssertEqual(pending.state, .unknown)
        let prior = try await store.reminderLinks()[0]
        XCTAssertEqual(prior.lastObservationID, link.lastObservationID); XCTAssertEqual(prior.remoteDueDate, .some(.none))
        try await store.reconcileReminders(expectedAccessVersion: 1, using: port)
        let recovered = try await store.reminderScheduleOperations()[0]; XCTAssertEqual(recovered.state, .observed)
        let current = try await store.reminderLinks()[0]; XCTAssertEqual(current.lastObservationID, recovered.resultObservationID)
        XCTAssertEqual(current.remoteDueDate, desired)
        let writes = await port.writes; XCTAssertEqual(writes, 1)
    }
    func testRevocationAfterSaveKeepsUnknownAndNewGrantAllowsOnlyReadRecovery() async throws {
        let (store, port, action, _, link) = try await fixture()
        let plan = try await intent(store, action, link)
        await port.configure(saved: { _ = try await store.setReminderAccess(calendarID: "fixture", title: "fixture", enabled: false, expectedVersion: 1) })
        do { _ = try await execute(store, port, plan, link); XCTFail("revoked after save") } catch {}
        let unknown = try await store.reminderScheduleOperations()[0]
        XCTAssertEqual(unknown.state, .unknown); XCTAssertTrue(unknown.saveAcknowledged)
        do { try await store.reconcileReminderSchedule(operationID: unknown.id, expectedAccessVersion: 1, using: port); XCTFail("revoked read") } catch {}
        _ = try await store.setReminderAccess(calendarID: "fixture", title: "fixture", enabled: true, expectedVersion: 2)
        try await store.reconcileReminderSchedule(operationID: unknown.id, expectedAccessVersion: 3, using: port)
        let recovered = try await store.reminderScheduleOperations()[0]; XCTAssertEqual(recovered.state, .confirmed)
        let writes = await port.writes; XCTAssertEqual(writes, 1)
    }
    func testRecoveryUnknownTimeAndIdentityNeverInventsSuccess() async throws {
        for mode in ["unknown","missing","duplicate","identity","completed"] {
            let (store, port, action, _, link) = try await fixture()
            let plan = try await intent(store, action, link)
            await port.configure(loseReceipt: true)
            do { _ = try await execute(store, port, plan, link) } catch {}
            switch mode {
            case "unknown": await port.unknownDue()
            case "missing": await port.remove()
            case "duplicate": await port.setDuplicate(true)
            case "identity": await port.edit(completed: true, id: "replacement-with-same-marker")
            default: await port.edit(completed: true)
            }
            let op = try await store.reminderScheduleOperations()[0]
            try await store.reconcileReminderSchedule(operationID: op.id, expectedAccessVersion: 1, using: port)
            let result = try await store.reminderScheduleOperations()[0]
            XCTAssertEqual(result.state, mode == "unknown" ? .unknown : .conflict, mode)
            XCTAssertNil(result.resultObservationID)
            let writes = await port.writes; XCTAssertEqual(writes, 1)
            if mode == "identity" {
                let action = try await store.actions()[0]; XCTAssertEqual(action.state, "open")
                let current = try await store.reminderLinks()[0]; XCTAssertEqual(current.externalID, link.externalID)
            }
            let valid = try await store.integrityCheck(); XCTAssertTrue(valid)
        }
    }
    func testRestartDoesNotDispatchInterruptedPreflightOrUnknownAttempt() async throws {
        for point in [SaveCheckpoint.scheduleOperationReserved, .scheduleOperationAttempted] {
            let fault = OperationFault(point)
            var old: VoiceOSStore?
            let port: OperationPort, plan: String, link: ReminderLink, root: URL
            do {
                let fixture = try await fixture { try fault.hit($0) }
                old = fixture.0; port = fixture.1; link = fixture.4
                plan = try await intent(fixture.0, fixture.2, link)
                root = await fixture.0.root
                do { _ = try await execute(fixture.0, port, plan, link) } catch {}
                if point == .scheduleOperationReserved {
                    // Simulate durable preflight state left by an exit instead
                    // of the in-process catch that normally marks it blocked.
                    let database = try Database(root.appendingPathComponent("voiceos.sqlite"))
                    try database.execute("UPDATE reminder_schedule_operations SET state='reserved'")
                }
            }
            XCTAssertNotNil(old)
            old = nil
            let restored = try VoiceOSStore(root: root, inspector: OperationInspector()); try await restored.recover()
            let op = try await restored.reminderScheduleOperations()[0]
            XCTAssertEqual(op.state, point == .scheduleOperationReserved ? .blocked : .unknown)
            _ = try await execute(restored, port, plan, link)
            let updates = await port.updates; XCTAssertEqual(updates, 0)
            let valid = try await restored.integrityCheck(); XCTAssertTrue(valid)
        }
    }
    func testPackagePreservesReceiptAndFreezesExecutionWithoutGrant() async throws {
        let (store, port, action, _, link) = try await fixture()
        let plan = try await intent(store, action, link)
        _ = try await execute(store, port, plan, link)
        let package = base.appendingPathComponent("package")
        try await store.exportPackage(to: package, includeMedia: true)
        XCTAssertEqual(try VoiceOSStore.packageSummary(at: package).version, 35)
        let root = base.appendingPathComponent("restored")
        try await VoiceOSStore.restorePackage(from: package, to: root, inspector: OperationInspector())
        let restored = try VoiceOSStore(root: root, inspector: OperationInspector()); try await restored.recover()
        let op = try await restored.reminderScheduleOperations()[0]; XCTAssertEqual(op.state, .confirmed); XCTAssertEqual(op.validity, "frozen")
        let access = try await restored.reminderAccess(); XCTAssertNil(access)
        do { try await restored.reconcileReminderSchedule(operationID: op.id, expectedAccessVersion: 1, using: port); XCTFail("migration grant") } catch {}
        let valid = try await restored.integrityCheck(); XCTAssertTrue(valid)
    }
    func testRehashedPackageCannotInventSuccessfulObservation() async throws {
        let (store, port, action, _, link) = try await fixture()
        let plan = try await intent(store, action, link)
        _ = try await execute(store, port, plan, link)
        let package = base.appendingPathComponent("forged")
        try await store.exportPackage(to: package, includeMedia: true)
        let file = package.appendingPathComponent("reminder_schedule_operations.jsonl")
        var row = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String:Any]
        row["result_observation_id"] = link.lastObservationID!
        var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]); data.append(10); try data.write(to: file)
        let manifestFile = package.appendingPathComponent("manifest.json")
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestFile)) as! [String:Any]
        var files = manifest["files"] as! [[String:Any]]
        let i = try XCTUnwrap(files.firstIndex { $0["path"] as? String == file.lastPathComponent })
        files[i]["bytes"] = data.count; files[i]["sha256"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        manifest["files"] = files; try JSONSerialization.data(withJSONObject: manifest).write(to: manifestFile)
        let root = base.appendingPathComponent("forged-restored")
        do { try await VoiceOSStore.restorePackage(from: package, to: root, inspector: OperationInspector()); XCTFail("false success") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
    func testSchema34UpgradeDoesNotChangeExistingHistory() async throws {
        let (store, _, _, _, _) = try await fixture()
        let root = await store.root
        let db = try Database(root.appendingPathComponent("voiceos.sqlite"))
        let tables = try db.query("SELECT name FROM sqlite_master WHERE type='table' AND name!='reminder_schedule_operations'").compactMap { $0["name"] }
        let before = try Dictionary(uniqueKeysWithValues: tables.map { ($0, try db.query("SELECT * FROM \($0) ORDER BY id")) })
        try db.execute("DROP TABLE reminder_schedule_operations"); try db.execute("DROP TABLE reminder_schedule_grant_revocations"); try db.execute("DROP TABLE reminder_schedule_grants"); try db.execute("PRAGMA user_version=34")
        let upgraded = try Database(root.appendingPathComponent("voiceos.sqlite"))
        XCTAssertEqual(try upgraded.query("PRAGMA user_version").first?["user_version"], "36")
        for table in tables { XCTAssertEqual(try upgraded.query("SELECT * FROM \(table) ORDER BY id"), before[table]) }
    }
}
