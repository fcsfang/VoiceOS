import XCTest
import VoiceOSPlatform
@testable import VoiceOSCore

private struct ReusingTaskFollowup: RecordingFollowupPort {
    let taskID: String
    let taskTitle: String
    func generate(_ input: RecordingFollowupInput) async throws -> RecordingFollowupGeneration {
        let empty = PracticeFollowup(isPractice: false, evidenceQuote: "", suggestions: [], comparisons: [], nextExercise: "")
        guard let goal = input.goals.first else {
            return .init(result: .init(thoughtUpdates: [], goalPlans: [], english: empty), responseIDs: ["fixture"])
        }
        let step = GoalStep(title: taskTitle, condition: "保持原来的条件", existingTaskID: taskID)
        let plan = GoalPlan(goalID: goal.id, summary: "沿用已有任务", adjustment: "没有新的进展",
                            phases: [GoalPhase(title: "继续", steps: [step])], nextStep: step)
        return .init(result: .init(thoughtUpdates: [], goalPlans: [plan], english: empty), responseIDs: ["fixture"])
    }
}

private extension VoiceOSStore {
    func markFollowupGoal(_ id: String) throws {
        try db.execute("UPDATE actions SET intent_json=? WHERE id=?", [String(decoding: try JSONEncoder().encode(ActionIntentMetadata(intentType: "goal", followupState: "pending", uncertain: false)), as: UTF8.self), id])
    }
}

final class FollowupNormalizationChecks: XCTestCase {
    func testSelectedHistoryKeepsFirstOccurrenceAndDropsUnknownIDs() {
        let selection = ResponsesRecordingFollowupPort.normalizedSelection(
            thoughtIDs: ["thought-b", "unknown", "thought-a", "thought-b"],
            goalIDs: ["goal-a", "goal-a", "missing-goal"],
            taskIDs: ["missing-task"],
            practiceSourceIDs: ["practice-b", "practice-a", "practice-b"],
            availableThoughtIDs: ["thought-a", "thought-b"],
            availableGoalIDs: ["goal-a"],
            availableTaskIDs: ["task-a"],
            availablePracticeSourceIDs: ["practice-a", "practice-b"])
        XCTAssertEqual(selection.thoughtIDs, ["thought-b", "thought-a"])
        XCTAssertEqual(selection.goalIDs, ["goal-a"])
        XCTAssertEqual(selection.taskIDs, [])
        XCTAssertEqual(selection.practiceSourceIDs, ["practice-b", "practice-a"])
    }

    func testSelectedHistoryMayBeEmpty() {
        let selection = ResponsesRecordingFollowupPort.normalizedSelection(
            thoughtIDs: [], goalIDs: [], taskIDs: [], practiceSourceIDs: [],
            availableThoughtIDs: ["thought-a"], availableGoalIDs: ["goal-a"],
            availableTaskIDs: ["task-a"], availablePracticeSourceIDs: ["practice-a"])
        XCTAssertTrue(selection.thoughtIDs.isEmpty)
        XCTAssertTrue(selection.goalIDs.isEmpty)
        XCTAssertTrue(selection.taskIDs.isEmpty)
        XCTAssertTrue(selection.practiceSourceIDs.isEmpty)
    }

    func testKnowledgeCandidatesDropUnknownQuotesAndDuplicateIDs() throws {
        let input = knowledgeInput("我认为检索质量比记忆容量更值得研究。")
        let selection = try VoiceOSStore.validateKnowledgeSelection(.init(candidates: [
            .init(id: "first", quote: "检索质量比记忆容量", reason: "可核查"),
            .init(id: "first", quote: "记忆容量", reason: "重复身份"),
            .init(id: "invented", quote: "这句话不在原文里", reason: "编造"),
            .init(id: "", quote: "更值得研究", reason: "缺少身份"),
            .init(id: "empty-quote", quote: "", reason: "缺少原话"),
            .init(id: "second", quote: "更值得研究", reason: "可核查")
        ], responseID: "response"), input: input)
        XCTAssertEqual(selection.candidates.map(\.id), ["first", "second"])
        XCTAssertEqual(selection.candidates.map(\.quote), ["检索质量比记忆容量", "更值得研究"])
    }

