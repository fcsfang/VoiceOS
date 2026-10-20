import XCTest
@testable import VoiceOSCore

private struct ReviewInspector: MediaInspector {
    func inspect(_ url: URL) async throws -> MediaInfo { throw VoiceOSError("authored text only") }
}
private struct ReviewRetrieval: LocalRetrievalPort {
    func rank(query: String, documents: [RetrievalDocument], semantic: Bool) async throws -> [RetrievalMatch] {
        documents.map { .init(documentID: $0.id, score: 1, method: "exact") }
    }
}
private actor ReviewModel: ModelPort {
    let configuration: ModelConfiguration
    private(set) var calls = 0
    init(_ config: ModelConfiguration) { configuration = config }
    func generate(_ request: ModelRequest) async throws -> ModelResponse {
        calls += 1
        return .init(status: .completed, claims: [], inputTokens: 3, outputTokens: 2)
    }
    func count() -> Int { calls }
}
private actor ReviewAssociation: ExpressionAssociationPort {
    let configuration: ModelConfiguration
    private var calls = 0
    init(_ config: ModelConfiguration) { configuration = config }
    func associate(_ request: ExpressionAssociationRequest) async throws -> ExpressionAssociationResponse {
        calls += 1
        return .init(proposals: [], inputTokens: 4, outputTokens: 1)
    }
    func count() -> Int { calls }
}
private struct ReviewFailingModel: ModelPort {
    let configuration: ModelConfiguration
    func generate(_ request: ModelRequest) async throws -> ModelResponse { throw VoiceOSError("synthetic transport interruption") }
}

final class ExpressionProcessingReviewRegressionTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-review-" + UUID().uuidString) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func config(_ version: String = "v1") -> ModelConfiguration {
        .init(provider: "review-fixture", model: "synthetic", promptVersion: version, schemaVersion: "v1", destination: .cloud)
    }
    private func setup() async throws -> (VoiceOSStore, String) {
        let store = try VoiceOSStore(root: root, inspector: ReviewInspector())
        try await store.recover()
        let source = try await store.recordUserExpression("离线审核合成个人文字")
        _ = try await store.setSourceLocalOnly(sourceID: source, expectedVersion: 1, localOnly: false)
        return (store, source)
    }
    func testReplayWithRepreparedSnapshotShouldReturnOriginalIntent() async throws {
        let (store, source) = try await setup(), configuration = config()
        let snapshot = try await store.prepareExpressionProcessingIntent(sourceID: source, cognition: configuration, association: configuration)
        let first = try await store.enqueueExpressionProcessingIntent(snapshot, commandID: "stable-command", cognition: configuration, association: configuration)
        let replaySnapshot = try await store.prepareExpressionProcessingIntent(sourceID: source, cognition: configuration, association: configuration)
        let replay = try await store.enqueueExpressionProcessingIntent(replaySnapshot, commandID: "stable-command", cognition: configuration, association: configuration)
        XCTAssertEqual(replay.id, first.id)
    }
    func testReusedCognitionShouldKeepActualAttemptIdentityAcrossConfigChange() async throws {
        let (store, source) = try await setup()
        _ = try await store.understandSource(sourceID: source, using: ReviewModel(config()))
        let prior = try await store.modelAttempts(sourceID: source)
        let upgraded = config("v2"), port = ReviewModel(upgraded)
        let snapshot = try await store.prepareExpressionProcessingIntent(sourceID: source, cognition: upgraded, association: upgraded)
        let intent = try await store.enqueueExpressionProcessingIntent(snapshot, commandID: "reuse-command", cognition: upgraded, association: upgraded)
        let result = try await store.runExpressionProcessingIntent(id: intent.id, retrieval: ReviewRetrieval(), cognitionPort: port, associationPort: ReviewAssociation(upgraded))
        XCTAssertEqual(result.state, .completed)
        let calls = await port.count(); XCTAssertEqual(calls, 0)
        XCTAssertEqual(result.cognitionAttemptID, prior.first?.id)
    }
    func testKnownCompletedCognitionRecoveryShouldNotBecomeUnknown() async throws {
        let id = try await { () async throws -> String in
            let (store, source) = try await setup(), configuration = config()
            let old = try await store.recordUserExpression("历史候选")
            _ = try await store.setSourceLocalOnly(sourceID: old, expectedVersion: 1, localOnly: false)
            let snapshot = try await store.prepareExpressionProcessingIntent(sourceID: source, cognition: configuration, association: configuration)
            let intent = try await store.enqueueExpressionProcessingIntent(snapshot, commandID: "recover-command", cognition: configuration, association: configuration)
            _ = try await store.understandSource(sourceID: source, using: ReviewModel(configuration))
            let database = try Database(root.appendingPathComponent("voiceos.sqlite"))
            try database.execute("UPDATE processing_intents SET state='running',phase='association' WHERE id=?", [intent.id])
            return intent.id
        }()
        let reopened = try VoiceOSStore(root: root, inspector: ReviewInspector())
        try await reopened.recover()
        let result = try await reopened.processingIntent(id: id)
        XCTAssertEqual(result.state, .queued); XCTAssertEqual(result.phase, .association)
        XCTAssertNotNil(result.cognitionAttemptID); XCTAssertNil(result.associationAttemptID)
        let model = ReviewModel(config()), association = ReviewAssociation(config())
        let completed = try await reopened.runExpressionProcessingIntent(id: id, retrieval: ReviewRetrieval(), cognitionPort: model, associationPort: association)
        XCTAssertEqual(completed.state, .completed)
        let cognitionCalls = await model.count(), associationCalls = await association.count()
        XCTAssertEqual(cognitionCalls, 0); XCTAssertEqual(associationCalls, 1)
    }
    func testLegacySchema25FingerprintRemainsReadableAndIdempotent() async throws {
        let (store, source) = try await setup(), configuration = config()
        let snapshot = try await store.prepareExpressionProcessingIntent(sourceID: source, cognition: configuration, association: configuration)
        let first = try await store.enqueueExpressionProcessingIntent(snapshot, commandID: "legacy-command", cognition: configuration, association: configuration)
        let database = try Database(root.appendingPathComponent("voiceos.sqlite"))
        try database.execute("UPDATE processing_intents SET command_fingerprint=snapshot_digest WHERE id=?", [first.id])
        let history = try await store.processingIntents(); XCTAssertEqual(history.count, 1)
        let prepared = try await store.prepareExpressionProcessingIntent(sourceID: source, cognition: configuration, association: configuration)
        let replay = try await store.enqueueExpressionProcessingIntent(prepared, commandID: "legacy-command", cognition: configuration, association: configuration)
        XCTAssertEqual(replay.id, first.id)
        let package = root.appendingPathComponent("legacy-package"), restoredRoot = root.appendingPathComponent("legacy-restored")
        try await store.exportPackage(to: package)
        try await VoiceOSStore.restorePackage(from: package, to: restoredRoot, inspector: ReviewInspector())
        let restored = try VoiceOSStore(root: restoredRoot, inspector: ReviewInspector()); try await restored.recover()
        let restoredIntents = try await restored.processingIntents()
        XCTAssertEqual(restoredIntents.first?.id, first.id); XCTAssertEqual(restoredIntents.first?.state, .frozen)
    }
    func testStableCommandStillRejectsChangedConfiguration() async throws {
        let (store, source) = try await setup(), configuration = config()
        let snapshot = try await store.prepareExpressionProcessingIntent(sourceID: source, cognition: configuration, association: configuration)
        _ = try await store.enqueueExpressionProcessingIntent(snapshot, commandID: "changed-command", cognition: configuration, association: configuration)
        let changed = config("v2")
        let changedSnapshot = try await store.prepareExpressionProcessingIntent(sourceID: source, cognition: changed, association: changed)
        do {
            _ = try await store.enqueueExpressionProcessingIntent(changedSnapshot, commandID: "changed-command", cognition: changed, association: changed)
            XCTFail("changed configuration cannot replay original command")
        } catch { XCTAssertTrue(error.localizedDescription.contains("不能更换内容")) }
    }
    func testUnknownCognitionRecoveryLinksReceiptAndNeverResends() async throws {
        let id = try await { () async throws -> String in
            let (store, source) = try await setup(), configuration = config()
            let snapshot = try await store.prepareExpressionProcessingIntent(sourceID: source, cognition: configuration, association: configuration)
            let intent = try await store.enqueueExpressionProcessingIntent(snapshot, cognition: configuration, association: configuration)
            let unknown = try await store.runExpressionProcessingIntent(id: intent.id, retrieval: ReviewRetrieval(), cognitionPort: ReviewFailingModel(configuration: configuration), associationPort: ReviewAssociation(configuration))
            XCTAssertEqual(unknown.state, .unknown); XCTAssertNotNil(unknown.cognitionAttemptID)
            let database = try Database(root.appendingPathComponent("voiceos.sqlite"))
            try database.execute("UPDATE processing_intents SET state='running',cognition_attempt_id=NULL WHERE id=?", [intent.id])
            return intent.id
        }()
        let reopened = try VoiceOSStore(root: root, inspector: ReviewInspector()); try await reopened.recover()
        let recovered = try await reopened.processingIntent(id: id)
        XCTAssertEqual(recovered.state, .unknown); XCTAssertNotNil(recovered.cognitionAttemptID)
        let model = ReviewModel(config()), association = ReviewAssociation(config())
        let replay = try await reopened.runExpressionProcessingIntent(id: id, retrieval: ReviewRetrieval(), cognitionPort: model, associationPort: association)
        XCTAssertEqual(replay.state, .unknown)
        let cognitionCalls = await model.count(), associationCalls = await association.count()
        XCTAssertEqual(cognitionCalls, 0); XCTAssertEqual(associationCalls, 0)
    }
    func testCorrectedAndRevokedHistoryRemainsPortable() async throws {
        let (store, source) = try await setup(), configuration = config()
        let snapshot = try await store.prepareExpressionProcessingIntent(sourceID: source, cognition: configuration, association: configuration)
        let intent = try await store.enqueueExpressionProcessingIntent(snapshot, cognition: configuration, association: configuration)
        let completed = try await store.runExpressionProcessingIntent(id: intent.id, retrieval: ReviewRetrieval(), cognitionPort: ReviewModel(configuration), associationPort: ReviewAssociation(configuration))
        let records = try await store.sources(), currentVersion = try XCTUnwrap(records.first?.transcriptVersionID)
        _ = try await store.correctTranscript(sourceID: source, expectedVersionID: currentVersion, text: "更正后的原话")
        _ = try await store.setSourceLocalOnly(sourceID: source, expectedVersion: 2, localOnly: true)
        let package = root.appendingPathComponent("corrected-package"), restoredRoot = root.appendingPathComponent("corrected-restored")
        try await store.exportPackage(to: package)
        try await VoiceOSStore.restorePackage(from: package, to: restoredRoot, inspector: ReviewInspector())
        let restored = try VoiceOSStore(root: restoredRoot, inspector: ReviewInspector()); try await restored.recover()
        let history = try await restored.processingIntents()
        XCTAssertEqual(history.first?.state, .frozen)
        XCTAssertEqual(history.first?.cognitionAttemptID, completed.cognitionAttemptID)
        XCTAssertEqual(history.first?.snapshot.context.sources[0].text, snapshot.context.sources[0].text)
    }
    func testRecoveryValidatesActualContextBeforeRelinkingUnrecordedReceipt() async throws {
        try await { () async throws -> Void in
            let (store, source) = try await setup(), configuration = config()
            let other = try await store.recordUserExpression("实际模型处理的是另一份原话")
            _ = try await store.setSourceLocalOnly(sourceID: other, expectedVersion: 1, localOnly: false)
            _ = try await store.understandSource(sourceID: other, using: ReviewModel(configuration))
            let snapshot = try await store.prepareExpressionProcessingIntent(sourceID: source, cognition: configuration, association: configuration)
            let intent = try await store.enqueueExpressionProcessingIntent(snapshot, cognition: configuration, association: configuration)
            let database = try Database(root.appendingPathComponent("voiceos.sqlite"))
            try database.execute("UPDATE processing_intents SET state='running' WHERE id=?", [intent.id])
            // Alter the catalog while leaving the actual model context untouched.
            // Scope-shaped SQL matches must not be treated as trustworthy receipts.
            try database.execute("UPDATE context_inputs SET source_id=?,transcript_version_id=? WHERE source_id=?", [source, snapshot.context.sources[0].transcriptVersionID, other])
        }()
        let reopened = try VoiceOSStore(root: root, inspector: ReviewInspector())
        do { try await reopened.recover(); XCTFail("mismatched context must not be relinked") }
        catch { XCTAssertTrue(error.localizedDescription.contains("回执") && error.localizedDescription.contains("绑定")) }
    }
    func testMigrationShouldRejectCognitionAttemptBelongingToAnotherSource() async throws {
        let (store, source) = try await setup(), configuration = config()
        let other = try await store.recordUserExpression("另一来源，不能充当本次理解回执")
        _ = try await store.setSourceLocalOnly(sourceID: other, expectedVersion: 1, localOnly: false)
        _ = try await store.understandSource(sourceID: other, using: ReviewModel(configuration))
        let otherAttempts = try await store.modelAttempts(sourceID: other)
        let otherAttempt = try XCTUnwrap(otherAttempts.first?.id)
        let snapshot = try await store.prepareExpressionProcessingIntent(sourceID: source, cognition: configuration, association: configuration)
        let intent = try await store.enqueueExpressionProcessingIntent(snapshot, commandID: "migration-command", cognition: configuration, association: configuration)
        _ = try await store.runExpressionProcessingIntent(id: intent.id, retrieval: ReviewRetrieval(), cognitionPort: ReviewModel(configuration), associationPort: ReviewAssociation(configuration))
        let package = root.appendingPathComponent("package")
        try await store.exportPackage(to: package)
        let file = package.appendingPathComponent("processing_intents.jsonl")
        var row = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        row["cognition_attempt_id"] = otherAttempt
        var bytes = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]); bytes.append(0x0A)
        try bytes.write(to: file)
        let manifestFile = package.appendingPathComponent("manifest.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestFile)) as? [String: Any])
        var files = try XCTUnwrap(manifest["files"] as? [[String: Any]])
        let index = try XCTUnwrap(files.firstIndex { $0["path"] as? String == "processing_intents.jsonl" })
        let digest = try DurableFiles.hash(file)
        files[index]["bytes"] = digest.0; files[index]["sha256"] = digest.1; manifest["files"] = files
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: manifestFile)
        do {
            try await VoiceOSStore.restorePackage(from: package, to: root.appendingPathComponent("restored"), inspector: ReviewInspector())
            XCTFail("Migration accepted a cognition receipt belonging to another source")
        } catch { XCTAssertTrue(error.localizedDescription.contains("回执") && error.localizedDescription.contains("绑定")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("restored").path))
    }
}
