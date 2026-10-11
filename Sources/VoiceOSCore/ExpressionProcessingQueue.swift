import Foundation
import CryptoKit

public enum ExpressionProcessingIntentState: String, Codable, Sendable {
    case queued, running, completed, unknown, blocked, cancelled, frozen, rejected
}

public enum ExpressionProcessingIntentPhase: String, Codable, Sendable {
    case queued, cognition, association, completed
}

public struct ExpressionProcessingIntentRecord: Identifiable, Sendable {
    public let id: String
    public let commandID: String
    public let sourceID: String
    public let snapshot: ExpressionProcessingIntentSnapshot
    public let state: ExpressionProcessingIntentState
    public let phase: ExpressionProcessingIntentPhase
    public let cognitionAttemptID: String?
    public let associationAttemptID: String?
    public let error: String?
    public let cancelReason: String?
    public let createdAt: String
    public let updatedAt: String
}

private extension VoiceOSStore {
    static func processingIdentity(_ identity: ProcessingModelIdentity) -> ModelConfiguration {
        ModelConfiguration(provider: identity.provider, model: identity.model,
                           promptVersion: identity.promptVersion, schemaVersion: identity.schemaVersion,
                           destination: identity.destination)
    }

    static func processingNow() -> String { ISO8601DateFormatter().string(from: Date()) }

    static func processingCommandFingerprint(_ snapshot: ExpressionProcessingIntentSnapshot) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(snapshot)).map { String(format: "%02x", $0) }.joined()
    }

    func processingRecord(_ row: [String: String]) throws -> ExpressionProcessingIntentRecord {
        guard let json = row["snapshot_json"], let snapshot = try? JSONDecoder().decode(ExpressionProcessingIntentSnapshot.self, from: Data(json.utf8)),
              let state = ExpressionProcessingIntentState(rawValue: row["state"] ?? ""),
              let phase = ExpressionProcessingIntentPhase(rawValue: row["phase"] ?? "") else {
            throw VoiceOSError("持久处理意图记录格式无效")
        }
        return ExpressionProcessingIntentRecord(id: row["id"]!, commandID: row["command_id"]!, sourceID: row["source_id"]!,
            snapshot: snapshot, state: state, phase: phase, cognitionAttemptID: row["cognition_attempt_id"],
            associationAttemptID: row["association_attempt_id"], error: row["error"], cancelReason: row["cancel_reason"],
            createdAt: row["created_at"]!, updatedAt: row["updated_at"]!)
    }

    func processingRow(id: String) throws -> [String: String] {
        guard let row = try db.query("SELECT * FROM processing_intents WHERE id=?", [id]).first else { throw VoiceOSError("处理意图不存在") }
        return row
    }

    func updateProcessing(_ id: String, state: ExpressionProcessingIntentState, phase: ExpressionProcessingIntentPhase? = nil,
                          error: String? = nil, cognitionAttemptID: String? = nil, associationAttemptID: String? = nil) throws {
        let now = Self.processingNow()
        var fields = ["state=?", "updated_at=?", "error=?"]
        var values: [String?] = [state.rawValue, now, error]
        if let phase { fields.append("phase=?"); values.append(phase.rawValue) }
        if let cognitionAttemptID { fields.append("cognition_attempt_id=?"); values.append(cognitionAttemptID) }
        if let associationAttemptID { fields.append("association_attempt_id=?"); values.append(associationAttemptID) }
        values.append(id)
        try db.execute("UPDATE processing_intents SET \(fields.joined(separator: ",")) WHERE id=?", values)
    }

    func cognitionAttemptID(for snapshot: ExpressionProcessingIntentSnapshot) throws -> String? {
        try db.query("""
            SELECT a.id FROM model_attempts a
            JOIN contexts c ON c.id=a.context_id JOIN context_inputs i ON i.context_id=c.id
            WHERE i.source_id=? AND i.transcript_version_id=? AND i.policy_version=?
              AND a.provider=? AND a.model=? AND a.prompt_version=? AND a.schema_version=?
              AND a.execution_kind='model_request'
            ORDER BY a.producer_sequence DESC LIMIT 1
            """, [snapshot.context.sources[0].sourceID, snapshot.context.sources[0].transcriptVersionID,
                   String(snapshot.policyVersion), snapshot.cognition.provider, snapshot.cognition.model,
                   snapshot.cognition.promptVersion, snapshot.cognition.schemaVersion]).first?["id"]
    }

    func associationAttemptID(for snapshot: ExpressionProcessingIntentSnapshot) throws -> String? {
        try db.query("""
            SELECT id FROM expression_association_attempts
            WHERE current_source_id=? AND snapshot_digest=? AND provider=? AND model=? AND prompt_version=? AND schema_version=?
            ORDER BY created_at DESC LIMIT 1
            """, [snapshot.context.sources[0].sourceID, snapshot.contentDigest, snapshot.association.provider,
                   snapshot.association.model, snapshot.association.promptVersion, snapshot.association.schemaVersion]).first?["id"]
    }

    /// A late result received after cancellation remains auditable, but cannot
    /// remain part of the current cognitive or association view.
    func freezeProcessingCognitionAttempt(_ attemptID: String) throws {
        guard let contextID = try db.query("SELECT context_id FROM model_attempts WHERE id=?", [attemptID]).first?["context_id"] else { return }
        try db.transaction {
            try db.execute("UPDATE contexts SET state='stale' WHERE id=?", [contextID])
            try db.execute("UPDATE claims SET validity='frozen' WHERE attempt_id=?", [attemptID])
            try db.execute("UPDATE actions SET validity='frozen' WHERE claim_id IN (SELECT id FROM claims WHERE attempt_id=?)", [attemptID])
            try db.execute("UPDATE questions SET validity='frozen' WHERE claim_id IN (SELECT id FROM claims WHERE attempt_id=?)", [attemptID])
        }
    }

    func freezeProcessingAssociationAttempt(_ attemptID: String) throws {
        try db.execute("UPDATE expression_association_attempts SET validity='frozen' WHERE id=?", [attemptID])
    }
}

