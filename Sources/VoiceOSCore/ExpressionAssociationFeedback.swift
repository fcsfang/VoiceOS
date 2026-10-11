import Foundation

/// Presentation of accepted AI proposals; never grants cloud or notification permission.
public struct ExpressionAssociationFeedback: Identifiable, Sendable {
    public let id: String
    public let attemptID: String
    public let currentSourceID: String
    public let proposal: ExpressionAssociationProposal
    public let historical: RetrievalHit
    /// Questions recorded at this historical citation, not an inferred identity match.
    public let historicalQuestions: [QuestionRecord]
}
extension VoiceOSStore {
    public func expressionAssociationFeedback(currentSourceID: String? = nil, limit: Int = 20) throws -> [ExpressionAssociationFeedback] {
        guard ready, (1...50).contains(limit) else { throw VoiceOSError("表达关联读取范围无效") }
        try Self.validateStoredExpressionAssociationIgnores(db)
        let mode = try cognitiveFeedbackPreference().mode
        if mode == .paused { return [] }
        let registeredQuestions = try questions()
        let ignored = Set(try db.query("SELECT fingerprint FROM expression_association_ignores").compactMap { $0["fingerprint"] })
        let target = mode == .reduced ? 1 : limit
        var items: [ExpressionAssociationFeedback] = [], seen = Set<String>()
        for record in try expressionAssociationAttempts().reversed() where record.state == "completed" && record.validity == "current" {
            if let currentSourceID, currentSourceID != record.currentSourceID { continue }
            for proposal in record.proposals {
                let fingerprint = try Self.associationFeedbackFingerprint(snapshot: record.snapshot, proposal: proposal)
                guard !ignored.contains(fingerprint), seen.insert(fingerprint).inserted,
                      let hit = record.snapshot.candidates.first(where: { $0.id == proposal.candidateID }) else { continue }
                items.append(.init(id: fingerprint, attemptID: record.id, currentSourceID: record.currentSourceID, proposal: proposal, historical: hit, historicalQuestions: registeredQuestions.filter { question in
                    question.seed.original.reference.sourceID == hit.document.sourceID &&
                    question.seed.original.reference.transcriptVersionID == hit.document.transcriptVersionID &&
                    question.seed.original.reference.spanID == hit.document.spanID
                }))
                if items.count == target { return items }
            }
        }
        return items
    }
    public func ignoreExpressionAssociation(attemptID: String, candidateID: String, relation: ExpressionRelation, commandID: String = UUID().uuidString) throws {
        guard ready, !commandID.isEmpty else { throw VoiceOSError("忽略关联命令无效") }
        try Self.validateStoredExpressionAssociations(db)
        try Self.validateStoredExpressionAssociationIgnores(db)
        if let old = try db.query("SELECT * FROM expression_association_ignores WHERE command_id=?", [commandID]).first {
            guard old["attempt_id"] == attemptID, old["candidate_id"] == candidateID, old["relation"] == relation.rawValue else { throw VoiceOSError("同一忽略命令不能更换内容") }
            return
        }
        guard let record = try expressionAssociationAttempts().first(where: { $0.id == attemptID }),
              record.state == "completed", record.validity == "current",
              let proposal = record.proposals.first(where: { $0.candidateID == candidateID && $0.relation == relation }) else { throw VoiceOSError("只能忽略仍有效的已接纳关联") }
        let fingerprint = try Self.associationFeedbackFingerprint(snapshot: record.snapshot, proposal: proposal)
        if !(try db.query("SELECT id FROM expression_association_ignores WHERE fingerprint=?", [fingerprint])).isEmpty { return }
        try db.transaction {
            try db.execute("INSERT INTO expression_association_ignores(id,command_id,attempt_id,candidate_id,relation,fingerprint,created_at) VALUES(?,?,?,?,?,?,?)", [UUID().uuidString, commandID, attemptID, candidateID, relation.rawValue, fingerprint, Self.now()])
            try checkpoint(.associationIgnoreUncommitted)
        }
        try checkpoint(.associationIgnoreCommitted)
    }
    static func associationFeedbackFingerprint(snapshot: ExpressionAssociationSnapshot, proposal: ExpressionAssociationProposal) throws -> String {
        guard let hit = snapshot.candidates.first(where: { $0.id == proposal.candidateID }) else { throw VoiceOSError("关联反馈出处缺失") }
        let source = snapshot.current.sources[0], d = hit.document
        // Stable across new preview/query/model IDs and permission toggles.
        return relevanceHash(Data(try relevanceJSON(["association-feedback-v1", source.sourceID, source.sourceVersionID, source.transcriptVersionID, d.sourceID, d.sourceVersionID, d.transcriptVersionID, d.spanID, String(d.textStart), String(d.textEnd), proposal.relation.rawValue]).utf8))
    }
    static func validateStoredExpressionAssociationIgnores(_ db: Database) throws {
        for row in try db.query("SELECT * FROM expression_association_ignores") {
            guard UUID(uuidString: row["id"] ?? "") != nil, !(row["command_id"] ?? "").isEmpty,
                  let attempt = try db.query("SELECT * FROM expression_association_attempts WHERE id=? AND state='completed'", [row["attempt_id"]]).first,
                  let result = attempt["result_json"], let json = attempt["snapshot_json"] else { throw VoiceOSError("忽略关联缺少已接纳历史") }
            let snapshot = try JSONDecoder().decode(ExpressionAssociationSnapshot.self, from: Data(json.utf8))
            let proposals = try JSONDecoder().decode([ExpressionAssociationProposal].self, from: Data(result.utf8))
            guard let proposal = proposals.first(where: { $0.candidateID == row["candidate_id"] && $0.relation.rawValue == row["relation"] }),
                  row["fingerprint"] == (try associationFeedbackFingerprint(snapshot: snapshot, proposal: proposal)) else { throw VoiceOSError("忽略关联身份或出处不一致") }
        }
    }
}
