import XCTest
import Foundation
@testable import VoiceOSCore

private struct RelevanceInspector: MediaInspector {
    func inspect(_ url: URL) async throws -> MediaInfo { throw VoiceOSError("not media") }
}
private struct AllOriginals: LocalRetrievalPort {
    func rank(query: String, documents: [RetrievalDocument], semantic: Bool) async throws -> [RetrievalMatch] {
        documents.map { RetrievalMatch(documentID: $0.id, score: 1, method: "exact") }
    }
}
private actor PausedSelector: LocalRelevancePort {
    var started = false
    var waiter: CheckedContinuation<Void, Never>?
    var continuation: CheckedContinuation<RelevanceSelection, Never>?
    var snapshot: RelevanceSnapshot?
    func waitForStart() async { if !started { await withCheckedContinuation { waiter = $0 } } }
    func select(_ value: RelevanceSnapshot) async throws -> RelevanceSelection {
        snapshot = value
        return await withCheckedContinuation { continuation = $0; started = true; waiter?.resume(); waiter = nil }
    }
    func release(empty: Bool = false) {
        guard let snapshot else { return }
        continuation?.resume(returning: RelevanceSelection(snapshotID: snapshot.id, queryID: snapshot.queryID,
                                                           candidateIDs: empty ? [] : [snapshot.candidates[0].id]))
        continuation = nil
    }
}
final class RelevanceSelectionTests: XCTestCase {
    var base: URL!
    override func setUpWithError() throws { base = FileManager.default.temporaryDirectory.appendingPathComponent("relevance-" + UUID().uuidString) }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: base) }
    func setupStore(_ texts: [String]) async throws -> (VoiceOSStore, [RetrievalHit]) {
        let store = try VoiceOSStore(root: base.appendingPathComponent("root"), inspector: RelevanceInspector())
        try await store.recover()
        for text in texts { _ = try await store.recordUserExpression(text) }
        return (store, try await store.retrieve("原文", using: AllOriginals()).hits)
    }
    func testLocalSelectionKeepsExactPrivateProvenanceAndDoesNotCreateDerivedState() async throws {
        let (s, hits) = try await setupStore(["原文：这只是带条件的猜想，尚未验证。🧠"])
        let queryID = UUID()
        let snapshot = try await s.prepareRelevanceSnapshot(query: "哪些条件？", queryID: queryID, candidates: hits)
        XCTAssertEqual(snapshot.destination, .local); XCTAssertTrue(snapshot.candidates[0].document.localOnly)
        let selection = RelevanceSelection(snapshotID: snapshot.id, queryID: queryID, candidateIDs: [hits[0].id])
        let accepted = try await s.acceptRelevanceSelection(selection, for: snapshot, currentQueryID: queryID)
        XCTAssertEqual(accepted[0].document.text, hits[0].document.text)
        XCTAssertEqual(accepted[0].document.spanID, hits[0].document.spanID)
        let claims = try await s.candidateClaims(); let actions = try await s.actions(); let attempts = try await s.modelAttempts()
        XCTAssertTrue(claims.isEmpty); XCTAssertTrue(actions.isEmpty); XCTAssertTrue(attempts.isEmpty)
    }
    func testEmptySelectionIsValidAndDoesNotImplyNoHistory() async throws {
        let (s, hits) = try await setupStore(["原文：自己的生活记录"])
        let queryID = UUID(), snapshot = try await s.prepareRelevanceSnapshot(query: "天文问题", queryID: queryID, candidates: hits)
        let result = try await s.acceptRelevanceSelection(RelevanceSelection(snapshotID: snapshot.id, queryID: queryID, candidateIDs: []), for: snapshot, currentQueryID: queryID)
        XCTAssertTrue(result.isEmpty); let sources = try await s.sources(); XCTAssertEqual(sources.count, 1)
    }
    func testCloudPreviewRequiresQueryAndEverySourceGrantWithoutSilentFiltering() async throws {
        let (s, hits) = try await setupStore(["原文甲", "原文乙"])
        let queryID = UUID()
        do { _ = try await s.prepareRelevanceSnapshot(query: "原文", queryID: queryID, candidates: hits, destination: .cloud, cloudQueryAllowed: true); XCTFail() } catch {}
        _ = try await s.setSourceLocalOnly(sourceID: hits[0].document.sourceID, expectedVersion: 1, localOnly: false)
        let mixed = try await s.retrieve("原文", using: AllOriginals()).hits
        do { _ = try await s.prepareRelevanceSnapshot(query: "原文", queryID: queryID, candidates: mixed, destination: .cloud, cloudQueryAllowed: true); XCTFail() } catch {}
        _ = try await s.setSourceLocalOnly(sourceID: hits[1].document.sourceID, expectedVersion: 1, localOnly: false)
        let publicHits = try await s.retrieve("原文", using: AllOriginals()).hits
        do { _ = try await s.prepareRelevanceSnapshot(query: "原文", queryID: queryID, candidates: publicHits, destination: .cloud); XCTFail() } catch {}
        let snapshot = try await s.prepareRelevanceSnapshot(query: "原文", queryID: queryID, candidates: publicHits, destination: .cloud, cloudQueryAllowed: true)
        XCTAssertEqual(snapshot.candidates.count, 2); try await s.validateRelevanceSnapshot(snapshot, currentQueryID: queryID)
        let attempts = try await s.modelAttempts(); XCTAssertTrue(attempts.isEmpty) // Preview reserves/sends nothing.
    }
    func testRevokedCloudGrantRejectsPreviouslyPreparedPreview() async throws {
        let (s, hits) = try await setupStore(["原文"])
        _ = try await s.setSourceLocalOnly(sourceID: hits[0].document.sourceID, expectedVersion: 1, localOnly: false)
        let allowed = try await s.retrieve("原文", using: AllOriginals()).hits; let queryID = UUID()
        let snapshot = try await s.prepareRelevanceSnapshot(query: "原文", queryID: queryID, candidates: allowed, destination: .cloud, cloudQueryAllowed: true)
        _ = try await s.setSourceLocalOnly(sourceID: hits[0].document.sourceID, expectedVersion: 2, localOnly: true)
        do { try await s.validateRelevanceSnapshot(snapshot, currentQueryID: queryID); XCTFail() } catch {}
    }
    func testChangingUnselectedSourceAlsoInvalidatesSelection() async throws {
        let (s, hits) = try await setupStore(["原文甲", "原文乙"])
        let queryID = UUID(), snapshot = try await s.prepareRelevanceSnapshot(query: "原文", queryID: queryID, candidates: hits)
        _ = try await s.correctTranscript(sourceID: hits[1].document.sourceID, expectedVersionID: hits[1].document.transcriptVersionID, text: "更正乙")
        let selection = RelevanceSelection(snapshotID: snapshot.id, queryID: queryID, candidateIDs: [hits[0].id])
        do { _ = try await s.acceptRelevanceSelection(selection, for: snapshot, currentQueryID: queryID); XCTFail() } catch {}
        let empty = RelevanceSelection(snapshotID: snapshot.id, queryID: queryID, candidateIDs: [])
        do { _ = try await s.acceptRelevanceSelection(empty, for: snapshot, currentQueryID: queryID); XCTFail() } catch {}
    }
    func testUnknownDuplicateOversizedOrWrongQuerySelectionRejected() async throws {
        let (s, hits) = try await setupStore(["原文"])
        let queryID = UUID(), snapshot = try await s.prepareRelevanceSnapshot(query: "原文", queryID: queryID, candidates: hits)
        let invalid = [RelevanceSelection(snapshotID: "wrong", queryID: queryID, candidateIDs: []),
                       RelevanceSelection(snapshotID: snapshot.id, queryID: UUID(), candidateIDs: []),
                       RelevanceSelection(snapshotID: snapshot.id, queryID: queryID, candidateIDs: ["invented"]),
                       RelevanceSelection(snapshotID: snapshot.id, queryID: queryID, candidateIDs: [hits[0].id, hits[0].id]),
                       RelevanceSelection(snapshotID: snapshot.id, queryID: queryID, candidateIDs: ["a", "b", "c", "d"])]
        for selection in invalid { do { _ = try await s.acceptRelevanceSelection(selection, for: snapshot, currentQueryID: queryID); XCTFail() } catch {} }
        do { try await s.validateRelevanceSnapshot(snapshot, currentQueryID: UUID()); XCTFail() } catch {}
    }
    func testBudgetIncludesQueryUnicodeAndDoesNotTruncate() async throws {
        let (s, hits) = try await setupStore(["原文🧠"])
        let query = "🧠", queryID = UUID()
        let snapshot = try await s.prepareRelevanceSnapshot(query: query, queryID: queryID, candidates: hits, scalarBudget: 4)
        XCTAssertEqual(snapshot.query, query); XCTAssertEqual(snapshot.candidates[0].document.text, "原文🧠")
        for budget in [0, 3, 4001] { do { _ = try await s.prepareRelevanceSnapshot(query: query, queryID: queryID, candidates: hits, scalarBudget: budget); XCTFail() } catch {} }
        do { _ = try await s.prepareRelevanceSnapshot(query: String(repeating: "🧠", count: 513), queryID: queryID, candidates: hits); XCTFail() } catch {}
        do { _ = try await s.prepareRelevanceSnapshot(query: "原文", queryID: queryID, candidates: [hits[0], hits[0]]); XCTFail() } catch {}
    }
    func testCanceledLocalSelectorCannotReturnLateResult() async throws {
        let (s, hits) = try await setupStore(["原文"])
        let port = PausedSelector()
        let task = Task { try await s.selectLocalRelevant(query: "原文", queryID: UUID(), candidates: hits, using: port) }
        await port.waitForStart(); task.cancel(); await port.release()
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testLateLocalSelectorCannotReturnCorrectedInput() async throws {
        let (s, hits) = try await setupStore(["原文"])
        let port = PausedSelector()
        let task = Task { try await s.selectLocalRelevant(query: "原文", queryID: UUID(), candidates: hits, using: port) }
        await port.waitForStart()
        _ = try await s.correctTranscript(sourceID: hits[0].document.sourceID, expectedVersionID: hits[0].document.transcriptVersionID, text: "已改动")
        await port.release(); do { _ = try await task.value; XCTFail() } catch {}
    }
    func testCorruptOriginalRejectsEvenEmptySelection() async throws {
        let (s, hits) = try await setupStore(["原文"])
        let queryID = UUID(), snapshot = try await s.prepareRelevanceSnapshot(query: "原文", queryID: queryID, candidates: hits)
        let sources = try await s.sources()
        try Data("altered".utf8).write(to: base.appendingPathComponent("root").appendingPathComponent(sources[0].relativePath))
        do { _ = try await s.acceptRelevanceSelection(RelevanceSelection(snapshotID: snapshot.id, queryID: queryID, candidateIDs: []), for: snapshot, currentQueryID: queryID); XCTFail() } catch {}
    }
    func testTamperedSnapshotDigestCannotBeAccepted() async throws {
        let (s, hits) = try await setupStore(["原文"])
        let queryID = UUID(), snapshot = try await s.prepareRelevanceSnapshot(query: "原文", queryID: queryID, candidates: hits)
        let tampered = RelevanceSnapshot(id: snapshot.id, queryID: queryID, query: "替换查询", destination: .local,
                                         cloudQueryAllowed: false, candidates: hits, scalarBudget: 4000, contentDigest: snapshot.contentDigest)
        do { try await s.validateRelevanceSnapshot(tampered, currentQueryID: queryID); XCTFail() } catch {}
    }
    func testRegrantDoesNotReactivatePreviousSnapshotAndCandidatesHaveHardLimit() async throws {
        let (s, hits) = try await setupStore((1...9).map { "原文\($0)" })
        let queryID = UUID()
        do { _ = try await s.prepareRelevanceSnapshot(query: "原文", queryID: queryID, candidates: hits); XCTFail() } catch {}
        let one = [hits[0]], sourceID = hits[0].document.sourceID
        let snapshot = try await s.prepareRelevanceSnapshot(query: "原文", queryID: queryID, candidates: one)
        _ = try await s.setSourceLocalOnly(sourceID: sourceID, expectedVersion: 1, localOnly: false)
        _ = try await s.setSourceLocalOnly(sourceID: sourceID, expectedVersion: 2, localOnly: true)
        do { try await s.validateRelevanceSnapshot(snapshot, currentQueryID: queryID); XCTFail() } catch {}
    }
    func testDecodedDocumentCannotForgeIdentityOrSpeakerOrigin() async throws {
        let (s, hits) = try await setupStore(["原文"])
        let data = try JSONEncoder().encode(hits[0].document)
        for (key, value) in [("id", "invented"), ("origin", "external"), ("name", "invented")] {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]); json[key] = value
            let doc = try JSONDecoder().decode(RetrievalDocument.self, from: JSONSerialization.data(withJSONObject: json))
            let hit = RetrievalHit(document: doc, method: "exact", score: 1)
            do { _ = try await s.prepareRelevanceSnapshot(query: "原文", queryID: UUID(), candidates: [hit]); XCTFail() } catch {}
        }
    }
    func testInvalidScoresAndMethodsCannotEnterSnapshot() async throws {
        let (s, hits) = try await setupStore(["原文"])
        for hit in [RetrievalHit(document: hits[0].document, method: "verified", score: 1),
                    RetrievalHit(document: hits[0].document, method: "exact", score: .nan),
                    RetrievalHit(document: hits[0].document, method: "exact", score: 1.1)] {
            do { _ = try await s.prepareRelevanceSnapshot(query: "原文", queryID: UUID(), candidates: [hit]); XCTFail() } catch {}
        }
        let cold = try VoiceOSStore(root: base.appendingPathComponent("cold"), inspector: RelevanceInspector())
        do { try await cold.validateRetrievalHit(hits[0]); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("恢复")) }
    }
}