extension VoiceOSStore {
    /// Persist an explicitly requested text-processing chain before any model call.
    /// Re-delivery of the same command returns the existing row; a changed payload is rejected.
    public func enqueueExpressionProcessingIntent(_ snapshot: ExpressionProcessingIntentSnapshot, commandID: String = UUID().uuidString,
                                                   cognition: ModelConfiguration, association: ModelConfiguration) throws -> ExpressionProcessingIntentRecord {
        try validateExpressionProcessingIntent(snapshot, cognition: cognition, association: association)
        let fingerprint = try Self.processingCommandFingerprint(snapshot)
        if let old = try db.query("SELECT * FROM processing_intents WHERE command_id=?", [commandID]).first {
            guard old["command_fingerprint"] == fingerprint else { throw VoiceOSError("同一处理命令不能更换内容") }
            return try processingRecord(old)
        }
        let source = snapshot.context.sources[0]
        let now = Self.processingNow()
        let json = try Self.relevanceJSON(snapshot)
        let id = UUID().uuidString
        try db.transaction {
            try db.execute("""
                INSERT INTO processing_intents(
                  id,command_id,command_fingerprint,source_id,source_version_id,transcript_version_id,policy_version,
                  snapshot_json,snapshot_digest,cognition_provider,cognition_model,cognition_prompt_version,cognition_schema_version,cognition_destination,
                  association_provider,association_model,association_prompt_version,association_schema_version,association_destination,
                  state,phase,created_at,updated_at)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,'queued','queued',?,?)
                """, [id, commandID, fingerprint, source.sourceID, source.sourceVersionID, source.transcriptVersionID, String(snapshot.policyVersion),
                       json, fingerprint, snapshot.cognition.provider, snapshot.cognition.model, snapshot.cognition.promptVersion, snapshot.cognition.schemaVersion, snapshot.cognition.destination.rawValue,
                       snapshot.association.provider, snapshot.association.model, snapshot.association.promptVersion, snapshot.association.schemaVersion, snapshot.association.destination.rawValue, now, now])
            try checkpoint(.processingIntentUncommitted)
        }
        try checkpoint(.processingIntentCommitted)
        return try processingRecord(processingRow(id: id))
    }

    public func processingIntents() throws -> [ExpressionProcessingIntentRecord] {
        try Self.validateStoredProcessingIntents(db)
        return try db.query("SELECT * FROM processing_intents ORDER BY created_at,id").map { try processingRecord($0) }
    }

    public func processingIntent(id: String) throws -> ExpressionProcessingIntentRecord {
        try processingRecord(processingRow(id: id))
    }

    @discardableResult
    public func cancelExpressionProcessingIntent(id: String, reason: String = "用户取消处理") throws -> ExpressionProcessingIntentRecord {
        let row = try processingRow(id: id)
        guard let state = ExpressionProcessingIntentState(rawValue: row["state"]!), [.queued, .running].contains(state) else { return try processingRecord(row) }
        let now = Self.processingNow()
        try db.execute("UPDATE processing_intents SET state='cancelled',error=NULL,cancel_reason=?,updated_at=? WHERE id=? AND state IN ('queued','running')", [reason, now, id])
        return try processingIntent(id: id)
    }

