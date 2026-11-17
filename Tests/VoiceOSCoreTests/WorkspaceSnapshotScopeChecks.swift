import XCTest
@testable import VoiceOSCore
import VoiceOSPlatform

private let scopeConfiguration = ModelConfiguration(provider: "fixture", model: "scope", promptVersion: "v1", schemaVersion: "v1", destination: .local)

private actor ScopeModel: ModelPort {
    let configuration = scopeConfiguration
    func generate(_ request: ModelRequest) async throws -> ModelResponse {
        let source = request.context.sources[0]
        let reference = ClaimReference(sourceID: source.sourceID, transcriptVersionID: source.transcriptVersionID, spanID: source.spans[0].id)
        return ModelResponse(status: .completed, claims: [ClaimProposal(statement: String(source.text.prefix(80)), ownership: .userTentative, references: [reference])])
    }
}

final class WorkspaceSnapshotScopeChecks: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-snapshot-scope-" + UUID().uuidString)
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
        ], commandID: "snapshot-scope-" + sourceID)
        let actions = try await store.actions()
        return (sourceID, try XCTUnwrap(actions.first { $0.title == title }))
    }
    private func seedKnowledgeSource(_ store: VoiceOSStore, text: String) async throws -> String {
        let sourceID = try await store.recordUserExpression(text)
        try await allowCloud(store, sourceID)
        _ = try await store.continueSourceUnderstanding(sourceID: sourceID, using: ScopeModel())
        return sourceID
    }

    func testCoreSecondaryLoadsCoreAndSecondaryWithoutAssistantOrKnowledge() async throws {
        let store = try await openStore()
        let seeded = try await seedTask(store, text: "整理检索质量的证据。", title: "整理检索质量")
        _ = try await store.enqueueRecordingFollowup(sourceID: seeded.sourceID)
        let execution = try await store.enqueueAssistantExecution(actionID: seeded.action.id, expectedVersion: seeded.action.version)
        let knowledgeSourceID = try await seedKnowledgeSource(store, text: String(repeating: "这是用于知识核查的完整个人原话。", count: 40))
        let review = try await store.enqueueKnowledgeReview(sourceID: knowledgeSourceID)

        let snapshot = try await store.workspaceSnapshot(.coreSecondary)
        XCTAssertFalse(snapshot.sources.isEmpty)
        XCTAssertFalse(snapshot.actions.isEmpty)
        XCTAssertFalse(snapshot.recordingFollowups.isEmpty)
        XCTAssertTrue(snapshot.followupValidity.isEmpty)
        XCTAssertTrue(snapshot.assistantExecutions.isEmpty)
        XCTAssertTrue(snapshot.assistantAssessmentIssues.isEmpty)
        XCTAssertTrue(snapshot.knowledgeReviews.isEmpty)

        let core = try await store.workspaceSnapshot(.core)
        let secondary = try await store.workspaceSnapshot(.secondary)
        XCTAssertEqual(Set(snapshot.sources.map(\.id)), Set(core.sources.map(\.id)))
        XCTAssertEqual(Set(snapshot.actions.map(\.id)), Set(core.actions.map(\.id)))
        XCTAssertEqual(Set(snapshot.recordingFollowups.map(\.id)), Set(secondary.recordingFollowups.map(\.id)))

        let assistant = try await store.workspaceSnapshot(.assistant)
        XCTAssertEqual(assistant.assistantExecutions.count, 1)
        XCTAssertTrue(assistant.assistantExecutions.contains { $0.id == execution.id })
        let knowledge = try await store.workspaceSnapshot(.knowledge)
        XCTAssertEqual(knowledge.knowledgeReviews.count, 1)
        XCTAssertTrue(knowledge.knowledgeReviews.contains { $0.id == review.id })
    }
}
