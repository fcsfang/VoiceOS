import XCTest
import Foundation
@testable import VoiceOSCore

private struct QuietInspector: MediaInspector {
    func inspect(_ url: URL) async throws -> MediaInfo { throw VoiceOSError("synthetic text only") }
}
private struct QuietRanker: LocalRetrievalPort {
    func rank(query:String,documents:[RetrievalDocument],semantic:Bool) async throws -> [RetrievalMatch] {
        documents.map { RetrievalMatch(documentID:$0.id,score:1,method:"exact") }
    }
}
private struct QuietSelector: RelevanceModelPort {
    let count: Int
    let configuration = ModelConfiguration(provider:"synthetic",model:"quiet-fixture",promptVersion:"v1",schemaVersion:"v1",destination:.local)
    func select(_ request:RelevanceModelRequest) async throws -> RelevanceModelResponse {
        RelevanceModelResponse(status:.completed,selection:RelevanceSelection(snapshotID:request.snapshot.id,queryID:request.snapshot.queryID,candidateIDs:Array(request.snapshot.candidates.prefix(count)).map(\.id)))
    }
}
final class CognitiveFeedbackTests: XCTestCase {
    var base: URL!
    override func setUpWithError() throws { base = FileManager.default.temporaryDirectory.appendingPathComponent("quiet-"+UUID().uuidString) }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at:base) }
    func store(_ name:String = "root") async throws -> VoiceOSStore {
        let s = try VoiceOSStore(root:base.appendingPathComponent(name),inspector:QuietInspector()); try await s.recover(); return s
    }
    func receipt(_ s:VoiceOSStore,query:String = "合成查询：如何检验条件？",count:Int = 3) async throws -> RelevanceSnapshot {
        if try await s.sources().isEmpty {
            for text in ["合成原文一：比较条件，尚未验证。","合成原文二：保留不同观点。","合成原文三：不凭完成动作判断理解。"] { _ = try await s.recordUserExpression(text) }
        }
        let hits = try await s.retrieve("原文",limit:8,using:QuietRanker()).hits
        let snap = try await s.prepareRelevanceSnapshot(query:query,queryID:UUID(),candidates:hits)
        _ = try await s.performRelevanceSelection(snap,using:QuietSelector(count:count)); return snap
    }
    func testReadAndCloseCreateNoAcknowledgementClaimOrAction() async throws {
        let s = try await store(); _ = try await receipt(s)
        let first = try await s.cognitiveFeedback(), again = try await s.cognitiveFeedback()
        XCTAssertEqual(first.count,3); XCTAssertEqual(first.map(\.id),again.map(\.id))
        let claims = try await s.candidateClaims(); XCTAssertTrue(claims.isEmpty)
        let actions = try await s.actions(), attempts = try await s.relevanceAttempts(); XCTAssertTrue(actions.isEmpty); XCTAssertEqual(attempts.count,1)
        let mode = try await s.cognitiveFeedbackPreference(); XCTAssertEqual(mode.version,0); XCTAssertEqual(mode.mode,.normal)
    }
    func testEmptySelectionNeverCreatesFeedback() async throws {
        let s = try await store(); _ = try await receipt(s,count:0)
        let items = try await s.cognitiveFeedback(); XCTAssertTrue(items.isEmpty)
    }
    func testIgnoredUnchangedQuoteDoesNotReturnAfterAnotherQueryReceipt() async throws {
        let s = try await store(); _ = try await receipt(s)
        let first = try await s.cognitiveFeedback(), item = first[0]
        try await s.ignoreCognitiveFeedback(attemptID:item.attemptID,candidateID:item.hit.id,commandID:"ignore-once")
        try await s.ignoreCognitiveFeedback(attemptID:item.attemptID,candidateID:item.hit.id,commandID:"ignore-once")
        _ = try await receipt(s)
        let remaining = try await s.cognitiveFeedback(); XCTAssertEqual(remaining.count,2); XCTAssertFalse(remaining.contains { $0.id == item.id })
        _ = try await receipt(s,query:"新的合成问题：有哪些不同观点？")
        let changed = try await s.cognitiveFeedback(); XCTAssertEqual(changed.count,5)
    }
    func testReducePauseResumeAndVersionConflictPreserveHistory() async throws {
        let s = try await store(); _ = try await receipt(s)
        try await s.setCognitiveFeedbackMode(.reduced,expectedVersion:0,commandID:"reduce")
        let reduced = try await s.cognitiveFeedback(); XCTAssertEqual(reduced.count,1)
        try await s.setCognitiveFeedbackMode(.paused,expectedVersion:1,commandID:"pause")
        let paused = try await s.cognitiveFeedback(); XCTAssertTrue(paused.isEmpty)
        do { try await s.setCognitiveFeedbackMode(.normal,expectedVersion:1); XCTFail() } catch {}
        try await s.setCognitiveFeedbackMode(.normal,expectedVersion:2,commandID:"resume")
        // An old duplicate cannot restore the earlier setting or produce another revision.
        try await s.setCognitiveFeedbackMode(.reduced,expectedVersion:0,commandID:"reduce")
        let normal = try await s.cognitiveFeedback(), mode = try await s.cognitiveFeedbackPreference()
        XCTAssertEqual(normal.count,3); XCTAssertEqual(mode.version,3); XCTAssertEqual(mode.mode,.normal)
    }
    func testCorrectionOfExcludedInputBlocksEveryCardAndOldSourceOpen() async throws {
        let s = try await store(), snap = try await receipt(s,count:1)
        let first = try await s.cognitiveFeedback(), excluded = snap.candidates[1].document
        _ = try await s.correctTranscript(sourceID:excluded.sourceID,expectedVersionID:excluded.transcriptVersionID,text:"合成更正：排除候选也影响选择。")
        let stale = try await s.cognitiveFeedback(); XCTAssertTrue(stale.isEmpty)
        do { _ = try await s.cognitiveFeedbackHit(attemptID:first[0].attemptID,candidateID:first[0].hit.id); XCTFail() } catch {}
        do { try await s.ignoreCognitiveFeedback(attemptID:first[0].attemptID,candidateID:first[0].hit.id); XCTFail() } catch {}
    }
    func testPolicyChangeAndUnselectedCandidateCannotBeIgnored() async throws {
        let s = try await store(), snap = try await receipt(s,count:1), first = try await s.cognitiveFeedback()
        do { try await s.ignoreCognitiveFeedback(attemptID:first[0].attemptID,candidateID:snap.candidates[1].id); XCTFail() } catch {}
        _ = try await s.setSourceLocalOnly(sourceID:snap.candidates[1].document.sourceID,expectedVersion:1,localOnly:false)
        let stale = try await s.cognitiveFeedback(); XCTAssertTrue(stale.isEmpty)
    }
    func testRestartPersistsIgnoreAndPauseWithoutCallingSelector() async throws {
        var item: CognitiveFeedbackItem!
        do {
            let s = try await store(); _ = try await receipt(s); item = try await s.cognitiveFeedback()[0]
            try await s.ignoreCognitiveFeedback(attemptID:item.attemptID,candidateID:item.hit.id,commandID:"ignore")
            try await s.setCognitiveFeedbackMode(.paused,expectedVersion:0)
        }
        let s = try await store(), paused = try await s.cognitiveFeedback(); XCTAssertTrue(paused.isEmpty)
        try await s.setCognitiveFeedbackMode(.normal,expectedVersion:1)
        let resumed = try await s.cognitiveFeedback(); XCTAssertEqual(resumed.count,2); XCTAssertFalse(resumed.contains { $0.id == item.id })
        let attempts = try await s.relevanceAttempts(); XCTAssertEqual(attempts.count,1)
    }
    func testPortableRoundTripKeepsPreferencesIgnoresAndFrozenReceipts() async throws {
        let s = try await store(); _ = try await receipt(s)
        let item = try await s.cognitiveFeedback()[0]
        try await s.ignoreCognitiveFeedback(attemptID:item.attemptID,candidateID:item.hit.id)
        try await s.setCognitiveFeedbackMode(.reduced,expectedVersion:0)
        let package = base.appendingPathComponent("package"), target = base.appendingPathComponent("restored")
        try await s.exportPackage(to:package)
        XCTAssertEqual(try VoiceOSStore.packageSummary(at:package).version,23)
        try await VoiceOSStore.restorePackage(from:package,to:target,inspector:QuietInspector())
        let r = try await store("restored"), items = try await r.cognitiveFeedback(), pref = try await r.cognitiveFeedbackPreference()
        XCTAssertTrue(items.isEmpty); XCTAssertEqual(pref.mode,.reduced)
        let second = base.appendingPathComponent("second"); try await r.exportPackage(to:second)
        for table in ["cognitive_feedback_preferences","cognitive_feedback_ignores"] {
            XCTAssertEqual(try Data(contentsOf:package.appendingPathComponent(table+".jsonl")),try Data(contentsOf:second.appendingPathComponent(table+".jsonl")))
        }
    }
    func testMigrationRejectsForgedIgnoreEvenWithRecomputedFileHash() async throws {
        let s = try await store(); _ = try await receipt(s)
        let item = try await s.cognitiveFeedback()[0]
        try await s.ignoreCognitiveFeedback(attemptID:item.attemptID,candidateID:item.hit.id)
        let package = base.appendingPathComponent("package"); try await s.exportPackage(to:package)
        try tamper(package,table:"cognitive_feedback_ignores",key:"fingerprint",value:String(repeating:"0",count:64))
        let target = base.appendingPathComponent("bad")
        do { try await VoiceOSStore.restorePackage(from:package,to:target,inspector:QuietInspector()); XCTFail() } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath:target.path))
    }
    func testMigrationRejectsPreferenceVersionGapEvenWithRecomputedFileHash() async throws {
        let s = try await store(); try await s.setCognitiveFeedbackMode(.paused,expectedVersion:0)
        let package = base.appendingPathComponent("package"); try await s.exportPackage(to:package)
        try tamper(package,table:"cognitive_feedback_preferences",key:"version",value:2)
        let target = base.appendingPathComponent("bad")
        do { try await VoiceOSStore.restorePackage(from:package,to:target,inspector:QuietInspector()); XCTFail() } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath:target.path))
    }
    func tamper(_ package:URL,table:String,key:String,value:Any) throws {
        let file = package.appendingPathComponent(table+".jsonl")
        var row = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:Any]); row[key] = value
        var data = try JSONSerialization.data(withJSONObject:row); data.append(10); try data.write(to:file)
        let manifest = package.appendingPathComponent("manifest.json")
        var m = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:manifest)) as? [String:Any])
        var files = m["files"] as! [[String:Any]]; let index = files.firstIndex { $0["path"] as? String == table+".jsonl" }!
        let hash = try DurableFiles.hash(file); files[index]["bytes"] = hash.0; files[index]["sha256"] = hash.1; m["files"] = files
        try JSONSerialization.data(withJSONObject:m).write(to:manifest)
    }
}
