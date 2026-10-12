import XCTest
import Foundation
import CryptoKit
@testable import VoiceOSCore

private struct ResolutionInspector: MediaInspector {
    func inspect(_ url: URL) async throws -> MediaInfo { throw VoiceOSError("text fixture only") }
}
private actor ResolutionPort: RemindersPort {
    var items: [ReminderSnapshot] = []
    var creates = 0, reads = 0
    var suspended = false
    var gate: CheckedContinuation<Void, Never>?, started: CheckedContinuation<Void, Never>?
    func create(calendarID: String, title: String, marker: String) async throws {
        creates += 1; items.append(.init(id: "fixture-external", title: title, completed: false, marker: marker))
    }
    func find(calendarID: String, externalID: String?, marker: String) async throws -> [ReminderSnapshot] {
        reads += 1
        if suspended { suspended = false; await withCheckedContinuation { gate = $0; started?.resume(); started = nil } }
        return items.filter { $0.marker == marker || $0.id == externalID }
    }
    func edit(completed: Bool, title: String? = nil, corruptMarker: Bool = false) {
        let old = items[0]
        items[0] = .init(id: old.id, title: title ?? old.title, completed: completed, marker: corruptMarker ? "invalid" : old.marker, dueDate: old.dueDate)
    }
    func editDue(_ due: ReminderDueDate?) {
        let old = items[0]
        items[0] = .init(id: old.id, title: old.title, completed: old.completed, marker: old.marker, dueDate: due)
    }
    func duplicate() { let old = items[0]; items.append(.init(id: "duplicate", title: old.title, completed: old.completed, marker: old.marker)) }
    func remove() { items = [] }
    func suspendNextRead() { suspended = true }
    func waitStarted() async { if gate == nil { await withCheckedContinuation { started = $0 } } }
    func release() { gate?.resume(); gate = nil }
}

