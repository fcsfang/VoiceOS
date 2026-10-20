import Foundation

public enum SegmentActionDisposition: String, Codable, Sendable { case accept, reject, ambiguous, duplicate }
/// Intermediate whole-source judgment. It does not authorize an external action.
public struct SegmentActionDecision: Codable, Sendable {
    public let evidenceID: String
    public let disposition: SegmentActionDisposition
    public let supportingEvidenceIDs: [String]
    public let duplicateOf: String?
    public let explanation: String
    public init(evidenceID: String, disposition: SegmentActionDisposition, supportingEvidenceIDs: [String],
                duplicateOf: String? = nil, explanation: String) {
        self.evidenceID = evidenceID; self.disposition = disposition
        self.supportingEvidenceIDs = supportingEvidenceIDs; self.duplicateOf = duplicateOf; self.explanation = explanation
    }
}
public struct SegmentAggregationReview: Codable, Sendable {
    public let batchID: String
    public let ledgerDigest: String
    public let reviewedEvidenceIDs: [String]
    public let actionDecisions: [SegmentActionDecision]
    public init(batchID: String, ledgerDigest: String, reviewedEvidenceIDs: [String], actionDecisions: [SegmentActionDecision]) {
        self.batchID = batchID; self.ledgerDigest = ledgerDigest
        self.reviewedEvidenceIDs = reviewedEvidenceIDs; self.actionDecisions = actionDecisions
    }
}
/// Local validation only: no aggregation receipt, accepted claim or task is created.
public struct ValidatedSegmentAggregation: Sendable {
    public let review: SegmentAggregationReview
    public let contentDigest: String
}
extension VoiceOSStore {
    public func validatePersistedSegmentAggregationReview(_ review: SegmentAggregationReview,
        extraction: ModelConfiguration, aggregation: ModelConfiguration) throws -> ValidatedSegmentAggregation {
        let ledger = try preparePersistedSegmentedEvidenceLedger(batchID:review.batchID,extraction:extraction,aggregation:aggregation)
        return try Self.validateSegmentAggregationReview(review, ledger:ledger)
    }
    static func validateSegmentAggregationReview(_ review: SegmentAggregationReview,
        ledger: SegmentedEvidenceLedger) throws -> ValidatedSegmentAggregation {
        guard review.batchID == ledger.batchID, review.ledgerDigest == ledger.contentDigest else {
            throw VoiceOSError("聚合判断不属于当前完整证据账本")
        }
        // A model declaration is not proof that a broken sentence was resolved.
        // Until exact boundary context has a separate durable mechanism, fail closed.
        guard !ledger.requiresBoundaryResolution else { throw VoiceOSError("跨段未完句尚未解决，不能接纳整篇聚合判断") }
        let evidenceIDs = ledger.evidence.map(\.id), known = Set(evidenceIDs)
        guard Set(review.reviewedEvidenceIDs) == known, review.reviewedEvidenceIDs.count == known.count else {
            throw VoiceOSError("聚合必须覆盖全部原话证据，不能省略否定或条件")
        }
        let actionIDs = ledger.evidence.filter { $0.proposal.kind == .possibleAction }.map(\.id)
        let actionSet = Set(actionIDs)
        guard Set(review.actionDecisions.map(\.evidenceID)) == actionSet,
              review.actionDecisions.count == actionIDs.count else {
            throw VoiceOSError("聚合必须逐项判断全部潜在行动，不能遗漏、重复或添加身份")
        }
        let decisions = Dictionary(uniqueKeysWithValues:review.actionDecisions.map { ($0.evidenceID,$0) })
        for decision in review.actionDecisions {
            let support = Set(decision.supportingEvidenceIDs)
            guard support.contains(decision.evidenceID), support.isSubset(of:known),
                  support.count == decision.supportingEvidenceIDs.count,
                  !decision.explanation.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
                  decision.explanation.unicodeScalars.count <= 1000 else {
                throw VoiceOSError("行动判断必须有本项及有效原话依据，说明不能为空或超出预算")
            }
            if decision.disposition == .duplicate {
                guard let target = decision.duplicateOf, target != decision.evidenceID,
                      actionSet.contains(target), support.contains(target) else {
                    throw VoiceOSError("重复关系必须指向另一项潜在行动并包含其证据")
                }
            } else if decision.duplicateOf != nil { throw VoiceOSError("非重复判断不能带重复目标") }
        }
        for decision in review.actionDecisions where decision.disposition == .duplicate {
            var visited: Set<String> = [decision.evidenceID], target = decision.duplicateOf!
            while true {
                guard visited.insert(target).inserted, let next = decisions[target] else { throw VoiceOSError("重复关系成环或目标缺失") }
                if next.disposition == .accept { break }
                guard next.disposition == .duplicate, let following = next.duplicateOf else {
                    throw VoiceOSError("重复关系必须最终指向保留项，不能指向拒绝或未明确项")
                }
                target = following
            }
        }
        // Normalize response order against source evidence order, not arrival order.
        let normalized = SegmentAggregationReview(batchID:review.batchID,ledgerDigest:review.ledgerDigest,
            reviewedEvidenceIDs:evidenceIDs,actionDecisions:actionIDs.map { decisions[$0]! })
        return .init(review:normalized,contentDigest:try segmentValueDigest(normalized))
    }
}