    /// Execute one persisted intent. Unknown model outcomes remain terminal and are never retried here.
    public func runExpressionProcessingIntent(id: String, retrieval: any LocalRetrievalPort,
                                               cognitionPort: any ModelPort,
                                               associationPort: (any ExpressionAssociationPort)?, semantic: Bool = false) async throws -> ExpressionProcessingIntentRecord {
        guard activeProcessingIntents.insert(id).inserted else { return try processingIntent(id: id) }
        defer { activeProcessingIntents.remove(id) }
        var row = try processingRow(id: id)
        guard let state = ExpressionProcessingIntentState(rawValue: row["state"]!) else { throw VoiceOSError("处理意图状态无效") }
        if [.completed, .unknown, .blocked, .cancelled, .frozen, .rejected].contains(state) { return try processingRecord(row) }
        let snapshot = try JSONDecoder().decode(ExpressionProcessingIntentSnapshot.self, from: Data(row["snapshot_json"]!.utf8))
        do {
            try validateExpressionProcessingIntent(snapshot, cognition: cognitionPort.configuration,
                                                   association: associationPort?.configuration ?? Self.processingIdentity(snapshot.association))
        } catch {
            try updateProcessing(id, state: .blocked, phase: .queued, error: error.localizedDescription)
            return try processingIntent(id: id)
        }
        try db.transaction {
            guard try db.query("SELECT state FROM processing_intents WHERE id=?", [id]).first?["state"] == "queued" else { return }
            try db.execute("UPDATE processing_intents SET state='running',phase='cognition',updated_at=?,error=NULL WHERE id=?", [Self.processingNow(), id])
        }
        try checkpoint(.processingIntentReserved)
        row = try processingRow(id: id)
        if row["state"] == ExpressionProcessingIntentState.cancelled.rawValue { return try processingRecord(row) }
        var cognitionAttemptForIntent: String?
        var cognitionWasReused = false
        var associationAttemptForIntent: String?
        var associationStarted = false
        do {
            let cognition = try await continueSourceUnderstanding(sourceID: snapshot.context.sources[0].sourceID, using: cognitionPort)
            let cognitionAttempt = try cognitionAttemptID(for: snapshot)
            cognitionAttemptForIntent = cognitionAttempt
            cognitionWasReused = cognition.reused
            row = try processingRow(id: id)
            if row["state"] == ExpressionProcessingIntentState.cancelled.rawValue {
                if !cognition.reused, let cognitionAttempt { try freezeProcessingCognitionAttempt(cognitionAttempt) }
                return try processingRecord(row)
            }
            if let cognitionAttempt { try updateProcessing(id, state: .running, phase: .cognition, cognitionAttemptID: cognitionAttempt) }
            guard cognition.state == "completed" || cognition.state == "discussion_completed" else {
                let terminal: ExpressionProcessingIntentState
                if cognition.state == "frozen" {
                    terminal = .frozen
                } else {
                    terminal = cognition.state.contains("rejected") ? .rejected : .unknown
                }
                try updateProcessing(id, state: terminal, phase: .cognition, error: "理解阶段状态为 \(cognition.state)，不会自动重发")
                return try processingIntent(id: id)
            }
            row = try processingRow(id: id)
            guard row["state"] == ExpressionProcessingIntentState.running.rawValue else { return try processingRecord(row) }
            try db.execute("UPDATE processing_intents SET phase='association',updated_at=? WHERE id=?", [Self.processingNow(), id])
            try Task.checkCancellation()
            guard let associationPort else {
                try updateProcessing(id, state: .blocked, phase: .association, error: "关联端口尚未配置")
                return try processingIntent(id: id)
            }
            associationStarted = true
            let association = try await processExpressionAssociation(sourceID: snapshot.context.sources[0].sourceID, retrieval: retrieval, semantic: semantic, model: associationPort)
            let associationAttempt: String?
            if let attempt = association.attempt?.id { associationAttempt = attempt }
            else { associationAttempt = try associationAttemptID(for: snapshot) }
            associationAttemptForIntent = associationAttempt
            row = try processingRow(id: id)
            if row["state"] == ExpressionProcessingIntentState.cancelled.rawValue {
                if let associationAttempt { try freezeProcessingAssociationAttempt(associationAttempt) }
                return try processingRecord(row)
            }
            if let associationAttempt {
                try updateProcessing(id, state: .running, phase: .association, associationAttemptID: associationAttempt)
            }
            row = try processingRow(id: id)
            guard row["state"] == ExpressionProcessingIntentState.running.rawValue else { return try processingRecord(row) }
            switch association.state {
            case .completed, .noCandidates:
                try updateProcessing(id, state: .completed, phase: .completed, error: nil)
            case .unknown:
                try updateProcessing(id, state: .unknown, phase: .association, error: "关联结果未知，不自动重发")
            case .paused, .localOnly, .modelUnavailable, .budgetExceeded, .inFlight:
                try updateProcessing(id, state: .blocked, phase: .association, error: "关联阶段未执行：\(association.state.rawValue)")
            }
        } catch is CancellationError {
            row = try processingRow(id: id)
            if row["state"] != ExpressionProcessingIntentState.cancelled.rawValue { try updateProcessing(id, state: .unknown, error: "处理被取消，结果未知；不会自动重发") }
        } catch {
            row = try processingRow(id: id)
            if row["state"] == ExpressionProcessingIntentState.cancelled.rawValue {
                if !associationStarted, !cognitionWasReused, let cognitionAttemptForIntent { try? freezeProcessingCognitionAttempt(cognitionAttemptForIntent) }
                if let associationAttemptForIntent { try? freezeProcessingAssociationAttempt(associationAttemptForIntent) }
                return try processingRecord(row)
            }
            let associationUnknown = (try? db.query("SELECT id FROM expression_association_attempts WHERE current_source_id=? AND state='unknown' ORDER BY created_at DESC LIMIT 1", [snapshot.context.sources[0].sourceID]).first) != nil
            let cognitionUnknown = (try? cognitionAttemptID(for: snapshot).flatMap { try db.query("SELECT state FROM model_attempts WHERE id=?", [$0]).first?["state"] == "unknown" }) ?? false
            try updateProcessing(id, state: (associationUnknown || cognitionUnknown) ? .unknown : .blocked, error: error.localizedDescription)
        }
        return try processingIntent(id: id)
    }

