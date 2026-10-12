import XCTest
import AVFoundation
@testable import VoiceOSCore
import VoiceOSPlatform

private struct RequestSpeech: SpeechPort {
    var text = "我会整理测试资料"
    var fails = false
    func transcribe(_ url: URL, locale: String) async throws -> SpeechText {
        if fails { throw VoiceOSError("synthetic local speech failure") }
        return SpeechText(text: text)
    }
}
private struct RequestModel: ModelPort {
    let configuration: ModelConfiguration
    func generate(_ request: ModelRequest) async throws -> ModelResponse { ModelResponse(status:.completed,claims:[]) }
}
private struct RequestAssociation: ExpressionAssociationPort {
    let configuration: ModelConfiguration
    func associate(_ request: ExpressionAssociationRequest) async throws -> ExpressionAssociationResponse { .init(proposals:[]) }
}
private struct RequestRetrieval: LocalRetrievalPort {
    func rank(query: String, documents: [RetrievalDocument], semantic: Bool) async throws -> [RetrievalMatch] { [] }
}
final class RecordingProcessingRequestTests: XCTestCase {
    var base: URL!
    override func setUpWithError() throws { base = FileManager.default.temporaryDirectory.appendingPathComponent("record-request-"+UUID().uuidString) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at:base) }
    func configuration(_ model: String = "fixture") -> ModelConfiguration { .init(provider:"fixture",model:model,promptVersion:"v1",schemaVersion:"v1",destination:.cloud) }
    func store(_ folder: String = "root", checkpoint: @escaping @Sendable (SaveCheckpoint) throws -> Void = {_ in}) async throws -> VoiceOSStore {
        let s = try VoiceOSStore(root:base.appendingPathComponent(folder),inspector:NativeMediaInspector(),checkpoint:checkpoint)
        try await s.recover(); return s
    }
    func seal(_ s: VoiceOSStore, _ intent: RecordingIntent) async throws {
        let format = AVAudioFormat(standardFormatWithSampleRate:24000,channels:1)!
        let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:12000)!; buffer.frameLength = 12000
        for i in 0..<12000 { buffer.floatChannelData![0][i] = 0.01 * sin(Float(i)*0.1) }
        do { let file = try AVAudioFile(forWriting:intent.stagingURL,settings:format.settings); try file.write(from:buffer) }
        try await s.sealDictation(sourceID:intent.sourceID)
    }
    func begin(_ s: VoiceOSStore) async throws -> RecordingIntent { try await s.beginProcessingDictation(commandID:"record",cognition:configuration(),association:configuration()) }
    func reconcile(_ s: VoiceOSStore) async throws { try await s.reconcileRecordingProcessingRequests(cognition:configuration(),association:configuration()) }

    func testAtomicRequestAndTextOnlyConsentPrecedeDeviceBytes() async throws {
        let s = try await store(), intent = try await begin(s)
        let replay = try await begin(s); XCTAssertEqual(intent.sourceID,replay.sourceID)
        XCTAssertFalse(FileManager.default.fileExists(atPath:intent.stagingURL.path))
        let policy = try await s.sourcePolicy(sourceID:intent.sourceID); XCTAssertFalse(policy.localOnly); XCTAssertEqual(policy.version,2)
        let requests = try await s.recordingProcessingRequests(); XCTAssertEqual(requests.count,1); XCTAssertEqual(requests[0].state,"waiting")
        let queues = try await s.processingIntents(), calls = try await s.modelAttempts(); XCTAssertTrue(queues.isEmpty); XCTAssertTrue(calls.isEmpty)
        do { _ = try await s.beginProcessingDictation(commandID:"record",cognition:configuration("changed"),association:configuration()); XCTFail() } catch {}
    }
    func testUncommittedRequestRollsBackRecordingAndConsent() async throws {
        let s = try await store(checkpoint: { if $0 == .recordingRequestUncommitted { throw VoiceOSError("synthetic interruption") } })
        do { _ = try await begin(s); XCTFail() } catch {}
        let rows = try await s.sources(), requests = try await s.recordingProcessingRequests(); XCTAssertTrue(rows.isEmpty); XCTAssertTrue(requests.isEmpty)
    }
    func testOrdinaryRecordingStaysLocalAndCannotBeUpgradedByCommandReplay() async throws {
        let s = try await store(), ordinary = try await s.beginDictation(commandID:"record")
        do { _ = try await begin(s); XCTFail() } catch {}
        let requests = try await s.recordingProcessingRequests(), policy = try await s.sourcePolicy(sourceID:ordinary.sourceID)
        XCTAssertTrue(requests.isEmpty); XCTAssertTrue(policy.localOnly)
    }
    func testRestartRetainsRequestButNeverPromotesUnsealedRecording() async throws {
        do { let s = try await store(); _ = try await begin(s) }
        let s = try await store(); try await reconcile(s)
        let requests = try await s.recordingProcessingRequests(), rows = try await s.sources(), queues = try await s.processingIntents()
        XCTAssertEqual(requests[0].state,"waiting"); XCTAssertEqual(rows[0].state,"interrupted"); XCTAssertTrue(queues.isEmpty)
    }
    func testOriginalTranscriptEnqueuesExactlyOnceAndMigrationFreezesRequest() async throws {
        let s = try await store(), intent = try await begin(s)
        try await seal(s,intent); try await s.processTranscriptions(using:RequestSpeech()); try await reconcile(s); try await reconcile(s)
        let queues = try await s.processingIntents(), requests = try await s.recordingProcessingRequests()
        XCTAssertEqual(queues.count,1); XCTAssertEqual(requests[0].processingIntentID,queues[0].id); XCTAssertEqual(requests[0].state,"enqueued")
        let package = base.appendingPathComponent("package")
        try await s.exportPackage(to:package,includeMedia:true); XCTAssertEqual(try VoiceOSStore.packageSummary(at:package).version,26)
        try await VoiceOSStore.restorePackage(from:package,to:base.appendingPathComponent("restored"),inspector:NativeMediaInspector())
        let restored = try await store("restored"); try await reconcile(restored)
        let migrated = try await restored.recordingProcessingRequests(), migratedQueue = try await restored.processingIntents()
        XCTAssertEqual(migrated[0].state,"frozen"); XCTAssertEqual(migratedQueue[0].state,.frozen)
    }
    func testRevokedConsentAndChangedModelBlockBeforeQueue() async throws {
        for changed in [false,true] {
            let s = try await store(changed ? "model" : "policy"), intent = try await begin(s)
            try await seal(s,intent); try await s.processTranscriptions(using:RequestSpeech())
            if changed { try await s.reconcileRecordingProcessingRequests(cognition:configuration("new"),association:configuration()) }
            else { _ = try await s.setSourceLocalOnly(sourceID:intent.sourceID,expectedVersion:2,localOnly:true); try await reconcile(s) }
            let requests = try await s.recordingProcessingRequests(), queues = try await s.processingIntents(), calls = try await s.modelAttempts()
            XCTAssertEqual(requests[0].state,"blocked"); XCTAssertTrue(queues.isEmpty); XCTAssertTrue(calls.isEmpty)
        }
    }
    func testFailedLocalSpeechWaitsForExplicitRetryAndCorrectionBlocks() async throws {
        let s = try await store(), intent = try await begin(s)
        try await seal(s,intent); try await s.processTranscriptions(using:RequestSpeech(fails:true)); try await reconcile(s)
        let waiting = try await s.recordingProcessingRequests(); XCTAssertEqual(waiting[0].state,"waiting")
        try await s.retryTranscription(sourceID:intent.sourceID); try await s.processTranscriptions(using:RequestSpeech())
        let row = try await s.sources()[0]
        _ = try await s.correctTranscript(sourceID:row.id,expectedVersionID:row.transcriptVersionID!,text:"更正后的个人表达")
        try await reconcile(s)
        let blocked = try await s.recordingProcessingRequests(), queues = try await s.processingIntents()
        XCTAssertEqual(blocked[0].state,"blocked"); XCTAssertTrue(queues.isEmpty)
    }
    func testHandoffInterruptionReconcilesSameCommittedQueueAfterRestart() async throws {
        var id = ""
        do {
            let s = try await store(checkpoint: { if $0 == .recordingRequestQueueCommitted { throw VoiceOSError("synthetic handoff interruption") } })
            let intent = try await begin(s); try await seal(s,intent); try await s.processTranscriptions(using:RequestSpeech())
            do { try await reconcile(s); XCTFail() } catch {}
            let requests = try await s.recordingProcessingRequests(), queues = try await s.processingIntents()
            XCTAssertEqual(requests[0].state,"waiting"); XCTAssertEqual(queues.count,1); id = queues[0].id
        }
        let restored = try await store(); try await reconcile(restored)
        let requests = try await restored.recordingProcessingRequests(), queues = try await restored.processingIntents()
        XCTAssertEqual(requests[0].processingIntentID,id); XCTAssertEqual(queues.count,1)
    }
    func testCancellationInHandoffWindowCancelsCommittedQueue() async throws {
        let s = try await store(checkpoint: { if $0 == .recordingRequestQueueCommitted { throw VoiceOSError("synthetic handoff interruption") } })
        let intent = try await begin(s); try await seal(s,intent); try await s.processTranscriptions(using:RequestSpeech())
        do { try await reconcile(s); XCTFail() } catch {}
        let request = try await s.recordingProcessingRequests()[0]
        try await s.cancelRecordingProcessingRequest(id:request.id); try await reconcile(s)
        let requests = try await s.recordingProcessingRequests(), queues = try await s.processingIntents()
        XCTAssertEqual(requests[0].state,"cancelled"); XCTAssertEqual(queues[0].state,.cancelled)
    }
    func testCompletedQueueCannotBeReportedAsCancelled() async throws {
        let s = try await store(), intent = try await begin(s)
        try await seal(s,intent); try await s.processTranscriptions(using:RequestSpeech()); try await reconcile(s)
        let queue = try await s.processingIntents()[0]
        _ = try await s.runExpressionProcessingIntent(id:queue.id,retrieval:RequestRetrieval(),cognitionPort:RequestModel(configuration:configuration()),associationPort:RequestAssociation(configuration:configuration()))
        let request = try await s.recordingProcessingRequests()[0]
        let cancelled = try await s.cancelRecordingProcessingRequest(id:request.id); XCTAssertFalse(cancelled)
        let after = try await s.processingIntents()[0]; XCTAssertEqual(after.state,.completed)
    }
    func testOversizedTranscriptBlocksWithoutSilentTruncation() async throws {
        let s = try await store(), intent = try await begin(s)
        try await seal(s,intent); try await s.processTranscriptions(using:RequestSpeech(text:String(repeating:"字",count:4001))); try await reconcile(s)
        let requests = try await s.recordingProcessingRequests(), queues = try await s.processingIntents(), rows = try await s.sources()
        XCTAssertEqual(requests[0].state,"blocked"); XCTAssertTrue(queues.isEmpty); XCTAssertEqual(rows[0].transcript?.count,4001)
    }
}

