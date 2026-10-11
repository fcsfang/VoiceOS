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
private actor BlockingQueueModel: ModelPort {
    let configuration: ModelConfiguration
    private var started = false
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private(set) var calls = 0
    init(_ configuration: ModelConfiguration) { self.configuration = configuration }
    func generate(_ request: ModelRequest) async throws -> ModelResponse {
        calls += 1; started = true; startedWaiter?.resume(); startedWaiter = nil
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in releaseWaiter = continuation }
        let source = request.context.sources[0]
        let reference = ClaimReference(sourceID: source.sourceID, transcriptVersionID: source.transcriptVersionID, spanID: source.spans[0].id)
        return ModelResponse(status: .completed, claims: [ClaimProposal(statement: "取消后的迟到候选", ownership: .userTentative, references: [reference])], inputTokens: 3, outputTokens: 2)
    }
    func waitStarted() async { if !started { await withCheckedContinuation { startedWaiter = $0 } } }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
    func callCount() -> Int { calls }
}
private actor BlockingQueueAssociation: ExpressionAssociationPort {
    let configuration: ModelConfiguration
    private var started = false
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private(set) var calls = 0
    init(_ configuration: ModelConfiguration) { self.configuration = configuration }
    func associate(_ request: ExpressionAssociationRequest) async throws -> ExpressionAssociationResponse {
        calls += 1; started = true; startedWaiter?.resume(); startedWaiter = nil
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in releaseWaiter = continuation }
        return ExpressionAssociationResponse(proposals: [], inputTokens: 4, outputTokens: 2)
    }
    func waitStarted() async { if !started { await withCheckedContinuation { startedWaiter = $0 } } }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
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

    func testCancellationDuringCognitionFreezesLateResultAndSkipsAssociation() async throws {
        let store = try VoiceOSStore(root: root, inspector: QueueInspector()); try await store.recover()
        let source = try await store.recordUserExpression("认知途中取消的表达")
        _ = try await store.setSourceLocalOnly(sourceID: source, expectedVersion: 1, localOnly: false)
        let configuration = config()
        let snapshot = try await store.prepareExpressionProcessingIntent(sourceID: source, cognition: configuration, association: configuration)
        let intent = try await store.enqueueExpressionProcessingIntent(snapshot, commandID: "cancel-during-cognition", cognition: configuration, association: configuration)
        let model = BlockingQueueModel(configuration), association = QueueAssociation(configuration)
        let running = Task { try await store.runExpressionProcessingIntent(id: intent.id, retrieval: QueueRetrieval(), cognitionPort: model, associationPort: association) }
        await model.waitStarted()
        let cancelled = try await store.cancelExpressionProcessingIntent(id: intent.id, reason: "认知途中取消")
        XCTAssertEqual(cancelled.state, .cancelled)
        await model.release()
        let result = try await running.value
        XCTAssertEqual(result.state, .cancelled)
        let modelCalls = await model.callCount(), associationCalls = await association.callCount()
        XCTAssertEqual(modelCalls, 1); XCTAssertEqual(associationCalls, 0)
        let attempts = try await store.modelAttempts(sourceID: source)
        XCTAssertEqual(attempts.count, 1); XCTAssertEqual(attempts[0].state, "completed"); XCTAssertEqual(attempts[0].contextState, "stale")
        let currentClaims = try await store.candidateClaims(), allClaims = try await store.candidateClaims(includeFrozen: true)
        XCTAssertTrue(currentClaims.isEmpty)
        XCTAssertEqual(allClaims.count, 1)
    }

    func testCancellationDuringAssociationFreezesLateAssociationReceipt() async throws {
        let store = try VoiceOSStore(root: root, inspector: QueueInspector()); try await store.recover()
        let old = try await store.recordUserExpression("关联候选历史表达")
        let source = try await store.recordUserExpression("关联途中取消的表达")
        for id in [old, source] { _ = try await store.setSourceLocalOnly(sourceID: id, expectedVersion: 1, localOnly: false) }
        let configuration = config()
        let snapshot = try await store.prepareExpressionProcessingIntent(sourceID: source, cognition: configuration, association: configuration)
        let intent = try await store.enqueueExpressionProcessingIntent(snapshot, commandID: "cancel-during-association", cognition: configuration, association: configuration)
        let model = QueueModel(configuration), association = BlockingQueueAssociation(configuration)
        let running = Task { try await store.runExpressionProcessingIntent(id: intent.id, retrieval: QueueRetrieval(), cognitionPort: model, associationPort: association) }
        await association.waitStarted()
        let cancelled = try await store.cancelExpressionProcessingIntent(id: intent.id, reason: "关联途中取消")
        XCTAssertEqual(cancelled.state, .cancelled)
        await association.release()
        let result = try await running.value
        XCTAssertEqual(result.state, .cancelled)
        let associationCalls = await association.callCount(); XCTAssertEqual(associationCalls, 1)
        let attempts = try await store.expressionAssociationAttempts()
        XCTAssertEqual(attempts.count, 1); XCTAssertEqual(attempts[0].state, "completed"); XCTAssertEqual(attempts[0].validity, "frozen")
    }

    func testRestoreRejectsTamperedProcessingIntentEvenWhenManifestChecksumIsUpdated() async throws {
        let store = try VoiceOSStore(root: root, inspector: QueueInspector()); try await store.recover()
        let source = try await store.recordUserExpression("迁移包篡改测试表达")
        _ = try await store.setSourceLocalOnly(sourceID: source, expectedVersion: 1, localOnly: false)
        let configuration = config()
        let snapshot = try await store.prepareExpressionProcessingIntent(sourceID: source, cognition: configuration, association: configuration)
        _ = try await store.enqueueExpressionProcessingIntent(snapshot, commandID: "tampered-processing-command", cognition: configuration, association: configuration)

        let package = root.appendingPathComponent("tampered-processing-package")
        try await store.exportPackage(to: package)
        let intentsFile = package.appendingPathComponent("processing_intents.jsonl")
        var intent = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: intentsFile)) as? [String: Any])
        intent["snapshot_digest"] = String(repeating: "0", count: 64)
        var bytes = try JSONSerialization.data(withJSONObject: intent, options: [.sortedKeys]); bytes.append(0x0A)
        try bytes.write(to: intentsFile)

        let manifestFile = package.appendingPathComponent("manifest.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestFile)) as? [String: Any])
        var files = try XCTUnwrap(manifest["files"] as? [[String: Any]])
        let index = try XCTUnwrap(files.firstIndex { $0["path"] as? String == "processing_intents.jsonl" })
        let digest = try DurableFiles.hash(intentsFile)
        files[index]["bytes"] = digest.0; files[index]["sha256"] = digest.1; manifest["files"] = files
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: manifestFile)

        let target = root.appendingPathComponent("tampered-processing-restored")
        do {
            try await VoiceOSStore.restorePackage(from: package, to: target, inspector: QueueInspector())
            XCTFail("tampered processing intent must be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("处理意图") || error.localizedDescription.contains("摘要"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }
}
