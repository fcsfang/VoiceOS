import XCTest
@testable import VoiceOSCore

private struct QueueInspector: MediaInspector {
    func inspect(_ url: URL) async throws -> MediaInfo { throw VoiceOSError("queue test uses authored text") }
}
private struct QueueRetrieval: LocalRetrievalPort {
    func rank(query: String, documents: [RetrievalDocument], semantic: Bool) async throws -> [RetrievalMatch] {
        documents.map { RetrievalMatch(documentID: $0.id, score: 1, method: "exact") }
    }
}
private actor QueueModel: ModelPort {
    let configuration: ModelConfiguration
    private(set) var calls = 0
    init(_ configuration: ModelConfiguration) { self.configuration = configuration }
    func generate(_ request: ModelRequest) async throws -> ModelResponse {
        calls += 1; return ModelResponse(status: .completed, claims: [], inputTokens: 3, outputTokens: 2)
    }
    func callCount() -> Int { calls }
}
private actor QueueAssociation: ExpressionAssociationPort {
    let configuration: ModelConfiguration
    private(set) var calls = 0
    init(_ configuration: ModelConfiguration) { self.configuration = configuration }
    func associate(_ request: ExpressionAssociationRequest) async throws -> ExpressionAssociationResponse {
        calls += 1; return ExpressionAssociationResponse(proposals: [], inputTokens: 4, outputTokens: 1)
    }
    func callCount() -> Int { calls }
}

final class ExpressionProcessingQueueTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent("processing-queue-" + UUID().uuidString) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func config() -> ModelConfiguration { .init(provider: "queue-fixture", model: "synthetic", promptVersion: "v1", schemaVersion: "v1", destination: .cloud) }

    func testExplicitQueueRunsOnceAndPersistsIdentity() async throws {
        let store = try VoiceOSStore(root: root, inspector: QueueInspector()); try await store.recover()
        let old = try await store.recordUserExpression("历史表达")
        let current = try await store.recordUserExpression("本次表达需要理解并关联历史")
        for source in [old, current] { _ = try await store.setSourceLocalOnly(sourceID: source, expectedVersion: 1, localOnly: false) }
        let configuration = config()
        let snapshot = try await store.prepareExpressionProcessingIntent(sourceID: current, cognition: configuration, association: configuration)
        let first = try await store.enqueueExpressionProcessingIntent(snapshot, commandID: "queue-command", cognition: configuration, association: configuration)
        let replay = try await store.enqueueExpressionProcessingIntent(snapshot, commandID: "queue-command", cognition: configuration, association: configuration)
        XCTAssertEqual(first.id, replay.id); XCTAssertEqual(first.state, .queued)
        let model = QueueModel(configuration), association = QueueAssociation(configuration)
        let result = try await store.runExpressionProcessingIntent(id: first.id, retrieval: QueueRetrieval(), cognitionPort: model, associationPort: association)
        XCTAssertEqual(result.state, .completed)
        let firstModelCalls = await model.callCount(), firstAssociationCalls = await association.callCount()
        XCTAssertEqual(firstModelCalls, 1); XCTAssertEqual(firstAssociationCalls, 1)
        let second = try await store.runExpressionProcessingIntent(id: first.id, retrieval: QueueRetrieval(), cognitionPort: model, associationPort: association)
        XCTAssertEqual(second.state, .completed)
        let secondModelCalls = await model.callCount(), secondAssociationCalls = await association.callCount()
        XCTAssertEqual(secondModelCalls, 1); XCTAssertEqual(secondAssociationCalls, 1)
        let package = root.appendingPathComponent("package")
        try await store.exportPackage(to: package)
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.appendingPathComponent("processing_intents.jsonl").path))
        let restoredRoot = root.appendingPathComponent("restored")
        try await VoiceOSStore.restorePackage(from: package, to: restoredRoot, inspector: QueueInspector())
        let restored = try VoiceOSStore(root: restoredRoot, inspector: QueueInspector()); try await restored.recover()
        let history = try await restored.processingIntents()
        XCTAssertEqual(history.count, 1); XCTAssertEqual(history[0].state, .frozen)
    }

    func testQueueCancellationIsDurableAndDoesNotDispatch() async throws {
        let store = try VoiceOSStore(root: root, inspector: QueueInspector()); try await store.recover()
        let source = try await store.recordUserExpression("明确取消的表达")
        _ = try await store.setSourceLocalOnly(sourceID: source, expectedVersion: 1, localOnly: false)
        let configuration = config(), snapshot = try await store.prepareExpressionProcessingIntent(sourceID: source, cognition: configuration, association: configuration)
        let queued = try await store.enqueueExpressionProcessingIntent(snapshot, commandID: "cancel-command", cognition: configuration, association: configuration)
        let cancelled = try await store.cancelExpressionProcessingIntent(id: queued.id, reason: "测试取消")
        XCTAssertEqual(cancelled.state, .cancelled); XCTAssertEqual(cancelled.cancelReason, "测试取消")
        let model = QueueModel(configuration), association = QueueAssociation(configuration)
        let result = try await store.runExpressionProcessingIntent(id: queued.id, retrieval: QueueRetrieval(), cognitionPort: model, associationPort: association)
        let modelCalls = await model.callCount(), associationCalls = await association.callCount()
        XCTAssertEqual(result.state, .cancelled); XCTAssertEqual(modelCalls, 0); XCTAssertEqual(associationCalls, 0)
    }
}