final class ReminderStatusResolutionTests: XCTestCase {
    private var base: URL!
    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("reminder-resolution-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: base) }
    private func fixture(checkpoint: @escaping @Sendable (SaveCheckpoint) throws -> Void = { _ in }) async throws -> (VoiceOSStore, ResolutionPort, ReminderLink, String) {
        let store = try VoiceOSStore(root: base.appendingPathComponent(UUID().uuidString), inspector: ResolutionInspector(), checkpoint: checkpoint)
        try await store.recover()
        let text = "我会整理开发验证素材。"
        let source = try await store.recordUserExpression(text)
        _ = try await store.setSourceLocalOnly(sourceID: source, expectedVersion: 1, localOnly: false)
        let context = try await store.prepareLocalTranscriptContext(sourceIDs: [source]), input = context.sources[0]
        let contextID = try await store.persistLocalContext(context)
        let attempt = try await store.reserveLocalModelAttempt(contextID: contextID, model: "fixture", promptVersion: "v1", schemaVersion: "v1")
        _ = try await store.commitLocalClaims(attemptID: attempt, proposals: [
            .init(statement: text, ownership: .userTentative,
                  references: [.init(sourceID: source, transcriptVersionID: input.transcriptVersionID, spanID: input.spans[0].id)],
                  action: .init(title: "整理开发验证素材", kind: .task, quote: text))
        ])
        _ = try await store.setReminderAccess(calendarID: "fixture", title: "fixture", enabled: true, expectedVersion: 0)
        let port = ResolutionPort()
        try await store.activateExtractedTasks(expectedAccessVersion: 1, using: port)
        let link = try await store.reminderLinks()[0]
        await port.edit(completed: true)
        try await store.readReminder(linkID: link.id, calendarID: link.calendarID, using: port, expectedAccessVersion: 1)
        await port.edit(completed: false)
        try await store.readReminder(linkID: link.id, calendarID: link.calendarID, using: port, expectedAccessVersion: 1)
        return (store, port, try await store.reminderLinks()[0], source)
    }
    private func accept(_ store: VoiceOSStore, _ port: ResolutionPort, _ link: ReminderLink, command: String = "accept") async throws -> Int {
        try await store.acceptReminderStatus(linkID: link.id, expectedActionVersion: 2,
                                             expectedObservationID: XCTUnwrap(link.lastObservationID), expectedAccessVersion: 1,
                                             using: port, commandID: command)
    }
    func testAcceptReopenPreservesHistoryAndLaterCompletionFlowsAutomatically() async throws {
        let (store, port, link, _) = try await fixture()
        XCTAssertEqual(link.state, "conflict")
        let version = try await accept(store, port, link); XCTAssertEqual(version, 3)
        let reopened = try await store.actions()[0]; XCTAssertEqual(reopened.state, "open")
        let resolved = try await store.reminderLinks()[0]; XCTAssertEqual(resolved.state, "linked")
        let reads = await port.reads
        let replay = try await accept(store, port, link); XCTAssertEqual(replay, 3)
        let replayReads = await port.reads; XCTAssertEqual(replayReads, reads)
        await port.edit(completed: true)
        try await store.readReminder(linkID: link.id, calendarID: link.calendarID, using: port, expectedAccessVersion: 1)
        try await store.readReminder(linkID: link.id, calendarID: link.calendarID, using: port, expectedAccessVersion: 1)
        let history = try await store.actionHistory(actionID: link.actionID)
        XCTAssertEqual(history.map(\.state), ["open", "completed", "open", "completed"])
        XCTAssertEqual(history.map(\.actor), ["user", "external", "user", "external"])
        let claims = try await store.candidateClaims(); XCTAssertEqual(claims[0].evidenceState, "unverified")
        let creates = await port.creates; XCTAssertEqual(creates, 1)
        do {
            _ = try await store.acceptReminderStatus(linkID: link.id, expectedActionVersion: 4,
                                                     expectedObservationID: XCTUnwrap(link.lastObservationID), expectedAccessVersion: 1,
                                                     using: port, commandID: "accept")
            XCTFail("command changed effect")
        } catch {}
    }
    func testDriftMissingDuplicateAndInvalidMarkerCannotAdoptOldObservation() async throws {
        for scenario in 0..<4 {
            let (store, port, link, _) = try await fixture()
            switch scenario {
            case 0: await port.edit(completed: true)
            case 1: await port.remove()
            case 2: await port.duplicate()
            default: await port.edit(completed: false, corruptMarker: true)
            }
            do { _ = try await accept(store, port, link); XCTFail("unsafe observation \(scenario)") } catch {}
            let action = try await store.actions(includeHistory: true)[0]
            XCTAssertEqual(action.version, 2); XCTAssertEqual(action.state, "completed")
            let history = try await store.actionHistory(actionID: link.actionID); XCTAssertEqual(history.count, 2)
            let creates = await port.creates; XCTAssertEqual(creates, 1)
        }
    }
    func testDismissedTaskCanAdoptCompletionWithoutGeneratingOutcomeOrChangingClaim() async throws {
        let (store, port, link, _) = try await fixture()
        _ = try await store.setActionState(actionID: link.actionID, expectedVersion: 2, state: .dismissed)
        await port.edit(completed: true)
        try await store.readReminder(linkID: link.id, calendarID: link.calendarID, using: port, expectedAccessVersion: 1)
        let conflict = try await store.reminderLinks()[0]
        XCTAssertEqual(conflict.state, "conflict")
        let version = try await store.acceptReminderStatus(linkID: link.id, expectedActionVersion: 3,
                                                         expectedObservationID: XCTUnwrap(conflict.lastObservationID),
                                                         expectedAccessVersion: 1, using: port)
        XCTAssertEqual(version, 4)
        let history = try await store.actionHistory(actionID: link.actionID)
        XCTAssertEqual(history.map(\.state), ["open", "completed", "dismissed", "completed"])
        XCTAssertEqual(history.last?.actor, "user")
        let claims = try await store.candidateClaims()
        XCTAssertEqual(claims[0].evidenceState, "unverified")
        let root = await store.root
        let db = try Database(root.appendingPathComponent("voiceos.sqlite"))
        XCTAssertTrue(try db.query("SELECT id FROM action_feedback").isEmpty)
        XCTAssertEqual(try db.query("SELECT id FROM reminder_status_resolutions").count, 1)
        let creates = await port.creates
        XCTAssertEqual(creates, 1)
    }
    func testAwaitRevalidatesLocalEditSourceRestrictionScopeAndCancellation() async throws {
        for scenario in 0..<4 {
            let (store, port, link, sourceID) = try await fixture()
            await port.suspendNextRead()
            let running = Task { try await self.accept(store, port, link) }
            await port.waitStarted()
            switch scenario {
            case 0: _ = try await store.setActionState(actionID: link.actionID, expectedVersion: 2, state: .dismissed)
            case 1: _ = try await store.setSourceLocalOnly(sourceID: sourceID, expectedVersion: 2, localOnly: true)
            case 2: _ = try await store.setReminderAccess(calendarID: link.calendarID, title: "fixture", enabled: false, expectedVersion: 1)
            default: running.cancel()
            }
            await port.release()
            do { _ = try await running.value; XCTFail("stale resolution \(scenario)") } catch {}
            let action = try await store.actions(includeHistory: true)[0]
            XCTAssertEqual(action.version, scenario == 0 ? 3 : 2)
            XCTAssertEqual(action.state, scenario == 0 ? "dismissed" : "completed")
            let history = try await store.actionHistory(actionID: link.actionID)
            XCTAssertFalse(history.contains { $0.note.contains("用户采用重新回读") })
        }
    }
    func testResolutionMigrationPreservesBothBaselinesAndRequiresNewScope() async throws {
        let (store, port, link, _) = try await fixture()
        _ = try await accept(store, port, link)
        await port.edit(completed: true)
        try await store.readReminder(linkID: link.id, calendarID: link.calendarID, using: port, expectedAccessVersion: 1)
        let package = base.appendingPathComponent("package")
        try await store.exportPackage(to: package, includeMedia: true)
        XCTAssertEqual(try VoiceOSStore.packageSummary(at: package).version, 32)
        let root = base.appendingPathComponent("restored")
        try await VoiceOSStore.restorePackage(from: package, to: root, inspector: ResolutionInspector())
        let restored = try VoiceOSStore(root: root, inspector: ResolutionInspector()); try await restored.recover()
        let access = try await restored.reminderAccess(); XCTAssertNil(access)
        let history = try await restored.actionHistory(actionID: link.actionID); XCTAssertEqual(history.count, 4)
        let creates = await port.creates
        do { try await restored.reconcileReminders(expectedAccessVersion: 1, using: port); XCTFail("restored authority") } catch {}
        _ = try await restored.setReminderAccess(calendarID: link.calendarID, title: "fixture", enabled: true, expectedVersion: 0)
        try await restored.reconcileReminders(expectedAccessVersion: 1, using: port)
        let after = await port.creates; XCTAssertEqual(after, creates)
        let recovered = try await restored.reminderLinks()[0]; XCTAssertEqual(recovered.state, "linked")
        let integrity = try await restored.integrityCheck(); XCTAssertTrue(integrity)
    }
    func testRehashedMigrationCannotRemoveResolutionOrChangeItsBaseline() async throws {
        for missing in [false, true] {
            let (store, port, link, _) = try await fixture(); _ = try await accept(store, port, link)
            let package = base.appendingPathComponent(UUID().uuidString)
            try await store.exportPackage(to: package, includeMedia: true)
            let file = package.appendingPathComponent("reminder_status_resolutions.jsonl")
            var rows = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
            if missing { rows = [] } else { rows[0]["base_action_version"] = 2 }
            var data = Data()
            for row in rows { data.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])); data.append(10) }
            try data.write(to: file)
            let manifestFile = package.appendingPathComponent("manifest.json")
            var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestFile)) as! [String: Any]
            var files = manifest["files"] as! [[String: Any]]
            let i = try XCTUnwrap(files.firstIndex { $0["path"] as? String == file.lastPathComponent })
            files[i]["bytes"] = data.count; files[i]["sha256"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            manifest["files"] = files
            var counts = manifest["counts"] as! [String: Int]; counts["reminder_status_resolutions"] = rows.count; manifest["counts"] = counts
            try JSONSerialization.data(withJSONObject: manifest).write(to: manifestFile)
            let target = base.appendingPathComponent(UUID().uuidString)
            do { try await VoiceOSStore.restorePackage(from: package, to: target, inspector: ResolutionInspector()); XCTFail("forged resolution") }
            catch { XCTAssertTrue(error.localizedDescription.contains("状态恢复")) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        }
    }
    func testSchema31UpgradeAddsEmptyResolutionHistoryWithoutChangingExistingRows() async throws {
        let (store, _, _, _) = try await fixture()
        let file = await store.root.appendingPathComponent("voiceos.sqlite")
        let original = try Database(file)
        let tableNames = try original.query("SELECT name FROM sqlite_master WHERE type='table' AND name NOT IN ('reminder_status_resolutions','reminder_time_observations')").compactMap { $0["name"] }
        let before = try Dictionary(uniqueKeysWithValues: tableNames.map { ($0, try original.query("SELECT * FROM \($0) ORDER BY id")) })
        try original.execute("DROP TABLE reminder_time_observations"); try original.execute("DROP TABLE reminder_status_resolutions"); try original.execute("PRAGMA user_version=31")
        let upgraded = try Database(file)
        XCTAssertEqual(try upgraded.query("PRAGMA user_version").first?["user_version"], "33")
        XCTAssertTrue(try upgraded.query("SELECT * FROM reminder_status_resolutions").isEmpty)
        for table in tableNames { XCTAssertEqual(try upgraded.query("SELECT * FROM \(table) ORDER BY id"), before[table]) }
    }
    func testResolutionCommitFailureHasNoPartialStateAndCommittedReceiptReplays() async throws {
        for committed in [false, true] {
            let (store, port, link, _) = try await fixture { point in
                if point == (committed ? .reminderResolutionCommitted : .reminderResolutionUncommitted) { throw VoiceOSError("injected commit window") }
            }
            do { _ = try await accept(store, port, link); XCTFail("injected failure") } catch {}
            let action = try await store.actions(includeHistory: true)[0]
            XCTAssertEqual(action.version, committed ? 3 : 2)
            XCTAssertEqual(action.state, committed ? "open" : "completed")
            let currentLink = try await store.reminderLinks()[0]; XCTAssertEqual(currentLink.state, committed ? "linked" : "conflict")
            let root = await store.root
            let db = try Database(root.appendingPathComponent("voiceos.sqlite"))
            XCTAssertEqual(try db.query("SELECT id FROM reminder_status_resolutions").count, committed ? 1 : 0)
            XCTAssertEqual(try db.query("SELECT id FROM action_revisions").count, committed ? 2 : 1)
            if committed { let replay = try await accept(store, port, link); XCTAssertEqual(replay, 3) }
        }
    }
    func testOrdinaryStateCommandCannotPretendToBeReminderResolution() async throws {
        let (store, _, link, _) = try await fixture()
        do {
            _ = try await store.setActionState(actionID: link.actionID, expectedVersion: 2, state: .open,
                                              commandID: "reminder-status-resolution:" + UUID().uuidString)
            XCTFail("reserved command namespace")
        } catch {}
        let action = try await store.actions(includeHistory: true)[0]; XCTAssertEqual(action.version, 2)
    }
    func testDueChangesPreserveStatusAndUnknownVersusNoneAcrossMigration() async throws {
        let (store, port, link, _) = try await fixture()
        let due = ReminderDueDate.dateOnly(localDate: "2026-10-13", timeZone: "Pacific/Kiritimati")
        await port.editDue(due)
        try await store.readReminder(linkID: link.id, calendarID: link.calendarID, using: port, expectedAccessVersion: 1)
        let dated = try await store.reminderLinks()[0]
        XCTAssertEqual(dated.remoteDueDate, due)
        XCTAssertNotEqual(dated.lastObservationID, link.lastObservationID)
        try await store.readReminder(linkID: link.id, calendarID: link.calendarID, using: port, expectedAccessVersion: 1)
        let repeated = try await store.reminderLinks()[0]
        XCTAssertEqual(repeated.lastObservationID, dated.lastObservationID)
        await port.editDue(nil)
        try await store.readReminder(linkID: link.id, calendarID: link.calendarID, using: port, expectedAccessVersion: 1)
        let unknown = try await store.reminderLinks()[0]
        XCTAssertNil(unknown.remoteDueDate)
        XCTAssertNotEqual(unknown.lastObservationID, dated.lastObservationID)
        await port.editDue(.some(.none))
        try await store.readReminder(linkID: link.id, calendarID: link.calendarID, using: port, expectedAccessVersion: 1)
        let none = try await store.reminderLinks()[0]
        XCTAssertEqual(none.remoteDueDate, .some(.none))
        let action = try await store.actions(includeHistory: true)[0]
        XCTAssertEqual(action.version, 2); XCTAssertEqual(action.state, "completed")
        let package = base.appendingPathComponent("time-package")
        try await store.exportPackage(to: package, includeMedia: true)
        XCTAssertEqual(try VoiceOSStore.packageSummary(at: package).version, 33)
        let restoredRoot = base.appendingPathComponent("time-restored")
        try await VoiceOSStore.restorePackage(from: package, to: restoredRoot, inspector: ResolutionInspector())
        let restored = try VoiceOSStore(root: restoredRoot, inspector: ResolutionInspector()); try await restored.recover()
        let restoredLink = try await restored.reminderLinks()[0]
        XCTAssertEqual(restoredLink.remoteDueDate, .some(.none))
        let db = try Database(restoredRoot.appendingPathComponent("voiceos.sqlite"))
        let dates = try db.query("SELECT * FROM reminder_time_observations")
        XCTAssertEqual(dates.count, 2)
        XCTAssertTrue(dates.contains { $0["due_json"]?.contains("2026-10-13") == true })
        let access = try await restored.reminderAccess(); XCTAssertNil(access)
        let creates = await port.creates; XCTAssertEqual(creates, 1)
    }
    func testDueDriftDuringResolutionCannotAdoptPreviouslyDisplayedObservation() async throws {
        let (store, port, link, _) = try await fixture()
        await port.editDue(.dateOnly(localDate: "2026-10-15", timeZone: nil))
        do { _ = try await accept(store, port, link); XCTFail("date drift reused old observation") } catch {}
        let updated = try await store.reminderLinks()[0]
        XCTAssertNotEqual(updated.lastObservationID, link.lastObservationID)
        let action = try await store.actions(includeHistory: true)[0]
        XCTAssertEqual(action.version, 2); XCTAssertEqual(action.state, "completed")
        let claims = try await store.candidateClaims(); XCTAssertEqual(claims[0].evidenceState, "unverified")
    }
}
