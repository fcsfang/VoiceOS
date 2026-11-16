import XCTest
@testable import VoiceOSCore
import VoiceOSPlatform

final class ActionRowStatusChecks: XCTestCase {
    private func facts(_ configure: (inout ActionRowFacts) -> Void) -> ActionRowStatus {
        var facts = ActionRowFacts()
        configure(&facts)
        return ActionRowLayout.status(facts)
    }

    private func action(id: String, parent: String?, state: String) -> ActionRecord {
        ActionRecord(id: id, claimID: "claim", claimReviewVersion: 1, title: "t", kind: "task",
                     intentActor: "user", note: "", state: state, validity: "current", version: 1,
                     autoSend: false, intent: nil, commandID: "c", createdAt: "", parentID: parent)
    }

    func testMetaCarriesDueInsteadOfSource() {
        let row = facts { facts in
            facts.isGoal = true
            facts.due = "到期 11月20日"
            facts.sourceTitle = "早餐时的想法"
        }
        XCTAssertEqual(row.meta, "到期 11月20日")
        XCTAssertFalse(row.meta.contains("来自"))
    }

    func testMetaFallsBackToSourceWhenNoDue() {
        let row = facts { facts in
            facts.isGoal = true
            facts.sourceTitle = "早餐时的想法"
        }
        XCTAssertEqual(row.meta, "来自『早餐时的想法』")
    }

    func testGoalShowsOpenNextStepCountInStatusSlot() {
        let row = facts { facts in
            facts.isGoal = true
            facts.nextStepCount = 2
            facts.sourceTitle = "早餐时的想法"
        }
        XCTAssertEqual(row.status, "2 个下一步")
        XCTAssertEqual(row.tone, .secondary)
        XCTAssertFalse(row.meta.contains("下一步"))
    }

    func testGoalWithNoNextStepsLeavesStatusToTheBanner() {
        let row = facts { facts in
            facts.isGoal = true
            facts.nextStepCount = 0
        }
        XCTAssertEqual(row.status, "")
    }

    func testNeedsReviewGroupDoesNotReafirmItsOwnStatus() {
        let row = facts { facts in
            facts.group = .needsReview
            facts.requiresReview = true
        }
        XCTAssertEqual(row.status, "")
        let frozen = facts { facts in
            facts.group = .needsReview
            facts.validity = "frozen"
        }
        XCTAssertEqual(frozen.status, "")
    }

    func testNeedsReviewShowsAsWarningOutsideItsGroup() {
        let row = facts { facts in
            facts.requiresReview = true
        }
        XCTAssertEqual(row.status, "待核对")
        XCTAssertEqual(row.tone, .warning)
    }

    func testCompletedGroupDoesNotRepeatCompletion() {
        let row = facts { facts in
            facts.group = .completed
            facts.state = "completed"
        }
        XCTAssertEqual(row.status, "")
    }

    func testHistoricalRowDoesNotRepeatTheGroupLabel() {
        let row = facts { facts in
            facts.group = .history
            facts.validity = "frozen"
        }
        XCTAssertEqual(row.status, "")
    }

    func testDismissedRowKeepsItsOwnOutcome() {
        let row = facts { facts in
            facts.group = .history
            facts.state = "dismissed"
        }
        XCTAssertEqual(row.status, "已放下")
        XCTAssertEqual(row.tone, .tertiary)
    }

    func testWarningExceptionWinsOverNextStepCount() {
        let row = facts { facts in
            facts.isGoal = true
            facts.nextStepCount = 3
            facts.localUnsynced = true
        }
        XCTAssertEqual(row.status, "本地未同步")
        XCTAssertEqual(row.tone, .warning)
    }

    func testNextStepCountsCountOpenChildrenPerOutcome() {
        let actions = [
            action(id: "a", parent: "goal", state: "open"),
            action(id: "b", parent: "goal", state: "completed"),
            action(id: "c", parent: "goal", state: "open"),
            action(id: "d", parent: nil, state: "open"),
            action(id: "e", parent: "other", state: "open"),
        ]
        XCTAssertEqual(ActionRowLayout.nextStepCounts(actions), ["goal": 2, "other": 1])
    }

    func testQuestionWithoutAnalysisShowsUnanswered() {
        let row = facts { facts in
            facts.isQuestion = true
            facts.sourceTitle = "早餐时的想法"
        }
        XCTAssertEqual(row.status, "未回答")
        XCTAssertEqual(row.tone, .secondary)
        XCTAssertEqual(row.meta, "来自『早餐时的想法』")
    }

