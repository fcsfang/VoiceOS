import Foundation

/// Read-only preparation. A snapshot grants neither model dispatch nor factual status.
public struct ExpressionAssociationSnapshot: Codable, Sendable {
    public let id: String
    public let current: LocalTranscriptContext
    public let policyVersion: Int
    public let destination: ModelDestination
    public let candidates: [RetrievalHit]
    public let preferenceVersion: Int
    public let preferenceMode: CognitiveFeedbackMode
    public let scalarBudget: Int
    public let contentDigest: String
}
public enum ExpressionRelation: String, Codable, Sendable {
    case continuation, qualification, possibleCorrection, sameQuestion
}
public struct ExpressionAssociationProposal: Codable, Sendable {
    public let candidateID: String
    public let current: OutcomeSourceEvidence
    public let historicalQuote: String
    public let relation: ExpressionRelation
    public let reason: String
    public init(candidateID: String, current: OutcomeSourceEvidence, historicalQuote: String, relation: ExpressionRelation, reason: String) {
        self.candidateID = candidateID; self.current = current; self.historicalQuote = historicalQuote
        self.relation = relation; self.reason = reason
    }
}
extension VoiceOSStore {
    public func prepareExpressionAssociation(currentSourceID: String, candidates: [RetrievalHit], destination: ModelDestination = .local, scalarBudget: Int = 8000) throws -> ExpressionAssociationSnapshot {
        guard ready, (1...8000).contains(scalarBudget), candidates.count <= 8,
              Set(candidates.map(\.id)).count == candidates.count,
              candidates.allSatisfy({ $0.document.sourceID != currentSourceID }) else { throw VoiceOSError("表达关联来源重复、自引用或超过范围") }
        let preference = try cognitiveFeedbackPreference()
        guard preference.mode != .paused else { throw VoiceOSError("静默关联已暂停，不准备新判断") }
        let current = try prepareLocalTranscriptContext(sourceIDs: [currentSourceID], scalarBudget: scalarBudget)
        let source = current.sources[0], policy = try sourcePolicy(sourceID: currentSourceID)
        guard source.origin == "user", source.speaker == "user", !source.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VoiceOSError("关联当前表达必须是明确的个人原话") }
        for hit in candidates {
            guard hit.score.isFinite, (0...1).contains(hit.score), ["exact", "local_semantic"].contains(hit.method) else { throw VoiceOSError("关联候选方法或分数无效") }
            try validateRetrievalHit(hit)
        }
        guard source.text.unicodeScalars.count + candidates.reduce(0, { $0 + $1.document.text.unicodeScalars.count }) <= scalarBudget else { throw VoiceOSError("表达关联超出全文预算；没有裁剪原话或候选") }
        guard destination != .cloud || (!policy.localOnly && candidates.allSatisfy({ !$0.document.localOnly })) else { throw VoiceOSError("表达或历史候选尚未全部允许文本云端处理") }
        let value = ExpressionAssociationSnapshot(id: UUID().uuidString, current: current, policyVersion: policy.version, destination: destination, candidates: candidates, preferenceVersion: preference.version, preferenceMode: preference.mode, scalarBudget: scalarBudget, contentDigest: "")
        return ExpressionAssociationSnapshot(id: value.id, current: current, policyVersion: policy.version, destination: destination, candidates: candidates, preferenceVersion: preference.version, preferenceMode: preference.mode, scalarBudget: scalarBudget, contentDigest: try Self.expressionAssociationDigest(value))
    }
    public func validateExpressionAssociation(_ snapshot: ExpressionAssociationSnapshot) throws {
        guard UUID(uuidString: snapshot.id) != nil, let source = snapshot.current.sources.first,
              snapshot.current.sources.count == 1, snapshot.current.scalarBudget == snapshot.scalarBudget else { throw VoiceOSError("表达关联快照身份或当前来源范围不符") }
        let actual = try prepareExpressionAssociation(currentSourceID: source.sourceID, candidates: snapshot.candidates, destination: snapshot.destination, scalarBudget: snapshot.scalarBudget)
        guard actual.contentDigest == snapshot.contentDigest,
              try Self.expressionAssociationDigest(snapshot) == snapshot.contentDigest else { throw VoiceOSError("表达、历史、授权或反馈偏好已变化") }
    }
    static func expressionAssociationDigest(_ snapshot: ExpressionAssociationSnapshot) throws -> String {
        struct Payload: Encodable {
            let purpose = "expression-association-v1"
            let current: LocalTranscriptContext
            let policyVersion: Int
            let destination: ModelDestination
            let candidates: [RetrievalHit]
            let preferenceVersion: Int
            let preferenceMode: CognitiveFeedbackMode
            let scalarBudget: Int
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return relevanceHash(try encoder.encode(Payload(current: snapshot.current, policyVersion: snapshot.policyVersion, destination: snapshot.destination, candidates: snapshot.candidates, preferenceVersion: snapshot.preferenceVersion, preferenceMode: snapshot.preferenceMode, scalarBudget: snapshot.scalarBudget)))
    }
    /// Only validates provenance/structure, never whether the relation is semantically true.
    public static func validateExpressionAssociationProposals(_ proposals: [ExpressionAssociationProposal], snapshot: ExpressionAssociationSnapshot) throws {
        guard snapshot.current.sources.count == 1, snapshot.preferenceMode != .paused,
              try expressionAssociationDigest(snapshot) == snapshot.contentDigest,
              proposals.count <= (snapshot.preferenceMode == .reduced ? 1 : 3) else { throw VoiceOSError("关联提案快照或数量不符") }
        let source = snapshot.current.sources[0]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard UUID(uuidString: snapshot.id) != nil, snapshot.policyVersion > 0, snapshot.preferenceVersion >= 0,
              (1...8000).contains(snapshot.scalarBudget), snapshot.current.scalarBudget == snapshot.scalarBudget,
              source.origin == "user", source.speaker == "user", !source.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              snapshot.current.contentDigest == relevanceHash(try encoder.encode(snapshot.current.sources)),
              snapshot.candidates.count <= 8, Set(snapshot.candidates.map(\.id)).count == snapshot.candidates.count,
              snapshot.candidates.allSatisfy({ $0.document.sourceID != source.sourceID && $0.score.isFinite && (0...1).contains($0.score) && ["exact", "local_semantic"].contains($0.method) }),
              source.text.unicodeScalars.count + snapshot.candidates.reduce(0, { $0 + $1.document.text.unicodeScalars.count }) <= snapshot.scalarBudget,
              snapshot.destination != .cloud || (!source.localOnly && snapshot.candidates.allSatisfy({ !$0.document.localOnly })) else { throw VoiceOSError("关联快照来源、预算、权限或目录结构无效") }
        try SpeechText(text: source.text, spans: source.spans).validate(duration: source.spans.compactMap(\.endMS).max().map { Double($0)/1000 })
        var seen = Set<String>()
        for proposal in proposals {
            let ref = proposal.current.reference
            guard seen.insert(proposal.candidateID).inserted,
                  let hit = snapshot.candidates.first(where: { $0.id == proposal.candidateID }),
                  ref.sourceID == source.sourceID, ref.transcriptVersionID == source.transcriptVersionID,
                  let span = source.spans.first(where: { $0.id == ref.spanID }),
                  !proposal.current.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !proposal.historicalQuote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  proposal.current.quote.unicodeScalars.count <= 2000, proposal.historicalQuote.unicodeScalars.count <= 2000,
                  !proposal.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, proposal.reason.unicodeScalars.count <= 600,
                  hit.document.text.contains(proposal.historicalQuote) else { throw VoiceOSError("关联理由、候选或双方出处不符") }
            let scalars = Array(source.text.unicodeScalars)
            guard String(String.UnicodeScalarView(scalars[span.textStart..<span.textEnd])).contains(proposal.current.quote) else { throw VoiceOSError("关联当前引文不是连续原话") }
        }
    }
}
