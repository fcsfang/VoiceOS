import XCTest
import Foundation
@testable import VoiceOSCore

private struct DurableInspector: MediaInspector {
    func inspect(_ url: URL) async throws -> MediaInfo { throw VoiceOSError("not media") }
}
private struct DurableRanker: LocalRetrievalPort {
    func rank(query: String, documents: [RetrievalDocument], semantic: Bool) async throws -> [RetrievalMatch] {
        documents.map { RetrievalMatch(documentID:$0.id,score:1,method:"exact") }
    }
}
private actor DurableSelector: RelevanceModelPort {
    nonisolated let configuration: ModelConfiguration
    var calls = 0
    let mode: String
    init(_ mode: String = "normal", destination: ModelDestination = .local) {
        self.mode = mode
        configuration = ModelConfiguration(provider:"synthetic",model:"fixture",promptVersion:"v1",schemaVersion:"v1",destination:destination)
    }
    func select(_ request: RelevanceModelRequest) async throws -> RelevanceModelResponse {
        calls += 1
        if mode == "throw" { throw VoiceOSError("sensitive error must not persist") }
        if mode == "parse-rejected" { throw ModelPortFailure.rejected("sensitive response",inputTokens:55,outputTokens:8) }
        let ids = mode == "empty" ? [] : (mode == "invalid" ? ["invented"] : [request.snapshot.candidates[0].id])
        return RelevanceModelResponse(status:mode == "incomplete" ? .incomplete : .completed,
                                      selection:RelevanceSelection(snapshotID:request.snapshot.id,queryID:request.snapshot.queryID,candidateIDs:ids),
                                      inputTokens:mode == "negative" ? -1 : 123,outputTokens:12)
    }
}
private actor LateDurableSelector: RelevanceModelPort {
    nonisolated let configuration = ModelConfiguration(provider:"synthetic",model:"fixture",promptVersion:"v1",schemaVersion:"v1",destination:.local)
    var continuation: CheckedContinuation<RelevanceModelResponse,Never>?
    var waiter: CheckedContinuation<Void,Never>?
    var request: RelevanceModelRequest?
    func waitForStart() async { if request == nil { await withCheckedContinuation { waiter = $0 } } }
    func select(_ value: RelevanceModelRequest) async throws -> RelevanceModelResponse {
        request = value
        return await withCheckedContinuation { continuation = $0; waiter?.resume(); waiter = nil }
    }
    func release() {
        guard let request else { return }
        continuation?.resume(returning:RelevanceModelResponse(status:.completed,selection:RelevanceSelection(snapshotID:request.snapshot.id,queryID:request.snapshot.queryID,candidateIDs:[]),inputTokens:99,outputTokens:4))
        continuation = nil
    }
}
final class DurableRelevanceTests: XCTestCase {
    var base: URL!
    override func setUpWithError() throws { base = FileManager.default.temporaryDirectory.appendingPathComponent("durable-relevance-"+UUID().uuidString) }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at:base) }
    func store(checkpoint: @escaping @Sendable (SaveCheckpoint) throws -> Void = { _ in }) async throws -> VoiceOSStore {
        let s = try VoiceOSStore(root:base.appendingPathComponent("root"),inspector:DurableInspector(),checkpoint:checkpoint); try await s.recover(); return s
    }
    func snapshot(_ s: VoiceOSStore, queryID: UUID = UUID()) async throws -> RelevanceSnapshot {
        if try await s.sources().isEmpty { _ = try await s.recordUserExpression("只有具体条件满足才有效，尚未验证。") }
        let hits = try await s.retrieve("原文",using:DurableRanker()).hits
        return try await s.prepareRelevanceSnapshot(query:"哪些条件？",queryID:queryID,candidates:hits)
    }
    func testCompletedReceiptCanBeReadWithoutRepeatingOrCreatingClaims() async throws {
        let s = try await store(), snap = try await snapshot(s), port = DurableSelector()
        let hits = try await s.performRelevanceSelection(snap,using:port); XCTAssertEqual(hits.count,1)
        let records = try await s.relevanceAttempts(); XCTAssertEqual(records.count,1); XCTAssertEqual(records[0].state,"completed")
        XCTAssertEqual(records[0].usage?["input_tokens"],123); XCTAssertEqual(records[0].billingState,"unknown")
        let again = try await s.relevanceResult(attemptID:records[0].id,currentQueryID:snap.queryID); XCTAssertEqual(again[0].id,hits[0].id)
        let fresh = try await snapshot(s,queryID:snap.queryID)
        do { _ = try await s.performRelevanceSelection(fresh,using:port); XCTFail() } catch {}
        let calls = await port.calls; XCTAssertEqual(calls,1)
        let claims = try await s.candidateClaims(), actions = try await s.actions(), other = try await s.modelAttempts()
        XCTAssertTrue(claims.isEmpty); XCTAssertTrue(actions.isEmpty); XCTAssertTrue(other.isEmpty)
    }
    func testEmptyResultAndInputValidityAreIndependent() async throws {
        let s = try await store(), snap = try await snapshot(s)
        let result = try await s.performRelevanceSelection(snap,using:DurableSelector("empty")); XCTAssertTrue(result.isEmpty)
        let records = try await s.relevanceAttempts()
        let source = snap.candidates[0].document
        _ = try await s.correctTranscript(sourceID:source.sourceID,expectedVersionID:source.transcriptVersionID,text:"更正条件")
        let updated = try await s.relevanceAttempts(); XCTAssertEqual(updated[0].state,"completed"); XCTAssertEqual(updated[0].validity,"frozen")
        do { _ = try await s.relevanceResult(attemptID:records[0].id,currentQueryID:snap.queryID); XCTFail() } catch {}
    }
    func testUnknownTransportAndInvalidResponsesNeverRetry() async throws {
        let s = try await store()
        for mode in ["throw","invalid","incomplete","negative"] {
            let snap = try await snapshot(s), port = DurableSelector(mode)
            do { _ = try await s.performRelevanceSelection(snap,using:port); XCTFail() } catch {}
            do { _ = try await s.performRelevanceSelection(snap,using:port); XCTFail() } catch {}
            let calls = await port.calls; XCTAssertEqual(calls,1)
        }
        let records = try await s.relevanceAttempts(); XCTAssertEqual(records.filter { $0.state == "unknown" }.count,1)
        XCTAssertEqual(records.filter { $0.state == "rejected" }.count,3)
    }
    func testLateCanceledResultRetainsUsageButCannotCommit() async throws {
        let s = try await store(), snap = try await snapshot(s), port = LateDurableSelector()
        let task = Task { try await s.performRelevanceSelection(snap,using:port) }
        await port.waitForStart(); task.cancel(); await port.release()
        do { _ = try await task.value; XCTFail() } catch {}
        let records = try await s.relevanceAttempts(); XCTAssertEqual(records[0].state,"rejected"); XCTAssertEqual(records[0].usage?["input_tokens"],99)
    }
    func testLatePolicyChangeRejectsEmptyResultAndFreezesAllInput() async throws {
        let s = try await store(), snap = try await snapshot(s), port = LateDurableSelector()
        let task = Task { try await s.performRelevanceSelection(snap,using:port) }
        await port.waitForStart()
        _ = try await s.setSourceLocalOnly(sourceID:snap.candidates[0].document.sourceID,expectedVersion:1,localOnly:false)
        await port.release(); do { _ = try await task.value; XCTFail() } catch {}
        let rows = try await s.relevanceAttempts(); XCTAssertEqual(rows[0].state,"rejected"); XCTAssertEqual(rows[0].validity,"frozen")
    }
    func testDestinationMismatchAndMissingGrantDoNotReserveOrCall() async throws {
        let s = try await store(), snap = try await snapshot(s), port = DurableSelector(destination:.cloud)
        do { _ = try await s.performRelevanceSelection(snap,using:port); XCTFail() } catch {}
        let rows = try await s.relevanceAttempts(), calls = await port.calls; XCTAssertTrue(rows.isEmpty); XCTAssertEqual(calls,0)
    }
    func testRestartKeepsReservationUnknownAndCannotRepeat() async throws {
        var snap: RelevanceSnapshot!
        let port = DurableSelector()
        do {
            let s = try await store(checkpoint:{ if $0 == .relevanceReserved { throw VoiceOSError("simulated interruption") } })
            snap = try await snapshot(s)
            do { _ = try await s.performRelevanceSelection(snap,using:port); XCTFail() } catch {}
        }
        let reopened = try await store()
        let rows = try await reopened.relevanceAttempts(); XCTAssertEqual(rows[0].state,"unknown")
        do { _ = try await reopened.performRelevanceSelection(snap,using:port); XCTFail() } catch {}
        let calls = await port.calls; XCTAssertEqual(calls,0)
    }
    func testPortableHistoryRoundtripFreezesExecutionAndPreservesReferences() async throws {
        let s = try await store(), snap = try await snapshot(s)
        _ = try await s.performRelevanceSelection(snap,using:DurableSelector())
        let package = base.appendingPathComponent("package"); try await s.exportPackage(to:package)
        let summary = try VoiceOSStore.packageSummary(at:package); XCTAssertEqual(summary.version,22)
        let target = base.appendingPathComponent("restored"); try await VoiceOSStore.restorePackage(from:package,to:target,inspector:DurableInspector())
        let restored = try VoiceOSStore(root:target,inspector:DurableInspector()); try await restored.recover()
        let rows = try await restored.relevanceAttempts(); XCTAssertEqual(rows[0].state,"completed"); XCTAssertEqual(rows[0].validity,"frozen")
        do { _ = try await restored.relevanceResult(attemptID:rows[0].id,currentQueryID:snap.queryID); XCTFail() } catch {}
        let second = base.appendingPathComponent("second"); try await restored.exportPackage(to:second)
        XCTAssertEqual(try Data(contentsOf:package.appendingPathComponent("relevance_inputs.jsonl")),try Data(contentsOf:second.appendingPathComponent("relevance_inputs.jsonl")))
    }
    func testMalformedMigrationWithFreshManifestStillRejectsDanglingSelection() async throws {
        let s = try await store(), snap = try await snapshot(s)
        _ = try await s.performRelevanceSelection(snap,using:DurableSelector())
        let package = base.appendingPathComponent("package"); try await s.exportPackage(to:package)
        let file = package.appendingPathComponent("relevance_attempts.jsonl")
        var row = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:Any])
        let selection = try VoiceOSStore.relevanceJSON(["invented"])
        row["selection_json"] = selection; row["result_digest"] = VoiceOSStore.relevanceHash(Data(selection.utf8))
        var data = try JSONSerialization.data(withJSONObject:row); data.append(10); try data.write(to:file)
        let manifest = package.appendingPathComponent("manifest.json")
        var m = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:manifest)) as? [String:Any])
        var files = m["files"] as! [[String:Any]]; let index = files.firstIndex { $0["path"] as? String == "relevance_attempts.jsonl" }!
        let hash = try DurableFiles.hash(file); files[index]["bytes"] = hash.0; files[index]["sha256"] = hash.1; m["files"] = files
        try JSONSerialization.data(withJSONObject:m).write(to:manifest)
        let target = base.appendingPathComponent("bad-restore")
        do { try await VoiceOSStore.restorePackage(from:package,to:target,inspector:DurableInspector()); XCTFail() } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath:target.path))
    }
    func testArchivedCloudInputRestoresAfterCorrectionAndPermissionRevocation() async throws {
        let s = try await store(), local = try await snapshot(s)
        let source = local.candidates[0].document
        _ = try await s.setSourceLocalOnly(sourceID:source.sourceID,expectedVersion:1,localOnly:false)
        let hits = try await s.retrieve("原文",using:DurableRanker()).hits
        let cloud = try await s.prepareRelevanceSnapshot(query:"哪些条件？",queryID:UUID(),candidates:hits,destination:.cloud,cloudQueryAllowed:true)
        _ = try await s.performRelevanceSelection(cloud,using:DurableSelector(destination:.cloud))
        _ = try await s.correctTranscript(sourceID:source.sourceID,expectedVersionID:source.transcriptVersionID,text:"更正后的原文")
        _ = try await s.setSourceLocalOnly(sourceID:source.sourceID,expectedVersion:2,localOnly:true)
        let package = base.appendingPathComponent("archived-cloud")
        try await s.exportPackage(to:package)
        let target = base.appendingPathComponent("restored-cloud")
        try await VoiceOSStore.restorePackage(from:package,to:target,inspector:DurableInspector())
        let restored = try VoiceOSStore(root:target,inspector:DurableInspector()); try await restored.recover()
        let rows = try await restored.relevanceAttempts()
        XCTAssertEqual(rows.count,1); XCTAssertEqual(rows[0].state,"completed"); XCTAssertEqual(rows[0].validity,"frozen")
        let sources = try await restored.sources(); XCTAssertTrue(sources[0].localOnly)
        do { _ = try await restored.relevanceResult(attemptID:rows[0].id,currentQueryID:cloud.queryID); XCTFail() } catch {}
    }
    func testKnownParserRejectionPersistsUsageAndCannotResend() async throws {
        let s = try await store(), snap = try await snapshot(s), port = DurableSelector("parse-rejected")
        do { _ = try await s.performRelevanceSelection(snap,using:port); XCTFail() } catch {}
        do { _ = try await s.performRelevanceSelection(snap,using:port); XCTFail() } catch {}
        let rows = try await s.relevanceAttempts(), calls = await port.calls
        XCTAssertEqual(calls,1); XCTAssertEqual(rows[0].state,"rejected")
        XCTAssertEqual(rows[0].usage,["input_tokens":55,"output_tokens":8])
    }
}
