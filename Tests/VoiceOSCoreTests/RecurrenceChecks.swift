import XCTest
import Foundation
@testable import VoiceOSCore
import VoiceOSPlatform

private actor RecurrenceReminders: RemindersPort {
    let snapshot: ReminderSnapshot
    init(_ snapshot: ReminderSnapshot) { self.snapshot = snapshot }
    func find(calendarID: String, externalID: String?, marker: String) async throws -> [ReminderSnapshot] {
        snapshot.marker == marker || snapshot.id == externalID ? [snapshot] : []
    }
    func create(calendarID: String, title: String, marker: String, context: String) async throws {}
}

final class RecurrenceChecks: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-recurrence-" + UUID().uuidString) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func openStore() async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }

    private func calendar(_ zone: String) -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: zone)!
        return value
    }

    private func date(_ calendar: Calendar, _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func insertSource(_ store: VoiceOSStore, text: String) async throws -> (sourceID: String, versionID: String, spanID: String) {
        let db = await store.db
        let id = UUID().uuidString, assetID = UUID().uuidString, jobID = UUID().uuidString, transcriptID = UUID().uuidString, versionID = UUID().uuidString
        try db.execute("""
        INSERT INTO sources(id,command_id,input_fingerprint,asset_id,version_id,name,kind,speaker,origin,state,created_at,timezone,expected_bytes,expected_hash,relative_path)
        VALUES(?,?,?,?,?,?, 'external_text','unknown','external','reference_only',?,?, '0','0',?)
        """, [id, "source:" + id, "fixture:" + id, assetID, "version:" + id, "合成资料", "2026-11-01T00:00:00Z", TimeZone.current.identifier, "assets/" + id])
        try db.execute("INSERT INTO assets(id,source_id,relative_path,bytes,sha256,role) VALUES(?,?,?,?,'0','original')", [assetID, id, "assets/" + id, "0"])
        try db.execute("INSERT INTO jobs(id,source_id,input_version_id,stage,config,state) VALUES(?,?,?,'transcription','fixture','completed')", [jobID, id, "version:" + id])
        try db.execute("INSERT INTO transcripts(id,source_id,input_asset_id,input_version_id,job_id,kind,text,locale,backend,created_at) VALUES(?,?,?,?,?,'verbatim',?,'zh_CN','fixture',?)", [transcriptID, id, assetID, "version:" + id, jobID, text, "2026-11-01T00:00:00Z"])
        let speech = SpeechText(text: text)
        try db.execute("INSERT INTO transcript_versions(id,transcript_id,version_no,text,spans_json,reason,actor,created_at) VALUES(?,?,1,?,?, 'original','system',?)", [versionID, transcriptID, text, String(decoding: try JSONEncoder().encode(speech.spans), as: UTF8.self), "2026-11-01T00:00:00Z"])
        try db.execute("UPDATE transcripts SET current_version_id=? WHERE id=?", [versionID, transcriptID])
        return (id, versionID, speech.spans[0].id)
    }

    private func makeTask(_ store: VoiceOSStore, text: String = "我要每周复盘", due: ReminderDueDate, alerts: [String] = [], note: String = "") async throws -> String {
        let source = try await insertSource(store, text: text)
        let context = try await store.prepareLocalTranscriptContext(sourceIDs: [source.sourceID], scalarBudget: Int.max)
        let contextID = try await store.persistLocalContext(context, commandID: UUID().uuidString)
        let attemptID = try await store.reserveLocalModelAttempt(contextID: contextID, model: "fixture", promptVersion: "v1", schemaVersion: "v1")
        let proposal = ClaimProposal(statement: text, ownership: .external, references: [ClaimReference(sourceID: source.sourceID, transcriptVersionID: source.versionID, spanID: source.spanID)], contentKind: .statement)
        let claims = try await store.commitLocalClaims(attemptID: attemptID, proposals: [proposal])
        let actionID = try await store.createAction(claimID: claims[0], expectedClaimReviewVersion: 0, title: "每周复盘", kind: .task, note: note)
        try await store.saveReminderFields(actionID: actionID, expectedVersion: 1, fields: ReminderFields(due: due, alerts: alerts))
        return actionID
    }

    func testMigrationAddsRecurrenceAndEntityTables() async throws {
        let store = try await openStore()
        let db = await store.db
        XCTAssertEqual(try db.query("PRAGMA user_version").first?["user_version"], "61")
        for table in ["action_recurrence", "source_entities"] {
            XCTAssertEqual(try db.query("SELECT name FROM sqlite_master WHERE type='table' AND name=?", [table]).count, 1)
        }
        XCTAssertEqual(try db.query("SELECT name FROM sqlite_master WHERE type='index' AND name='action_recurrence_series'").count, 1)
    }

    func testPeriodsAdvanceFromLocalDate() {
        let zone = calendar("Asia/Shanghai")
        XCTAssertEqual(RecurrencePeriod.nextLocalDate(after: "2026-11-15", period: .daily, calendar: zone), "2026-11-16")
        XCTAssertEqual(RecurrencePeriod.nextLocalDate(after: "2026-11-15", period: .weekly, calendar: zone), "2026-11-22")
        XCTAssertEqual(RecurrencePeriod.nextLocalDate(after: "2026-11-15", period: .biweekly, calendar: zone), "2026-11-29")
        XCTAssertEqual(RecurrencePeriod.nextDue(after: date(zone, 2026, 11, 15, 10, 30), period: .weekly, calendar: zone), date(zone, 2026, 11, 22, 10, 30))
    }

    func testMonthlyClampsMonthEnd() {
        let zone = calendar("Asia/Shanghai")
        XCTAssertEqual(RecurrencePeriod.nextLocalDate(after: "2026-01-31", period: .monthly, calendar: zone), "2026-02-28")
        XCTAssertEqual(RecurrencePeriod.nextLocalDate(after: "2024-01-31", period: .monthly, calendar: zone), "2024-02-29")
        XCTAssertEqual(RecurrencePeriod.nextLocalDate(after: "2026-12-31", period: .monthly, calendar: zone), "2027-01-31")
    }

    func testMonthlyLeapDayFallsBackToFebruary28() {
        let zone = calendar("Asia/Shanghai")
        var value = "2024-02-29"
        for _ in 0..<12 { value = RecurrencePeriod.nextLocalDate(after: value, period: .monthly, calendar: zone) }
        XCTAssertEqual(value, "2025-02-28")
    }

    func testSetRecurrenceRequiresOpenActionAndKeepsOneRow() async throws {
        let store = try await openStore()
        let db = await store.db
        let action = try await makeTask(store, due: .dateOnly(localDate: "2026-11-01", timeZone: "Asia/Shanghai"))
        try await store.setRecurrence(actionID: action, period: .weekly)
        let weekly = try await store.recurrence(actionID: action)
        XCTAssertEqual(weekly, .weekly)
        try await store.setRecurrence(actionID: action, period: .daily)
        let daily = try await store.recurrence(actionID: action)
        XCTAssertEqual(daily, .daily)
        let all = try await store.actionRecurrences()
        XCTAssertEqual(all, [action: .daily])
        XCTAssertEqual(try db.query("SELECT count(*) AS n FROM action_recurrence").first?["n"], "1")
        do {
            try await store.setRecurrence(actionID: UUID().uuidString, period: .weekly)
            XCTFail("行动不存在时不能设置重复")
        } catch {
            XCTAssertEqual((error as? VoiceOSError)?.message, "行动不存在")
        }
    }

    func testCompleteCreatesOneSuccessorAndMovesSeries() async throws {
        let store = try await openStore()
        let db = await store.db
        let zone = calendar("Asia/Shanghai")
        let action = try await makeTask(store, due: .dateOnly(localDate: "2026-11-01", timeZone: "Asia/Shanghai"))
        try await store.setRecurrence(actionID: action, period: .weekly)
        let seriesID = try XCTUnwrap(try db.query("SELECT series_id FROM action_recurrence WHERE action_id=?", [action]).first?["series_id"])
        let successor = try await store.completeActionWithRecurrence(id: action, now: date(zone, 2026, 11, 2, 8, 0))
        let successorID = try XCTUnwrap(successor)
        let old = try XCTUnwrap(try db.query("SELECT * FROM actions WHERE id=?", [action]).first)
        XCTAssertEqual(old["state"], "completed")
        XCTAssertEqual(old["version"], "2")
        let row = try XCTUnwrap(try db.query("SELECT * FROM actions WHERE id=?", [successorID]).first)
        XCTAssertEqual(row["title"], "每周复盘")
        XCTAssertEqual(row["note"], "")
        XCTAssertEqual(row["claim_id"], old["claim_id"])
        XCTAssertEqual(row["claim_review_version"], "0")
        XCTAssertEqual(row["kind"], "task")
        XCTAssertEqual(row["intent_actor"], "user")
        XCTAssertEqual(row["state"], "open")
        XCTAssertEqual(row["validity"], "current")
        XCTAssertEqual(row["auto_send"], "0")
        XCTAssertEqual(row["version"], "1")
        XCTAssertEqual(row["command_id"], "recurrence:" + action + ":2026-11-08")
        let intent = try JSONDecoder().decode(ActionIntentMetadata.self, from: Data(try XCTUnwrap(row["intent_json"]).utf8))
        XCTAssertEqual(intent.reminderFields?.desired?.due, .dateOnly(localDate: "2026-11-08", timeZone: "Asia/Shanghai"))
        XCTAssertEqual(intent.reminderFields?.desired?.alerts, ["2026-11-08T01:00:00.000Z"])
        let moved = try await store.recurrence(actionID: successorID)
        XCTAssertEqual(moved, .weekly)
        let original = try await store.recurrence(actionID: action)
        XCTAssertNil(original)
        XCTAssertEqual(try db.query("SELECT series_id FROM action_recurrence WHERE action_id=?", [successorID]).first?["series_id"], seriesID)
        XCTAssertFalse(try db.query("SELECT id FROM action_revisions WHERE action_id=? AND command_id=?", [action, "recurrence-complete:" + action + ":1"]).isEmpty)
        let repeated = try await store.completeActionWithRecurrence(id: action, now: date(zone, 2026, 11, 9, 8, 0))
        XCTAssertNil(repeated)
        XCTAssertEqual(try db.query("SELECT count(*) AS n FROM actions").first?["n"], "2")
        XCTAssertEqual(try db.query("SELECT count(*) AS n FROM action_recurrence").first?["n"], "1")
    }

    func testInstantRecurrenceShiftsExistingAlerts() async throws {
        let store = try await openStore()
        let db = await store.db
        let zone = calendar("Asia/Shanghai")
        let action = try await makeTask(store, due: .instant(utc: "2026-11-01T02:00:00.000Z", timeZone: "Asia/Shanghai"), alerts: ["2026-11-01T01:00:00.000Z"])
        try await store.setRecurrence(actionID: action, period: .weekly)
        let successor = try await store.completeActionWithRecurrence(id: action, now: date(zone, 2026, 11, 2))
        let successorID = try XCTUnwrap(successor)
        let row = try XCTUnwrap(try db.query("SELECT * FROM actions WHERE id=?", [successorID]).first)
        let intent = try JSONDecoder().decode(ActionIntentMetadata.self, from: Data(try XCTUnwrap(row["intent_json"]).utf8))
        XCTAssertEqual(intent.reminderFields?.desired?.due, .instant(utc: "2026-11-08T02:00:00.000Z", timeZone: "Asia/Shanghai"))
        XCTAssertEqual(intent.reminderFields?.desired?.alerts, ["2026-11-08T01:00:00.000Z"])
        XCTAssertEqual(row["command_id"], "recurrence:" + action + ":2026-11-08T02:00:00.000Z")
    }

    func testNoDueCompletesWithoutSuccessor() async throws {
        let store = try await openStore()
        let db = await store.db
        let action = try await makeTask(store, due: .none)
        try await store.setRecurrence(actionID: action, period: .daily)
        let successor = try await store.completeActionWithRecurrence(id: action, now: date(calendar("Asia/Shanghai"), 2026, 11, 2))
        XCTAssertNil(successor)
        XCTAssertEqual(try db.query("SELECT state FROM actions WHERE id=?", [action]).first?["state"], "completed")
        XCTAssertEqual(try db.query("SELECT count(*) AS n FROM actions").first?["n"], "1")
        XCTAssertEqual(try db.query("SELECT count(*) AS n FROM action_recurrence").first?["n"], "0")
        do {
            try await store.setRecurrence(actionID: action, period: .weekly)
            XCTFail("已完成行动不能设置重复")
        } catch {
            XCTAssertEqual((error as? VoiceOSError)?.message, "只有未完成的行动可以设置重复")
        }
    }

    func testClearedRecurrenceCompletesWithoutSuccessor() async throws {
        let store = try await openStore()
        let db = await store.db
        let action = try await makeTask(store, due: .dateOnly(localDate: "2026-11-01", timeZone: "Asia/Shanghai"))
        try await store.setRecurrence(actionID: action, period: .weekly)
        try await store.clearRecurrence(actionID: action)
        let cleared = try await store.recurrence(actionID: action)
        XCTAssertNil(cleared)
        let successor = try await store.completeActionWithRecurrence(id: action, now: date(calendar("Asia/Shanghai"), 2026, 11, 2))
        XCTAssertNil(successor)
        let row = try XCTUnwrap(try db.query("SELECT state,version FROM actions WHERE id=?", [action]).first)
        XCTAssertEqual(row["state"], "completed")
        XCTAssertEqual(row["version"], "2")
        XCTAssertEqual(try db.query("SELECT count(*) AS n FROM actions").first?["n"], "1")
        XCTAssertEqual(try db.query("SELECT count(*) AS n FROM action_recurrence").first?["n"], "0")
        XCTAssertFalse(try db.query("SELECT id FROM action_revisions WHERE action_id=? AND command_id=?", [action, "recurrence-complete:" + action + ":1"]).isEmpty)
    }

    func testExternalCompletionEquivalentCreatesOneSuccessor() async throws {
        let store = try await openStore()
        let db = await store.db
        let zone = calendar("Asia/Shanghai")
        let action = try await makeTask(store, due: .dateOnly(localDate: "2026-11-01", timeZone: "Asia/Shanghai"))
        try await store.setRecurrence(actionID: action, period: .weekly)
        _ = try await store.setActionState(actionID: action, expectedVersion: 1, state: .completed)
        let successorRaw = try await store.completeActionWithRecurrence(id: action, now: date(zone, 2026, 11, 2, 8, 0))
        let successor = try XCTUnwrap(successorRaw)
        let old = try XCTUnwrap(try db.query("SELECT state,version FROM actions WHERE id=?", [action]).first)
        XCTAssertEqual(old["state"], "completed")
        XCTAssertEqual(old["version"], "2")
        let row = try XCTUnwrap(try db.query("SELECT state,validity,title FROM actions WHERE id=?", [successor]).first)
        XCTAssertEqual(row["state"], "open")
        XCTAssertEqual(row["validity"], "current")
        XCTAssertEqual(row["title"], "每周复盘")
        let successorPeriod = try await store.recurrence(actionID: successor)
        XCTAssertEqual(successorPeriod, .weekly)
        let repeated = try await store.completeActionWithRecurrence(id: action, now: date(zone, 2026, 11, 9, 8, 0))
        XCTAssertNil(repeated)
        XCTAssertEqual(try db.query("SELECT count(*) AS n FROM actions").first?["n"], "2")
        XCTAssertEqual(try db.query("SELECT count(*) AS n FROM action_recurrence").first?["n"], "1")
    }

    func testReopenDeletesUntouchedSuccessorAndRestoresSeries() async throws {
        let store = try await openStore()
        let db = await store.db
        let zone = calendar("Asia/Shanghai")
        let action = try await makeTask(store, due: .dateOnly(localDate: "2026-11-01", timeZone: "Asia/Shanghai"))
        try await store.setRecurrence(actionID: action, period: .weekly)
        let seriesID = try XCTUnwrap(try db.query("SELECT series_id FROM action_recurrence WHERE action_id=?", [action]).first?["series_id"])
        let successorRaw = try await store.completeActionWithRecurrence(id: action, now: date(zone, 2026, 11, 2, 8, 0))
        let successor = try XCTUnwrap(successorRaw)
        let kept = try await store.reopenActionWithRecurrence(id: action, successorID: successor)
        XCTAssertNil(kept)
        let reopened = try XCTUnwrap(try db.query("SELECT state,version FROM actions WHERE id=?", [action]).first)
        XCTAssertEqual(reopened["state"], "open")
        XCTAssertEqual(reopened["version"], "3")
        XCTAssertEqual(try db.query("SELECT id FROM actions WHERE id=?", [successor]).count, 0)
        let successorRecurrence = try await store.recurrence(actionID: successor)
        let actionRecurrence = try await store.recurrence(actionID: action)
        XCTAssertNil(successorRecurrence)
        XCTAssertEqual(actionRecurrence, .weekly)
        XCTAssertEqual(try db.query("SELECT series_id FROM action_recurrence WHERE action_id=?", [action]).first?["series_id"], seriesID)
        XCTAssertEqual(try db.query("SELECT count(*) AS n FROM action_recurrence").first?["n"], "1")
    }

    func testReopenFindsSuccessorByCommandPrefix() async throws {
        let store = try await openStore()
        let db = await store.db
        let zone = calendar("Asia/Shanghai")
        let action = try await makeTask(store, due: .dateOnly(localDate: "2026-11-01", timeZone: "Asia/Shanghai"))
        try await store.setRecurrence(actionID: action, period: .weekly)
        let successorRaw = try await store.completeActionWithRecurrence(id: action, now: date(zone, 2026, 11, 2, 8, 0))
        let successor = try XCTUnwrap(successorRaw)
        let kept = try await store.reopenActionWithRecurrence(id: action)
        XCTAssertNil(kept)
        XCTAssertEqual(try db.query("SELECT id FROM actions WHERE id=?", [successor]).count, 0)
        let restored = try await store.recurrence(actionID: action)
        XCTAssertEqual(restored, .weekly)
    }

    func testReopenKeepsModifiedSuccessor() async throws {
        let store = try await openStore()
        let db = await store.db
        let zone = calendar("Asia/Shanghai")
        let action = try await makeTask(store, due: .dateOnly(localDate: "2026-11-01", timeZone: "Asia/Shanghai"))
        try await store.setRecurrence(actionID: action, period: .weekly)
        let successorRaw = try await store.completeActionWithRecurrence(id: action, now: date(zone, 2026, 11, 2, 8, 0))
        let successor = try XCTUnwrap(successorRaw)
        _ = try await store.setActionState(actionID: successor, expectedVersion: 1, state: .dismissed)
        let kept = try await store.reopenActionWithRecurrence(id: action, successorID: successor)
        XCTAssertEqual(kept, successor)
        XCTAssertEqual(try db.query("SELECT state FROM actions WHERE id=?", [successor]).first?["state"], "dismissed")
        let successorRecurrence = try await store.recurrence(actionID: successor)
        let actionRecurrence = try await store.recurrence(actionID: action)
        XCTAssertEqual(successorRecurrence, .weekly)
        XCTAssertNil(actionRecurrence)
        XCTAssertEqual(try db.query("SELECT state FROM actions WHERE id=?", [action]).first?["state"], "open")
    }

    func testCompleteReopenCompleteUsesVersionedCommandsAndOneSuccessor() async throws {
        let store = try await openStore()
        let db = await store.db
        let zone = calendar("Asia/Shanghai")
        let action = try await makeTask(store, due: .dateOnly(localDate: "2026-11-01", timeZone: "Asia/Shanghai"))
        try await store.setRecurrence(actionID: action, period: .weekly)
        let firstRaw = try await store.completeActionWithRecurrence(id: action, now: date(zone, 2026, 11, 2, 8, 0))
        let first = try XCTUnwrap(firstRaw)
        let reopened = try await store.reopenActionWithRecurrence(id: action, successorID: first)
        XCTAssertNil(reopened)
        XCTAssertEqual(try db.query("SELECT version FROM actions WHERE id=?", [action]).first?["version"], "3")
        let secondRaw = try await store.completeActionWithRecurrence(id: action, now: date(zone, 2026, 11, 2, 8, 0))
        let second = try XCTUnwrap(secondRaw)
        XCTAssertNotEqual(first, second)
        let commands = try db.query("SELECT command_id FROM action_revisions WHERE action_id=? AND command_id LIKE 'recurrence-complete:%' ORDER BY version", [action]).compactMap { $0["command_id"] }
        XCTAssertEqual(commands, ["recurrence-complete:" + action + ":1", "recurrence-complete:" + action + ":3"])
        XCTAssertEqual(try db.query("SELECT count(*) AS n FROM actions").first?["n"], "2")
        XCTAssertEqual(try db.query("SELECT count(*) AS n FROM action_recurrence").first?["n"], "1")
        let moved = try await store.recurrence(actionID: second)
        XCTAssertEqual(moved, .weekly)
        let row = try XCTUnwrap(try db.query("SELECT state,validity FROM actions WHERE id=?", [second]).first)
        XCTAssertEqual(row["state"], "open")
        XCTAssertEqual(row["validity"], "current")
    }

    func testReopenDeletesUntouchedSuccessorWithPredecessorNote() async throws {
        let store = try await openStore()
        let db = await store.db
        let zone = calendar("Asia/Shanghai")
        let action = try await makeTask(store, due: .dateOnly(localDate: "2026-11-01", timeZone: "Asia/Shanghai"), note: "原话：每周复盘")
        try await store.setRecurrence(actionID: action, period: .weekly)
        let successorRaw = try await store.completeActionWithRecurrence(id: action, now: date(zone, 2026, 11, 2, 8, 0))
        let successor = try XCTUnwrap(successorRaw)
        XCTAssertEqual(try db.query("SELECT note FROM actions WHERE id=?", [successor]).first?["note"], "原话：每周复盘")
        let kept = try await store.reopenActionWithRecurrence(id: action, successorID: successor)
        XCTAssertNil(kept)
        XCTAssertEqual(try db.query("SELECT id FROM actions WHERE id=?", [successor]).count, 0)
        let moved = try await store.recurrence(actionID: action)
        XCTAssertEqual(moved, .weekly)
    }

    func testFrozenSourceCreatesFrozenSuccessorWithoutAutoSend() async throws {
        let store = try await openStore()
        let db = await store.db
        let zone = calendar("Asia/Shanghai")
        let action = try await makeTask(store, due: .dateOnly(localDate: "2026-11-01", timeZone: "Asia/Shanghai"))
        try await store.setRecurrence(actionID: action, period: .weekly)
        try db.execute("UPDATE actions SET auto_send=1 WHERE id=?", [action])
        _ = try await store.setActionState(actionID: action, expectedVersion: 1, state: .completed)
        try db.execute("UPDATE actions SET validity='frozen' WHERE id=?", [action])
        let successorRaw = try await store.completeActionWithRecurrence(id: action, now: date(zone, 2026, 11, 2, 8, 0))
        let successor = try XCTUnwrap(successorRaw)
        let row = try XCTUnwrap(try db.query("SELECT * FROM actions WHERE id=?", [successor]).first)
        XCTAssertEqual(row["state"], "open")
        XCTAssertEqual(row["validity"], "frozen")
        XCTAssertEqual(row["auto_send"], "0")
        XCTAssertEqual(row["command_id"], "recurrence:" + action + ":2026-11-08")
        let moved = try await store.recurrence(actionID: successor)
        XCTAssertEqual(moved, .weekly)
    }

    func testReminderReadbackRetriesDeferredSuccessorAndKeepsLink() async throws {
        let store = try await openStore()
        let db = await store.db
        let action = try await makeTask(store, due: .dateOnly(localDate: "2026-11-01", timeZone: "Asia/Shanghai"))
        try await store.setRecurrence(actionID: action, period: .weekly)
        _ = try await store.setActionState(actionID: action, expectedVersion: 1, state: .completed)
        let linkID = UUID().uuidString
        let marker = "voiceos-action:" + linkID
        try db.execute("INSERT INTO reminder_links(id,action_id,action_version,calendar_id,marker,desired_title,state,created_at) VALUES(?,?,2,?,?,?,'linked',?)", [linkID, action, "recurrence-calendar", marker, "每周复盘", "2026-11-01T00:00:00Z"])
        let snapshot = ReminderSnapshot(id: "remote-recurrence", title: "每周复盘", completed: true, marker: marker)
        let reminders = RecurrenceReminders(snapshot)
        try db.execute("CREATE TRIGGER block_recurrence_successor BEFORE INSERT ON actions WHEN NEW.command_id LIKE 'recurrence:%' BEGIN SELECT RAISE(ABORT,'blocked'); END")
        do {
            try await store.readReminder(linkID: linkID, calendarID: "recurrence-calendar", using: reminders)
            XCTFail("后继生成失败时回读应提示重试")
        } catch {
            XCTAssertEqual((error as? VoiceOSError)?.message, "外部完成已登记；下一次未生成，请重试")
        }
        XCTAssertEqual(try db.query("SELECT state FROM reminder_links WHERE id=?", [linkID]).first?["state"], "linked")
        XCTAssertEqual(try db.query("SELECT count(*) AS n FROM action_recurrence WHERE action_id=?", [action]).first?["n"], "1")
        XCTAssertEqual(try db.query("SELECT count(*) AS n FROM actions").first?["n"], "1")
        try db.execute("DROP TRIGGER block_recurrence_successor")
        try await store.readReminder(linkID: linkID, calendarID: "recurrence-calendar", using: reminders)
        let successor = try XCTUnwrap(try db.query("SELECT id FROM actions WHERE command_id LIKE ?", ["recurrence:" + action + ":%"]).first?["id"])
        let moved = try await store.recurrence(actionID: successor)
        XCTAssertEqual(moved, .weekly)
        XCTAssertEqual(try db.query("SELECT count(*) AS n FROM actions").first?["n"], "2")
        XCTAssertEqual(try db.query("SELECT count(*) AS n FROM action_recurrence").first?["n"], "1")
        try await store.readReminder(linkID: linkID, calendarID: "recurrence-calendar", using: reminders)
        XCTAssertEqual(try db.query("SELECT count(*) AS n FROM actions").first?["n"], "2")
    }

    func testRecurrenceSuccessorsBypassLinkedTitleBarrier() {
        XCTAssertTrue(VoiceOSStore.bypassesLinkedTitleBarrier(commandID: "recurrence:abc:2026-11-22"))
        XCTAssertFalse(VoiceOSStore.bypassesLinkedTitleBarrier(commandID: "extracted:abc"))
    }
}
