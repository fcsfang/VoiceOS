import XCTest
@testable import VoiceOSCore

final class SegmentAggregationValidationTests: XCTestCase {
    func ledger(boundary: Bool = false) throws -> SegmentedEvidenceLedger {
        let helper = SegmentedEvidenceTests(), scope = try helper.scope("明天整理笔记。整理同一份笔记。以后再整理笔记。后来决定先不做。",budget:10,evidenceBudget:4000)
        var inputs = helper.inputs(scope)
        for i in 0..<3 { inputs[i] = .init(segmentID:scope.plan.segments[i].id,proposals:[helper.proposal(scope.plan.segments[i],kind:.possibleAction)]) }
        let last = inputs.count-1
        inputs[last] = .init(segmentID:scope.plan.segments[last].id,proposals:[helper.proposal(scope.plan.segments[last],kind:boundary ? .incompleteBoundary:.negation)])
        return try helper.ledger(scope,inputs)
    }
    func decision(_ id: String, _ disposition: SegmentActionDisposition = .reject, target: String? = nil,
                  support: [String]? = nil, explanation: String = "综合原话判断，暂存而不创建任务") -> SegmentActionDecision {
        .init(evidenceID:id,disposition:disposition,supportingEvidenceIDs:support ?? ([id]+(target.map { [$0] } ?? [])),duplicateOf:target,explanation:explanation)
    }
    func review(_ l: SegmentedEvidenceLedger, decisions: [SegmentActionDecision]? = nil, reviewed: [String]? = nil,
                batch: String? = nil, digest: String? = nil) -> SegmentAggregationReview {
        .init(batchID:batch ?? l.batchID,ledgerDigest:digest ?? l.contentDigest,reviewedEvidenceIDs:reviewed ?? l.evidence.map(\.id),
            actionDecisions:decisions ?? l.evidence.filter { $0.proposal.kind == .possibleAction }.map { decision($0.id) })
    }
    func validate(_ r: SegmentAggregationReview,_ l: SegmentedEvidenceLedger) throws -> ValidatedSegmentAggregation {
        try VoiceOSStore.validateSegmentAggregationReview(r,ledger:l)
    }
    func testWholeReviewRetainsNegationAndNormalizesResponseOrder() throws {
        let l = try ledger(), a = try validate(review(l),l)
        let b = try validate(review(l,decisions:Array(a.review.actionDecisions.reversed()),reviewed:Array(l.evidence.map(\.id).reversed())),l)
        XCTAssertEqual(a.contentDigest,b.contentDigest)
        XCTAssertEqual(a.review.reviewedEvidenceIDs,l.evidence.map(\.id))
        XCTAssertEqual(a.review.actionDecisions.count,3)
    }
    func testMissingRepeatedAndInventedActionDecisionsRejected() throws {
        let l = try ledger(), good = review(l).actionDecisions
        XCTAssertThrowsError(try validate(review(l,decisions:Array(good.dropLast())),l))
        XCTAssertThrowsError(try validate(review(l,decisions:[good[0],good[0],good[2]]),l))
        XCTAssertThrowsError(try validate(review(l,decisions:[good[0],good[1],decision("invented")]),l))
    }
    func testEveryEvidenceAndMatchingLedgerIdentityRequired() throws {
        let l = try ledger(), all = l.evidence.map(\.id)
        XCTAssertThrowsError(try validate(review(l,reviewed:Array(all.dropLast())),l))
        XCTAssertThrowsError(try validate(review(l,reviewed:all+[all[0]]),l))
        XCTAssertThrowsError(try validate(review(l,batch:"other"),l))
        XCTAssertThrowsError(try validate(review(l,digest:"other"),l))
    }
    func testDuplicateChainsResolveToAcceptedItemWithoutTitleHeuristics() throws {
        let l = try ledger(), ids = review(l).actionDecisions.map(\.evidenceID)
        let decisions = [decision(ids[0],.accept),decision(ids[1],.duplicate,target:ids[0]),decision(ids[2],.duplicate,target:ids[1])]
        let result = try validate(review(l,decisions:decisions),l)
        XCTAssertEqual(result.review.actionDecisions.map(\.disposition),[.accept,.duplicate,.duplicate])
    }
    func testSelfCyclesMissingTargetsAndDiscardedDuplicateRootsRejected() throws {
        let l = try ledger(), ids = review(l).actionDecisions.map(\.evidenceID)
        for ds in [
            [decision(ids[0],.duplicate,target:ids[0]),decision(ids[1]),decision(ids[2])],
            [decision(ids[0],.duplicate,target:ids[1]),decision(ids[1],.duplicate,target:ids[0]),decision(ids[2])],
            [decision(ids[0],.duplicate,target:"invented"),decision(ids[1]),decision(ids[2])],
            [decision(ids[0],.duplicate,target:ids[1]),decision(ids[1],.ambiguous),decision(ids[2])],
            [decision(ids[0],.duplicate,target:ids[1]),decision(ids[1],.reject),decision(ids[2])],
            [decision(ids[0],.accept,target:ids[1]),decision(ids[1]),decision(ids[2])]
        ] { XCTAssertThrowsError(try validate(review(l,decisions:ds),l)) }
    }
    func testSupportAndExplanationMustBindToActualEvidence() throws {
        let l = try ledger(), ds = review(l).actionDecisions, id = ds[0].evidenceID
        for bad in [decision(id,support:[]),decision(id,support:[id,id]),decision(id,support:[id,"invented"]),
                    decision(id,explanation:"  "),decision(id,explanation:String(repeating:"x",count:1001)),
                    decision(id,.duplicate,target:ds[1].evidenceID,support:[id])] {
            XCTAssertThrowsError(try validate(review(l,decisions:[bad,ds[1],ds[2]]),l))
        }
    }
    func testUnresolvedBoundaryBlocksReviewAndEmptyLedgerIsValid() throws {
        let pending = try ledger(boundary:true)
        XCTAssertThrowsError(try validate(review(pending),pending))
        let helper = SegmentedEvidenceTests(), scope = try helper.scope()
        let empty = try helper.ledger(scope,helper.inputs(scope))
        XCTAssertTrue(try validate(review(empty),empty).review.actionDecisions.isEmpty)
        XCTAssertEqual(try validate(review(empty),empty).review.reviewedEvidenceIDs,[])
    }
}
