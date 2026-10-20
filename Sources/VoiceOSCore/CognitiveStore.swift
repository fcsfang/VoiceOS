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
public enum CandidateOwnership: String, Codable, Sendable { case external, aiCandidate = "ai_candidate", unresolved, userTentative = "user_tentative" }
public struct ExtractedAction: Codable, Sendable {
    public let title: String
    public let kind: ActionKind
    public let quote: String
    public let autoSend: Bool
    public init(title: String, kind: ActionKind, quote: String, autoSend: Bool = false) {
        self.title = title; self.kind = kind; self.quote = quote; self.autoSend = autoSend
    }
}
public enum CognitiveContentKind: String, Codable, Sendable { case statement, question, hypothesis, reflection, unclassified }
public struct ClaimProposal: Codable, Sendable {
    public let statement: String
    public let ownership: CandidateOwnership
    public let references: [ClaimReference]
    public let action: ExtractedAction?
    public let contentKind: CognitiveContentKind?
    public init(statement: String, ownership: CandidateOwnership, references: [ClaimReference], action: ExtractedAction? = nil, contentKind: CognitiveContentKind? = nil) {
        self.statement = statement; self.ownership = ownership; self.references = references; self.action = action; self.contentKind = contentKind
    }
}
public struct CandidateClaim: Identifiable, Sendable {
    public let contentKind: CognitiveContentKind?
    public let id: String
    public let statement: String
    public let ownership: String
    public let evidenceState: String
    public let validity: String
    public let references: [ClaimReference]
    public let reviewVersion: Int
    public let reviewState: String
}
extension VoiceOSStore {
    @discardableResult
    public func persistLocalContext(_ context: LocalTranscriptContext, commandID: String = UUID().uuidString, destination: ModelDestination = .local) throws -> String {
        // Receipts replay original identity even after invalidation; never reactivate it.
        let snapshot = try json(context)
        if let existing = try db.query("SELECT * FROM contexts WHERE command_id=?", [commandID]).first {
            guard existing["snapshot_json"] == snapshot, existing["destination"] == destination.rawValue else { throw VoiceOSError("同一上下文命令不能更换内容") }
            return existing["id"]!
        }
        try validateLocalTranscriptContext(context)
        if destination == .cloud, context.sources.contains(where: \.localOnly) { throw VoiceOSError("仅本地来源不能用于云端处理") }
        let id = UUID().uuidString
        try db.transaction {
            try db.execute("INSERT INTO contexts(id,command_id,snapshot_json,digest,state,created_at,destination) VALUES(?,?,?,?,'current',?,?)", [id,commandID,snapshot,context.contentDigest,timestamp(),destination.rawValue])
            for input in context.sources {
                try db.execute("INSERT INTO context_inputs(id,context_id,source_id,transcript_version_id,policy_version) VALUES(?,?,?,?,?)", [UUID().uuidString,id,input.sourceID,input.transcriptVersionID,try db.query("SELECT policy_version FROM sources WHERE id=?", [input.sourceID]).first?["policy_version"]])
            }
        }
        return id
    }
    public func localContext(id: String) throws -> LocalTranscriptContext {
        guard let row = try db.query("SELECT * FROM contexts WHERE id=? AND state='current'", [id]).first else { throw VoiceOSError("上下文已失效或不存在") }
        let context = try JSONDecoder().decode(LocalTranscriptContext.self, from: Data(row["snapshot_json"]!.utf8))
        do {
            try validateLocalTranscriptContext(context)
            guard try db.query("SELECT i.id FROM context_inputs i JOIN sources s ON s.id=i.source_id WHERE i.context_id=? AND i.policy_version!=s.policy_version", [id]).isEmpty else { throw VoiceOSError("来源授权版本已变化") }
        }
        catch { try db.transaction { try freezeContext(id) }; throw error }
        return context
    }
    /// This slice only supports local fixtures. A reservation is durable before work;
    /// it is not a cloud grant and there is no automatic resend after interruption.
    public func reserveLocalModelAttempt(contextID: String, model: String, promptVersion: String, schemaVersion: String) throws -> String {
        guard try db.query("SELECT destination FROM contexts WHERE id=?", [contextID]).first?["destination"] == "local" else { throw VoiceOSError("本地夹具不能使用云端上下文") }
        _ = try localContext(id: contextID)
        guard !model.isEmpty, !promptVersion.isEmpty, !schemaVersion.isEmpty else { throw VoiceOSError("模型调用配置缺少版本") }
        let id = UUID().uuidString
        try db.execute("INSERT INTO model_attempts(id,context_id,provider,model,prompt_version,schema_version,state,created_at,producer_sequence) VALUES(?,?,'local_fixture',?,?,?,'reserved',?,?)", [id,contextID,model,promptVersion,schemaVersion,timestamp(),try db.nextModelProducerSequence()])
        try checkpoint(.modelReserved)
        return id
    }
    public func commitLocalClaims(attemptID: String, proposals: [ClaimProposal]) throws -> [String] {
        guard try db.query("SELECT provider FROM model_attempts WHERE id=?", [attemptID]).first?["provider"] == "local_fixture" else { throw VoiceOSError("只能提交本地夹具调用") }
        return try commitClaims(attemptID: attemptID, proposals: proposals)
    }
    func commitClaims(attemptID: String, proposals: [ClaimProposal], additionalCommit: ([String]) throws -> Void = { _ in }) throws -> [String] {
        guard let attempt = try db.query("SELECT * FROM model_attempts WHERE id=?", [attemptID]).first else { throw VoiceOSError("调用记录不存在") }
        let digest = try hash(proposals)
        if attempt["state"] == "completed" {
            guard attempt["result_digest"] == digest else { throw VoiceOSError("已提交调用不能改写结果") }
            return try db.query("SELECT id FROM claims WHERE attempt_id=? ORDER BY id", [attemptID]).map { $0["id"]! }
        }
        guard attempt["state"] == "reserved" else { throw VoiceOSError("调用已结束或结果未知，不能重放提交") }
        do {
            let context = try localContext(id: attempt["context_id"]!)
            try Self.validateProposals(proposals, context: context)
        } catch {
            try db.execute("UPDATE model_attempts SET state='rejected',error=? WHERE id=?", [error.localizedDescription,attemptID])
            throw error
        }
        // Validation and commit have no await; this actor is the sole writer.
        let ids = try db.transaction { try insertValidatedClaims(attemptID:attemptID,proposals:proposals,additionalCommit:additionalCommit) }
        try checkpoint(.claimsCommitted)
        return ids
    }
    /// Caller owns the transaction and has validated the original typed producer.
    func insertValidatedClaims(attemptID: String, proposals: [ClaimProposal], additionalCommit: ([String]) throws -> Void = { _ in }) throws -> [String] {
        guard let attempt=try db.query("SELECT * FROM model_attempts WHERE id=? AND state='reserved'",[attemptID]).first else { throw VoiceOSError("认知生产者未预留") }
        let digest=try hash(proposals)
        var ids: [String] = []
        for (ordinal, proposal) in proposals.enumerated() {
            let id = UUID().uuidString; ids.append(id)
            try db.execute("INSERT INTO claims(id,attempt_id,ordinal,statement,ownership,evidence_state,validity,refs_json,created_at,action_json,content_kind) VALUES(?,?,?,?,?,'unverified','current',?,?,?,?)", [id,attemptID,String(ordinal),proposal.statement,proposal.ownership.rawValue,try json(proposal.references),timestamp(),try proposal.action.map { try json($0) },proposal.contentKind?.rawValue])
            if let action = proposal.action {
                let actor = action.kind == .aiSuggestion ? "ai" : "user"
                let command = "extracted:" + attemptID + ":" + String(ordinal)
                let fingerprint = try Self.actionHash([id,"0",action.title,action.kind.rawValue,actor,action.quote])
                try db.execute("INSERT INTO actions(id,claim_id,claim_review_version,title,kind,intent_actor,note,state,validity,command_id,input_fingerprint,created_at,auto_send) VALUES(?,?,0,?,?,?,?,'open','current',?,?,?,?)", [UUID().uuidString,id,action.title,action.kind.rawValue,actor,action.quote,command,fingerprint,timestamp(),action.autoSend ? "1" : "0"])
            }
        }
        try db.execute("UPDATE model_attempts SET state='completed',result_digest=? WHERE id=? AND state='reserved'", [digest,attemptID])
        // Typed questions share the claims transaction: no partial identity after a crash.
        for (index, proposal) in proposals.enumerated() where proposal.contentKind == .question {
            let ref = proposal.references[0]
            let context = try localContext(id: attempt["context_id"]!)
            guard let source = context.sources.first(where: { $0.sourceID == ref.sourceID }),
                  let span = source.spans.first(where: { $0.id == ref.spanID }) else { throw VoiceOSError("问题出处缺失") }
            let scalars = Array(source.text.unicodeScalars)
            let quote = String(String.UnicodeScalarView(scalars[span.textStart..<min(span.textEnd, span.textStart + 2000)]))
            let seed = try prepareQuestionSeed(claimID: ids[index], expectedReviewVersion: 0, original: .init(reference: ref, quote: quote), scalarBudget: context.scalarBudget)
            _ = try insertQuestion(seed)
        }
        try additionalCommit(ids)
        try checkpoint(.claimsUncommitted)
        return ids.sorted()
    }
    public func candidateClaims(includeFrozen: Bool = false) throws -> [CandidateClaim] {
        // Dynamic read checks are a second barrier in addition to atomic invalidation.
        for row in try db.query("SELECT id FROM contexts WHERE state='current'") {
            do { _ = try localContext(id: row["id"]!) } catch { try db.transaction { try freezeContext(row["id"]!) } }
        }
        let whereClause = includeFrozen ? "" : "WHERE c.validity='current' AND x.state='current' AND COALESCE(r.decision,'pending')!='rejected'"
        return try db.query("SELECT c.*,r.statement AS reviewed_statement,r.ownership AS reviewed_ownership,r.decision AS review_state FROM claims c JOIN model_attempts a ON a.id=c.attempt_id JOIN contexts x ON x.id=a.context_id LEFT JOIN claim_reviews r ON r.claim_id=c.id AND r.version=c.review_version \(whereClause) ORDER BY c.created_at,c.id").map {
            CandidateClaim(contentKind: $0["reviewed_statement"] != nil && $0["reviewed_statement"] != $0["statement"] ? nil : $0["content_kind"].flatMap(CognitiveContentKind.init(rawValue:)), id: $0["id"]!, statement: $0["reviewed_statement"] ?? $0["statement"]!, ownership: $0["reviewed_ownership"] ?? $0["ownership"]!, evidenceState: $0["evidence_state"]!, validity: $0["validity"]!, references: try JSONDecoder().decode([ClaimReference].self, from: Data($0["refs_json"]!.utf8)), reviewVersion: Int($0["review_version"]!)!, reviewState: $0["review_state"] ?? "pending")
        }
    }