    static func validateStoredProcessingIntents(_ db: Database) throws {
        for row in try db.query("SELECT * FROM processing_intents") {
            guard let id = row["id"], UUID(uuidString: id) != nil,
                  let sourceID = row["source_id"], let source = try db.query("SELECT version_id FROM sources WHERE id=?", [sourceID]).first,
                  source["version_id"] == row["source_version_id"],
                  UUID(uuidString: row["source_version_id"] ?? "") != nil,
                  UUID(uuidString: row["transcript_version_id"] ?? "") != nil,
                  let snapshotJSON = row["snapshot_json"],
                  row["snapshot_digest"] == (try? Self.processingCommandFingerprint(JSONDecoder().decode(ExpressionProcessingIntentSnapshot.self, from: Data(snapshotJSON.utf8)))),
                  row["command_fingerprint"] == row["snapshot_digest"],
                  row["cognition_destination"] == row["association_destination"] else { throw VoiceOSError("持久处理意图身份或摘要不一致") }
            let snapshot = try JSONDecoder().decode(ExpressionProcessingIntentSnapshot.self, from: Data(snapshotJSON.utf8))
            let contextEncoder = JSONEncoder(); contextEncoder.outputFormatting = [.sortedKeys]
            let contextDigest = Self.relevanceHash(try contextEncoder.encode(snapshot.context.sources))
            guard snapshot.context.sources.count == 1, snapshot.context.contentDigest == contextDigest, snapshot.context.sources[0].sourceID == sourceID,
                  snapshot.context.sources[0].sourceVersionID == row["source_version_id"], snapshot.context.sources[0].transcriptVersionID == row["transcript_version_id"],
                  snapshot.policyVersion == Int(row["policy_version"] ?? "0"), snapshot.cognition.provider == row["cognition_provider"], snapshot.association.provider == row["association_provider"],
                  snapshot.cognition.model == row["cognition_model"], snapshot.association.model == row["association_model"],
                  snapshot.cognition.promptVersion == row["cognition_prompt_version"], snapshot.association.promptVersion == row["association_prompt_version"],
                  snapshot.cognition.schemaVersion == row["cognition_schema_version"], snapshot.association.schemaVersion == row["association_schema_version"],
                  snapshot.cognition.destination.rawValue == row["cognition_destination"], snapshot.association.destination.rawValue == row["association_destination"] else { throw VoiceOSError("持久处理意图快照与目录不一致") }
            if let attempt = row["cognition_attempt_id"] { guard try db.query("SELECT id FROM model_attempts WHERE id=?", [attempt]).count == 1 else { throw VoiceOSError("处理意图引用不存在的理解调用") } }
            if let attempt = row["association_attempt_id"] { guard try db.query("SELECT id FROM expression_association_attempts WHERE id=?", [attempt]).count == 1 else { throw VoiceOSError("处理意图引用不存在的关联调用") } }
        }
    }
}
