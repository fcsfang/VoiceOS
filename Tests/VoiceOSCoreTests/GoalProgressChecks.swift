import XCTest
@testable import VoiceOSCore
import VoiceOSPlatform

final class GoalProgressChecks: XCTestCase {
    private var base: URL!
    private var root: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-goal-progress-" + UUID().uuidString)
        root = base.appendingPathComponent("library")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: base) }

    private func openStore() async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }

    private func addAction(_ store: VoiceOSStore, title: String, kind: ActionKind) async throws -> ActionRecord {
        let source = try await store.recordUserExpression("需要核对的内容。")
        let context = try await store.prepareLocalTranscriptContext(sourceIDs: [source])
        let references = context.sources.map {
            ClaimReference(sourceID: $0.sourceID, transcriptVersionID: $0.transcriptVersionID, spanID: $0.spans[0].id)
        }
        let quote = try XCTUnwrap(context.sources.first?.text)
        let claimIDs = try await store.importOrganizedClaims(context: context, proposals: [
            .init(statement: title, ownership: .userTentative, references: references,
                  action: .init(title: title, kind: kind, quote: quote))
        ], commandID: "goal-progress-claims-" + UUID().uuidString)
        let claimID = try XCTUnwrap(claimIDs.first)
        let actions = try await store.actions()
        return try XCTUnwrap(actions.first { $0.claimID == claimID })
    }

    func testGoalWithoutChildrenReportsZeroAndCreationFallback() async throws {
        let store = try await openStore()
        let goal = try await addAction(store, title: "整理家里", kind: .opportunity)

        let progress = try await store.goalProgress(actionID: goal.id)

        XCTAssertEqual(progress.nextSteps, 0)
        XCTAssertEqual(progress.completedSteps, 0)
        XCTAssertEqual(progress.lastActivityAt, goal.createdAt)
    }

    func testCompletedChildCountsAndDismissedChildIsNotOpen() async throws {
        let store = try await openStore()
        let goal = try await addAction(store, title: "整理家里", kind: .opportunity)
        let first = try await store.createAction(claimID: goal.claimID, expectedClaimReviewVersion: goal.claimReviewVersion,
                                                 title: "买收纳盒", kind: .task, commandID: "goal-progress-first")
        let second = try await store.createAction(claimID: goal.claimID, expectedClaimReviewVersion: goal.claimReviewVersion,
                                                  title: "清空衣柜", kind: .task, commandID: "goal-progress-second")
        let firstAttached = try await store.attachNextAction(outcomeID: goal.id, actionID: first, commandID: "goal-progress-attach-first")
        let secondAttached = try await store.attachNextAction(outcomeID: goal.id, actionID: second, commandID: "goal-progress-attach-second")

        _ = try await store.setActionState(actionID: first, expectedVersion: firstAttached, state: .completed, commandID: "goal-progress-complete-first")
        var progress = try await store.goalProgress(actionID: goal.id)
        XCTAssertEqual(progress.nextSteps, 1)
        XCTAssertEqual(progress.completedSteps, 1)

        _ = try await store.setActionState(actionID: second, expectedVersion: secondAttached, state: .dismissed, commandID: "goal-progress-dismiss-second")
        progress = try await store.goalProgress(actionID: goal.id)
        XCTAssertEqual(progress.nextSteps, 0)
        XCTAssertEqual(progress.completedSteps, 1)
    }

    func testLastActivityTakesNewestRevisionAcrossGoalAndChildren() async throws {
        let store = try await openStore()
        let goal = try await addAction(store, title: "整理家里", kind: .opportunity)
        let child = try await store.createAction(claimID: goal.claimID, expectedClaimReviewVersion: goal.claimReviewVersion,
                                                 title: "买收纳盒", kind: .task, commandID: "goal-progress-latest")
        let attached = try await store.attachNextAction(outcomeID: goal.id, actionID: child, commandID: "goal-progress-latest-attach")
        _ = try await store.setActionState(actionID: child, expectedVersion: attached, state: .completed, commandID: "goal-progress-latest-complete")

        var timestamps = [goal.createdAt]
        timestamps += try await store.actionRevisions(actionID: goal.id).map(\.createdAt)
        timestamps += try await store.actionRevisions(actionID: child).map(\.createdAt)
        let newest = try XCTUnwrap(timestamps.max())

        let progress = try await store.goalProgress(actionID: goal.id)
        let childRevisions = try await store.actionRevisions(actionID: child)

        XCTAssertEqual(progress.lastActivityAt, newest)
        XCTAssertTrue(childRevisions.contains { $0.createdAt == progress.lastActivityAt })
    }
}
