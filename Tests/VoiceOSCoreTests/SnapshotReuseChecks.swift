import XCTest
@testable import VoiceOSCore
import VoiceOSPlatform

private actor SnapshotTopicPort: TopicOrganizationPort {
    private var calls = 0
    func count() -> Int { calls }
    func organizeSkeleton(_ input: TopicSkeletonInput) async throws -> TopicSkeletonResult {
        calls += 1
        return .init(briefing: "合成简报", highlightSourceIDs: input.viewpoints.map(\.sourceID),
                     topics: [.init(topicID: "", title: "合成主题", summary: "合成摘要",
                                    questions: [], viewpointIDs: input.viewpoints.map(\.id))],
                     responseID: "snapshot-skeleton-\(calls)")
    }
    func organizeSkeletonMerge(_ input: TopicSkeletonMergeInput) async throws -> TopicSkeletonMergeResult {
        mergedSkeletonMerge(input, responseID: "snapshot-merge-\(calls)")
    }
    func organizeBody(_ input: TopicBodyInput) async throws -> TopicBodyResult {
        .init(topics: input.topics.map { topic in
            .init(topicID: topic.topicID, questions: [],
                  sections: [.init(id: "synthetic", title: "合成小节", summary: "合成正文",
                                   claimIDs: topic.viewpoints.map(\.id), actionIDs: topic.tasks.map(\.id),
                                   evidence: topic.quotes.prefix(1).map { .init(sourceID: $0.sourceID, quote: $0.quote) })])
        }, responseID: "snapshot-body-\(calls)")
    }
}

private struct EmptyFollowupPort: RecordingFollowupPort {
    func generate(_ input: RecordingFollowupInput) async throws -> RecordingFollowupGeneration {
        .init(result: .init(thoughtUpdates: [], goalPlans: [],
                            english: .init(isPractice: false, evidenceQuote: "", suggestions: [], comparisons: [], nextExercise: "")),
              responseIDs: ["fixture-response"])
    }
}

final class SnapshotReuseChecks: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-snapshot-reuse-" + UUID().uuidString)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func openStore() async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }

    private func allowCloud(_ store: VoiceOSStore, _ sourceID: String) async throws {
        _ = try await store.setSourceLocalOnly(sourceID: sourceID, expectedVersion: 1, localOnly: false)
    }

    private func seedTask(_ store: VoiceOSStore, text: String, title: String) async throws -> (sourceID: String, action: ActionRecord) {
        let sourceID = try await store.recordUserExpression(text)
        try await allowCloud(store, sourceID)
        let context = try await store.prepareLocalTranscriptContext(sourceIDs: [sourceID])
        let item = try XCTUnwrap(context.sources.first)
        _ = try await store.importOrganizedClaims(context: context, proposals: [
            .init(statement: text, ownership: .userTentative,
                  references: [.init(sourceID: sourceID, transcriptVersionID: item.transcriptVersionID, spanID: item.spans[0].id)],
                  action: .init(title: title, kind: .task, quote: text))
        ], commandID: "snapshot-reuse-" + sourceID)
        let actions = try await store.actions()
        return (sourceID, try XCTUnwrap(actions.first { $0.title == title }))
    }

    func testBriefingSkipsRecomputeUntilAnInputChanges() async throws {
        let store = try await openStore()
        let sourceID = try await store.recordUserExpression("检索质量决定回答质量。")
        try await allowCloud(store, sourceID)
        let context = try await store.prepareLocalTranscriptContext(sourceIDs: [sourceID])
        let item = try XCTUnwrap(context.sources.first)
        _ = try await store.importOrganizedClaims(context: context, proposals: [
            .init(statement: item.text, ownership: .userTentative,
                  references: [.init(sourceID: sourceID, transcriptVersionID: item.transcriptVersionID, spanID: item.spans[0].id)])
        ], commandID: "snapshot-topic-claims-" + sourceID)
        let port = SnapshotTopicPort()
        let organized = try await store.organizeTopics(using: port)
        XCTAssertTrue(organized)
        let firstCalls = await port.count()
        XCTAssertEqual(firstCalls, 1)

        let first = try await store.workspaceBriefing()
        XCTAssertNotNil(first)
        let second = try await store.workspaceBriefing()
        XCTAssertEqual(second?.digest, first?.digest)
        let repeatGrouping = try await store.organizeTopics(using: port)
        XCTAssertFalse(repeatGrouping, "同一输入不应再发起整理")
        let laterCalls = await port.count()
        XCTAssertEqual(laterCalls, 1)

        _ = try await store.setSourceLocalOnly(sourceID: sourceID, expectedVersion: 2, localOnly: true)
        let afterRevocation = try await store.workspaceBriefing()
        XCTAssertNil(afterRevocation, "授权变化后简报必须失效")
    }

    func testAssistantSnapshotRevalidatesAfterInputChanges() async throws {
        let store = try await openStore()
        let seeded = try await seedTask(store, text: "整理检索质量的证据。", title: "整理检索质量")
        let execution = try await store.enqueueAssistantExecution(actionID: seeded.action.id, expectedVersion: seeded.action.version)

        let first = try await store.workspaceSnapshot(.assistant)
        let current = try XCTUnwrap(first.assistantExecutions.first { $0.id == execution.id })
        XCTAssertEqual(current.validity, "current")
        XCTAssertEqual(current.state, "queued")

        let repeatedSnapshot = try await store.workspaceSnapshot(.assistant)
        let repeated = try XCTUnwrap(repeatedSnapshot.assistantExecutions.first { $0.id == execution.id })
        XCTAssertEqual(repeated.validity, "current")
        XCTAssertEqual(repeated.state, "queued")

        _ = try await store.setSourceLocalOnly(sourceID: seeded.sourceID, expectedVersion: 2, localOnly: true)
        let changedSnapshot = try await store.workspaceSnapshot(.assistant)
        let frozen = try XCTUnwrap(changedSnapshot.assistantExecutions.first { $0.id == execution.id })
        XCTAssertEqual(frozen.validity, "frozen")
        XCTAssertEqual(frozen.state, "cancelled")
    }

    func testFollowupReadsAndValidityReflectLaterWrites() async throws {
        let store = try await openStore()
        let sourceID = try await store.recordUserExpression("继续练英语讲解。")
        try await allowCloud(store, sourceID)
        _ = try await store.enqueueRecordingFollowup(sourceID: sourceID)
        let completed = try await store.processRecordingFollowup(sourceID: sourceID, using: EmptyFollowupPort())
        XCTAssertEqual(completed.state, "completed")

        let receipts = try await store.recordingFollowups()
        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(receipts.first?.state, "completed")
        let validity = try await store.recordingFollowupValidity(completed)
        XCTAssertTrue(validity.sourceCurrent)

        _ = try await store.setSourceLocalOnly(sourceID: sourceID, expectedVersion: 2, localOnly: true)
        let after = try await store.recordingFollowupValidity(completed)
        XCTAssertFalse(after.sourceCurrent)
        let finalReceipts = try await store.recordingFollowups()
        XCTAssertEqual(finalReceipts.count, 1)
    }
}
