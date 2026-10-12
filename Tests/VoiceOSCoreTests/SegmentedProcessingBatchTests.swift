import XCTest
import CryptoKit
@testable import VoiceOSCore

private struct BatchInspector: MediaInspector {
    func inspect(_ url: URL) async throws -> MediaInfo { .init(duration:2,kind:"audio") }
}
private struct BatchSpeech: SpeechPort {
    func transcribe(_ url: URL, locale: String) async throws -> SpeechText {
        let text = String(repeating:"原话。",count:2000)
        return .init(text:text,spans:[TranscriptSpan(textStart:0,textEnd:text.unicodeScalars.count,startMS:0,endMS:2000)])
    }
}
final class SegmentedProcessingBatchTests: XCTestCase {
    var base: URL!
    override func setUpWithError() throws { base = FileManager.default.temporaryDirectory.appendingPathComponent("batch-"+UUID().uuidString) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at:base) }
    func config(_ model: String = "fixture", destination: ModelDestination = .local) -> ModelConfiguration {
        .init(provider:"batch-test",model:model,promptVersion:"v1",schemaVersion:"v1",destination:destination)
    }
    func store(_ folder: String = "root", checkpoint: @escaping @Sendable (SaveCheckpoint) throws -> Void = {_ in}) async throws -> VoiceOSStore {
        let s = try VoiceOSStore(root:base.appendingPathComponent(folder),inspector:BatchInspector(),checkpoint:checkpoint)
        try await s.recover(); return s
    }
    func seed(_ s: VoiceOSStore) async throws -> String {
        let root = await s.root, file = root.appendingPathComponent("fixture.wav")
        try Data("synthetic batch inspector fixture".utf8).write(to:file)
        let id = try await s.importPersonalAudio(file)
        try await s.processTranscriptions(using:BatchSpeech()); return id
    }
    func prepare(_ s: VoiceOSStore,_ id: String) async throws -> SegmentedExpressionProcessingScope {
        try await s.prepareSegmentedExpressionProcessingScope(sourceID:id,extraction:config(),aggregation:config())
    }
    func enqueue(_ s: VoiceOSStore,_ scope: SegmentedExpressionProcessingScope) async throws -> SegmentedProcessingBatch {
        try await s.enqueueSegmentedProcessingBatch(scope,commandID:"batch-command",extraction:config(),aggregation:config())
    }
    func testSemanticReplayAndCancellationCreateNoProductEntities() async throws {
        let s = try await store(), id = try await seed(s), a = try await prepare(s,id), batch = try await enqueue(s,a)
        let b = try await prepare(s,id), replay = try await enqueue(s,b)
        XCTAssertNotEqual(a.id,b.id); XCTAssertEqual(batch.id,replay.id)
        let cancelled = try await s.cancelSegmentedProcessingBatch(id:batch.id)
        XCTAssertEqual(cancelled.state,.cancelled)
        let repeated = try await enqueue(s,b), checked = try await s.checkSegmentedProcessingBatch(id:batch.id,extraction:config(),aggregation:config())
        XCTAssertEqual(repeated.state,.cancelled); XCTAssertEqual(checked.state,.cancelled)
        let attempts = try await s.modelAttempts(), intents = try await s.processingIntents(), actions = try await s.actions()
        XCTAssertTrue(attempts.isEmpty); XCTAssertTrue(intents.isEmpty); XCTAssertTrue(actions.isEmpty)
        let policy = try await s.sourcePolicy(sourceID:id); XCTAssertTrue(policy.localOnly); XCTAssertEqual(policy.version,1)
    }
    func testChangedCommandPayloadAndModelConfigurationCannotExpandBatch() async throws {
        let s = try await store(), id = try await seed(s), original = try await prepare(s,id), batch = try await enqueue(s,original)
        let changed = try await s.prepareSegmentedExpressionProcessingScope(sourceID:id,extraction:config(),aggregation:config(),segmentScalarBudget:2000)
        do { _ = try await enqueue(s,changed); XCTFail() } catch {}
        let blocked = try await s.checkSegmentedProcessingBatch(id:batch.id,extraction:config("different"),aggregation:config())
        XCTAssertEqual(blocked.state,.blocked)
        let again = try await s.checkSegmentedProcessingBatch(id:batch.id,extraction:config(),aggregation:config())
        XCTAssertEqual(again.state,.blocked)
    }
    func testCorrectionKeepsOriginalHistoricalReceiptAndBlocksCurrentUse() async throws {
        let s = try await store(), id = try await seed(s), scope = try await prepare(s,id), batch = try await enqueue(s,scope)
        _ = try await s.correctTranscript(sourceID:id,expectedVersionID:scope.plan.source.transcriptVersionID,text:"更正后的文字")
        let old = try await enqueue(s,scope); XCTAssertEqual(old.id,batch.id)
        let current = try await s.checkSegmentedProcessingBatch(id:batch.id,extraction:config(),aggregation:config())
        XCTAssertEqual(current.state,.blocked)
        let rows = try await s.segmentedProcessingBatches(); XCTAssertEqual(rows[0].scope.plan.source.text,scope.plan.source.text)
    }
    func testRestartKeepsUnsentQueuedBatchAndDetectsRevocationWithoutCalls() async throws {
        var batchID = ""
        do {
            let s = try await store(), id = try await seed(s), cloud = config(destination:.cloud)
            _ = try await s.setSourceLocalOnly(sourceID:id,expectedVersion:1,localOnly:false)
            let scope = try await s.prepareSegmentedExpressionProcessingScope(sourceID:id,extraction:cloud,aggregation:cloud)
            batchID = try await s.enqueueSegmentedProcessingBatch(scope,commandID:"cloud-batch",extraction:cloud,aggregation:cloud).id
            _ = try await s.setSourceLocalOnly(sourceID:id,expectedVersion:2,localOnly:true)
        }
        let s = try await store(), batch = try await s.segmentedProcessingBatch(id:batchID)
        XCTAssertEqual(batch.state,.blocked)
        let attempts = try await s.modelAttempts(); XCTAssertTrue(attempts.isEmpty)
    }
    func testQueueAndCancelTransactionBoundaries() async throws {
        for point in [SaveCheckpoint.segmentedBatchUncommitted,.segmentedBatchCommitted,.segmentedBatchCancelUncommitted,.segmentedBatchCancelCommitted] {
            let s = try await store(point.rawValue,checkpoint:{ if $0 == point { throw VoiceOSError("synthetic interruption") } })
            let id = try await seed(s), scope = try await prepare(s,id)
            if point == .segmentedBatchUncommitted || point == .segmentedBatchCommitted {
                do { _ = try await enqueue(s,scope); XCTFail() } catch {}
                let batches = try await s.segmentedProcessingBatches()
                XCTAssertEqual(batches.count,point == .segmentedBatchUncommitted ? 0 : 1)
            } else {
                let batch = try await enqueue(s,scope)
                do { _ = try await s.cancelSegmentedProcessingBatch(id:batch.id); XCTFail() } catch {}
                let read = try await s.segmentedProcessingBatch(id:batch.id)
                XCTAssertEqual(read.state,point == .segmentedBatchCancelUncommitted ? .queued : .cancelled)
            }
        }
    }
    func testNewPackageFreezesBatchAndRetainsHistoryAfterCorrection() async throws {
        let s = try await store(), id = try await seed(s), scope = try await prepare(s,id), batch = try await enqueue(s,scope)
        _ = try await s.correctTranscript(sourceID:id,expectedVersionID:scope.plan.source.transcriptVersionID,text:"更正后的文字")
        let package = base.appendingPathComponent("package")
        try await s.exportPackage(to:package,includeMedia:false)
        XCTAssertEqual(try VoiceOSStore.packageSummary(at:package).version,27)
        try await VoiceOSStore.restorePackage(from:package,to:base.appendingPathComponent("restored"),inspector:BatchInspector())
        let restored = try await store("restored"), frozen = try await restored.segmentedProcessingBatch(id:batch.id)
        XCTAssertEqual(frozen.state,.frozen); XCTAssertEqual(frozen.scope.plan.source.text,scope.plan.source.text)
        let replay = try await enqueue(restored,scope); XCTAssertEqual(replay.state,.frozen)
    }
    func testForgedPlanRejectedEvenAfterRecomputingAllTransportDigests() async throws {
        let s = try await store(), id = try await seed(s), scope = try await prepare(s,id)
        _ = try await enqueue(s,scope)
        let package = base.appendingPathComponent("tampered")
        try await s.exportPackage(to:package,includeMedia:true)
        let file = package.appendingPathComponent("segmented_processing_batches.jsonl")
        var row = try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any]
        var json = try JSONSerialization.jsonObject(with:Data((row["scope_json"] as! String).utf8)) as! [String:Any]
        var plan = json["plan"] as! [String:Any], segments = plan["segments"] as! [[String:Any]]
        segments[0]["text"] = "伪造的原话"; plan["segments"] = segments; json["plan"] = plan
        let decoded = try JSONDecoder().decode(SegmentedExpressionProcessingScope.self,from:JSONSerialization.data(withJSONObject:json))
        let forged = SegmentedExpressionProcessingScope(id:decoded.id,plan:decoded.plan,extraction:decoded.extraction,aggregation:decoded.aggregation,
            evidenceScalarBudget:decoded.evidenceScalarBudget,contentDigest:try VoiceOSStore.segmentedScopeDigest(plan:decoded.plan,
                extraction:decoded.extraction,aggregation:decoded.aggregation,evidenceBudget:decoded.evidenceScalarBudget))
        row["scope_json"] = try VoiceOSStore.relevanceJSON(forged)
        row["scope_digest"] = try VoiceOSStore.segmentedStoredDigest(forged)
        row["command_fingerprint"] = try VoiceOSStore.segmentedCommandFingerprint(forged)
        let data = try JSONSerialization.data(withJSONObject:row,options:[.sortedKeys]) + Data([10]); try data.write(to:file)
        let manifestURL = package.appendingPathComponent("manifest.json")
        var manifest = try JSONSerialization.jsonObject(with:Data(contentsOf:manifestURL)) as! [String:Any]
        var files = manifest["files"] as! [[String:Any]]
        let index = files.firstIndex(where: { $0["path"] as? String == file.lastPathComponent })!
        files[index]["bytes"] = data.count
        files[index]["sha256"] = SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
        manifest["files"] = files; try JSONSerialization.data(withJSONObject:manifest).write(to:manifestURL)
        do { try await VoiceOSStore.restorePackage(from:package,to:base.appendingPathComponent("reject"),inspector:BatchInspector()); XCTFail() } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath:base.appendingPathComponent("reject").path))
    }
    func testInvalidImportedStateCannotBeHiddenByMigrationFreeze() async throws {
        let s = try await store(), id = try await seed(s), scope = try await prepare(s,id)
        _ = try await enqueue(s,scope)
        let package = base.appendingPathComponent("state-tampered")
        try await s.exportPackage(to:package)
        let file = package.appendingPathComponent("segmented_processing_batches.jsonl")
        var row = try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any]
        row["state"] = "pretend_completed"
        let data = try JSONSerialization.data(withJSONObject:row,options:[.sortedKeys]) + Data([10]); try data.write(to:file)
        let manifestURL = package.appendingPathComponent("manifest.json")
        var manifest = try JSONSerialization.jsonObject(with:Data(contentsOf:manifestURL)) as! [String:Any]
        var files = manifest["files"] as! [[String:Any]]
        let index = files.firstIndex(where: { $0["path"] as? String == file.lastPathComponent })!
        files[index]["bytes"] = data.count; files[index]["sha256"] = SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
        manifest["files"] = files; try JSONSerialization.data(withJSONObject:manifest).write(to:manifestURL)
        do { try await VoiceOSStore.restorePackage(from:package,to:base.appendingPathComponent("state-reject"),inspector:BatchInspector()); XCTFail() } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath:base.appendingPathComponent("state-reject").path))
    }
    func testSchema26UpgradesWithoutChangingEmptyPackageScope() async throws {
        do {
            let s = try await store()
            try await s.exportPackage(to:base.appendingPathComponent("empty"))
            XCTAssertEqual(try VoiceOSStore.packageSummary(at:base.appendingPathComponent("empty")).version,24)
        }
        do {
            let db = try Database(base.appendingPathComponent("root/voiceos.sqlite"))
            try db.execute("DROP TABLE segmented_processing_batches"); try db.execute("DROP TABLE reminder_schedule_operations"); try db.execute("DROP TABLE action_schedule_intents"); try db.execute("DROP TABLE reminder_time_observations"); try db.execute("DROP TABLE reminder_status_resolutions"); try db.execute("PRAGMA user_version=26")
        }
        let s = try await store(), batches = try await s.segmentedProcessingBatches()
        XCTAssertTrue(batches.isEmpty)
    }
}