    func testQuestionWaitingOrRunningShowsAnswering() {
        for state in ["queued", "running", "reserved", "blocked"] {
            let row = facts { facts in
                facts.isQuestion = true
                facts.answerState = state
            }
            XCTAssertEqual(row.status, "回答中", state)
            XCTAssertEqual(row.tone, .secondary, state)
        }
    }

    func testQuestionWithCompletedAnalysisShowsAnswered() {
        let row = facts { facts in
            facts.isQuestion = true
            facts.answerState = "completed"
        }
        XCTAssertEqual(row.status, "已回答")
        XCTAssertEqual(row.tone, .success)
    }

    func testQuestionWithFailedOrCancelledAnalysisShowsFailure() {
        for state in ["failed", "cancelled"] {
            let row = facts { facts in
                facts.isQuestion = true
                facts.answerState = state
            }
            XCTAssertEqual(row.status, "回答失败", state)
            XCTAssertEqual(row.tone, .warning, state)
        }
        let unknown = facts { facts in
            facts.isQuestion = true
            facts.answerState = "unknown"
        }
        XCTAssertEqual(unknown.status, "未回答")
    }

    func testQuestionStatusWinsOverNextStepCount() {
        let row = facts { facts in
            facts.isQuestion = true
            facts.nextStepCount = 2
        }
        XCTAssertEqual(row.status, "未回答")
        XCTAssertEqual(row.meta, "")
    }

    func testCompletedRowShowsCompletionDateInsteadOfSource() {
        let row = facts { facts in
            facts.group = .completed
            facts.state = "completed"
            facts.completedAt = "完成于 11月16日"
            facts.sourceTitle = "早餐时的想法"
        }
        XCTAssertEqual(row.meta, "完成于 11月16日")
        XCTAssertEqual(row.status, "")
    }

    func testCompletionDateOnlyAppliesInsideTheCompletedGroup() {
        let row = facts { facts in
            facts.state = "completed"
            facts.completedAt = "完成于 11月16日"
            facts.sourceTitle = "早餐时的想法"
        }
        XCTAssertEqual(row.meta, "来自『早餐时的想法』")
        XCTAssertEqual(row.status, "已登记完成")
    }
}

final class ActionCompletionTimeChecks: XCTestCase {
    private var base: URL!
    private var root: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-completion-time-" + UUID().uuidString)
        root = base.appendingPathComponent("library")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: base) }

    private func openStore() async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }

    private func addAction(_ store: VoiceOSStore) async throws -> ActionRecord {
        let source = try await store.recordUserExpression("整理桌面。")
        let context = try await store.prepareLocalTranscriptContext(sourceIDs: [source])
        let references = context.sources.map {
            ClaimReference(sourceID: $0.sourceID, transcriptVersionID: $0.transcriptVersionID, spanID: $0.spans[0].id)
        }
        let quote = try XCTUnwrap(context.sources.first?.text)
        let claimIDs = try await store.importOrganizedClaims(context: context, proposals: [
            .init(statement: "整理桌面", ownership: .userTentative, references: references,
                  action: .init(title: "整理桌面", kind: .task, quote: quote))
        ], commandID: "completion-time-claims")
        let claimID = try XCTUnwrap(claimIDs.first)
        let actions = try await store.actions()
        return try XCTUnwrap(actions.first { $0.claimID == claimID })
    }

    func testCompletedAtTracksTheNewestCompletionRevision() async throws {
        let store = try await openStore()
        let action = try await addAction(store)
        let firstCompletion = try await store.setActionState(actionID: action.id, expectedVersion: action.version, state: .completed)
        let db = await store.db
        try db.execute("UPDATE action_revisions SET created_at='2025-01-01T00:00:00Z' WHERE action_id=? AND version=?", [action.id, String(firstCompletion)])
        var actions = try await store.actions(includeHistory: true)
        var record = try XCTUnwrap(actions.first { $0.id == action.id })
        XCTAssertEqual(record.completedAt, "2025-01-01T00:00:00Z")
        let reopened = try await store.setActionState(actionID: action.id, expectedVersion: record.version, state: .open)
        actions = try await store.actions(includeHistory: true)
        record = try XCTUnwrap(actions.first { $0.id == action.id })
        XCTAssertEqual(record.completedAt, "2025-01-01T00:00:00Z")
        _ = try await store.setActionState(actionID: action.id, expectedVersion: reopened, state: .completed)
        let history = try await store.actionHistory(actionID: action.id)
        actions = try await store.actions(includeHistory: true)
        record = try XCTUnwrap(actions.first { $0.id == action.id })
        XCTAssertEqual(history.last?.state, "completed")
        XCTAssertEqual(record.completedAt, history.last?.createdAt)
        XCTAssertNotEqual(record.completedAt, "2025-01-01T00:00:00Z")
    }
}