    func testKnowledgeSelectionAllowsNoCandidates() throws {
        let input = knowledgeInput("没有需要核查的判断。")
        let selection = try VoiceOSStore.validateKnowledgeSelection(.init(candidates: [], responseID: "response"), input: input)
        XCTAssertTrue(selection.candidates.isEmpty)
        XCTAssertEqual(selection.responseID, "response")
    }

    func testKnowledgeSelectionRequiresResponseID() {
        let input = knowledgeInput("没有需要核查的判断。")
        XCTAssertThrowsError(try VoiceOSStore.validateKnowledgeSelection(.init(candidates: [], responseID: ""), input: input))
    }

    func testFollowupFillsTaskGoalFromPreviousPlanAndAcceptsItAsNextStep() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-followup-links-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await store.recover()

        let goalSource = try await store.recordUserExpression("我希望把英语讲解练习坚持下去。")
        _ = try await store.setSourceLocalOnly(sourceID: goalSource, expectedVersion: 1, localOnly: false)
        let goalContext = try await store.prepareLocalTranscriptContext(sourceIDs: [goalSource])
        let goalText = goalContext.sources[0]
        _ = try await store.importOrganizedClaims(context: goalContext, proposals: [.init(statement: goalText.text, ownership: .userTentative,
            references: [.init(sourceID: goalSource, transcriptVersionID: goalText.transcriptVersionID, spanID: goalText.spans[0].id)])], commandID: "followup-link-goal")
        let goalClaims = try await store.latestCandidateClaims(for: goalSource)
        let goalClaim = try XCTUnwrap(goalClaims.first)
        let goalID = try await store.createAction(claimID: goalClaim.id, expectedClaimReviewVersion: goalClaim.reviewVersion, title: "坚持英语讲解练习", kind: .opportunity)
        try await store.markFollowupGoal(goalID)

        let taskSource = try await store.recordUserExpression("先补一页检索质量的例子。")
        _ = try await store.setSourceLocalOnly(sourceID: taskSource, expectedVersion: 1, localOnly: false)
        let taskContext = try await store.prepareLocalTranscriptContext(sourceIDs: [taskSource])
        let taskText = taskContext.sources[0]
        _ = try await store.importOrganizedClaims(context: taskContext, proposals: [.init(statement: taskText.text, ownership: .userTentative,
            references: [.init(sourceID: taskSource, transcriptVersionID: taskText.transcriptVersionID, spanID: taskText.spans[0].id)])], commandID: "followup-link-task")
        let taskClaims = try await store.latestCandidateClaims(for: taskSource)
        let taskClaim = try XCTUnwrap(taskClaims.first)
        let taskTitle = "补一页检索质量的例子"
        let taskID = try await store.createAction(claimID: taskClaim.id, expectedClaimReviewVersion: taskClaim.reviewVersion, title: taskTitle, kind: .task)
        let createdTask = try await store.actions().first { $0.id == taskID }
        XCTAssertNil(createdTask?.intent?.goalID)

        let first = try await store.processRecordingFollowup(sourceID: goalSource, using: ReusingTaskFollowup(taskID: taskID, taskTitle: taskTitle))
        XCTAssertEqual(first.state, "completed")
        XCTAssertEqual(first.result?.goalPlans.first?.nextStep.existingTaskID, taskID)

        let nextSource = try await store.recordUserExpression("继续练英语讲解。")
        _ = try await store.setSourceLocalOnly(sourceID: nextSource, expectedVersion: 1, localOnly: false)
        let input = try await store.prepareRecordingFollowup(sourceID: nextSource)
        XCTAssertEqual(input.tasks.first { $0.id == taskID }?.goalID, goalID)
    }

    private func knowledgeInput(_ text: String) -> KnowledgeReviewInput {
        let source = ContextTranscript(sourceID: "source", sourceVersionID: "source-v1", transcriptVersionID: "transcript-v1",
                                       origin: "user", speaker: "user", localOnly: false, text: text, spans: [])
        return KnowledgeReviewInput(sourceID: "source", transcriptVersionID: "transcript-v1", policyVersion: 1,
                                    context: LocalTranscriptContext(sources: [source], scalarBudget: max(1, text.unicodeScalars.count), contentDigest: "digest"),
                                    claimReviewVersions: ["claim": 1], inputDigest: "digest")
    }
}
