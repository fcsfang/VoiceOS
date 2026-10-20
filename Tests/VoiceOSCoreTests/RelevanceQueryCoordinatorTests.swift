import XCTest
import Foundation
import VoiceOSPlatform
@testable import VoiceOSCore

private struct QueryInspector: MediaInspector {
    func inspect(_ url: URL) async throws -> MediaInfo { throw VoiceOSError("not media") }
}
private struct QueryRanker: LocalRetrievalPort {
    func rank(query:String,documents:[RetrievalDocument],semantic:Bool) async throws -> [RetrievalMatch] {
        documents.map { RetrievalMatch(documentID:$0.id,score:1,method:"exact") }
    }
}
private actor QuerySelector: RelevanceModelPort {
    nonisolated let configuration = ModelConfiguration(provider:"synthetic",model:"fixture",promptVersion:"v1",schemaVersion:"v1",destination:.cloud)
    var pending: CheckedContinuation<RelevanceModelResponse,Never>?
    var request: RelevanceModelRequest?
    var waiter: CheckedContinuation<Void,Never>?
    let empty: Bool
    init(empty:Bool = false) { self.empty = empty }
    func select(_ r: RelevanceModelRequest) async throws -> RelevanceModelResponse {
        request = r
        return await withCheckedContinuation { pending = $0; waiter?.resume(); waiter = nil }
    }
    func started() async { if request == nil { await withCheckedContinuation { waiter = $0 } } }
    func release() {
        guard let r = request else { return }
        pending?.resume(returning:RelevanceModelResponse(status:.completed,selection:RelevanceSelection(snapshotID:r.snapshot.id,queryID:r.snapshot.queryID,candidateIDs:empty ? [] : [r.snapshot.candidates[0].id]),inputTokens:11,outputTokens:2))
        pending = nil
    }
}
@MainActor
final class RelevanceQueryCoordinatorTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent("query-"+UUID().uuidString) }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at:root) }
    func setup() async throws -> (VoiceOSStore,[RetrievalHit]) {
        let s = try VoiceOSStore(root:root,inspector:QueryInspector()); try await s.recover()
        let id = try await s.recordUserExpression("仅条件成立才考虑；这是合成资料。")
        _ = try await s.setSourceLocalOnly(sourceID:id,expectedVersion:1,localOnly:false)
        return (s,try await s.retrieve("条件",using:QueryRanker()).hits)
    }
    func eventually(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<200 { if condition() { return }; try await Task.sleep(for:.milliseconds(5)) }
        XCTFail("coordinator did not settle")
    }
    func testCompleteCanDisplayAndConsumedSnapshotCannotSendAgain() async throws {
        let (s,hits) = try await setup(), c = RelevanceQueryCoordinator(), p = QuerySelector()
        await c.prepare(query:"哪些条件？",candidates:hits,store:s); XCTAssertNotNil(c.snapshot)
        c.run(store:s,port:p); await p.started(); await p.release()
        try await eventually { !c.busy }
        XCTAssertEqual(c.hits?.count,1); XCTAssertEqual(c.usage?["input_tokens"],11); XCTAssertNil(c.snapshot)
        c.run(store:s,port:p)
        let rows = try await s.relevanceAttempts(); XCTAssertEqual(rows.count,1)
    }
    func testLateCanceledCallbackCannotReplaceNewQueryPreview() async throws {
        let (s,hits) = try await setup(), c = RelevanceQueryCoordinator(), p = QuerySelector()
        await c.prepare(query:"旧问题",candidates:hits,store:s)
        c.run(store:s,port:p); await p.started()
        c.stop(); XCTAssertTrue(c.status.contains("已停止等待"))
        await c.prepare(query:"新问题",candidates:hits,store:s)
        let id = c.snapshot?.queryID
        await p.release()
        // Wait on the store state, not an arbitrary duration.
        for _ in 0..<200 {
            if try await s.relevanceAttempts().first?.state == "rejected" { break }
            try await Task.sleep(for:.milliseconds(5))
        }
        XCTAssertEqual(c.snapshot?.queryID,id); XCTAssertEqual(c.snapshot?.query,"新问题")
        XCTAssertNil(c.hits); XCTAssertNil(c.usage); XCTAssertFalse(c.busy)
        let rows = try await s.relevanceAttempts(); XCTAssertEqual(rows[0].state,"rejected")
    }
    func testEmptyResultStillInvalidatesWhenExcludedInputChanges() async throws {
        let (s,hits) = try await setup(), c = RelevanceQueryCoordinator(), p = QuerySelector(empty:true)
        await c.prepare(query:"哪些条件？",candidates:hits,store:s)
        c.run(store:s,port:p); await p.started(); await p.release()
        try await eventually { !c.busy }; XCTAssertEqual(c.hits?.count,0)
        _ = try await s.correctTranscript(sourceID:hits[0].document.sourceID,expectedVersionID:hits[0].document.transcriptVersionID,text:"已更正")
        await c.validate(store:s)
        XCTAssertNil(c.hits); XCTAssertTrue(c.status.contains("已变化"))
    }
    func testLocalOnlyPreviewNeverReservesAttempt() async throws {
        let (s,hits) = try await setup(), c = RelevanceQueryCoordinator()
        _ = try await s.setSourceLocalOnly(sourceID:hits[0].document.sourceID,expectedVersion:2,localOnly:true)
        let current = try await s.retrieve("条件",using:QueryRanker()).hits
        await c.prepare(query:"哪些条件？",candidates:current,store:s)
        XCTAssertNil(c.snapshot); XCTAssertFalse(c.busy)
        let rows = try await s.relevanceAttempts(); XCTAssertTrue(rows.isEmpty)
    }
}
