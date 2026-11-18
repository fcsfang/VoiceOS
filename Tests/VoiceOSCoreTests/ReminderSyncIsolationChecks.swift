import XCTest
@testable import VoiceOSCore
import VoiceOSPlatform

private actor IsolationReminders: RemindersPort, RecordingExpressionRemindersPort {
    var items: [ReminderSnapshot] = []
    var failedCreateTitles: Set<String> = []
    var createdTitles: [String] = []
    var expressionEdits = 0
    func failCreation(of title: String) { failedCreateTitles.insert(title) }
    func addItem(id: String, title: String, marker: String) {
        items.append(.init(id: id, title: title, completed: false, marker: marker))
    }
    func complete() { items = items.map { .init(id: $0.id, title: $0.title, completed: true, marker: $0.marker) } }
    func find(calendarID: String, externalID: String?, marker: String) async throws -> [ReminderSnapshot] {
        items.filter { $0.marker == marker || $0.id == externalID }
    }
    func create(calendarID: String, title: String, marker: String, context: String) async throws {
        createdTitles.append(title)
        if failedCreateTitles.contains(title) { throw VoiceOSError("合成发送失败") }
        items.append(.init(id: UUID().uuidString, title: title, completed: false, marker: marker))
    }
    func reconcileExpression(_ edit: RecordingExpressionReminderEdit, authorize: @Sendable () async throws -> Void) async throws -> ReminderSnapshot {
        expressionEdits += 1
        guard let index = items.firstIndex(where: { $0.id == edit.externalID && $0.marker == edit.marker }) else { throw VoiceOSError("提醒身份不符") }
        try await authorize()
        items[index] = .init(id: edit.externalID, title: edit.desiredTitle, completed: false, marker: edit.marker)
        return items[index]
    }
}

