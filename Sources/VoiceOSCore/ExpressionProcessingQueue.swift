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
    public let ignoredAt: String?
    public let ignoreReason: String?
    public let supersededBy: String?
    public let createdAt: String
    public let updatedAt: String
}

public extension ExpressionProcessingIntentRecord {
    /// An ignored or superseded failure stays queryable but stops asking for attention.
    var isDismissed: Bool { ignoredAt != nil || supersededBy != nil }
    var needsAttention: Bool { !isDismissed && [.blocked, .unknown, .rejected].contains(state) }
    var canReprocess: Bool { !isDismissed && [.rejected, .unknown].contains(state) }
    var canIgnore: Bool { !isDismissed && [.rejected, .blocked].contains(state) }
}

extension VoiceOSStore {
    static func processingIdentity(_ identity: ProcessingModelIdentity) -> ModelConfiguration {
        ModelConfiguration(provider: identity.provider, model: identity.model,
                           promptVersion: identity.promptVersion, schemaVersion: identity.schemaVersion,
                           destination: identity.destination)
    }

    static func processingNow() -> String { TimestampFormatting.iso.string(from: Date()) }

    static func processingSnapshotDigest(_ snapshot: ExpressionProcessingIntentSnapshot) throws -> String {
        let encoder = StableJSON.makeEncoder()
        return Digest.sha256(try encoder.encode(snapshot))
    }

