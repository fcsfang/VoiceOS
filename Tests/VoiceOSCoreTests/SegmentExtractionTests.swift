import XCTest
import CryptoKit
@testable import VoiceOSCore

private struct ExtractionInspector: MediaInspector {
    func inspect(_ url: URL) async throws -> MediaInfo { throw VoiceOSError("text-only") }
}
private actor ExtractionFixture: SegmentExtractionPort {
    nonisolated let configuration: ModelConfiguration
    enum Mode: Sendable { case valid, empty, fail, forged, refused }
    let mode: Mode
    var calls = 0
    init(_ config: ModelConfiguration, mode: Mode = .valid) { configuration = config; self.mode = mode }
    func extract(_ request: SegmentExtractionRequest) async throws -> SegmentExtractionResponse {
        calls += 1
        if mode == .empty { return .init(proposals:[],inputTokens:0,outputTokens:0) }
        if mode == .fail { throw VoiceOSError("synthetic missing response") }
        let s = request.segment
        let proposal = SegmentEvidenceProposal(kind:s.ordinal == 1 ? .possibleAction:.negation,statement:"合成证据，尚未聚合",
            quote:mode == .forged ? "伪造原话":s.text,textStart:s.textStart,textEnd:s.textEnd,spanIDs:s.references.map(\.spanID))
        return .init(status:mode == .refused ? .refused:.completed,proposals:[proposal],inputTokens:12,outputTokens:4)
    }
}
private actor WaitingExtraction: SegmentExtractionPort {
    nonisolated let configuration: ModelConfiguration
    var calls = 0
    var started: CheckedContinuation<Void,Never>?
    var response: CheckedContinuation<SegmentExtractionResponse,Never>?
    var request: SegmentExtractionRequest?
    init(_ configuration: ModelConfiguration) { self.configuration = configuration }
    func waitUntilStarted() async { if calls == 0 { await withCheckedContinuation { started = $0 } } }
    func extract(_ request: SegmentExtractionRequest) async throws -> SegmentExtractionResponse {
        calls += 1; self.request = request
        started?.resume(); started = nil
        return await withCheckedContinuation { response = $0 }
    }
    func finish() {
        guard let s = request?.segment else { return }
        response?.resume(returning:.init(proposals:[.init(kind:.possibleAction,statement:"迟到的合成提案",quote:s.text,
            textStart:s.textStart,textEnd:s.textEnd,spanIDs:s.references.map(\.spanID))],inputTokens:15,outputTokens:5))
        response = nil
    }
}
final class SegmentExtractionTests: XCTestCase {
    var base: URL!
    override func setUpWithError() throws { base = FileManager.default.temporaryDirectory.appendingPathComponent("extraction-"+UUID().uuidString) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at:base) }
    func config(_ model: String = "fixture", destination: ModelDestination = .local) -> ModelConfiguration {
        .init(provider:"extraction-test",model:model,promptVersion:"v1",schemaVersion:"v1",destination:destination)
    }
    func store(_ folder: String = "root", checkpoint: @escaping @Sendable (SaveCheckpoint) throws -> Void = {_ in}) async throws -> VoiceOSStore {
        let s = try VoiceOSStore(root:base.appendingPathComponent(folder),inspector:ExtractionInspector(),checkpoint:checkpoint)
        try await s.recover(); return s
    }
    func seed(_ s: VoiceOSStore, cloud: Bool = false) async throws -> SegmentedProcessingBatch {
        let id = try await s.recordUserExpression("合成测试：我要整理笔记。后来改主意，先不做了。")
        if cloud { _ = try await s.setSourceLocalOnly(sourceID:id,expectedVersion:1,localOnly:false) }
        let c = config(destination:cloud ? .cloud:.local)
        let scope = try await s.prepareSegmentedExpressionProcessingScope(sourceID:id,extraction:c,aggregation:c,segmentScalarBudget:12)
        return try await s.enqueueSegmentedProcessingBatch(scope,extraction:c,aggregation:c)
    }
    func testDurableSegmentsPrepareCompleteLedgerWithoutProductEntities() async throws {
        let s = try await store(), batch = try await seed(s), port = ExtractionFixture(config())
        do { _ = try await s.preparePersistedSegmentedEvidenceLedger(batchID:batch.id,extraction:config(),aggregation:config()); XCTFail() } catch {}
        for _ in batch.scope.plan.segments { _ = try await s.runNextSegmentExtraction(batchID:batch.id,using:port) }
        let done = try await s.runNextSegmentExtraction(batchID:batch.id,using:port); XCTAssertNil(done)
        let calls = await port.calls; XCTAssertEqual(calls,batch.scope.plan.segments.count)
        let ledger = try await s.preparePersistedSegmentedEvidenceLedger(batchID:batch.id,extraction:config(),aggregation:config())
        XCTAssertEqual(ledger.evidence[0].proposal.kind,.possibleAction); XCTAssertEqual(ledger.evidence.last?.proposal.kind,.negation)
        let review = SegmentAggregationReview(batchID:batch.id,ledgerDigest:ledger.contentDigest,reviewedEvidenceIDs:ledger.evidence.map(\.id),
            actionDecisions:ledger.evidence.filter { $0.proposal.kind == .possibleAction }.map {
                .init(evidenceID:$0.id,disposition:.reject,supportingEvidenceIDs:ledger.evidence.map(\.id),explanation:"后段改变主意，合成判断不创建任务")
            })
        let validation = try await s.validatePersistedSegmentAggregationReview(review,extraction:config(),aggregation:config())
        XCTAssertEqual(validation.review.actionDecisions.first?.disposition,.reject)
        let actions = try await s.actions(), claims = try await s.candidateClaims(), oldCalls = try await s.modelAttempts()
        XCTAssertTrue(actions.isEmpty); XCTAssertTrue(claims.isEmpty); XCTAssertTrue(oldCalls.isEmpty)
        let history = try await s.segmentExtractionAttempts(batchID:batch.id)
        XCTAssertTrue(history.allSatisfy { $0.state == .completed && $0.usage?["input_tokens"] == 12 })
        _ = try await s.cancelSegmentedProcessingBatch(id:batch.id)
        do { _ = try await s.validatePersistedSegmentAggregationReview(review,extraction:config(),aggregation:config()); XCTFail("取消后的判断不能接纳") } catch {}
    }
    func testSuccessfulEmptyResponsesHaveCompleteReceiptsAndNoResend() async throws {
        let s = try await store(), batch = try await seed(s), port = ExtractionFixture(config(),mode:.empty)
        for _ in batch.scope.plan.segments { _ = try await s.runNextSegmentExtraction(batchID:batch.id,using:port) }
        let ledger = try await s.preparePersistedSegmentedEvidenceLedger(batchID:batch.id,extraction:config(),aggregation:config())
        XCTAssertTrue(ledger.evidence.isEmpty); XCTAssertEqual(ledger.segmentIDs.count,batch.scope.plan.segments.count)
        _ = try await s.runNextSegmentExtraction(batchID:batch.id,using:ExtractionFixture(config(),mode:.valid))
        let records = try await s.segmentExtractionAttempts(batchID:batch.id)
        XCTAssertTrue(records.allSatisfy { $0.response?.proposals.isEmpty == true && $0.usage?["input_tokens"] == 0 })
    }
    func testUnknownAndRejectedNeverDispatchAnotherSegment() async throws {
        for mode in [ExtractionFixture.Mode.fail,.forged,.refused] {
            let s = try await store(String(describing:mode)), batch = try await seed(s), port = ExtractionFixture(config(),mode:mode)
            let result = try await s.runNextSegmentExtraction(batchID:batch.id,using:port)
            XCTAssertEqual(result?.state,mode == .fail ? .unknown:.rejected)
            let next = try await s.runNextSegmentExtraction(batchID:batch.id,using:port); XCTAssertNil(next)
            let calls = await port.calls; XCTAssertEqual(calls,1)
            let parent = try await s.segmentedProcessingBatch(id:batch.id); XCTAssertEqual(parent.state,mode == .fail ? .unknown:.rejected)
        }
    }
    func testCancellationAndConcurrentStepFreezeLateResponse() async throws {
        let s = try await store(), batch = try await seed(s), port = WaitingExtraction(config())
        let task = Task { try await s.runNextSegmentExtraction(batchID:batch.id,using:port) }
        await port.waitUntilStarted()
        let busy = try await s.runNextSegmentExtraction(batchID:batch.id,using:port); XCTAssertNil(busy)
        _ = try await s.cancelSegmentedProcessingBatch(id:batch.id); await port.finish()
        let result = try await task.value; XCTAssertEqual(result?.state,.completed); XCTAssertEqual(result?.validity,"frozen")
        XCTAssertEqual(result?.usage?["input_tokens"],15)
        let parent = try await s.segmentedProcessingBatch(id:batch.id); XCTAssertEqual(parent.state,.cancelled)
        let next = try await s.runNextSegmentExtraction(batchID:batch.id,using:port); XCTAssertNil(next)
        do { _ = try await s.preparePersistedSegmentedEvidenceLedger(batchID:batch.id,extraction:config(),aggregation:config()); XCTFail() } catch {}
    }
    func testCorrectionOrRevocationWhileInFlightFreezeResultAndPriorReceipts() async throws {
        for cloud in [false,true] {
            let s = try await store(cloud ? "policy":"correction"), batch = try await seed(s,cloud:cloud)
            let c = config(destination:cloud ? .cloud:.local), immediate = ExtractionFixture(c)
            _ = try await s.runNextSegmentExtraction(batchID:batch.id,using:immediate)
            let port = WaitingExtraction(c), task = Task { try await s.runNextSegmentExtraction(batchID:batch.id,using:port) }
            await port.waitUntilStarted()
            if cloud { _ = try await s.setSourceLocalOnly(sourceID:batch.scope.plan.source.sourceID,expectedVersion:2,localOnly:true) }
            else { _ = try await s.correctTranscript(sourceID:batch.scope.plan.source.sourceID,expectedVersionID:batch.scope.plan.source.transcriptVersionID,text:"更正后的表达") }
            await port.finish(); let result = try await task.value
            XCTAssertEqual(result?.validity,"frozen")
            let parent = try await s.segmentedProcessingBatch(id:batch.id); XCTAssertEqual(parent.state,.blocked)
            let receipts = try await s.segmentExtractionAttempts(batchID:batch.id); XCTAssertTrue(receipts.allSatisfy { $0.validity == "frozen" })
        }
    }
    func testConfigDriftDoesNotReserveOrSend() async throws {
        let s = try await store(), batch = try await seed(s), wrong = ExtractionFixture(config("new"))
        let result = try await s.runNextSegmentExtraction(batchID:batch.id,using:wrong); XCTAssertNil(result)
        let calls = await wrong.calls, attempts = try await s.segmentExtractionAttempts(batchID:batch.id)
        XCTAssertEqual(calls,0); XCTAssertTrue(attempts.isEmpty)
    }
    func testTaskCancellationFreezesReceivedResultAndPreservesUsage() async throws {
        let s = try await store(), batch = try await seed(s), port = WaitingExtraction(config())
        let task = Task { try await s.runNextSegmentExtraction(batchID:batch.id,using:port) }
        await port.waitUntilStarted(); task.cancel(); await port.finish()
        let result = try await task.value
        XCTAssertEqual(result?.state,.completed); XCTAssertEqual(result?.validity,"frozen")
        XCTAssertEqual(result?.usage?["output_tokens"],5)
        let parent = try await s.segmentedProcessingBatch(id:batch.id); XCTAssertEqual(parent.state,.blocked)
    }
    func testReservedRestartBecomesUnknownAndDoesNotRetry() async throws {
        var id = ""
        do {
            let s = try await store(checkpoint:{ if $0 == .segmentExtractionReserved { throw VoiceOSError("synthetic crash") } }), batch = try await seed(s)
            id = batch.id
            do { _ = try await s.runNextSegmentExtraction(batchID:id,using:ExtractionFixture(config())); XCTFail() } catch {}
        }
        let s = try await store(), parent = try await s.segmentedProcessingBatch(id:id), port = ExtractionFixture(config())
        XCTAssertEqual(parent.state,.unknown)
        let result = try await s.runNextSegmentExtraction(batchID:id,using:port); XCTAssertNil(result)
        let attempts = try await s.segmentExtractionAttempts(batchID:id), calls = await port.calls
        XCTAssertEqual(attempts[0].state,.unknown); XCTAssertEqual(calls,0)
    }
    func testResultTransactionBoundariesDoNotReplayCommittedSegment() async throws {
        for point in [SaveCheckpoint.segmentExtractionUncommitted,.segmentExtractionCommitted] {
            let s = try await store(point.rawValue,checkpoint:{ if $0 == point { throw VoiceOSError("synthetic interruption") } }), batch = try await seed(s), port = ExtractionFixture(config())
            let result = try await s.runNextSegmentExtraction(batchID:batch.id,using:port)
            XCTAssertEqual(result?.state,point == .segmentExtractionUncommitted ? .unknown:.completed)
            XCTAssertEqual(result?.usage?["input_tokens"],12)
            _ = try await s.runNextSegmentExtraction(batchID:batch.id,using:port)
            let calls = await port.calls; XCTAssertEqual(calls,point == .segmentExtractionUncommitted ? 1:2)
        }
    }
    func testTamperedMigrationCannotChangeFragmentScopeQuotesOrGlobalSequence() async throws {
        let s = try await store(), batch = try await seed(s)
        _ = try await s.runNextSegmentExtraction(batchID:batch.id,using:ExtractionFixture(config()))
        let context = try await s.prepareLocalTranscriptContext(sourceIDs:[batch.scope.plan.source.sourceID])
        let contextID = try await s.persistLocalContext(context)
        _ = try await s.reserveLocalModelAttempt(contextID:contextID,model:"fixture",promptVersion:"v1",schemaVersion:"v1")
        let old = try await s.modelAttempts()
        for kind in ["scope","quote","sequence"] {
            let package = base.appendingPathComponent("tampered-"+kind)
            try await s.exportPackage(to:package)
            let file = package.appendingPathComponent("segmented_extraction_attempts.jsonl")
            var row = try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any]
            if kind == "scope" {
                var value = try JSONSerialization.jsonObject(with:Data((row["input_json"] as! String).utf8)) as! [String:Any]
                value["policyVersion"] = 999
                let request = try JSONDecoder().decode(SegmentExtractionRequest.self,from:JSONSerialization.data(withJSONObject:value))
                row["input_json"] = try VoiceOSStore.relevanceJSON(request); row["input_digest"] = try VoiceOSStore.segmentValueDigest(request)
            } else if kind == "quote" {
                var value = try JSONSerialization.jsonObject(with:Data((row["result_json"] as! String).utf8)) as! [String:Any]
                var proposals = value["proposals"] as! [[String:Any]]; proposals[0]["quote"] = "伪造"; value["proposals"] = proposals
                let response = try JSONDecoder().decode(SegmentExtractionResponse.self,from:JSONSerialization.data(withJSONObject:value))
                row["result_json"] = try VoiceOSStore.relevanceJSON(response); row["result_digest"] = try VoiceOSStore.segmentValueDigest(response)
            } else { row["producer_sequence"] = old[0].producerSequence }
            let data = try JSONSerialization.data(withJSONObject:row,options:[.sortedKeys]) + Data([10]); try data.write(to:file)
            let manifestURL = package.appendingPathComponent("manifest.json")
            var manifest = try JSONSerialization.jsonObject(with:Data(contentsOf:manifestURL)) as! [String:Any]
            var files = manifest["files"] as! [[String:Any]], index = files.firstIndex { $0["path"] as? String == file.lastPathComponent }!
            files[index]["bytes"] = data.count; files[index]["sha256"] = SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
            manifest["files"] = files; try JSONSerialization.data(withJSONObject:manifest).write(to:manifestURL)
            let target = base.appendingPathComponent("reject-"+kind)
            do { try await VoiceOSStore.restorePackage(from:package,to:target,inspector:ExtractionInspector()); XCTFail() } catch {}
            XCTAssertFalse(FileManager.default.fileExists(atPath:target.path))
        }
    }
    func testMigrationFreezesStagedReceiptsAndPreservesGlobalSequence() async throws {
        let s = try await store(), batch = try await seed(s)
        _ = try await s.runNextSegmentExtraction(batchID:batch.id,using:ExtractionFixture(config()))
        let context = try await s.prepareLocalTranscriptContext(sourceIDs:[batch.scope.plan.source.sourceID])
        let contextID = try await s.persistLocalContext(context)
        _ = try await s.reserveLocalModelAttempt(contextID:contextID,model:"fixture",promptVersion:"v1",schemaVersion:"v1")
        let old = try await s.modelAttempts(), segments = try await s.segmentExtractionAttempts(batchID:batch.id)
        XCTAssertGreaterThan(old[0].producerSequence,segments[0].producerSequence)
        let package = base.appendingPathComponent("package")
        try await s.exportPackage(to:package); XCTAssertEqual(try VoiceOSStore.packageSummary(at:package).version,28)
        try await VoiceOSStore.restorePackage(from:package,to:base.appendingPathComponent("restored"),inspector:ExtractionInspector())
        let restored = try await store("restored"), receipts = try await restored.segmentExtractionAttempts(batchID:batch.id)
        XCTAssertEqual(receipts[0].validity,"frozen"); XCTAssertEqual(receipts[0].producerSequence,segments[0].producerSequence)
        let result = try await restored.runNextSegmentExtraction(batchID:batch.id,using:ExtractionFixture(config())); XCTAssertNil(result)
    }
}

