import XCTest
@testable import VoiceOSCore
import VoiceOSPlatform

private struct QuietAssistantPort: AssistantModelPort {
    let configuration = ModelConfiguration(provider: "fixture", model: "assistant-idle", promptVersion: "v1", schemaVersion: "v1", destination: .local)
    func assess(_ input: AssistantTaskInput) async throws -> AssistantAssessment {
        .init(explicitDelegation: true, supported: true, kind: .draft, reason: "夹具")
    }
    func execute(_ request: AssistantExecutionRequest) async throws -> AssistantExecutionResult {
        .init(title: request.input.title, markdown: "# 夹具\n\n不应被调用。", responseID: UUID().uuidString)
    }
}

final class AssistantShortCircuitChecks: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-assistant-idle-" + UUID().uuidString)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }
    private func openStore() async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }
    private func seedTask(_ store: VoiceOSStore, text: String, title: String) async throws -> (sourceID: String, action: ActionRecord) {
        let sourceID = try await store.recordUserExpression(text)
        _ = try await store.setSourceLocalOnly(sourceID: sourceID, expectedVersion: 1, localOnly: false)
        let context = try await store.prepareLocalTranscriptContext(sourceIDs: [sourceID])
        let item = try XCTUnwrap(context.sources.first)
        _ = try await store.importOrganizedClaims(context: context, proposals: [
            .init(statement: text, ownership: .userTentative,
                  references: [.init(sourceID: sourceID, transcriptVersionID: item.transcriptVersionID, spanID: item.spans[0].id)],
                  action: .init(title: title, kind: .task, quote: text))
        ], commandID: "assistant-idle-" + sourceID)
        let actions = try await store.actions()
        return (sourceID, try XCTUnwrap(actions.first { $0.title == title }))
    }

    /// With the published list holding no queued or running work, both entry
    /// points return before the full revalidation read. The full path stays for
    /// callers without a snapshot hint, so stale rows still freeze.
    func testIdlePublishedListSkipsProcessAndDiscoveryValidation() async throws {
        let store = try await openStore()
        let seeded = try await seedTask(store, text: "请帮我整理检索质量。", title: "整理检索质量")
        let queued = try await store.enqueueAssistantExecution(actionID: seeded.action.id, expectedVersion: seeded.action.version)
        let db = await store.db
        try db.execute("UPDATE assistant_executions SET state='completed',updated_at=? WHERE id=?", ["2026-11-17T00:00:00Z", queued.id])
        let snapshot = try await store.workspaceSnapshot(.assistant)
        XCTAssertEqual(snapshot.assistantExecutions.first { $0.id == queued.id }?.state, "completed")
        XCTAssertNotNil(snapshot.assistantValidation)

        _ = try await store.setSourceLocalOnly(sourceID: seeded.sourceID, expectedVersion: 2, localOnly: true)
        let port = QuietAssistantPort()
        let skippedProcess = try await store.processNextAssistantExecution(using: port, snapshot: snapshot)
        XCTAssertFalse(skippedProcess)
        let skippedDiscovery = try await store.discoverAutomaticAssistantExecutions(using: port, snapshot: snapshot)
        XCTAssertFalse(skippedDiscovery)
        let untouched = try XCTUnwrap(db.query("SELECT validity,state FROM assistant_executions WHERE id=?", [queued.id]).first)
        XCTAssertEqual(untouched["validity"], "current", "无排队时快照提示应短路，不再全表校验")
        XCTAssertEqual(untouched["state"], "completed")

        _ = try await store.processNextAssistantExecution(using: port)
        let validated = try XCTUnwrap(db.query("SELECT validity FROM assistant_executions WHERE id=?", [queued.id]).first)
        XCTAssertEqual(validated["validity"], "frozen", "没有快照提示时仍执行完整校验")
    }
}