    // The command describes a scope, not the randomly generated preparation ID.
    static func processingCommandFingerprint(_ snapshot: ExpressionProcessingIntentSnapshot) throws -> String {
        let canonical = ExpressionProcessingIntentSnapshot(id: "expression-processing-command-v1", context: snapshot.context,
            policyVersion: snapshot.policyVersion, cognition: snapshot.cognition, association: snapshot.association, contentDigest: snapshot.contentDigest)
        return try processingSnapshotDigest(canonical)
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
            ignoredAt: row["ignored_at"], ignoreReason: row["ignore_reason"], supersededBy: row["superseded_by"],
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

    func cognitionAttemptID(for snapshot: ExpressionProcessingIntentSnapshot, latest: Bool = false) throws -> String? {
        let source = snapshot.context.sources[0]
        return try processingCognitionReceipt(sourceID: source.sourceID, sourceVersionID: source.sourceVersionID,
            transcriptVersionID: source.transcriptVersionID, policyVersion: snapshot.policyVersion,
            contentDigest: snapshot.context.contentDigest, latest: latest)?["id"]
    }

    func associationAttemptID(for snapshot: ExpressionProcessingIntentSnapshot, latest: Bool = false) throws -> String? {
        try processingAssociationReceipt(snapshot, latest: latest)?["id"]
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
            let original = try processingRecord(old)
            guard try Self.processingCommandFingerprint(original.snapshot) == fingerprint else { throw VoiceOSError("同一处理命令不能更换内容") }
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
                       json, try Self.processingSnapshotDigest(snapshot), snapshot.cognition.provider, snapshot.cognition.model, snapshot.cognition.promptVersion, snapshot.cognition.schemaVersion, snapshot.cognition.destination.rawValue,
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

    /// A deliberate re-understanding. It queues a new command and keeps the old
    /// receipt as history; the worker treats the new command as an explicit retry.
    @discardableResult
    public func reprocessExpressionProcessingIntent(id: String, cognition: ModelConfiguration,
                                                    association: ModelConfiguration? = nil) throws -> ExpressionProcessingIntentRecord {
        let old = try processingIntent(id: id)
        guard old.ignoredAt == nil else { throw VoiceOSError("这次理解已被忽略，不能重新理解") }
        guard old.supersededBy == nil else { throw VoiceOSError("这次理解已经重新排队，请查看新的处理记录") }
        guard [.rejected, .unknown].contains(old.state) else { throw VoiceOSError("这次理解不在可重新理解的状态") }
        let associationConfig = association ?? ModelConfiguration(provider: old.snapshot.association.provider,
            model: old.snapshot.association.model, promptVersion: old.snapshot.association.promptVersion,
            schemaVersion: old.snapshot.association.schemaVersion, destination: old.snapshot.association.destination)
        let prefix = "expression-reprocess:" + old.id + ":"
        let sequence = try db.query("SELECT command_id FROM processing_intents WHERE command_id LIKE ?", [prefix + "%"]).count + 1
        let created = try enqueueExpressionProcessingIntent(old.snapshot, commandID: prefix + String(sequence),
            cognition: cognition, association: associationConfig)
        try db.execute("UPDATE processing_intents SET superseded_by=?, updated_at=? WHERE id=? AND superseded_by IS NULL",
                       [created.id, Self.processingNow(), old.id])
        return created
    }

    /// The user chooses not to chase this failure. The reason and time persist so
    /// the record remains auditable while it leaves the attention set.
    @discardableResult
    public func ignoreExpressionProcessingIntent(id: String, reason: String) throws -> ExpressionProcessingIntentRecord {
        let old = try processingIntent(id: id)
        if old.ignoredAt != nil { return old }
        guard old.supersededBy == nil, [.rejected, .blocked].contains(old.state) else { throw VoiceOSError("这次理解不在可忽略的状态") }
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw VoiceOSError("忽略原因不能为空") }
        let now = Self.processingNow()
        try db.execute("UPDATE processing_intents SET ignored_at=?, ignore_reason=?, updated_at=? WHERE id=? AND ignored_at IS NULL",
                       [now, trimmed, now, id])
        return try processingIntent(id: id)
    }

    public func processingIntentsNeedingAttention() throws -> [ExpressionProcessingIntentRecord] {
        try processingIntents().filter(\.needsAttention)
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
        // The reprocess command carries its own key so explicit retries can add a new
        // attempt while ordinary commands keep the once-only receipt rules.
        let retryKey: String? = row["command_id"]!.hasPrefix("expression-reprocess:")
            ? String(row["command_id"]!.dropFirst("expression-reprocess:".count)) : nil
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
            let cognition = try await continueSourceUnderstanding(sourceID: snapshot.context.sources[0].sourceID, using: cognitionPort, retryKey: retryKey)
            let cognitionAttempt = cognition.attemptID
            cognitionAttemptForIntent = cognitionAttempt
            cognitionWasReused = cognition.reused
            row = try processingRow(id: id)
            if row["state"] == ExpressionProcessingIntentState.cancelled.rawValue {
                if let cognitionAttempt { try updateProcessing(id, state: .cancelled, cognitionAttemptID: cognitionAttempt) }
                if !cognition.reused, let cognitionAttempt { try freezeProcessingCognitionAttempt(cognitionAttempt) }
                return try processingIntent(id: id)
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
            // A result is both a task receipt and a new personal expression.
            // Follow-up sees its saved knowledge; association failure cannot hide it.
            if try db.query("SELECT id FROM sources WHERE id=? AND feedback_json IS NOT NULL AND local_only=0", [snapshot.context.sources[0].sourceID]).first != nil {
                _ = try enqueueRecordingFollowup(sourceID: snapshot.context.sources[0].sourceID)
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
            let association = try await processExpressionAssociation(sourceID: snapshot.context.sources[0].sourceID, retrieval: retrieval, semantic: semantic, model: associationPort, retryKey: retryKey)
            // A transcription review changes the context digest without changing the
            // transcript version; an association receipt from the earlier basis must
            // not be rebound to this intent.
            let associationAttempt: String?
            if let attempt = association.attempt {
                associationAttempt = attempt.snapshot.current.contentDigest == snapshot.context.contentDigest ? attempt.id : nil
            } else {
                associationAttempt = try associationAttemptID(for: snapshot, latest: retryKey != nil)
            }
            let associationReceiptIsStale = association.attempt != nil && associationAttempt == nil
            associationAttemptForIntent = associationAttempt
            row = try processingRow(id: id)
            if row["state"] == ExpressionProcessingIntentState.cancelled.rawValue {
                if let associationAttempt { try updateProcessing(id, state: .cancelled, associationAttemptID: associationAttempt) }
                if let associationAttempt { try freezeProcessingAssociationAttempt(associationAttempt) }
                return try processingIntent(id: id)
            }
            if let associationAttempt {
                try updateProcessing(id, state: .running, phase: .association, associationAttemptID: associationAttempt)
            }
            row = try processingRow(id: id)
            guard row["state"] == ExpressionProcessingIntentState.running.rawValue else { return try processingRecord(row) }
            switch association.state {
            case .completed, .noCandidates:
                try updateProcessing(id, state: .completed, phase: .completed, error: nil)
            case .frozen where associationReceiptIsStale:
                try updateProcessing(id, state: .completed, phase: .completed, error: "关联依据已变化；本次只保存理解，旧关联保留为历史")
            case .unknown:
                try updateProcessing(id, state: .unknown, phase: .association, error: "关联结果未知，不自动重发")
            case .frozen:
                try updateProcessing(id, state: .frozen, phase: .association, error: "关联依据已变化，回执作为冻结历史保留；未重发")
            case .paused, .localOnly, .modelUnavailable, .budgetExceeded, .inFlight:
                try updateProcessing(id, state: .blocked, phase: .association, error: "关联阶段未执行：\(association.state.rawValue)")
            }
        } catch is CancellationError {
            row = try processingRow(id: id)
            let cognitionID = try cognitionAttemptID(for: snapshot, latest: retryKey != nil), associationID = try associationAttemptID(for: snapshot, latest: retryKey != nil)
            let cancelled = row["state"] == ExpressionProcessingIntentState.cancelled.rawValue
            try updateProcessing(id, state: cancelled ? .cancelled : .unknown,
                error: cancelled ? nil : "处理被取消，结果未知；不会自动重发", cognitionAttemptID: cognitionID, associationAttemptID: associationID)
            if cancelled {
                if !associationStarted, !cognitionWasReused, let cognitionID { try freezeProcessingCognitionAttempt(cognitionID) }
                if let associationID { try freezeProcessingAssociationAttempt(associationID) }
            }
        } catch {
            row = try processingRow(id: id)
            let cognitionID = try cognitionAttemptID(for: snapshot, latest: retryKey != nil)
            let associationID = try associationAttemptID(for: snapshot, latest: retryKey != nil)
            if row["state"] == ExpressionProcessingIntentState.cancelled.rawValue {
                try updateProcessing(id, state: .cancelled, cognitionAttemptID: cognitionID, associationAttemptID: associationID)
                if !associationStarted, !cognitionWasReused, let attempt = cognitionAttemptForIntent ?? cognitionID { try freezeProcessingCognitionAttempt(attempt) }
                if let attempt = associationAttemptForIntent ?? associationID { try freezeProcessingAssociationAttempt(attempt) }
                return try processingIntent(id: id)
            }
            let associationState = try associationID.flatMap { try db.query("SELECT state FROM expression_association_attempts WHERE id=?", [$0]).first?["state"] }
            let cognitionState = try cognitionID.flatMap { try db.query("SELECT state FROM model_attempts WHERE id=?", [$0]).first?["state"] }
            let terminal: ExpressionProcessingIntentState
            if associationState == "unknown" || cognitionState == "unknown" { terminal = .unknown }
            else if associationState == "rejected" || cognitionState == "rejected" { terminal = .rejected }
            else { terminal = .blocked }
            try updateProcessing(id, state: terminal, error: error.localizedDescription,
                                 cognitionAttemptID: cognitionID, associationAttemptID: associationID)
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
                  row["snapshot_digest"] == (try? Self.processingSnapshotDigest(JSONDecoder().decode(ExpressionProcessingIntentSnapshot.self, from: Data(snapshotJSON.utf8)))),
                  row["cognition_destination"] == row["association_destination"] else { throw VoiceOSError("持久处理意图身份或摘要不一致") }
            guard (row["ignored_at"] == nil) == (row["ignore_reason"] == nil) else { throw VoiceOSError("忽略处理失败的状态不完整") }
            if let supersededBy = row["superseded_by"] {
                guard try db.query("SELECT id FROM processing_intents WHERE id=?", [supersededBy]).first != nil else { throw VoiceOSError("重新理解记录缺失") }
            }
            let snapshot = try JSONDecoder().decode(ExpressionProcessingIntentSnapshot.self, from: Data(snapshotJSON.utf8))
            // schema25/v24 before this fix used the full snapshot hash as both fields.
            let semanticFingerprint = try Self.processingCommandFingerprint(snapshot)
            guard row["command_fingerprint"] == row["snapshot_digest"] || row["command_fingerprint"] == semanticFingerprint else { throw VoiceOSError("处理命令摘要不一致") }
            let contextEncoder = StableJSON.makeEncoder()
            let contextDigest = Self.relevanceHash(try contextEncoder.encode(snapshot.context.sources))
            guard snapshot.context.sources.count == 1, snapshot.context.contentDigest == contextDigest, snapshot.context.sources[0].sourceID == sourceID,
                  snapshot.context.sources[0].sourceVersionID == row["source_version_id"], snapshot.context.sources[0].transcriptVersionID == row["transcript_version_id"],
                  snapshot.policyVersion == Int(row["policy_version"] ?? "0"), snapshot.cognition.provider == row["cognition_provider"], snapshot.association.provider == row["association_provider"],
                  snapshot.cognition.model == row["cognition_model"], snapshot.association.model == row["association_model"],
                  snapshot.cognition.promptVersion == row["cognition_prompt_version"], snapshot.association.promptVersion == row["association_prompt_version"],
                  snapshot.cognition.schemaVersion == row["cognition_schema_version"], snapshot.association.schemaVersion == row["association_schema_version"],
                  snapshot.cognition.destination.rawValue == row["cognition_destination"], snapshot.association.destination.rawValue == row["association_destination"] else { throw VoiceOSError("持久处理意图快照与目录不一致") }
            try validateProcessingReceiptBindings(db, row: row, snapshot: snapshot)
        }
    }
}
