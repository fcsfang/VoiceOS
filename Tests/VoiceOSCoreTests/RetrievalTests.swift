import XCTest
import Foundation
@testable import VoiceOSCore
import VoiceOSPlatform
import NaturalLanguage

private struct RetrievalInspector: MediaInspector {
    func inspect(_ url: URL) async throws -> MediaInfo { throw VoiceOSError("not media") }
}
private struct ExactSearch: LocalRetrievalPort {
    func rank(query: String, documents: [RetrievalDocument], semantic: Bool) async throws -> [RetrievalMatch] {
        documents.filter { $0.text.contains(query) }.map { RetrievalMatch(documentID:$0.id,score:1,method:"exact") }
    }
}
private actor DelayedSearch: LocalRetrievalPort {
    var ready = false
    var waiter: CheckedContinuation<Void,Never>?
    var continuation: CheckedContinuation<[RetrievalMatch],Never>?
    var docs: [RetrievalDocument] = []
    func waitForStart() async { if !ready { await withCheckedContinuation { waiter = $0 } } }
    func rank(query: String, documents: [RetrievalDocument], semantic: Bool) async throws -> [RetrievalMatch] {
        docs = documents
        return await withCheckedContinuation { continuation = $0; ready = true; waiter?.resume(); waiter = nil }
    }
    func release() { continuation?.resume(returning:docs.map { RetrievalMatch(documentID:$0.id,score:1,method:"exact") }); continuation = nil }
}
private struct InvalidSearch: LocalRetrievalPort {
    let mode: Int
    func rank(query: String, documents: [RetrievalDocument], semantic: Bool) async throws -> [RetrievalMatch] {
        let id = documents[0].id
        if mode == 0 { return [RetrievalMatch(documentID:"invented",score:1,method:"exact")] }
        if mode == 1 { return [RetrievalMatch(documentID:id,score:.nan,method:"exact")] }
        if mode == 2 { return [RetrievalMatch(documentID:id,score:1,method:"verified")] }
        return [RetrievalMatch(documentID:id,score:1,method:"exact"),RetrievalMatch(documentID:id,score:1,method:"exact")]
    }
}
final class RetrievalTests: XCTestCase {
    var base: URL!
    override func setUpWithError() throws { base = FileManager.default.temporaryDirectory.appendingPathComponent("retrieval-"+UUID().uuidString) }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at:base) }
    func store() async throws -> VoiceOSStore {
        let s = try VoiceOSStore(root:base.appendingPathComponent("root"),inspector:RetrievalInspector()); try await s.recover(); return s
    }
    func testLocalPrivateSearchReturnsOriginalQuoteAndStableProvenance() async throws {
        let s = try await store(); let id = try await s.recordUserExpression("只有检索可靠时，增加上下文才可能有用；我还没验证。🧠")
        let result = try await s.retrieve("还没验证",using:ExactSearch()); let hit = try XCTUnwrap(result.hits.first)
        XCTAssertEqual(hit.document.sourceID,id); XCTAssertTrue(hit.document.localOnly); XCTAssertEqual(hit.document.origin,"user")
        XCTAssertTrue(hit.document.text.contains("只有检索可靠时")); try await s.validateRetrievalHit(hit)
        let claims = try await s.candidateClaims(); let actions = try await s.actions(); XCTAssertTrue(claims.isEmpty); XCTAssertTrue(actions.isEmpty)
    }
    func testCorrectionRemovesOldVersionAndRejectsOldHit() async throws {
        let s = try await store(); let id = try await s.recordUserExpression("旧错误：无条件有效")
        let old = try await s.retrieve("旧错误",using:ExactSearch()); let hit = try XCTUnwrap(old.hits.first)
        _ = try await s.correctTranscript(sourceID:id,expectedVersionID:hit.document.transcriptVersionID,text:"更正：只在限定条件下有效")
        do { try await s.validateRetrievalHit(hit); XCTFail() } catch {}
        let missing = try await s.retrieve("旧错误",using:ExactSearch()); XCTAssertTrue(missing.hits.isEmpty)
        let current = try await s.retrieve("限定条件",using:ExactSearch()); XCTAssertEqual(current.hits.count,1)
    }
    func testLateSearchCannotReturnCorrectedSource() async throws {
        let s = try await store(); let id = try await s.recordUserExpression("待纠正原文")
        let rows = try await s.sources(); let source = try XCTUnwrap(rows.first)
        let port = DelayedSearch(); let task = Task { try await s.retrieve("原文",using:port) }
        await port.waitForStart()
        _ = try await s.correctTranscript(sourceID:id,expectedVersionID:source.transcriptVersionID!,text:"当前原文")
        await port.release(); do { _ = try await task.value; XCTFail() } catch {}
    }
    func testLateSearchCannotBypassChangedPolicy() async throws {
        let s = try await store(); let id = try await s.recordUserExpression("受限原文")
        let port = DelayedSearch(); let task = Task { try await s.retrieve("原文",using:port) }; await port.waitForStart()
        _ = try await s.setSourceLocalOnly(sourceID:id,expectedVersion:1,localOnly:false)
        await port.release(); do { _ = try await task.value; XCTFail() } catch {}
        let fresh = try await s.retrieve("原文",using:ExactSearch()); XCTAssertFalse(fresh.hits[0].document.localOnly)
    }
    func testCancellationDiscardsLateRankResult() async throws {
        let s = try await store(); _ = try await s.recordUserExpression("可取消查找")
        let port = DelayedSearch(); let task = Task { try await s.retrieve("查找",using:port) }; await port.waitForStart()
        task.cancel(); await port.release(); do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testUntrustedRankerCannotInventQuoteOrResultIdentity() async throws {
        let s = try await store(); _ = try await s.recordUserExpression("原文")
        for mode in 0...3 { do { _ = try await s.retrieve("原文",using:InvalidSearch(mode:mode)); XCTFail() } catch {} }
    }
    func testFragmentBoundaryUnicodeAndSourceDeduplication() async throws {
        let s = try await store()
        let query = String(repeating:"🧠",count:512)
        _ = try await s.recordUserExpression(String(repeating:"前",count:700)+query+String(repeating:"后",count:700))
        let result = try await s.retrieve(query,using:ExactSearch()); XCTAssertEqual(result.hits.count,1); XCTAssertEqual(result.matchingSources,1)
        try await s.validateRetrievalHit(result.hits[0]); XCTAssertGreaterThan(result.scannedFragments,1)
    }
    func testDamagedOriginalCannotRemainSearchable() async throws {
        let s = try await store(); _ = try await s.recordUserExpression("完整原文")
        let rows = try await s.sources(); let source = try XCTUnwrap(rows.first)
        try Data("changed".utf8).write(to:base.appendingPathComponent("root").appendingPathComponent(source.relativePath))
        let result = try await s.retrieve("原文",using:ExactSearch()); XCTAssertTrue(result.hits.isEmpty)
        let updated = try await s.sources(); XCTAssertEqual(updated[0].state,"quarantined")
    }
    func testRestoredReferenceTextRemainsSearchableWithoutProjection() async throws {
        let s = try await store(); let id = try await s.recordUserExpression("迁移后找回反思")
        let package = base.appendingPathComponent("package"); try await s.exportPackage(to:package)
        let target = base.appendingPathComponent("restored"); try await VoiceOSStore.restorePackage(from:package,to:target,inspector:RetrievalInspector())
        let restored = try VoiceOSStore(root:target,inspector:RetrievalInspector()); try await restored.recover()
        let result = try await restored.retrieve("反思",using:ExactSearch()); XCTAssertEqual(result.hits[0].document.sourceID,id)
        try await restored.validateRetrievalHit(result.hits[0])
    }
    func testNativeGateUsesMeasuredSentenceDistanceScale() async throws {
        guard let embedding = NLEmbedding.sentenceEmbedding(for:.simplifiedChinese,revision:1) else { throw XCTSkip("Local Chinese resource unavailable") }
        let s = try await store()
        let texts = ["旧想法：按遗忘曲线安排检索练习。","学习做饭要练刀工。","今天购买了两个苹果。"]
        var ids: [String] = []
        for text in texts { ids.append(try await s.recordUserExpression(text)) }
        let query = "把提取训练放到容易忘的时候会不会更有效？"
        let expected = Set(zip(ids,texts).filter { embedding.distance(between:query,and:$0.1) <= 0.30 }.map { $0.0 })
        let result = try await s.retrieve(query,semantic:true,using:NativeRetrieval())
        XCTAssertEqual(Set(result.hits.map { $0.document.sourceID }),expected)
        for hit in result.hits {
            let distance = embedding.distance(between:query,and:hit.document.text)
            XCTAssertEqual(hit.score,1-distance,accuracy:0.00001)
        }
    }
    func testEnglishSemanticModeDoesNotPretendUnsupportedFallbackIsSemantic() async throws {
        let s = try await store(); _ = try await s.recordUserExpression("Remember earlier ideas")
        do { _ = try await s.retrieve("Remember",semantic:true,using:NativeRetrieval()); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("仅支持中文")) }
        let result = try await s.retrieve("Remember",using:NativeRetrieval()); XCTAssertEqual(result.hits.count,1); XCTAssertEqual(result.hits[0].method,"exact")
    }

}