private actor AggregationFixture: SegmentAggregationPort {
    nonisolated let configuration: ModelConfiguration
    let fail: Bool
    var calls=0
    init(_ config: ModelConfiguration, fail: Bool = false) { configuration=config; self.fail=fail }
    func aggregate(_ r: SegmentAggregationRequest) async throws -> SegmentAggregationResponse {
        calls += 1
        if fail { throw VoiceOSError("synthetic lost response") }
        return aggregationFixtureResponse(r)
    }
}
private func aggregationFixtureResponse(_ r: SegmentAggregationRequest) -> SegmentAggregationResponse {
    .init(review:.init(batchID:r.batchID,ledgerDigest:r.ledger.contentDigest,reviewedEvidenceIDs:r.ledger.evidence.map(\.id),
        actionDecisions:r.ledger.evidence.filter { $0.proposal.kind == .possibleAction }.map {
            .init(evidenceID:$0.id,disposition:.reject,supportingEvidenceIDs:r.ledger.evidence.map(\.id),explanation:"后段取消，合成结果")
        }),inputTokens:30,outputTokens:10)
}
private actor WaitingAggregation: SegmentAggregationPort {
    nonisolated let configuration: ModelConfiguration
    var request: SegmentAggregationRequest?
    var started: CheckedContinuation<Void,Never>?
    var finishContinuation: CheckedContinuation<SegmentAggregationResponse,Never>?
    init(_ c: ModelConfiguration) { configuration=c }
    func waitForStart() async { if request == nil { await withCheckedContinuation { started=$0 } } }
    func aggregate(_ r: SegmentAggregationRequest) async throws -> SegmentAggregationResponse {
        request=r; started?.resume(); started=nil
        return await withCheckedContinuation { finishContinuation=$0 }
    }
    func finish() { if let request { finishContinuation?.resume(returning:aggregationFixtureResponse(request)); finishContinuation=nil } }
}
extension SegmentExtractionTests {
    func completeSegments(_ store: VoiceOSStore,_ batch: SegmentedProcessingBatch) async throws {
        let port=ExtractionFixture(config())
        for _ in batch.scope.plan.segments { _ = try await store.runNextSegmentExtraction(batchID:batch.id,using:port) }
    }
    func testAggregationDurableSuccessNoRepeatAndFrozenMigration() async throws {
        let s=try await store(), batch=try await seed(s), p=AggregationFixture(config())
        do { _ = try await s.runSegmentAggregation(batchID:batch.id,using:p); XCTFail() } catch {}
        let zero=await p.calls; XCTAssertEqual(zero,0)
        try await completeSegments(s,batch)
        let a=try await s.runSegmentAggregation(batchID:batch.id,using:p)
        XCTAssertEqual(a?.state,.completed); XCTAssertEqual(a?.usage?["input_tokens"],30)
        let again=try await s.runSegmentAggregation(batchID:batch.id,using:p)
        XCTAssertEqual(again?.id,a?.id); let calls=await p.calls; XCTAssertEqual(calls,1)
        let claims=try await s.candidateClaims(), actions=try await s.actions(); XCTAssertTrue(claims.isEmpty); XCTAssertTrue(actions.isEmpty)
        let package=base.appendingPathComponent("aggregate-package"), target=base.appendingPathComponent("aggregate-restored")
        try await s.exportPackage(to:package)
        let manifest=try String(contentsOf:package.appendingPathComponent("manifest.json"),encoding:.utf8)
        XCTAssertTrue(manifest.contains("29"))
        try await VoiceOSStore.restorePackage(from:package,to:target,inspector:ExtractionInspector())
        let restored=try VoiceOSStore(root:target,inspector:ExtractionInspector()); try await restored.recover()
        let frozen=try await restored.segmentAggregationAttempt(batchID:batch.id); XCTAssertEqual(frozen?.id,a?.id); XCTAssertEqual(frozen?.validity,"frozen")
        _ = try await restored.runSegmentAggregation(batchID:batch.id,using:p)
        let after=await p.calls; XCTAssertEqual(after,1)
    }
    func testAggregationUnknownAndReservationRecoveryNeverResend() async throws {
        let s=try await store(), b=try await seed(s); try await completeSegments(s,b)
        let port=AggregationFixture(config(),fail:true)
        let a=try await s.runSegmentAggregation(batchID:b.id,using:port); XCTAssertEqual(a?.state,.unknown)
        _ = try await s.runSegmentAggregation(batchID:b.id,using:port); let calls=await port.calls; XCTAssertEqual(calls,1)
        var reservedBatchID=""
        do {
            let reserved=try await store("reserved-agg",checkpoint:{ if $0 == .segmentAggregationReserved { throw VoiceOSError("exit before send") } })
            let rb=try await seed(reserved); reservedBatchID=rb.id; try await completeSegments(reserved,rb)
            do { _ = try await reserved.runSegmentAggregation(batchID:rb.id,using:port); XCTFail() } catch {}
        }
        let reopened=try await store("reserved-agg")
        let unknown=try await reopened.segmentAggregationAttempt(batchID:reservedBatchID); XCTAssertEqual(unknown?.state,.unknown)
        _ = try await reopened.runSegmentAggregation(batchID:reservedBatchID,using:port)
        let after=await port.calls; XCTAssertEqual(after,1)
    }
    func testAggregationLateCancellationKeepsUsageFrozenAndNoProducts() async throws {
        let s=try await store(), b=try await seed(s); try await completeSegments(s,b)
        let port=WaitingAggregation(config())
        let task=Task { try await s.runSegmentAggregation(batchID:b.id,using:port) }
        await port.waitForStart()
        _ = try await s.cancelSegmentedProcessingBatch(id:b.id)
        await port.finish()
        let result=try await task.value
        XCTAssertEqual(result?.state,.completed); XCTAssertEqual(result?.validity,"frozen"); XCTAssertEqual(result?.usage?["output_tokens"],10)
        let parent=try await s.segmentedProcessingBatch(id:b.id); XCTAssertEqual(parent.state,.cancelled)
        let actions=try await s.actions(); XCTAssertTrue(actions.isEmpty)
    }
    func testAggregationTransactionFailureRetainsUsageAndCommittedResult() async throws {
        for checkpoint in [SaveCheckpoint.segmentAggregationUncommitted,.segmentAggregationCommitted] {
            let s=try await store("agg-\(checkpoint)",checkpoint:{ if $0 == checkpoint { throw VoiceOSError("synthetic transaction boundary") } })
            let b=try await seed(s); try await completeSegments(s,b); let port=AggregationFixture(config())
            let a=try await s.runSegmentAggregation(batchID:b.id,using:port)
            XCTAssertEqual(a?.state,checkpoint == .segmentAggregationUncommitted ? .unknown:.completed)
            XCTAssertEqual(a?.usage?["input_tokens"],30)
            _ = try await s.runSegmentAggregation(batchID:b.id,using:port)
            let calls=await port.calls; XCTAssertEqual(calls,1)
        }
    }
}

