import Foundation
import CryptoKit

public struct ClaimReference: Codable, Sendable {
    public let sourceID: String
    public let transcriptVersionID: String
    public let spanID: String
    public init(sourceID: String, transcriptVersionID: String, spanID: String) {
        self.sourceID = sourceID; self.transcriptVersionID = transcriptVersionID; self.spanID = spanID
    }
}
public enum CandidateOwnership: String, Codable, Sendable { case external, aiCandidate = "ai_candidate", unresolved }
public struct ClaimProposal: Codable, Sendable {
    public let statement: String
    public let ownership: CandidateOwnership
    public let references: [ClaimReference]
    public init(statement: String, ownership: CandidateOwnership, references: [ClaimReference]) {
        self.statement = statement; self.ownership = ownership; self.references = references
    }
}
public struct CandidateClaim: Identifiable, Sendable {
    public let id: String
    public let statement: String
    public let ownership: String
    public let evidenceState: String
    public let validity: String
    public let references: [ClaimReference]
}
extension VoiceOSStore {
    @discardableResult
    public func persistLocalContext(_ context: LocalTranscriptContext, commandID: String = UUID().uuidString) throws -> String {
        // Receipts replay original identity even after invalidation; never reactivate it.
        let snapshot = try json(context)
        if let existing = try db.query("SELECT * FROM contexts WHERE command_id=?", [commandID]).first {
            guard existing["snapshot_json"] == snapshot else { throw VoiceOSError("同一上下文命令不能更换内容") }
            return existing["id"]!
        }
        try validateLocalTranscriptContext(context)
        let id = UUID().uuidString
        try db.transaction {
            try db.execute("INSERT INTO contexts(id,command_id,snapshot_json,digest,state,created_at) VALUES(?,?,?,?,'current',?)", [id,commandID,snapshot,context.contentDigest,timestamp()])
            for input in context.sources {
                try db.execute("INSERT INTO context_inputs(id,context_id,source_id,transcript_version_id) VALUES(?,?,?,?)", [UUID().uuidString,id,input.sourceID,input.transcriptVersionID])
            }
        }
        return id
    }
    public func localContext(id: String) throws -> LocalTranscriptContext {
        guard let row = try db.query("SELECT * FROM contexts WHERE id=? AND state='current'", [id]).first else { throw VoiceOSError("上下文已失效或不存在") }
        let context = try JSONDecoder().decode(LocalTranscriptContext.self, from: Data(row["snapshot_json"]!.utf8))
        do { try validateLocalTranscriptContext(context) }
        catch { try db.transaction { try freezeContext(id) }; throw error }
        return context
    }
    /// This slice only supports local fixtures. A reservation is durable before work;
    /// it is not a cloud grant and there is no automatic resend after interruption.
    public func reserveLocalModelAttempt(contextID: String, model: String, promptVersion: String, schemaVersion: String) throws -> String {
        _ = try localContext(id: contextID)
        guard !model.isEmpty, !promptVersion.isEmpty, !schemaVersion.isEmpty else { throw VoiceOSError("模型调用配置缺少版本") }
        let id = UUID().uuidString
        try db.execute("INSERT INTO model_attempts(id,context_id,provider,model,prompt_version,schema_version,state,created_at) VALUES(?,?,'local_fixture',?,?,?,'reserved',?)", [id,contextID,model,promptVersion,schemaVersion,timestamp()])
        try checkpoint(.modelReserved)
        return id
    }
    public func commitLocalClaims(attemptID: String, proposals: [ClaimProposal]) throws -> [String] {
        guard let attempt = try db.query("SELECT * FROM model_attempts WHERE id=?", [attemptID]).first else { throw VoiceOSError("调用记录不存在") }
        let digest = try hash(proposals)
        if attempt["state"] == "completed" {
            guard attempt["result_digest"] == digest else { throw VoiceOSError("已提交调用不能改写结果") }
            return try db.query("SELECT id FROM claims WHERE attempt_id=? ORDER BY id", [attemptID]).map { $0["id"]! }
        }
        guard attempt["state"] == "reserved", attempt["provider"] == "local_fixture" else { throw VoiceOSError("调用已结束或结果未知，不能重放提交") }
        do {
            let context = try localContext(id: attempt["context_id"]!)
            try Self.validateProposals(proposals, context: context)
        } catch {
            try db.execute("UPDATE model_attempts SET state='rejected',error=? WHERE id=?", [error.localizedDescription,attemptID])
            throw error
        }
        // Validation and commit have no await; this actor is the sole writer.
        var ids: [String] = []
        try db.transaction {
            for (ordinal, proposal) in proposals.enumerated() {
                let id = UUID().uuidString; ids.append(id)
                try db.execute("INSERT INTO claims(id,attempt_id,ordinal,statement,ownership,evidence_state,validity,refs_json,created_at) VALUES(?,?,?,?,?,'unverified','current',?,?)", [id,attemptID,String(ordinal),proposal.statement,proposal.ownership.rawValue,try json(proposal.references),timestamp()])
            }
            try db.execute("UPDATE model_attempts SET state='completed',result_digest=? WHERE id=? AND state='reserved'", [digest,attemptID])
            try checkpoint(.claimsUncommitted)
        }
        try checkpoint(.claimsCommitted)
        return ids.sorted()
    }
    public func candidateClaims(includeFrozen: Bool = false) throws -> [CandidateClaim] {
        // Dynamic read checks are a second barrier in addition to atomic invalidation.
        for row in try db.query("SELECT id FROM contexts WHERE state='current'") {
            do { _ = try localContext(id: row["id"]!) } catch { try db.transaction { try freezeContext(row["id"]!) } }
        }
        let whereClause = includeFrozen ? "" : "WHERE c.validity='current' AND x.state='current'"
        return try db.query("SELECT c.* FROM claims c JOIN model_attempts a ON a.id=c.attempt_id JOIN contexts x ON x.id=a.context_id \(whereClause) ORDER BY c.created_at,c.id").map {
            CandidateClaim(id: $0["id"]!, statement: $0["statement"]!, ownership: $0["ownership"]!, evidenceState: $0["evidence_state"]!, validity: $0["validity"]!, references: try JSONDecoder().decode([ClaimReference].self, from: Data($0["refs_json"]!.utf8)))
        }
    }
    static func validateProposals(_ proposals: [ClaimProposal], context: LocalTranscriptContext) throws {
        for proposal in proposals {
            guard !proposal.statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !proposal.references.isEmpty else { throw VoiceOSError("认知候选缺少内容或出处") }
            for ref in proposal.references {
                guard context.sources.contains(where: { $0.sourceID == ref.sourceID && $0.transcriptVersionID == ref.transcriptVersionID && $0.spans.contains(where: { $0.id == ref.spanID }) && (proposal.ownership != .external || $0.origin == "external") }) else { throw VoiceOSError("认知候选引用了未选入或错误版本的来源片段") }
            }
        }
    }
    static func validateStoredCognition(_ db: Database) throws {
        for row in try db.query("SELECT * FROM contexts") {
            let context = try JSONDecoder().decode(LocalTranscriptContext.self, from: Data(row["snapshot_json"]!.utf8))
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let digest = SHA256.hash(data: try encoder.encode(context.sources)).map { String(format: "%02x", $0) }.joined()
            guard context.scalarBudget > 0, !context.sources.isEmpty,
                  context.sources.reduce(0, { $0 + $1.text.unicodeScalars.count }) <= context.scalarBudget,
                  digest == context.contentDigest, digest == row["digest"],
                  Set(context.sources.map(\.sourceID)).count == context.sources.count else { throw VoiceOSError("迁移上下文摘要或预算不一致") }
            let inputs = try db.query("SELECT * FROM context_inputs WHERE context_id=?", [row["id"]])
            guard inputs.count == context.sources.count else { throw VoiceOSError("迁移上下文输入不完整") }
            for input in context.sources {
                guard inputs.contains(where: { $0["source_id"] == input.sourceID && $0["transcript_version_id"] == input.transcriptVersionID }),
                      let version = try db.query("SELECT v.*,t.source_id,t.current_version_id,s.version_id,s.duration,s.state,s.origin,s.speaker,s.local_only FROM transcript_versions v JOIN transcripts t ON t.id=v.transcript_id JOIN sources s ON s.id=t.source_id WHERE v.id=?", [input.transcriptVersionID]).first,
                      version["source_id"] == input.sourceID, version["version_id"] == input.sourceVersionID,
                      version["text"] == input.text else { throw VoiceOSError("迁移上下文来源版本不一致") }
                let spans = try JSONDecoder().decode([TranscriptSpan].self, from: Data(version["spans_json"]!.utf8))
                guard try encoder.encode(spans) == encoder.encode(input.spans) else { throw VoiceOSError("迁移上下文片段不一致") }
                try SpeechText(text: input.text, spans: input.spans).validate(duration: version["duration"].flatMap(Double.init))
                if row["state"] == "current" {
                    guard version["current_version_id"] == input.transcriptVersionID,
                          ["saved","reference_only"].contains(version["state"] ?? ""),
                          version["origin"] == input.origin, version["speaker"] == input.speaker, (version["local_only"] != "0") == input.localOnly else { throw VoiceOSError("迁移的当前上下文引用失效来源") }
                }
            }
            for claim in try db.query("SELECT c.*,a.state AS attempt_state FROM claims c JOIN model_attempts a ON a.id=c.attempt_id WHERE a.context_id=?", [row["id"]]) {
                guard claim["attempt_state"] == "completed", let owner = CandidateOwnership(rawValue: claim["ownership"]!),
                      claim["validity"] != "current" || row["state"] == "current" else { throw VoiceOSError("迁移认知候选状态不一致") }
                let refs = try JSONDecoder().decode([ClaimReference].self, from: Data(claim["refs_json"]!.utf8))
                try validateProposals([ClaimProposal(statement: claim["statement"]!, ownership: owner, references: refs)], context: context)
            }
        }
        for attempt in try db.query("SELECT * FROM model_attempts WHERE state='completed'") {
            var proposals: [ClaimProposal] = []
            for (index, claim) in try db.query("SELECT * FROM claims WHERE attempt_id=? ORDER BY ordinal", [attempt["id"]]).enumerated() {
                guard claim["ordinal"] == String(index), let owner = CandidateOwnership(rawValue: claim["ownership"]!) else { throw VoiceOSError("迁移候选顺序不一致") }
                proposals.append(ClaimProposal(statement: claim["statement"]!, ownership: owner, references: try JSONDecoder().decode([ClaimReference].self, from: Data(claim["refs_json"]!.utf8))))
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let digest = SHA256.hash(data: try encoder.encode(proposals)).map { String(format: "%02x", $0) }.joined()
            guard digest == attempt["result_digest"] else { throw VoiceOSError("迁移调用结果摘要不一致") }
        }
    }
    // Call inside the same transaction as a correction/quarantine.
    func invalidateCognition(sourceID: String) throws {
        for row in try db.query("SELECT context_id FROM context_inputs WHERE source_id=?", [sourceID]) { try freezeContext(row["context_id"]!) }
    }
    private func freezeContext(_ id: String) throws {
        try db.execute("UPDATE contexts SET state='stale' WHERE id=?", [id])
        try db.execute("UPDATE claims SET validity='frozen' WHERE attempt_id IN (SELECT id FROM model_attempts WHERE context_id=?)", [id])
    }
    private func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    private func hash<T: Encodable>(_ value: T) throws -> String { SHA256.hash(data: Data(try json(value).utf8)).map { String(format: "%02x", $0) }.joined() }
    private func timestamp() -> String { ISO8601DateFormatter().string(from: Date()) }
}