final class ReminderSyncIsolationChecks: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-reminder-isolation-" + UUID().uuidString)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func openStore() async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }

    private func makeTask(_ store: VoiceOSStore, title: String, commandID: String) async throws -> ActionRecord {
        let text = "我打算\(title)。"
        let sourceID = try await store.recordUserExpression(text)
        _ = try await store.setSourceLocalOnly(sourceID: sourceID, expectedVersion: 1, localOnly: false)
        let context = try await store.prepareLocalTranscriptContext(sourceIDs: [sourceID])
        let references = context.sources.map {
            ClaimReference(sourceID: $0.sourceID, transcriptVersionID: $0.transcriptVersionID, spanID: $0.spans[0].id)
        }
        _ = try await store.importOrganizedClaims(context: context, proposals: [
            .init(statement: text, ownership: .userTentative, references: references,
                  action: .init(title: title, kind: .task, quote: text))
        ], commandID: commandID)
        let actions = try await store.actions()
        return try XCTUnwrap(actions.first { $0.title == title })
    }

    @discardableResult
    private func insertLink(_ store: VoiceOSStore, action: ActionRecord, state: String, calendarID: String, externalID: String? = nil) async throws -> String {
        let id = UUID().uuidString
        let database = await store.db
        try database.execute("INSERT INTO reminder_links(id,action_id,action_version,calendar_id,marker,desired_title,state,external_id,created_at) VALUES(?,?,?,?,?,?,?,?,?)",
                             [id, action.id, String(action.version), calendarID, "voiceos-action:" + id, action.title, state, externalID, "2026-01-01T00:00:00Z"])
        return id
    }

    private func completeExpression(_ store: VoiceOSStore, sourceID: String, updates: [String]) async throws {
        let sources = try await store.sources()
        let source = try XCTUnwrap(sources.first { $0.id == sourceID })
        var presentation = source.presentation ?? RecordingPresentation()
        presentation.expression = RecordingExpression(
            id: UUID().uuidString, sourceIDs: [sourceID], title: "合成补录", summary: "", reason: "合成",
            responseIDs: ["isolation-a", "isolation-b"],
            versions: [sourceID: try XCTUnwrap(source.transcriptVersionID)], policies: [sourceID: source.policyVersion],
            state: "completed", previousActionIDs: [], reminderUpdates: updates, taskReviewPending: false)
        try await store.saveExpressionPresentation(presentation, sourceID: sourceID)
    }

    private func makeExpressionFixture(_ store: VoiceOSStore, reminders: IsolationReminders) async throws -> (bad: ActionRecord, good: ActionRecord, badLinkID: String, goodLinkID: String) {
        let access = try await store.setReminderAccess(calendarID: "fixture", title: "VoiceOS", enabled: true, expectedVersion: 0)
        let bad = try await makeTask(store, title: "补录坏项", commandID: "isolation-bad")
        let good = try await makeTask(store, title: "补录好项", commandID: "isolation-good")
        let badLinkID = try await insertLink(store, action: bad, state: "unknown", calendarID: access.calendarID)
        let goodLinkID = try await insertLink(store, action: good, state: "unknown", calendarID: access.calendarID, externalID: "external-good")
        await reminders.addItem(id: "external-good", title: good.title, marker: "voiceos-action:" + goodLinkID)
        let sourceID = try await store.recordUserExpression("我打算先补录坏项，再补录好项。")
        _ = try await store.setSourceLocalOnly(sourceID: sourceID, expectedVersion: 1, localOnly: false)
        try await completeExpression(store, sourceID: sourceID, updates: [bad.id, good.id])
        return (bad, good, badLinkID, goodLinkID)
    }

    func testBadExpressionUpdateDoesNotBlockLaterUpdates() async throws {
        let store = try await openStore(), reminders = IsolationReminders()
        let fixture = try await makeExpressionFixture(store, reminders: reminders)
        do {
            try await store.syncRecordingExpressionReminders(using: reminders)
            XCTFail("坏项必须留下可重试的失败汇总")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("补录"), "失败汇总应说明补录未完成")
        }
        let expressions = try await store.recordingExpressions()
        let expression = try XCTUnwrap(expressions.first)
        XCTAssertFalse(expression.reminderUpdates?.contains(fixture.good.id) == true, "坏项之后的成功项应照旧移除")
        XCTAssertTrue(expression.reminderUpdates?.contains(fixture.bad.id) == true, "失败项应保留为可重试")
        let summary = try await store.reminderSyncAnomalies()
        XCTAssertEqual(summary.failures.map(\.actionID), [fixture.bad.id], "失败原因只该落在坏项上")
        let failure = try XCTUnwrap(summary.failures.first)
        XCTAssertEqual(failure.stage, .expression)
        XCTAssertTrue(failure.reason.contains("外部标识"), "原因应说明缺少外部标识")
        XCTAssertFalse(failure.failedAt.isEmpty, "失败时间应可见")
        let edits = await reminders.expressionEdits
        XCTAssertEqual(edits, 1, "好项应完成一次补录")
    }

    func testExpressionFailurePersistsAndClearsAfterSuccess() async throws {
        var badID = "", badLinkID = ""
        do {
            let store = try await openStore(), reminders = IsolationReminders()
            let fixture = try await makeExpressionFixture(store, reminders: reminders)
            badID = fixture.bad.id; badLinkID = fixture.badLinkID
            do { try await store.syncRecordingExpressionReminders(using: reminders) } catch {}
        }
        let store = try await openStore(), reminders = IsolationReminders()
        let persisted = try await store.reminderSyncAnomalies()
        XCTAssertEqual(persisted.failures.first?.actionID, badID, "失败原因应已落盘")
        XCTAssertFalse(persisted.failures.first?.reason.isEmpty ?? true, "落盘原因不应为空")
        let database = await store.db
        let marker = try XCTUnwrap(database.query("SELECT marker FROM reminder_links WHERE id=?", [badLinkID]).first?["marker"])
        await reminders.addItem(id: "external-bad", title: "补录坏项", marker: marker)
        try database.execute("UPDATE reminder_links SET external_id='external-bad' WHERE id=?", [badLinkID])
        try await store.syncRecordingExpressionReminders(using: reminders)
        let cleared = try await store.reminderSyncAnomalies()
        XCTAssertTrue(cleared.failures.isEmpty, "成功后失败原因应清除")
        let expressions = try await store.recordingExpressions()
        let expression = try XCTUnwrap(expressions.first)
        XCTAssertFalse(expression.reminderUpdates?.contains(badID) == true, "成功项应移出待补录")
        let edits = await reminders.expressionEdits
        try await store.syncRecordingExpressionReminders(using: reminders)
        let repeated = await reminders.expressionEdits
        XCTAssertEqual(repeated, edits, "已完成的补录不应重复处理")
    }

    func testActivationFailureContinuesAndReadbackStillRuns() async throws {
        let store = try await openStore(), reminders = IsolationReminders()
        let access = try await store.setReminderAccess(calendarID: "fixture", title: "VoiceOS", enabled: true, expectedVersion: 0)
        let done = try await makeTask(store, title: "回读完成任务", commandID: "isolation-done")
        try await store.sendTaskToReminders(actionID: done.id, expectedVersion: done.version, calendarID: access.calendarID, using: reminders, expectedAccessVersion: access.version)
        await reminders.complete()
        let bad = try await makeTask(store, title: "发送坏项", commandID: "isolation-bad-send")
        let good = try await makeTask(store, title: "发送好项", commandID: "isolation-good-send")
        let database = await store.db
        try database.execute("UPDATE actions SET created_at='2026-01-01T00:00:02Z' WHERE id=?", [bad.id])
        try database.execute("UPDATE actions SET created_at='2026-01-01T00:00:03Z' WHERE id=?", [good.id])
        await reminders.failCreation(of: bad.title)
        do {
            try await store.refreshAuthorizedReminders(expectedAccessVersion: access.version, using: reminders)
            XCTFail("发送失败必须留下可重试的失败汇总")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("新任务发送未完成"), "汇总应说明新任务发送未完成")
        }
        let created = await reminders.createdTitles
        XCTAssertTrue(created.contains(good.title), "坏项之后的发送不能停摆")
        let links = try await store.reminderLinks()
        XCTAssertTrue(links.contains { $0.actionID == good.id && $0.state == "linked" && $0.externalID != nil })
        let doneAfter = try await store.actions(includeHistory: true).first { $0.id == done.id }
        XCTAssertEqual(doneAfter?.state, "completed", "既有回读必须照常执行")
        let failures = try await store.reminderSyncAnomalies().failures
        let failure = try XCTUnwrap(failures.first { $0.actionID == bad.id })
        XCTAssertEqual(failure.stage, .activation)
        XCTAssertTrue(failure.reason.contains("提醒事项结果尚未确认"), "原因应说明结果未确认")
    }
}
