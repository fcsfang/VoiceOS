import Foundation
import XCTest
@testable import VoiceOSCore
import VoiceOSPlatform

private actor ExternalCompletionReminders: RemindersPort {
    var items: [ReminderSnapshot] = []
    func find(calendarID: String, externalID: String?, marker: String) async throws -> [ReminderSnapshot] {
        items.filter { $0.marker == marker || $0.id == externalID }
    }
    func create(calendarID: String, title: String, marker: String, context: String) async throws {
        items.append(.init(id: UUID().uuidString, title: title, completed: false, marker: marker))
    }
    func complete() {
        items = items.map { .init(id: $0.id, title: $0.title, completed: true, marker: $0.marker) }
    }
}

final class ExternalCompletionChecks: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-external-completion-" + UUID().uuidString)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func openStore() async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }

    private func makeTask(_ store: VoiceOSStore) async throws -> ActionRecord {
        let text = "我会查阅相关论文。"
        let sourceID = try await store.recordUserExpression(text)
        _ = try await store.setSourceLocalOnly(sourceID: sourceID, expectedVersion: 1, localOnly: false)
        let context = try await store.prepareLocalTranscriptContext(sourceIDs: [sourceID])
        let references = context.sources.map {
            ClaimReference(sourceID: $0.sourceID, transcriptVersionID: $0.transcriptVersionID, spanID: $0.spans[0].id)
        }
        _ = try await store.importOrganizedClaims(context: context, proposals: [
            .init(statement: text, ownership: .userTentative, references: references,
                  action: .init(title: "查阅相关论文", kind: .task, quote: text))
        ], commandID: "external-completion-task")
        let actions = try await store.actions()
        return try XCTUnwrap(actions.first)
    }

    private struct Fixture {
        let action: ActionRecord
        let link: ReminderLink
        let observationID: String
        let access: ReminderAccess
        let reminders: ExternalCompletionReminders
    }

    private func makeFixture(_ store: VoiceOSStore, complete: Bool = true) async throws -> Fixture {
        let action = try await makeTask(store)
        let reminders = ExternalCompletionReminders()
        let access = try await store.setReminderAccess(calendarID: "external-completion", title: "VoiceOS 验证", enabled: true, expectedVersion: 0)
        try await store.sendTaskToReminders(actionID: action.id, expectedVersion: action.version, calendarID: access.calendarID, using: reminders, expectedAccessVersion: access.version)
        let database = await store.db
        try database.execute("UPDATE actions SET validity='frozen' WHERE id=?", [action.id])
        if complete {
            await reminders.complete()
            let sent = try await store.reminderLinks()
            try await store.readReminder(linkID: try XCTUnwrap(sent.first).id, calendarID: access.calendarID, using: reminders, expectedAccessVersion: access.version)
        }
        let links = try await store.reminderLinks()
        let link = try XCTUnwrap(links.first)
        return Fixture(action: action, link: link, observationID: try XCTUnwrap(link.lastObservationID), access: access, reminders: reminders)
    }

    private func assertRefused(_ store: VoiceOSStore, fixture: Fixture, expectedVersion: Int? = nil,
                               observationID: String? = nil, validity: String = "frozen", state: String = "open") async throws {
        do {
            _ = try await store.confirmExternalCompletion(
                actionID: fixture.action.id, expectedVersion: expectedVersion ?? fixture.action.version,
                linkID: fixture.link.id, expectedObservationID: observationID ?? fixture.observationID,
                commandID: UUID().uuidString)
            XCTFail("Invalid external completion must be refused")
        } catch {}
        let actions = try await store.actions(includeHistory: true)
        let saved = try XCTUnwrap(actions.first { $0.id == fixture.action.id })
        XCTAssertEqual(saved.version, fixture.action.version)
        XCTAssertEqual(saved.state, state)
        XCTAssertEqual(saved.validity, validity)
        let history = try await store.actionHistory(actionID: fixture.action.id)
        XCTAssertEqual(history.count, 1)
    }

    func testFrozenTaskWithCompletedObservationConfirmsCompletion() async throws {
        let store = try await openStore()
        let fixture = try await makeFixture(store)
        let confirmed = try await store.confirmExternalCompletion(
            actionID: fixture.action.id, expectedVersion: fixture.action.version,
            linkID: fixture.link.id, expectedObservationID: fixture.observationID, commandID: "confirm-once")
        XCTAssertEqual(confirmed, fixture.action.version + 1)
        let actions = try await store.actions(includeHistory: true)
        let saved = try XCTUnwrap(actions.first { $0.id == fixture.action.id })
        XCTAssertEqual(saved.state, "completed")
        XCTAssertEqual(saved.version, fixture.action.version + 1)
        XCTAssertEqual(saved.validity, "frozen")
        let history = try await store.actionHistory(actionID: fixture.action.id)
        let revision = try XCTUnwrap(history.last)
        XCTAssertEqual(revision.version, confirmed)
        XCTAssertEqual(revision.actor, "user")
        XCTAssertEqual(revision.state, "completed")
        XCTAssertTrue(revision.note.contains(fixture.observationID))
        XCTAssertTrue(revision.note.contains("冻结"))
    }

    func testConfirmedCompletionEntersOutcomeQueueUntilResultSaved() async throws {
        let store = try await openStore()
        let fixture = try await makeFixture(store)
        let confirmed = try await store.confirmExternalCompletion(
            actionID: fixture.action.id, expectedVersion: fixture.action.version,
            linkID: fixture.link.id, expectedObservationID: fixture.observationID, commandID: "queue-result")
        let pending = try await store.pendingOutcomeFollowups()
        XCTAssertTrue(pending.contains { $0.id == fixture.action.id && $0.version == confirmed })
        let snapshot = try await store.workspaceSnapshot()
        XCTAssertTrue(snapshot.outcomeFollowups.contains { $0.id == fixture.action.id && $0.version == confirmed })
        let sourceID = try await store.recordActionFeedback(
            actionID: fixture.action.id, expectedVersion: confirmed, kind: .outcome, text: "阅读后发现检索质量确实影响结果。")
        let remaining = try await store.pendingOutcomeFollowups()
        XCTAssertFalse(remaining.contains { $0.id == fixture.action.id })
        let refreshed = try await store.workspaceSnapshot()
        XCTAssertFalse(refreshed.outcomeFollowups.contains { $0.id == fixture.action.id })
        let outcomes = try await store.recentActionOutcomes()
        let recorded = outcomes.first { $0.actionID == fixture.action.id }
        XCTAssertEqual(recorded?.sourceID, sourceID)
        XCTAssertEqual(recorded?.actionVersion, confirmed)
    }

    func testRepeatedConfirmationIsIdempotentAndNewCommandIsRefused() async throws {
        let store = try await openStore()
        let fixture = try await makeFixture(store)
        let first = try await store.confirmExternalCompletion(
            actionID: fixture.action.id, expectedVersion: fixture.action.version,
            linkID: fixture.link.id, expectedObservationID: fixture.observationID, commandID: "repeat")
        let second = try await store.confirmExternalCompletion(
            actionID: fixture.action.id, expectedVersion: fixture.action.version,
            linkID: fixture.link.id, expectedObservationID: fixture.observationID, commandID: "repeat")
        XCTAssertEqual(second, first)
        let history = try await store.actionHistory(actionID: fixture.action.id)
        XCTAssertEqual(history.count, 2)
        let actions = try await store.actions(includeHistory: true)
        XCTAssertEqual(actions.first { $0.id == fixture.action.id }?.version, first)
        do {
            _ = try await store.confirmExternalCompletion(
                actionID: fixture.action.id, expectedVersion: fixture.action.version,
                linkID: fixture.link.id, expectedObservationID: fixture.observationID, commandID: "different")
            XCTFail("A new command must not complete an already completed task")
        } catch {}
        let unchanged = try await store.actionHistory(actionID: fixture.action.id)
        XCTAssertEqual(unchanged.count, 2)
    }

    func testWrongVersionIsRefused() async throws {
        let store = try await openStore()
        let fixture = try await makeFixture(store)
        try await assertRefused(store, fixture: fixture, expectedVersion: fixture.action.version + 1)
    }

    func testWrongObservationIsRefused() async throws {
        let store = try await openStore()
        let fixture = try await makeFixture(store)
        try await assertRefused(store, fixture: fixture, observationID: UUID().uuidString)
    }

    func testUnlinkedReminderIsRefused() async throws {
        let store = try await openStore()
        let fixture = try await makeFixture(store)
        let database = await store.db
        try database.execute("UPDATE reminder_links SET state='conflict' WHERE id=?", [fixture.link.id])
        try await assertRefused(store, fixture: fixture)
    }

    func testNonFrozenTaskIsRefused() async throws {
        let store = try await openStore()
        let fixture = try await makeFixture(store)
        let database = await store.db
        try database.execute("UPDATE actions SET validity='current' WHERE id=?", [fixture.action.id])
        try await assertRefused(store, fixture: fixture, validity: "current")
    }

    func testDismissedTaskIsRefused() async throws {
        let store = try await openStore()
        let fixture = try await makeFixture(store)
        let database = await store.db
        try database.execute("UPDATE actions SET state='dismissed' WHERE id=?", [fixture.action.id])
        try await assertRefused(store, fixture: fixture, state: "dismissed")
    }

    func testUncompletedObservationIsRefused() async throws {
        let store = try await openStore()
        let fixture = try await makeFixture(store, complete: false)
        try await assertRefused(store, fixture: fixture)
    }

    func testInvalidMarkerIsRefused() async throws {
        let store = try await openStore()
        let fixture = try await makeFixture(store)
        let database = await store.db
        try database.execute("UPDATE reminder_observations SET marker_valid=0 WHERE id=?", [fixture.observationID])
        try await assertRefused(store, fixture: fixture)
    }

    func testMismatchedObservationIdentityIsRefused() async throws {
        let store = try await openStore()
        let fixture = try await makeFixture(store)
        let database = await store.db
        try database.execute("UPDATE reminder_observations SET external_id='other-reminder' WHERE id=?", [fixture.observationID])
        try await assertRefused(store, fixture: fixture)
    }

    func testFrozenCompletedTaskWithoutConfirmationStaysOutOfOutcomeQueue() async throws {
        let store = try await openStore()
        let action = try await makeTask(store)
        let completed = try await store.setActionState(
            actionID: action.id, expectedVersion: action.version, state: .completed, commandID: "local-completion")
        let database = await store.db
        try database.execute("UPDATE actions SET validity='frozen' WHERE id=?", [action.id])
        let pending = try await store.pendingOutcomeFollowups()
        XCTAssertFalse(pending.contains { $0.id == action.id })
        let outcomes = try await store.recentActionOutcomes()
        XCTAssertTrue(outcomes.isEmpty)
        let actions = try await store.actions(includeHistory: true)
        XCTAssertEqual(actions.first { $0.id == action.id }?.version, completed)
    }

    func testCandidateOffersOnlyFrozenOpenTaskWithCompletedLinkedObservation() {
        func action(state: String = "open", validity: String = "frozen", kind: String = "task") -> ActionRecord {
            ActionRecord(id: "action", claimID: "claim", claimReviewVersion: 1, title: "查阅相关论文", kind: kind,
                         intentActor: "user", note: "", state: state, validity: validity, version: 4, autoSend: false, intent: nil,
                         commandID: "test:action", createdAt: "2026-01-01T00:00:00Z")
        }
        func link(state: String = "linked", markerValid: Bool? = true, completed: Bool? = true,
                  observationID: String? = "observation") -> ReminderLink {
            ReminderLink(id: "link", actionID: "action", calendarID: "calendar", state: state, externalID: "reminder",
                         remoteTitle: "查阅相关论文", remoteCompleted: completed, lastObservedAt: nil, lastCheckedAt: nil,
                         lastObservationID: observationID, remoteMarkerValid: markerValid, remoteDueDate: nil)
        }
        let candidate = ExternalCompletionCandidate(action: action(), link: link())
        XCTAssertEqual(candidate?.expectedVersion, 4)
        XCTAssertEqual(candidate?.linkID, "link")
        XCTAssertEqual(candidate?.observationID, "observation")
        XCTAssertEqual(candidate?.commandID, "external-completion-ui:action:observation")

        XCTAssertNil(ExternalCompletionCandidate(action: action(state: "completed"), link: link()))
        XCTAssertNil(ExternalCompletionCandidate(action: action(state: "dismissed"), link: link()))
        XCTAssertNil(ExternalCompletionCandidate(action: action(validity: "current"), link: link()))
        XCTAssertNil(ExternalCompletionCandidate(action: action(kind: "opportunity"), link: link()))
        XCTAssertNil(ExternalCompletionCandidate(action: action(), link: link(state: "conflict")))
        XCTAssertNil(ExternalCompletionCandidate(action: action(), link: link(state: "reserved")))
        XCTAssertNil(ExternalCompletionCandidate(action: action(), link: link(markerValid: false)))
        XCTAssertNil(ExternalCompletionCandidate(action: action(), link: link(markerValid: nil)))
        XCTAssertNil(ExternalCompletionCandidate(action: action(), link: link(completed: false)))
        XCTAssertNil(ExternalCompletionCandidate(action: action(), link: link(completed: nil)))
        XCTAssertNil(ExternalCompletionCandidate(action: action(), link: link(observationID: nil)))
        XCTAssertNil(ExternalCompletionCandidate(action: action(), link: nil))
    }
}
