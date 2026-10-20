import XCTest
@testable import VoiceOSCore

private struct EvidenceInspector: MediaInspector {
    func inspect(_ url: URL) async throws -> MediaInfo { throw VoiceOSError("text-only fixture") }
}
final class SegmentedEvidenceTests: XCTestCase {
    func config() -> ModelConfiguration { .init(provider:"evidence-test",model:"no-dispatch",promptVersion:"v1",schemaVersion:"v1",destination:.local) }
    func scope(_ text: String = "我会整理笔记。后来改主意，先不做了。", budget: Int = 10, evidenceBudget: Int = 4000) throws -> SegmentedExpressionProcessingScope {
        let source = ContextTranscript(sourceID:UUID().uuidString,sourceVersionID:UUID().uuidString,transcriptVersionID:UUID().uuidString,
            origin:"user",speaker:"user",localOnly:true,text:text,spans:[TranscriptSpan(textStart:0,textEnd:text.unicodeScalars.count,startMS:0,endMS:2000)])
        let plan = try VoiceOSStore.segmentTranscript(source,policyVersion:1,scalarBudget:budget)
        return .init(id:UUID().uuidString,plan:plan,extraction:ProcessingModelIdentity(config()),aggregation:ProcessingModelIdentity(config()),
            evidenceScalarBudget:evidenceBudget,contentDigest:try VoiceOSStore.segmentedScopeDigest(plan:plan,extraction:ProcessingModelIdentity(config()),aggregation:ProcessingModelIdentity(config()),evidenceBudget:evidenceBudget))
    }
    func inputs(_ scope: SegmentedExpressionProcessingScope) -> [SegmentEvidenceInput] {
        scope.plan.segments.map { .init(segmentID:$0.id,proposals:[]) }
    }
    func proposal(_ segment: TranscriptSegment, kind: SegmentEvidenceKind) -> SegmentEvidenceProposal {
        .init(kind:kind,statement:kind == .possibleAction ? "潜在行动，尚未整篇判断" : "后文证据，尚未判断",
            quote:segment.text,textStart:segment.textStart,textEnd:segment.textEnd,spanIDs:segment.references.map(\.spanID))
    }
    func ledger(_ scope: SegmentedExpressionProcessingScope,_ records: [SegmentEvidenceInput]) throws -> SegmentedEvidenceLedger {
        try VoiceOSStore.segmentedEvidenceLedger(batchID:"synthetic-batch",scope:scope,inputs:records)
    }
    func testAllSegmentsAndLaterNegationPreservedInOriginalOrder() throws {
        let s = try scope(), first = s.plan.segments.first!, last = s.plan.segments.last!
        var records = inputs(s)
        records[0] = .init(segmentID:first.id,proposals:[proposal(first,kind:.possibleAction)])
        records[records.count-1] = .init(segmentID:last.id,proposals:[proposal(last,kind:.negation)])
        let a = try ledger(s,records), b = try ledger(s,Array(records.reversed()))
        XCTAssertEqual(a.contentDigest,b.contentDigest)
        XCTAssertEqual(a.evidence.map { $0.proposal.kind },[.possibleAction,.negation])
        XCTAssertEqual(a.evidence.map { $0.proposal.quote },[first.text,last.text])
        XCTAssertEqual(a.segmentIDs,s.plan.segments.map(\.id))
        XCTAssertEqual(a.evidence[1].references[0].containingSpanStartMS,0)
    }
    func testMissingDuplicateAndUnknownSegmentInputsRejected() throws {
        let s = try scope(), records = inputs(s)
        XCTAssertThrowsError(try ledger(s,Array(records.dropLast())))
        var duplicate = records; duplicate[duplicate.count-1] = duplicate[0]
        XCTAssertThrowsError(try ledger(s,duplicate))
        var wrong = records; wrong[0] = .init(segmentID:"invented",proposals:[])
        XCTAssertThrowsError(try ledger(s,wrong))
        let empty = try ledger(s,records); XCTAssertTrue(empty.evidence.isEmpty)
        XCTAssertEqual(empty.segmentIDs.count,records.count)
    }
    func testForgedQuoteWrongSpanAndCrossSegmentRangeRejected() throws {
        let s = try scope(), segment = s.plan.segments[0], original = proposal(segment,kind:.statement)
        let invalid = [
            SegmentEvidenceProposal(kind:.statement,statement:"说明",quote:"伪造",textStart:original.textStart,textEnd:original.textEnd,spanIDs:original.spanIDs),
            .init(kind:.statement,statement:"说明",quote:original.quote,textStart:original.textStart,textEnd:original.textEnd,spanIDs:["invented"]),
            .init(kind:.statement,statement:"说明",quote:s.plan.source.text,textStart:0,textEnd:s.plan.source.text.unicodeScalars.count,spanIDs:original.spanIDs)]
        for p in invalid {
            var records = inputs(s); records[0] = .init(segmentID:segment.id,proposals:[p])
            XCTAssertThrowsError(try ledger(s,records))
        }
    }
    func testCrossSpanQuoteRequiresEveryOriginalSpanAndRetainsContainingTimes() throws {
        let text = "abcdefghi.klmnopqrst."
        let source = ContextTranscript(sourceID:UUID().uuidString,sourceVersionID:UUID().uuidString,transcriptVersionID:UUID().uuidString,
            origin:"user",speaker:"user",localOnly:true,text:text,
            spans:[TranscriptSpan(textStart:0,textEnd:3,startMS:0,endMS:300),TranscriptSpan(textStart:3,textEnd:text.unicodeScalars.count,startMS:300,endMS:2000)])
        let plan = try VoiceOSStore.segmentTranscript(source,policyVersion:1,scalarBudget:10)
        let s = SegmentedExpressionProcessingScope(id:UUID().uuidString,plan:plan,extraction:ProcessingModelIdentity(config()),aggregation:ProcessingModelIdentity(config()),evidenceScalarBudget:4000,
            contentDigest:try VoiceOSStore.segmentedScopeDigest(plan:plan,extraction:ProcessingModelIdentity(config()),aggregation:ProcessingModelIdentity(config()),evidenceBudget:4000))
        let segment = plan.segments[0], p = proposal(segment,kind:.statement)
        var records = inputs(s); records[0] = .init(segmentID:segment.id,proposals:[p])
        let valid = try ledger(s,records)
        XCTAssertEqual(valid.evidence[0].references.count,2)
        XCTAssertEqual(valid.evidence[0].references[1].containingSpanEndMS,2000)
        records[0] = .init(segmentID:segment.id,proposals:[.init(kind:p.kind,statement:p.statement,quote:p.quote,textStart:p.textStart,textEnd:p.textEnd,spanIDs:[p.spanIDs[0]])])
        XCTAssertThrowsError(try ledger(s,records))
    }
    func testPartialEmojiQuoteIsRejectedEvenWithExactScalarMatch() throws {
        let s = try scope("甲👨‍👩‍👧‍👦乙。丙丁戊己庚辛壬癸。",budget:15), segment = s.plan.segments[0]
        var records = inputs(s)
        records[0] = .init(segmentID:segment.id,proposals:[.init(kind:.statement,statement:"说明",quote:"👨",textStart:1,textEnd:2,spanIDs:segment.references.map(\.spanID))])
        XCTAssertThrowsError(try ledger(s,records))
    }
    func testEvidenceBudgetOverflowNeverDropsNegationAndBoundaryIsExplicit() throws {
        let small = try scope(evidenceBudget:100), records = inputs(small)
        XCTAssertThrowsError(try ledger(small,records)) // Coverage metadata itself exceeds the explicit budget.
        let s = try scope(), segment = s.plan.segments[0]
        var pending = inputs(s); pending[0] = .init(segmentID:segment.id,proposals:[proposal(segment,kind:.incompleteBoundary)])
        XCTAssertTrue(try ledger(s,pending).requiresBoundaryResolution)
    }
    func testStorePreparationCreatesNoClaimsOrActionsAndRejectsCancelledBatch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = try VoiceOSStore(root:root,inspector:EvidenceInspector()); try await store.recover()
        let id = try await store.recordUserExpression("我会整理笔记。后来改主意，先不做了。")
        let s = try await store.prepareSegmentedExpressionProcessingScope(sourceID:id,extraction:config(),aggregation:config(),segmentScalarBudget:10)
        let batch = try await store.enqueueSegmentedProcessingBatch(s,extraction:config(),aggregation:config())
        let records = inputs(s)
        let prepared = try await store.prepareSegmentedEvidenceLedger(batchID:batch.id,inputs:records,extraction:config(),aggregation:config())
        XCTAssertTrue(prepared.evidence.isEmpty)
        try await store.validateSegmentedEvidenceLedger(prepared,inputs:records,extraction:config(),aggregation:config())
        let tampered = SegmentedEvidenceLedger(batchID:prepared.batchID,scopeDigest:prepared.scopeDigest,segmentIDs:prepared.segmentIDs,
            evidence:prepared.evidence,requiresBoundaryResolution:prepared.requiresBoundaryResolution,payloadJSON:"{}",contentDigest:prepared.contentDigest)
        do { try await store.validateSegmentedEvidenceLedger(tampered,inputs:records,extraction:config(),aggregation:config()); XCTFail() } catch {}
        let calls = try await store.modelAttempts(), actions = try await store.actions(); XCTAssertTrue(calls.isEmpty); XCTAssertTrue(actions.isEmpty)
        _ = try await store.cancelSegmentedProcessingBatch(id:batch.id)
        do { _ = try await store.prepareSegmentedEvidenceLedger(batchID:batch.id,inputs:records,extraction:config(),aggregation:config()); XCTFail() } catch {}
    }
}
