import Foundation

/// Parent lifecycle. Fragment calls remain staged until full aggregation exists.
public enum SegmentedProcessingBatchState: String, Codable, Sendable {
    case queued, blocked, cancelled, frozen, unknown, rejected
}
public struct SegmentedProcessingBatch: Identifiable, Sendable {
    public let id: String
    public let commandID: String
    public let scope: SegmentedExpressionProcessingScope
    public let state: SegmentedProcessingBatchState
    public let error: String?
    public let createdAt: String
    public let updatedAt: String
}
extension VoiceOSStore {
    static func segmentedCommandFingerprint(_ scope: SegmentedExpressionProcessingScope) throws -> String {
        let canonical = SegmentedExpressionProcessingScope(id:"semantic-command-v1",plan:scope.plan,
            extraction:scope.extraction,aggregation:scope.aggregation,
            evidenceScalarBudget:scope.evidenceScalarBudget,contentDigest:scope.contentDigest)
        return relevanceHash(Data(try relevanceJSON(canonical).utf8))
    }
    static func segmentedStoredDigest(_ scope: SegmentedExpressionProcessingScope) throws -> String {
        relevanceHash(Data(try relevanceJSON(scope).utf8))
    }
    static func segmentedBatchRecord(_ row: [String:String]) throws -> SegmentedProcessingBatch {
        guard let json = row["scope_json"], let state = SegmentedProcessingBatchState(rawValue:row["state"] ?? ""),
              let id = row["id"], let command = row["command_id"], let created = row["created_at"], let updated = row["updated_at"] else {
            throw VoiceOSError("分段批次记录格式无效")
        }
        return .init(id:id,commandID:command,scope:try JSONDecoder().decode(SegmentedExpressionProcessingScope.self,from:Data(json.utf8)),
            state:state,error:row["error"],createdAt:created,updatedAt:updated)
    }
    public func segmentedProcessingBatches() throws -> [SegmentedProcessingBatch] {
        try Self.validateStoredSegmentedProcessingBatches(db)
        return try db.query("SELECT * FROM segmented_processing_batches ORDER BY created_at,id").map(Self.segmentedBatchRecord)
    }
    public func segmentedProcessingBatch(id: String) throws -> SegmentedProcessingBatch {
        guard let row = try db.query("SELECT * FROM segmented_processing_batches WHERE id=?",[id]).first else { throw VoiceOSError("分段批次不存在") }
        try Self.validateStoredSegmentedBatch(db,row:row)
        return try Self.segmentedBatchRecord(row)
    }
    /// Persist the explicitly requested scope. A command replay returns its original
    /// receipt even after cancellation or source correction; it cannot reactivate it.
    public func enqueueSegmentedProcessingBatch(_ scope: SegmentedExpressionProcessingScope, commandID: String = UUID().uuidString,
        extraction: ModelConfiguration, aggregation: ModelConfiguration) throws -> SegmentedProcessingBatch {
        guard ready, !commandID.isEmpty else { throw VoiceOSError("资料库尚未准备好或分段命令为空") }
        let fingerprint = try Self.segmentedCommandFingerprint(scope)
        if let old = try db.query("SELECT * FROM segmented_processing_batches WHERE command_id=?",[commandID]).first {
            try Self.validateStoredSegmentedBatch(db,row:old)
            guard old["command_fingerprint"] == fingerprint else { throw VoiceOSError("同一分段命令不能更换处理范围") }
            return try Self.segmentedBatchRecord(old)
        }
        try validateSegmentedExpressionProcessingScope(scope,extraction:extraction,aggregation:aggregation)
        let id = UUID().uuidString, now = Self.processingNow(), source = scope.plan.source
        try db.transaction {
            try db.execute("""
            INSERT INTO segmented_processing_batches(id,command_id,command_fingerprint,source_id,source_version_id,
                transcript_version_id,policy_version,scope_json,scope_digest,state,created_at,updated_at)
            VALUES(?,?,?,?,?,?,?,?,?,'queued',?,?)
            """,[id,commandID,fingerprint,source.sourceID,source.sourceVersionID,source.transcriptVersionID,
                String(scope.plan.policyVersion),try Self.relevanceJSON(scope),try Self.segmentedStoredDigest(scope),now,now])
            try checkpoint(.segmentedBatchUncommitted)
        }
        try checkpoint(.segmentedBatchCommitted)
        return try segmentedProcessingBatch(id:id)
    }
    @discardableResult
    public func cancelSegmentedProcessingBatch(id: String) throws -> SegmentedProcessingBatch {
        let old = try segmentedProcessingBatch(id:id)
        guard old.state == .queued else { return old }
        try db.transaction {
            try db.execute("UPDATE segmented_processing_batches SET state='cancelled',error='用户取消；原件与逐字稿保留',updated_at=? WHERE id=? AND state='queued'",[Self.processingNow(),id])
            try db.execute("UPDATE segmented_extraction_attempts SET validity='frozen' WHERE batch_id=?",[id])
            try db.execute("UPDATE segmented_aggregation_attempts SET validity='frozen' WHERE batch_id=?",[id])
            try checkpoint(.segmentedBatchCancelUncommitted)
        }
        try checkpoint(.segmentedBatchCancelCommitted)
        return try segmentedProcessingBatch(id:id)
    }
    /// Preflight only: no executor, no implicit transition out of a terminal state.
    public func checkSegmentedProcessingBatch(id: String, extraction: ModelConfiguration,
        aggregation: ModelConfiguration) throws -> SegmentedProcessingBatch {
        let batch = try segmentedProcessingBatch(id:id)
        guard batch.state == .queued else { return batch }
        do { try validateSegmentedExpressionProcessingScope(batch.scope,extraction:extraction,aggregation:aggregation) }
        catch {
            try db.transaction {
                try db.execute("UPDATE segmented_processing_batches SET state='blocked',error=?,updated_at=? WHERE id=? AND state='queued'",[error.localizedDescription,Self.processingNow(),id])
                try db.execute("UPDATE segmented_extraction_attempts SET validity='frozen' WHERE batch_id=?",[id])
            try db.execute("UPDATE segmented_aggregation_attempts SET validity='frozen' WHERE batch_id=?",[id])
            }
        }
        return try segmentedProcessingBatch(id:id)
    }
    func recoverSegmentedProcessingBatches() throws {
        for batch in try segmentedProcessingBatches() where batch.state == .queued {
            _ = try checkSegmentedProcessingBatch(id:batch.id,extraction:Self.processingIdentity(batch.scope.extraction),
                aggregation:Self.processingIdentity(batch.scope.aggregation))
        }
    }
    static func validateStoredSegmentedProcessingBatches(_ db: Database) throws {
        for row in try db.query("SELECT * FROM segmented_processing_batches") { try validateStoredSegmentedBatch(db,row:row) }
    }
    /// Historical validation uses the recorded transcript and permission epoch,
    /// retaining legal history after correction or revocation. Execution uses current validation.
    static func validateStoredSegmentedBatch(_ db: Database,row: [String:String]) throws {
        let batch = try segmentedBatchRecord(row), scope = batch.scope, p = scope.plan, s = p.source
        guard UUID(uuidString:batch.id) != nil, UUID(uuidString:scope.id) != nil, !batch.commandID.isEmpty,
              row["scope_digest"] == (try segmentedStoredDigest(scope)),
              row["command_fingerprint"] == (try segmentedCommandFingerprint(scope)),
              row["source_id"] == s.sourceID, row["source_version_id"] == s.sourceVersionID,
              row["transcript_version_id"] == s.transcriptVersionID, row["policy_version"] == String(p.policyVersion),
              scope.extraction.isValid, scope.aggregation.isValid, scope.extraction.destination == scope.aggregation.destination,
              (1...4000).contains(scope.evidenceScalarBudget), p.segments.count > 1, !s.text.isEmpty,
              scope.contentDigest == (try segmentedScopeDigest(plan:p,extraction:scope.extraction,aggregation:scope.aggregation,evidenceBudget:scope.evidenceScalarBudget)),
              s.origin == "user", s.speaker == "user", scope.extraction.destination != .cloud || !s.localOnly,
              let historical = try db.query("""
              SELECT v.text,v.spans_json,t.source_id,t.input_version_id,s.version_id,s.kind,s.origin,s.speaker,s.duration,s.policy_version,s.local_only
              FROM transcript_versions v JOIN transcripts t ON t.id=v.transcript_id JOIN sources s ON s.id=t.source_id WHERE v.id=?
              """,[s.transcriptVersionID]).first,
              ["user_text","audio"].contains(historical["kind"] ?? ""), historical["source_id"] == s.sourceID,
              historical["input_version_id"] == s.sourceVersionID, historical["version_id"] == s.sourceVersionID,
              historical["text"] == s.text, historical["origin"] == s.origin, historical["speaker"] == s.speaker,
              try relevanceJSON(JSONDecoder().decode([TranscriptSpan].self,from:Data(historical["spans_json"]!.utf8))) == relevanceJSON(s.spans),
              let currentPolicyVersion = Int(historical["policy_version"] ?? ""),
              p.policyVersion > 0, p.policyVersion <= currentPolicyVersion else {
            throw VoiceOSError("分段批次来源、端口或历史快照不一致")
        }
        try SpeechText(text:s.text,spans:s.spans).validate(duration:historical["duration"].flatMap(Double.init))
        let canonical = try segmentTranscript(s,policyVersion:p.policyVersion,scalarBudget:p.scalarBudget)
        guard try relevanceJSON(canonical) == relevanceJSON(p) else { throw VoiceOSError("分段批次的原话或引用不是规范计划") }
        let local = historical["policy_version"] == String(p.policyVersion) ? historical["local_only"] :
            try db.query("SELECT from_local_only FROM source_policy_revisions WHERE source_id=? AND from_version=?",[s.sourceID,String(p.policyVersion)]).first?["from_local_only"]
        guard local == (s.localOnly ? "1":"0") else { throw VoiceOSError("分段批次授权历史不一致") }
    }
}