private struct RequestSegmentExtraction: SegmentExtractionPort {
    let configuration: ModelConfiguration
    func extract(_ request: SegmentExtractionRequest) async throws -> SegmentExtractionResponse { .init(proposals:[]) }
}
private struct RequestSegmentAggregation: SegmentAggregationPort {
    let configuration: ModelConfiguration
    func aggregate(_ request: SegmentAggregationRequest) async throws -> SegmentAggregationResponse {
        .init(review:.init(batchID:request.batchID,ledgerDigest:request.ledger.contentDigest,reviewedEvidenceIDs:[],actionDecisions:[]),finalClaims:[])
    }
}
extension RecordingProcessingRequestTests {
    func beginLong(_ store: VoiceOSStore) async throws -> RecordingIntent {
        try await store.beginProcessingDictation(commandID:"long",cognition:configuration(),association:configuration(),segmentExtraction:configuration(),segmentAggregation:configuration())
    }
    func reconcileLong(_ store: VoiceOSStore) async throws {
        try await store.reconcileRecordingProcessingRequests(cognition:configuration(),association:configuration(),segmentExtraction:configuration(),segmentAggregation:configuration())
    }
    func transcribeLong(_ store: VoiceOSStore,_ intent: RecordingIntent) async throws {
        try await seal(store,intent)
        try await store.processTranscriptions(using:RequestSpeech(text:String(repeating:"合成录音文字。",count:700)))
    }
    func testRecordingLongPlanQueuesOneBatchAndStopsAfterAssociationCheck() async throws {
        let s=try await store(), intent=try await beginLong(s)
        try await transcribeLong(s,intent); try await reconcileLong(s)
        let request=try await s.recordingProcessingRequests()[0], batchID=try XCTUnwrap(request.segmentedBatchID)
        XCTAssertEqual(request.state,"enqueued"); XCTAssertNil(request.processingIntentID)
        try await s.processRecordingSegmentPlan(requestID:request.id,extraction:RequestSegmentExtraction(configuration:configuration()),aggregation:RequestSegmentAggregation(configuration:configuration()),retrieval:RequestRetrieval(),association:RequestAssociation(configuration:configuration()))
        let ids=try await s.segmentedCognitiveClaimIDs(batchID:batchID); XCTAssertEqual(ids,[])
        let after=try await s.recordingProcessingRequests()[0]; XCTAssertEqual(after.segmentedAssociationState,"noCandidates")
        let before=try await s.segmentExtractionAttempts(batchID:batchID).map(\.id)
        _ = try await s.recordUserExpression("后来新增的历史；不能靠新录音自动重扫旧请求。")
        try await s.processRecordingSegmentPlan(requestID:request.id,extraction:RequestSegmentExtraction(configuration:configuration()),aggregation:RequestSegmentAggregation(configuration:configuration()),retrieval:RequestRetrieval(),association:RequestAssociation(configuration:configuration()))
        let repeated=try await s.segmentExtractionAttempts(batchID:batchID).map(\.id); XCTAssertEqual(before,repeated)
        let package=base.appendingPathComponent("long-record-package"), restoredRoot=base.appendingPathComponent("long-record-restored")
        try await s.exportPackage(to:package)
        XCTAssertEqual(try VoiceOSStore.packageSummary(at:package).version,31)
        try await VoiceOSStore.restorePackage(from:package,to:restoredRoot,inspector:NativeMediaInspector())
        let restored=try VoiceOSStore(root:restoredRoot,inspector:NativeMediaInspector()); try await restored.recover()
        let frozen=try await restored.recordingProcessingRequests()[0]; XCTAssertEqual(frozen.state,"frozen"); XCTAssertEqual(frozen.segmentedBatchID,batchID)
    }
    func testLegacyLongRecordingDoesNotAcquireUnrecordedSegmentPorts() async throws {
        let s=try await store(), old=try await begin(s)
        try await transcribeLong(s,old); try await reconcileLong(s)
        let request=try await s.recordingProcessingRequests()[0]; XCTAssertEqual(request.state,"blocked"); XCTAssertNil(request.segmentedBatchID)
        let batches=try await s.segmentedProcessingBatches(); XCTAssertTrue(batches.isEmpty)
    }
    func testLongRecordingCancelAfterBatchCommitBeforeLinkCancelsActualBatch() async throws {
        let s=try await store(checkpoint:{ if $0 == .recordingRequestQueueCommitted { throw VoiceOSError("synthetic link boundary") } }), intent=try await beginLong(s)
        try await transcribeLong(s,intent)
        do { try await reconcileLong(s); XCTFail() } catch {}
        let request=try await s.recordingProcessingRequests()[0]; XCTAssertEqual(request.state,"waiting")
        let batches=try await s.segmentedProcessingBatches(); XCTAssertEqual(batches.count,1)
        let cancelled=try await s.cancelRecordingProcessingRequest(id:request.id); XCTAssertTrue(cancelled)
        let batch=try await s.segmentedProcessingBatch(id:batches[0].id); XCTAssertEqual(batch.state,.cancelled)
        let linked=try await s.recordingProcessingRequests()[0]; XCTAssertEqual(linked.segmentedBatchID,batch.id); XCTAssertEqual(linked.state,"cancelled")
    }
}
