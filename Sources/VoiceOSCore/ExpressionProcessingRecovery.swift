import Foundation

extension VoiceOSStore {
    // Scope identity is independent of the currently configured model. The earliest
    // existing receipt owns once-only cognition; config changes cannot replay it.
    func processingCognitionReceipt(sourceID: String, sourceVersionID: String, transcriptVersionID: String, policyVersion: Int) throws -> [String: String]? {
        try db.query("""
            SELECT a.*,c.state AS context_state FROM model_attempts a
            JOIN contexts c ON c.id=a.context_id JOIN context_inputs i ON i.context_id=c.id
            JOIN transcript_versions v ON v.id=i.transcript_version_id JOIN transcripts t ON t.id=v.transcript_id
            WHERE i.source_id=? AND t.input_version_id=? AND i.transcript_version_id=? AND i.policy_version=?
              AND a.execution_kind='model_request'
            ORDER BY a.producer_sequence LIMIT 1
            """, [sourceID, sourceVersionID, transcriptVersionID, String(policyVersion)]).first
    }

    func processingAssociationReceipt(_ snapshot: ExpressionProcessingIntentSnapshot) throws -> [String: String]? {
        let source = snapshot.context.sources[0]
        return try db.query("""
            SELECT a.*,c.state AS context_state FROM expression_association_attempts a
            JOIN contexts c ON c.id=a.context_id JOIN context_inputs i ON i.context_id=c.id
            JOIN transcript_versions v ON v.id=i.transcript_version_id JOIN transcripts t ON t.id=v.transcript_id
            WHERE a.current_source_id=? AND i.source_id=? AND t.input_version_id=? AND i.transcript_version_id=? AND i.policy_version=?
            ORDER BY a.created_at,a.id LIMIT 1
            """, [source.sourceID, source.sourceID, source.sourceVersionID, source.transcriptVersionID, String(snapshot.policyVersion)]).first
    }

    /// Startup only, after reserved model receipts have become unknown and their
    /// historical bindings have been validated. No requests are dispatched here.
    func recoverExpressionProcessingIntents() throws {
        try db.transaction {
            for row in try db.query("SELECT * FROM processing_intents WHERE state='running'") {
                let record = try processingRecord(row), snapshot = record.snapshot, source = snapshot.context.sources[0]
                let cognition = try processingCognitionReceipt(sourceID: source.sourceID, sourceVersionID: source.sourceVersionID,
                    transcriptVersionID: source.transcriptVersionID, policyVersion: snapshot.policyVersion)
                let association = try processingAssociationReceipt(snapshot)
                let cognitionID = cognition?["id"], associationID = association?["id"]
                var boundRow = row
                boundRow["cognition_attempt_id"] = cognitionID
                boundRow["association_attempt_id"] = associationID
                try Self.validateProcessingReceiptBindings(db, row: boundRow, snapshot: snapshot)
                let state: ExpressionProcessingIntentState
                let phase: ExpressionProcessingIntentPhase
                let error: String?
                if cognition?["state"] == "unknown" || cognition?["state"] == "reserved" || association?["state"] == "unknown" || association?["state"] == "reserved" {
                    state = .unknown; phase = association == nil ? .cognition : .association
                    error = "已有模型调用结果未知；不会自动重发"
                } else if cognition?["state"] == "rejected" {
                    state = .rejected; phase = .cognition; error = "理解结果未接纳；不会自动重发"
                } else if (cognition != nil && cognition?["context_state"] != "current") || (association != nil && (association?["context_state"] != "current" || association?["validity"] != "current")) {
                    state = .frozen; phase = association == nil ? .cognition : .association
                    error = "已有处理依据已冻结；不会自动续接"
                } else if cognition?["state"] == "completed", association?["state"] == "completed" {
                    state = .completed; phase = .completed; error = nil
                } else if association != nil {
                    state = .unknown; phase = .association; error = "阶段回执无法确认安全续接；不会自动重发"
                } else {
                    // No receipt proves this stage was never reserved. The normal
                    // worker rechecks fixed text, permission and config before use.
                    state = .queued; phase = cognition == nil ? .queued : .association; error = nil
                }
                try updateProcessing(record.id, state: state, phase: phase, error: error,
                    cognitionAttemptID: cognitionID, associationAttemptID: associationID)
            }
        }
    }