private struct FinalExtractionFixture: SegmentExtractionPort {
    let configuration: ModelConfiguration
    func extract(_ r: SegmentExtractionRequest) async throws -> SegmentExtractionResponse {
        guard r.segment.ordinal == 1 else { return .init(proposals:[]) }
        let quote=String(r.segment.text.prefix(8)), end=r.segment.textStart+quote.unicodeScalars.count
        return .init(proposals:[.init(kind:.possibleAction,statement:"合成潜在行动",quote:quote,textStart:r.segment.textStart,textEnd:end,spanIDs:r.segment.references.filter { $0.textStart<end }.map(\.spanID))])
    }
}
private struct FinalAggregationFixture: SegmentAggregationPort {
    let configuration: ModelConfiguration
    let invalid: Bool
    init(_ c: ModelConfiguration, invalid: Bool = false) { configuration=c; self.invalid=invalid }
    func aggregate(_ r: SegmentAggregationRequest) async throws -> SegmentAggregationResponse {
        let e=r.ledger.evidence.first!, action=ExtractedAction(title:"合成任务",kind:.task,quote:e.proposal.quote)
        let review=SegmentAggregationReview(batchID:r.batchID,ledgerDigest:r.ledger.contentDigest,reviewedEvidenceIDs:r.ledger.evidence.map(\.id),
            actionDecisions:[.init(evidenceID:e.id,disposition:invalid ? .reject:.accept,supportingEvidenceIDs:[e.id],explanation:"合成整篇判断")])
        return .init(review:review,finalClaims:[.init(statement:"合成认知",evidenceIDs:[e.id],actionEvidenceID:e.id,action:action)],inputTokens:20,outputTokens:5)
    }
}
extension SegmentExtractionTests {
    func seedFinal(_ s: VoiceOSStore) async throws -> SegmentedProcessingBatch {
        let id=try await s.recordUserExpression("合成原话内容。")
        let original=try await s.transcriptHistory(sourceID:id)[0].id
        _ = try await s.correctTranscript(sourceID:id,expectedVersionID:original,text:String(repeating:"合成原话内容。",count:700)) // >4000, synthetic corrected transcript
        let scope=try await s.prepareSegmentedExpressionProcessingScope(sourceID:id,extraction:config(),aggregation:config(),segmentScalarBudget:2000)
        let batch=try await s.enqueueSegmentedProcessingBatch(scope,extraction:config(),aggregation:config())
        for _ in scope.plan.segments { _ = try await s.runNextSegmentExtraction(batchID:batch.id,using:FinalExtractionFixture(configuration:config())) }
        return batch
    }
    func testFinalCognitionCommitsLongSourceOnceAndFreezesMigration() async throws {
        let s=try await store(), b=try await seedFinal(s)
        do { _ = try await s.prepareLocalTranscriptContext(sourceIDs:[b.scope.plan.source.sourceID]); XCTFail("旧4000字入口应仍拒绝") } catch {}
        _ = try await s.runSegmentAggregation(batchID:b.id,using:FinalAggregationFixture(config()))
        let ids=try await s.commitSegmentedCognition(batchID:b.id,extraction:config(),aggregation:config())
        let again=try await s.commitSegmentedCognition(batchID:b.id,extraction:config(),aggregation:config()); XCTAssertEqual(ids,again)
        let claims=try await s.candidateClaims(), actions=try await s.actions(), models=try await s.modelAttempts()
        XCTAssertEqual(claims.count,1); XCTAssertEqual(actions.count,1); XCTAssertEqual(models.count,1)
        XCTAssertEqual(models[0].executionKind,"segmented_derivation"); XCTAssertEqual(models[0].billingState,"not_applicable")
        XCTAssertEqual(claims[0].references[0].transcriptVersionID,b.scope.plan.source.transcriptVersionID)
        let package=base.appendingPathComponent("final-package"), restoredRoot=base.appendingPathComponent("final-restored")
        try await s.exportPackage(to:package)
        let summary=try VoiceOSStore.packageSummary(at:package); XCTAssertEqual(summary.version,30)
        try await VoiceOSStore.restorePackage(from:package,to:restoredRoot,inspector:ExtractionInspector())
        let restored=try VoiceOSStore(root:restoredRoot,inspector:ExtractionInspector()); try await restored.recover()
        let frozenClaims=try await restored.candidateClaims(includeFrozen:true), current=try await restored.candidateClaims()
        XCTAssertEqual(frozenClaims.count,1); XCTAssertTrue(current.isEmpty)
        let replay=try await restored.commitSegmentedCognition(batchID:b.id,extraction:config(),aggregation:config()); XCTAssertEqual(replay,ids)
        let stillFrozen=try await restored.candidateClaims(); XCTAssertTrue(stillFrozen.isEmpty)
    }
    func testRejectedActionCannotBecomeFinalTaskAndCancelledResultCannotCommit() async throws {
        let s=try await store(), b=try await seedFinal(s)
        let rejected=try await s.runSegmentAggregation(batchID:b.id,using:FinalAggregationFixture(config(),invalid:true)); XCTAssertEqual(rejected?.state,.rejected)
        do { _ = try await s.commitSegmentedCognition(batchID:b.id,extraction:config(),aggregation:config()); XCTFail() } catch {}
        let actions=try await s.actions(); XCTAssertTrue(actions.isEmpty)
        let s2=try await store("cancelled-final"), b2=try await seedFinal(s2)
        _ = try await s2.runSegmentAggregation(batchID:b2.id,using:FinalAggregationFixture(config()))
        _ = try await s2.cancelSegmentedProcessingBatch(id:b2.id)
        do { _ = try await s2.commitSegmentedCognition(batchID:b2.id,extraction:config(),aggregation:config()); XCTFail() } catch {}
        let claims=try await s2.candidateClaims(); XCTAssertTrue(claims.isEmpty)
    }
    func testFinalCommitRollbackCanResumeWithoutAnotherModelRequest() async throws {
        var batchID="", aggregateID=""
        do {
            let s=try await store(checkpoint:{ if $0 == .claimsUncommitted { throw VoiceOSError("synthetic crash before complete transaction") } }), b=try await seedFinal(s)
            batchID=b.id
            let a=try await s.runSegmentAggregation(batchID:b.id,using:FinalAggregationFixture(config())); aggregateID=a!.id
            do { _ = try await s.commitSegmentedCognition(batchID:b.id,extraction:config(),aggregation:config()); XCTFail() } catch {}
            let claims=try await s.candidateClaims(), models=try await s.modelAttempts(); XCTAssertTrue(claims.isEmpty); XCTAssertTrue(models.isEmpty)
        }
        let reopened=try await store()
        let ids=try await reopened.commitSegmentedCognition(batchID:batchID,extraction:config(),aggregation:config()); XCTAssertEqual(ids.count,1)
        let a=try await reopened.segmentAggregationAttempt(batchID:batchID); XCTAssertEqual(a?.id,aggregateID)
    }
    func testSourceCorrectionFreezesCommittedLongSourceWithoutRegeneration() async throws {
        let s=try await store(), b=try await seedFinal(s)
        _ = try await s.runSegmentAggregation(batchID:b.id,using:FinalAggregationFixture(config()))
        let ids=try await s.commitSegmentedCognition(batchID:b.id,extraction:config(),aggregation:config())
        _ = try await s.correctTranscript(sourceID:b.scope.plan.source.sourceID,expectedVersionID:b.scope.plan.source.transcriptVersionID,text:"改稿，不再保留旧行动。")
        let current=try await s.candidateClaims(); XCTAssertTrue(current.isEmpty)
        let again=try await s.commitSegmentedCognition(batchID:b.id,extraction:config(),aggregation:config()); XCTAssertEqual(again,ids)
        let actions=try await s.actions(); XCTAssertTrue(actions.isEmpty)
    }
}
