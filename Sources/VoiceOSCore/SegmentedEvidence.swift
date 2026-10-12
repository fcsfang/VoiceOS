import Foundation

public enum SegmentEvidenceKind: String, Codable, Sendable {
    case statement, question, possibleAction, condition, negation, correction, quotation, incompleteBoundary
}
/// A decoded local proposal, not proof of a successful model attempt.
public struct SegmentEvidenceProposal: Codable, Sendable {
    public let kind: SegmentEvidenceKind
    public let statement: String
    public let quote: String
    public let textStart: Int
    public let textEnd: Int
    public let spanIDs: [String]
    public init(kind: SegmentEvidenceKind, statement: String, quote: String, textStart: Int, textEnd: Int, spanIDs: [String]) {
        self.kind = kind; self.statement = statement; self.quote = quote
        self.textStart = textStart; self.textEnd = textEnd; self.spanIDs = spanIDs
    }
}
public struct SegmentEvidenceInput: Codable, Sendable {
    public let segmentID: String
    public let proposals: [SegmentEvidenceProposal]
    public init(segmentID: String, proposals: [SegmentEvidenceProposal]) { self.segmentID = segmentID; self.proposals = proposals }
}
public struct ValidatedSegmentEvidence: Codable, Identifiable, Sendable {
    public let id: String
    public let segmentID: String
    public let ordinal: Int
    public let proposal: SegmentEvidenceProposal
    public let references: [TranscriptSegmentReference]
}
/// Local evidence preparation only. No receipts, execution grant, accepted claims,
/// model usage or external task authorization can be inferred from this ledger.
public struct SegmentedEvidenceLedger: Codable, Sendable {
    public let batchID: String
    public let scopeDigest: String
    public let segmentIDs: [String]
    public let evidence: [ValidatedSegmentEvidence]
    public let requiresBoundaryResolution: Bool
    /// Exactly this JSON is budgeted, including provenance and empty-segment coverage.
    public let payloadJSON: String
    public let contentDigest: String
}
extension VoiceOSStore {
    public func prepareSegmentedEvidenceLedger(batchID: String, inputs: [SegmentEvidenceInput],
        extraction: ModelConfiguration, aggregation: ModelConfiguration) throws -> SegmentedEvidenceLedger {
        let batch = try segmentedProcessingBatch(id:batchID)
        guard batch.state == .queued else { throw VoiceOSError("分段批次已取消、阻塞或冻结") }
        try validateSegmentedExpressionProcessingScope(batch.scope,extraction:extraction,aggregation:aggregation)
        return try Self.segmentedEvidenceLedger(batchID:batchID,scope:batch.scope,inputs:inputs)
    }
    public func validateSegmentedEvidenceLedger(_ ledger: SegmentedEvidenceLedger, inputs: [SegmentEvidenceInput],
        extraction: ModelConfiguration, aggregation: ModelConfiguration) throws {
        let current = try prepareSegmentedEvidenceLedger(batchID:ledger.batchID,inputs:inputs,
            extraction:extraction,aggregation:aggregation)
        guard try Self.relevanceJSON(current) == Self.relevanceJSON(ledger) else {
            throw VoiceOSError("整篇证据、覆盖范围或摘要已变化")
        }
    }
    static func segmentedEvidenceLedger(batchID: String, scope: SegmentedExpressionProcessingScope,
        inputs: [SegmentEvidenceInput]) throws -> SegmentedEvidenceLedger {
        let plan = scope.plan
        let expected = plan.segments.map(\.id)
        guard inputs.count == expected.count, Set(inputs.map(\.segmentID)).count == inputs.count,
              Set(inputs.map(\.segmentID)) == Set(expected) else { throw VoiceOSError("整篇证据需要每段恰好一份输入，不能缺段或重复") }
        let byID = Dictionary(uniqueKeysWithValues:inputs.map { ($0.segmentID,$0) })
        let scalars = Array(plan.source.text.unicodeScalars)
        var boundaries: Set<Int> = [0], offset = 0
        for character in plan.source.text { offset += String(character).unicodeScalars.count; boundaries.insert(offset) }
        var evidence: [ValidatedSegmentEvidence] = []
        for segment in plan.segments {
            for (ordinal, proposal) in byID[segment.id]!.proposals.enumerated() {
                guard !proposal.statement.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
                      proposal.statement.unicodeScalars.count <= 1000, !proposal.quote.isEmpty,
                      proposal.textStart >= segment.textStart, proposal.textEnd <= segment.textEnd,
                      proposal.textStart < proposal.textEnd,
                      String(String.UnicodeScalarView(scalars[proposal.textStart..<proposal.textEnd])) == proposal.quote else {
                    throw VoiceOSError("片段证据必须逐字引用本段原文，不能越界或截断说明")
                }
                // Exact scalar matches are insufficient if a quote splits a grapheme.
                guard boundaries.contains(proposal.textStart), boundaries.contains(proposal.textEnd) else {
                    throw VoiceOSError("片段引用不能拆开完整字符")
                }
                let refs = segment.references.compactMap { ref -> TranscriptSegmentReference? in
                    let start = max(ref.textStart,proposal.textStart), end = min(ref.textEnd,proposal.textEnd)
                    guard start < end else { return nil }
                    return .init(spanID:ref.spanID,textStart:start,textEnd:end,
                        containingSpanStartMS:ref.containingSpanStartMS,containingSpanEndMS:ref.containingSpanEndMS)
                }
                guard !refs.isEmpty, proposal.spanIDs == refs.map(\.spanID),
                      refs.first?.textStart == proposal.textStart, refs.last?.textEnd == proposal.textEnd else {
                    throw VoiceOSError("片段证据的原片段引用不完整或被替换")
                }
                let id = relevanceHash(Data("\(scope.contentDigest):\(segment.id):\(ordinal):\(try relevanceJSON(proposal))".utf8))
                evidence.append(.init(id:id,segmentID:segment.id,ordinal:ordinal,proposal:proposal,references:refs))
            }
        }
        struct Payload: Codable {
            let batchID: String
            let scopeDigest: String
            let segmentIDs: [String]
            let evidence: [ValidatedSegmentEvidence]
            let requiresBoundaryResolution: Bool
        }
        let pending = evidence.contains { $0.proposal.kind == .incompleteBoundary }
        let payload = try relevanceJSON(Payload(batchID:batchID,scopeDigest:scope.contentDigest,
            segmentIDs:expected,evidence:evidence,requiresBoundaryResolution:pending))
        guard payload.unicodeScalars.count <= scope.evidenceScalarBudget else { throw VoiceOSError("整篇证据超过聚合预算，未丢弃提案或否定条件") }
        return .init(batchID:batchID,scopeDigest:scope.contentDigest,segmentIDs:expected,evidence:evidence,
            requiresBoundaryResolution:pending,payloadJSON:payload,contentDigest:relevanceHash(Data(payload.utf8)))
    }
}