    static func validateProcessingReceiptBindings(_ db: Database, row: [String: String], snapshot: ExpressionProcessingIntentSnapshot) throws {
        let source = snapshot.context.sources[0]
        // Historical validation uses the recorded transcript and permission epoch,
        // not today's values: corrections/revocations must retain auditable history.
        guard UUID(uuidString: snapshot.id) != nil, snapshot.context.scalarBudget == 40000,
              snapshot.cognition.isValid, snapshot.association.isValid,
              source.origin == "user", source.speaker == "user", source.text.unicodeScalars.count <= 40000,
              snapshot.cognition.destination != .cloud || !source.localOnly,
              snapshot.contentDigest == (try expressionProcessingIntentDigest(context: snapshot.context, policyVersion: snapshot.policyVersion, cognition: snapshot.cognition, association: snapshot.association)),
              let version = try db.query("SELECT v.text,v.spans_json,t.source_id,t.input_version_id,s.origin,s.speaker FROM transcript_versions v JOIN transcripts t ON t.id=v.transcript_id JOIN sources s ON s.id=t.source_id WHERE v.id=?", [source.transcriptVersionID]).first,
              version["source_id"] == source.sourceID, version["input_version_id"] == source.sourceVersionID,
              version["text"] == source.text, version["origin"] == source.origin, version["speaker"] == source.speaker,
              try relevanceJSON(JSONDecoder().decode([TranscriptSpan].self, from: Data(version["spans_json"]!.utf8))) == relevanceJSON(source.spans),
              let policy = try db.query("SELECT policy_version,local_only FROM sources WHERE id=?", [source.sourceID]).first,
              snapshot.policyVersion > 0, snapshot.policyVersion <= Int(policy["policy_version"]!)! else { throw VoiceOSError("处理意图原话或授权历史不一致") }
        let historicalLocal = policy["policy_version"] == String(snapshot.policyVersion) ? policy["local_only"] :
            try db.query("SELECT from_local_only FROM source_policy_revisions WHERE source_id=? AND from_version=?", [source.sourceID, String(snapshot.policyVersion)]).first?["from_local_only"]
        guard historicalLocal == (source.localOnly ? "1" : "0") else { throw VoiceOSError("处理意图授权历史不一致") }

        for (column, table) in [("cognition_attempt_id", "model_attempts"), ("association_attempt_id", "expression_association_attempts")] {
            guard let id = row[column] else { continue }
            guard let receipt = try db.query("SELECT a.*,c.snapshot_json AS context_snapshot FROM \(table) a JOIN contexts c ON c.id=a.context_id WHERE a.id=?", [id]).first,
                  let input = try db.query("SELECT * FROM context_inputs WHERE context_id=? AND source_id=?", [receipt["context_id"], source.sourceID]).first,
                  input["transcript_version_id"] == source.transcriptVersionID, input["policy_version"] == String(snapshot.policyVersion),
                  let json = receipt["context_snapshot"],
                  let actualSource = try JSONDecoder().decode(LocalTranscriptContext.self, from: Data(json.utf8)).sources.first(where: { $0.sourceID == source.sourceID }),
                  try relevanceJSON(actualSource) == relevanceJSON(source) else { throw VoiceOSError("处理意图回执的来源、逐字稿或授权绑定不一致") }
            if column == "cognition_attempt_id" {
                guard receipt["execution_kind"] == "model_request" else { throw VoiceOSError("处理意图不能引用其他类型的模型调用") }
            } else {
                guard receipt["current_source_id"] == source.sourceID else { throw VoiceOSError("处理意图关联回执来源不一致") }
            }
        }
    }
}
