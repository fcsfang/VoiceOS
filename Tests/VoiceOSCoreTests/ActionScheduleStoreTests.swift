import XCTest
import Foundation
import CryptoKit
@testable import VoiceOSCore

private struct ScheduleInspector: MediaInspector {
    func inspect(_ url: URL) async throws -> MediaInfo { throw VoiceOSError("text fixture") }
}
private actor SchedulePort: RemindersPort {
    var item: ReminderSnapshot?
    var creates = 0
    func create(calendarID: String, title: String, marker: String) async throws {
        creates += 1
        item = .init(id: "schedule-remote", title: title, completed: false, marker: marker, dueDate: .some(.none))
    }
    func find(calendarID: String, externalID: String?, marker: String) async throws -> [ReminderSnapshot] {
        item.map { [$0] } ?? []
    }
    func editDue(_ due: ReminderDueDate) {
        let old = item!
        item = .init(id: old.id, title: old.title, completed: old.completed, marker: old.marker, dueDate: due)
    }
}
final class ActionScheduleStoreTests: XCTestCase {
    private var base: URL!
    private let due = ReminderDueDate.dateOnly(localDate: "2026-10-14", timeZone: "Asia/Shanghai")
    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("schedule-intent-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: base) }
    private func fixture(checkpoint: @escaping @Sendable (SaveCheckpoint) throws -> Void = { _ in }) async throws -> (VoiceOSStore, String, String) {
        let store = try VoiceOSStore(root: base.appendingPathComponent(UUID().uuidString), inspector: ScheduleInspector(), checkpoint: checkpoint)
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
        return (store, try await store.actions()[0].id, source)
    }
    private func proposal(_ authority: ScheduleAuthority = .aiFlexible, due: ReminderDueDate? = nil) throws -> ReminderScheduleProposal {
        try .init(due: due ?? self.due, authority: authority, rawExpression: "明天整理验证资料", anchorEventTime: Date(timeIntervalSince1970: 1791820800.125))
    }
    private func record(_ store: VoiceOSStore, _ action: String, version: Int = 0, actor: ActionScheduleActor = .ai,
                        authority: ScheduleAuthority = .aiFlexible, command: String = UUID().uuidString) async throws -> String {
        try await store.recordActionSchedule(actionID: action, expectedActionVersion: 1, expectedScheduleVersion: version,
                                             proposal: proposal(authority), actor: actor, anchorTimeZone: "Asia/Shanghai", commandID: command)
    }
    private func link(_ store: VoiceOSStore) async throws -> (SchedulePort, ReminderLink) {
        _ = try await store.setReminderAccess(calendarID: "fixture", title: "fixture", enabled: true, expectedVersion: 0)
        let port = SchedulePort()
        try await store.activateExtractedTasks(expectedAccessVersion: 1, using: port)
        return (port, try await store.reminderLinks()[0])
    }
    func testIndependentScheduleHistoryKeepsActionAndClaimUnchanged() async throws {
        let (store, actionID, _) = try await fixture()
        _ = try await record(store, actionID)
        _ = try await record(store, actionID, version: 1)
        let latest = try await store.actionScheduleIntents()
        XCTAssertEqual(latest.count, 1); XCTAssertEqual(latest[0].version, 2)
        XCTAssertEqual(latest[0].anchorTimeZone, "Asia/Shanghai")
        XCTAssertEqual(latest[0].anchorEventTime.timeIntervalSince1970, 1791820800.125, accuracy: 0.001)
        XCTAssertTrue(latest[0].eligibleForPlanning)
        let history = try await store.actionScheduleIntents(includeHistory: true)
        XCTAssertEqual(history.map(\.version), [1,2]); XCTAssertFalse(history[0].eligibleForPlanning)
        let action = try await store.actions()[0]; XCTAssertEqual(action.version, 1); XCTAssertEqual(action.state, "open")
        let claims = try await store.candidateClaims(); XCTAssertEqual(claims[0].evidenceState, "unverified")
        let links = try await store.reminderLinks(); XCTAssertTrue(links.isEmpty)
    }
    func testReplayDoesNotCreateNewScheduleButDifferentInputIsRejected() async throws {
        let (store, action, _) = try await fixture()
        let id = try await record(store, action, command: "same")
        let repeated = try await record(store, action, command: "same"); XCTAssertEqual(repeated, id)
        do { _ = try await record(store, action, version: 1, command: "same"); XCTFail("changed command") } catch {}
        let rows = try await store.actionScheduleIntents(includeHistory: true); XCTAssertEqual(rows.count, 1)
    }
    func testAiCannotCreateOrDowngradeUserCommitmentEvenWithSameDate() async throws {
        let (store, action, _) = try await fixture()
        do { _ = try await record(store, action, authority: .userCommitment); XCTFail("AI pledge") } catch {}
        _ = try await record(store, action, actor: .user, authority: .userCommitment)
        do { _ = try await record(store, action, version: 1); XCTFail("downgrade pledge") } catch {}
        let current = try await store.actionScheduleIntents()[0]
        XCTAssertEqual(current.authority, .userCommitment); XCTAssertEqual(current.actor, .user)
        // Explicit user revision remains a local desired change, not an external grant.
        _ = try await record(store, action, version: 1, actor: .user)
        let next = try await store.actionScheduleIntents()[0]; XCTAssertEqual(next.version, 2)
    }
    func testCompareAndSwapStatusAndSourceChangesBlockStalePlans() async throws {
        let (store, action, source) = try await fixture()
        _ = try await record(store, action)
        do { _ = try await record(store, action); XCTFail("schedule CAS") } catch {}
        _ = try await store.setActionState(actionID: action, expectedVersion: 1, state: .completed)
        let old = try await store.actionScheduleIntents()[0]; XCTAssertFalse(old.eligibleForPlanning)
        do { _ = try await record(store, action, version: 1); XCTFail("stale action version") } catch {}
        _ = try await store.setSourceLocalOnly(sourceID: source, expectedVersion: 2, localOnly: true)
        let frozen = try await store.actionScheduleIntents()[0]; XCTAssertEqual(frozen.validity, "frozen")
    }
    func testSavedNoneBasePlansOrdinaryChangeAndPreservesLaterExternalEdit() async throws {
        let (store, action, _) = try await fixture()
        let (port, link) = try await link(store)
        let id = try await store.recordActionSchedule(actionID: action, expectedActionVersion: 1, expectedScheduleVersion: 0,
                                                     proposal: proposal(), actor: .ai, anchorTimeZone: "Asia/Shanghai",
                                                     baseObservationID: link.lastObservationID, expectedAccessVersion: 1)
        let plan = try await store.previewReminderSchedule(intentID: id, expectedAccessVersion: 1)
        XCTAssertEqual(plan.disposition, .writeFlexible)
        await port.editDue(.dateOnly(localDate: "2026-10-15", timeZone: "Asia/Shanghai"))
        try await store.readReminder(linkID: link.id, calendarID: link.calendarID, using: port, expectedAccessVersion: 1)
        let changed = try await store.previewReminderSchedule(intentID: id, expectedAccessVersion: 1)
        XCTAssertEqual(changed.disposition, .replanKeepingRemote)
        let creates = await port.creates; XCTAssertEqual(creates, 1)
        _ = try await store.setReminderAccess(calendarID: link.calendarID, title: "fixture", enabled: false, expectedVersion: 1)
        do { _ = try await store.previewReminderSchedule(intentID: id, expectedAccessVersion: 1); XCTFail("revoked preview") } catch {}
    }
    func testManualDeadlineIsNotAssumedToBeAiFlexible() async throws {
        let (store, action, _) = try await fixture()
        let (port, original) = try await link(store)
        await port.editDue(.dateOnly(localDate: "2026-10-16", timeZone: "Asia/Shanghai"))
        try await store.readReminder(linkID: original.id, calendarID: original.calendarID, using: port, expectedAccessVersion: 1)
        let link = try await store.reminderLinks()[0]
        do {
            _ = try await store.recordActionSchedule(actionID: action, expectedActionVersion: 1, expectedScheduleVersion: 0,
                                                     proposal: proposal(), actor: .ai, anchorTimeZone: "Asia/Shanghai",
                                                     baseObservationID: original.lastObservationID, expectedAccessVersion: 1)
            XCTFail("stale baseline")
        } catch {}
        let id = try await store.recordActionSchedule(actionID: action, expectedActionVersion: 1, expectedScheduleVersion: 0,
                                                     proposal: proposal(), actor: .ai, anchorTimeZone: "Asia/Shanghai",
                                                     baseObservationID: link.lastObservationID, expectedAccessVersion: 1)
        let record = try await store.actionScheduleIntents()[0]; XCTAssertEqual(record.baseAuthority, .externalManual)
        let plan = try await store.previewReminderSchedule(intentID: id, expectedAccessVersion: 1)
        XCTAssertEqual(plan.disposition, .requiresConfirmation)
    }
    func testMigrationPreservesPledgeHistoryAndFreezesExecution() async throws {
        let (store, action, _) = try await fixture()
        _ = try await record(store, action, actor: .user, authority: .userCommitment)
        let package = base.appendingPathComponent("schedules")
        try await store.exportPackage(to: package, includeMedia: true)
        XCTAssertEqual(try VoiceOSStore.packageSummary(at: package).version, 34)
        let root = base.appendingPathComponent("restored")
        try await VoiceOSStore.restorePackage(from: package, to: root, inspector: ScheduleInspector())
        let restored = try VoiceOSStore(root: root, inspector: ScheduleInspector()); try await restored.recover()
        let intent = try await restored.actionScheduleIntents()[0]
        XCTAssertEqual(intent.due, due); XCTAssertEqual(intent.authority, .userCommitment)
        XCTAssertEqual(intent.validity, "frozen"); XCTAssertFalse(intent.eligibleForPlanning)
        let access = try await restored.reminderAccess(); XCTAssertNil(access)
    }
    func testRehashedMigrationCannotDowngradeManualBase() async throws {
        let (store, action, _) = try await fixture()
        let (port, initial) = try await link(store)
        await port.editDue(due)
        try await store.readReminder(linkID: initial.id, calendarID: initial.calendarID, using: port, expectedAccessVersion: 1)
        let link = try await store.reminderLinks()[0]
        _ = try await store.recordActionSchedule(actionID: action, expectedActionVersion: 1, expectedScheduleVersion: 0,
                                                proposal: proposal(due: .dateOnly(localDate: "2026-10-17", timeZone: "Asia/Shanghai")), actor: .ai,
                                                anchorTimeZone: "Asia/Shanghai", baseObservationID: link.lastObservationID, expectedAccessVersion: 1)
        let package = base.appendingPathComponent("forged")
        try await store.exportPackage(to: package, includeMedia: true)
        let file = package.appendingPathComponent("action_schedule_intents.jsonl")
        var row = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        row["base_authority"] = "ai_flexible"
        var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]); data.append(10); try data.write(to: file)
        let manifestFile = package.appendingPathComponent("manifest.json")
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestFile)) as! [String: Any]
        var files = manifest["files"] as! [[String: Any]]
        let i = try XCTUnwrap(files.firstIndex { $0["path"] as? String == file.lastPathComponent })
        files[i]["bytes"] = data.count; files[i]["sha256"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        manifest["files"] = files; try JSONSerialization.data(withJSONObject: manifest).write(to: manifestFile)
        let root = base.appendingPathComponent("forged-restored")
        do { try await VoiceOSStore.restorePackage(from: package, to: root, inspector: ScheduleInspector()); XCTFail("downgraded base") }
        catch { XCTAssertTrue(error.localizedDescription.contains("基线")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
    func testCommitWindowsRollbackOrReplayWithoutPartialHistory() async throws {
        for committed in [false, true] {
            let (store, action, _) = try await fixture { point in
                if point == (committed ? .actionScheduleCommitted : .actionScheduleUncommitted) { throw VoiceOSError("injected schedule window") }
            }
            do { _ = try await record(store, action, command: "window"); XCTFail("window") } catch {}
            let rows = try await store.actionScheduleIntents(includeHistory: true)
            XCTAssertEqual(rows.count, committed ? 1 : 0)
            if committed { let id = try await record(store, action, command: "window"); XCTAssertEqual(id, rows[0].id) }
            let actions = try await store.actions(); XCTAssertEqual(actions[0].version, 1)
        }
    }
    func testSchema33UpgradePreservesExistingNonemptyTables() async throws {
        let (store, _, _) = try await fixture()
        _ = try await link(store)
        let root = await store.root
        let db = try Database(root.appendingPathComponent("voiceos.sqlite"))
        let tables = try db.query("SELECT name FROM sqlite_master WHERE type='table' AND name!='action_schedule_intents'").compactMap { $0["name"] }
        let before = try Dictionary(uniqueKeysWithValues: tables.map { ($0, try db.query("SELECT * FROM \($0) ORDER BY id")) })
        try db.execute("DROP TABLE action_schedule_intents"); try db.execute("PRAGMA user_version=33")
        let upgraded = try Database(root.appendingPathComponent("voiceos.sqlite"))
        XCTAssertEqual(try upgraded.query("PRAGMA user_version").first?["user_version"], "34")
        for table in tables { XCTAssertEqual(try upgraded.query("SELECT * FROM \(table) ORDER BY id"), before[table]) }
    }
}