    /// Returns the latest completed cognition producer that used a source.
    ///
    /// Reprocessing a source creates a new immutable model attempt so that the
    /// old result remains auditable.  The control center needs a current view,
    /// however, rather than rendering every historical attempt as if it were a
    /// second set of thoughts.  This helper deliberately keeps the historical
    /// `candidateClaims` API unchanged and narrows only the source-facing view.
    public func latestCandidateClaims(for sourceID: String, includeFrozen: Bool = false) throws -> [CandidateClaim] {
        guard let attempt = try db.query("""
            SELECT a.id
            FROM model_attempts a
            JOIN context_inputs i ON i.context_id=a.context_id
            WHERE i.source_id=? AND a.state='completed'
            -- created_at is intentionally human-readable and may have only
            -- second-level precision.  producer_sequence is the durable
            -- ordering authority for model results, including rapid retries.
            ORDER BY a.producer_sequence DESC, a.created_at DESC, a.id DESC
            LIMIT 1
            """, [sourceID]).first,
              let attemptID = attempt["id"] else { return [] }
        let ids = Set(try db.query("SELECT id FROM claims WHERE attempt_id=?", [attemptID]).compactMap { $0["id"] })
        return try candidateClaims(includeFrozen: includeFrozen).filter { claim in
            ids.contains(claim.id) && claim.references.contains { $0.sourceID == sourceID }
        }
    }
    static func validateProposals(_ proposals: [ClaimProposal], context: LocalTranscriptContext) throws {
        guard proposals.count <= 32 else { throw VoiceOSError("行动提取超过单次范围") }
        for proposal in proposals {
            guard proposal.contentKind != .question || proposal.action == nil else { throw VoiceOSError("问题不能同时作为行动承诺；需分开提取") }
            guard !proposal.statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !proposal.references.isEmpty, proposal.references.count <= 32, proposal.statement.unicodeScalars.count <= 2000 else { throw VoiceOSError("认知候选缺少内容或出处") }
            for ref in proposal.references {
                guard context.sources.contains(where: { $0.sourceID == ref.sourceID && $0.transcriptVersionID == ref.transcriptVersionID && $0.spans.contains(where: { $0.id == ref.spanID }) && (proposal.ownership != .external || $0.origin == "external") && (proposal.ownership != .userTentative || ($0.origin == "user" && $0.speaker == "user")) }) else { throw VoiceOSError("认知候选引用了未选入或错误版本的来源片段") }
            }
            if let action = proposal.action {
                guard !action.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, action.title.unicodeScalars.count <= 2000,
                      !action.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, action.quote.unicodeScalars.count <= 2000,
                      !action.autoSend || action.kind == .task,
                      (action.kind == .aiSuggestion && proposal.ownership == .aiCandidate) || (action.kind != .aiSuggestion && proposal.ownership == .userTentative) else { throw VoiceOSError("行动提取缺少原话、正确归属或可执行范围") }
                let refsBySource = Dictionary(grouping: proposal.references, by: { "\($0.sourceID):\($0.transcriptVersionID)" })
                guard refsBySource.values.contains(where: { refs in
                    guard let source = context.sources.first(where: { s in s.sourceID == refs[0].sourceID && s.transcriptVersionID == refs[0].transcriptVersionID }) else { return false }
                    let ranges = refs.compactMap { ref in source.spans.first(where: { $0.id == ref.spanID }) }.map { ($0.textStart, $0.textEnd) }
                    guard let left = ranges.map({ $0.0 }).min(), let right = ranges.map({ $0.1 }).max(), left < right else { return false }
                    let scalars = Array(source.text.unicodeScalars)
                    return String(String.UnicodeScalarView(scalars[left..<right])).contains(action.quote)
                }) else { throw VoiceOSError("行动提取缺少原话、正确归属或可执行范围") }
            }
        }
    }
    static func validateStoredCognition(_ db: Database) throws {
        guard try db.query("SELECT id FROM model_attempts WHERE producer_sequence IS NULL OR typeof(producer_sequence)!='integer' OR producer_sequence<=0").isEmpty else { throw VoiceOSError("成果生产者缺少有效持久顺序") }
        for source in try db.query("SELECT id,local_only,policy_version FROM sources") {
            guard let version = Int(source["policy_version"]!), version >= 1, ["0","1"].contains(source["local_only"]!) else { throw VoiceOSError("迁移来源授权格式错误") }
            let history = try db.query("SELECT * FROM source_policy_revisions WHERE source_id=? ORDER BY to_version", [source["id"]])
            guard history.count == version-1 else { throw VoiceOSError("迁移来源授权历史不完整") }
            var flag = history.first?["from_local_only"] ?? source["local_only"]!
            for (index, change) in history.enumerated() {
                guard change["from_version"] == String(index+1), change["to_version"] == String(index+2),
                      ["0","1"].contains(flag), change["from_local_only"] == flag,
                      ["0","1"].contains(change["to_local_only"] ?? ""), change["to_local_only"] != flag else { throw VoiceOSError("迁移来源授权版本链不一致") }
                flag = change["to_local_only"]!
            }
            guard flag == source["local_only"] else { throw VoiceOSError("迁移来源授权当前值不一致") }
        }
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
                      let version = try db.query("SELECT v.*,t.source_id,t.current_version_id,s.version_id,s.duration,s.state,s.origin,s.speaker,s.local_only,s.policy_version FROM transcript_versions v JOIN transcripts t ON t.id=v.transcript_id JOIN sources s ON s.id=t.source_id WHERE v.id=?", [input.transcriptVersionID]).first,
                      version["source_id"] == input.sourceID, version["version_id"] == input.sourceVersionID,
                      version["text"] == input.text else { throw VoiceOSError("迁移上下文来源版本不一致") }
                let spans = try JSONDecoder().decode([TranscriptSpan].self, from: Data(version["spans_json"]!.utf8))
                guard try encoder.encode(spans) == encoder.encode(input.spans) else { throw VoiceOSError("迁移上下文片段不一致") }
                try SpeechText(text: input.text, spans: input.spans).validate(duration: version["duration"].flatMap(Double.init))
                if row["state"] == "current" {
                    guard version["current_version_id"] == input.transcriptVersionID,
                          ["saved","reference_only"].contains(version["state"] ?? ""),
                          inputs.contains(where: { $0["source_id"] == input.sourceID && ($0["policy_version"] ?? "1") == version["policy_version"] }),
                          version["origin"] == input.origin, version["speaker"] == input.speaker, (version["local_only"] != "0") == input.localOnly else { throw VoiceOSError("迁移的当前上下文引用失效来源") }
                }
            }
            for claim in try db.query("SELECT c.*,a.state AS attempt_state FROM claims c JOIN model_attempts a ON a.id=c.attempt_id WHERE a.context_id=?", [row["id"]]) {
                guard claim["attempt_state"] == "completed", let owner = CandidateOwnership(rawValue: claim["ownership"]!),
                      claim["validity"] != "current" || row["state"] == "current" else { throw VoiceOSError("迁移认知候选状态不一致") }
                let refs = try JSONDecoder().decode([ClaimReference].self, from: Data(claim["refs_json"]!.utf8))
                try validateProposals([ClaimProposal(statement: claim["statement"]!, ownership: owner, references: refs, action: try claim["action_json"].map { try JSONDecoder().decode(ExtractedAction.self, from: Data($0.utf8)) }, contentKind: claim["content_kind"].flatMap(CognitiveContentKind.init(rawValue:)))], context: context)
            }
        }
        for attempt in try db.query("SELECT * FROM model_attempts WHERE state='completed' AND provider NOT LIKE 'english_feedback:%'") {
            var proposals: [ClaimProposal] = []
            for (index, claim) in try db.query("SELECT * FROM claims WHERE attempt_id=? ORDER BY ordinal", [attempt["id"]]).enumerated() {
                guard claim["ordinal"] == String(index), let owner = CandidateOwnership(rawValue: claim["ownership"]!) else { throw VoiceOSError("迁移候选顺序不一致") }
                proposals.append(ClaimProposal(statement: claim["statement"]!, ownership: owner, references: try JSONDecoder().decode([ClaimReference].self, from: Data(claim["refs_json"]!.utf8)), action: try claim["action_json"].map { try JSONDecoder().decode(ExtractedAction.self, from: Data($0.utf8)) }, contentKind: claim["content_kind"].flatMap(CognitiveContentKind.init(rawValue:))))
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let digest = SHA256.hash(data: try encoder.encode(proposals)).map { String(format: "%02x", $0) }.joined()
            guard digest == attempt["result_digest"] else { throw VoiceOSError("迁移调用结果摘要不一致") }
        }
        try validateStoredUserExpressions(db)
        try validateStoredActionFeedback(db)
        for claim in try db.query("SELECT * FROM claims WHERE action_json IS NOT NULL") {
            let proposal = try JSONDecoder().decode(ExtractedAction.self, from: Data(claim["action_json"]!.utf8))
            let command = "extracted:" + claim["attempt_id"]! + ":" + claim["ordinal"]!
            let rows = try db.query("SELECT * FROM actions WHERE command_id=?", [command])
            guard rows.count == 1, let action = rows.first, action["claim_id"] == claim["id"], action["claim_review_version"] == "0",
                  action["title"] == proposal.title, action["kind"] == proposal.kind.rawValue, action["note"] == proposal.quote,
                  action["intent_actor"] == (proposal.kind == .aiSuggestion ? "ai" : "user"), action["auto_send"] == (proposal.autoSend ? "1" : "0") else { throw VoiceOSError("行动提取结果与原始调用不一致") }
        }
        guard try db.query("SELECT a.id FROM actions a JOIN claims c ON c.id=a.claim_id WHERE a.auto_send=1 AND (c.action_json IS NULL OR a.command_id!=('extracted:' || c.attempt_id || ':' || c.ordinal))").isEmpty else { throw VoiceOSError("自动行动缺少提取依据") }
        try validateStoredClaimReviews(db)
        try validateStoredActions(db)
        try validateStoredReminders(db)
    }
    // Call inside the same transaction as a correction/quarantine.
    func invalidateCognition(sourceID: String) throws {
        try db.execute("UPDATE segmented_processing_batches SET state='blocked',error='来源文字、授权或原件已变化',updated_at=? WHERE source_id=? AND state='queued'",[Self.processingNow(),sourceID])
        try db.execute("UPDATE segmented_aggregation_attempts SET validity='frozen' WHERE batch_id IN (SELECT id FROM segmented_processing_batches WHERE source_id=?)",[sourceID])
        try db.execute("UPDATE segmented_extraction_attempts SET validity='frozen' WHERE batch_id IN (SELECT id FROM segmented_processing_batches WHERE source_id=?)",[sourceID])
        try db.execute("UPDATE relevance_attempts SET validity='frozen' WHERE id IN (SELECT attempt_id FROM relevance_inputs WHERE source_id=?)", [sourceID])
        for row in try db.query("SELECT context_id FROM context_inputs WHERE source_id=?", [sourceID]) { try freezeContext(row["context_id"]!) }
    }
    private func freezeContext(_ id: String) throws {
        try db.execute("UPDATE contexts SET state='stale' WHERE id=?", [id])
        try db.execute("UPDATE conversations SET validity='frozen' WHERE entry_context_id=? OR id IN (SELECT conversation_id FROM conversation_user_turns WHERE context_id=?)",[id,id])
        try db.execute("UPDATE discussion_attempts SET validity='frozen' WHERE context_id=? OR conversation_id IN (SELECT id FROM conversations WHERE validity='frozen')",[id])
        try freezeDiscussionDerivations()
        try freezeConversationOutcomes()
        try db.execute("UPDATE actions SET validity='frozen' WHERE claim_id IN (SELECT id FROM claims WHERE attempt_id IN (SELECT id FROM model_attempts WHERE context_id=?))", [id])
        try db.execute("UPDATE claims SET validity='frozen' WHERE attempt_id IN (SELECT id FROM model_attempts WHERE context_id=?)", [id])
    }
    private func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    private func hash<T: Encodable>(_ value: T) throws -> String { SHA256.hash(data: Data(try json(value).utf8)).map { String(format: "%02x", $0) }.joined() }
    private func timestamp() -> String { ISO8601DateFormatter().string(from: Date()) }
}
