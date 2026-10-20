import Foundation

public struct DiscussionClaimDerivation:Identifiable,Sendable {
    public let id:String
    public let conversationID:String
    public let discussionAttemptID:String
    public let partIndex:Int
    public let claimID:String?
    public let state:String
    public let referenceKind:String
}
extension VoiceOSStore {
    /// Local copy of an AI paragraph. Never calls a model, writes user text or creates an action.
    public func retainDiscussionAICandidate(attemptID:String,partIndex:Int,commandID:String = UUID().uuidString) throws -> String {
        guard ready,!commandID.isEmpty,(0..<8).contains(partIndex) else { throw VoiceOSError("AI候选保留命令无效") }
        if let receipt=try db.query("SELECT * FROM discussion_claim_derivations WHERE command_id=?",[commandID]).first {
            guard receipt["discussion_attempt_id"] == attemptID,receipt["part_index"] == String(partIndex) else { throw VoiceOSError("同一派生命令不能更换AI段落") }
        }
        var row=try db.query("SELECT * FROM discussion_claim_derivations WHERE discussion_attempt_id=? AND part_index=?",[attemptID,String(partIndex)]).first
        if let row,row["state"] == "completed",let claimID=row["claim_id"] { return claimID }
        if let existing=try existingOutcomeParagraphClaim(attemptID:attemptID,partIndex:partIndex) { return existing }
        guard let parent=try db.query("SELECT * FROM discussion_attempts WHERE id=?",[attemptID]).first,parent["state"] == "completed",parent["validity"] == "current",
              try conversation(id:parent["conversation_id"]!).validity == "current" else { throw VoiceOSError("讨论回复尚未接纳或已冻结，不能新增AI候选") }
        let snapshot=try JSONDecoder().decode(DiscussionSnapshot.self,from:Data(parent["snapshot_json"]!.utf8))
        let current=try localContext(id:parent["context_id"]!)
        guard try Self.relevanceJSON(current) == Self.relevanceJSON(snapshot.context) else { throw VoiceOSError("讨论实际输入已变化") }
        let parts=try Self.discussionParts(parent)
        guard parts.indices.contains(partIndex),parts[partIndex].kind == .aiSuggestion else { throw VoiceOSError("只能保留AI分析，不能把原话引用变成AI观点") }
        let (proposal,referenceKind)=try Self.discussionDerivedProposal(snapshot:snapshot,part:parts[partIndex])
        let partDigest=Self.relevanceHash(Data(try Self.relevanceJSON(parts[partIndex]).utf8))
        if row == nil {
            let id=UUID().uuidString,modelID=UUID().uuidString
            let contextID=try persistLocalContext(current,commandID:"discussion-derivation:"+id,destination:.local)
            try db.transaction {
                try db.execute("INSERT INTO model_attempts(id,context_id,provider,model,prompt_version,schema_version,state,created_at,execution_kind,producer_sequence) VALUES(?,?,'discussion_derivation','discussion-part-copy-v1','not_applicable','ai-candidate-v1','reserved',?,'discussion_derivation',?)",[modelID,contextID,Self.now(),try db.nextModelProducerSequence()])
                try db.execute("INSERT INTO discussion_claim_derivations(id,command_id,discussion_attempt_id,part_index,part_digest,reference_kind,model_attempt_id,state,created_at) VALUES(?,?,?,?,?,?,?,'pending',?)",[id,commandID,attemptID,String(partIndex),partDigest,referenceKind,modelID,Self.now()])
            }
            try checkpoint(.discussionCandidateReserved)
            row=try db.query("SELECT * FROM discussion_claim_derivations WHERE id=?",[id]).first
        }
        guard let row,row["state"] == "pending",row["part_digest"] == partDigest,row["reference_kind"] == referenceKind,
              let internalAttempt=try db.query("SELECT * FROM model_attempts WHERE id=?",[row["model_attempt_id"]]).first,
              internalAttempt["execution_kind"] == "discussion_derivation",["reserved","unknown"].contains(internalAttempt["state"] ?? "") else { throw VoiceOSError("AI候选派生身份或状态不符") }
        // Explicitly resume a pure local copy, never a model_request or any external operation.
        if internalAttempt["state"] == "unknown" { try db.execute("UPDATE model_attempts SET state='reserved',error=NULL WHERE id=? AND execution_kind='discussion_derivation' AND state='unknown'",[internalAttempt["id"]]) }
        let ids=try commitClaims(attemptID:internalAttempt["id"]!,proposals:[proposal],additionalCommit:{ ids in
            guard ids.count == 1 else { throw VoiceOSError("AI段落派生必须对应唯一候选") }
            try db.execute("UPDATE discussion_claim_derivations SET state='completed',claim_id=? WHERE id=? AND state='pending'",[ids[0],row["id"]])
            try checkpoint(.discussionCandidateUncommitted)
        })
        try checkpoint(.discussionCandidateCommitted)
        return ids[0]
    }
    public func discussionClaimDerivations(conversationID:String) throws -> [DiscussionClaimDerivation] {
        _=try conversation(id:conversationID)
        return try discussionClaimOrigins().filter { $0.conversationID == conversationID }
    }
    public func discussionClaimOrigins() throws -> [DiscussionClaimDerivation] {
        try db.query("SELECT d.*,a.conversation_id FROM discussion_claim_derivations d JOIN discussion_attempts a ON a.id=d.discussion_attempt_id ORDER BY d.created_at,d.id").map {
            DiscussionClaimDerivation(id:$0["id"]!,conversationID:$0["conversation_id"]!,discussionAttemptID:$0["discussion_attempt_id"]!,partIndex:Int($0["part_index"]!)!,claimID:$0["claim_id"],state:$0["state"]!,referenceKind:$0["reference_kind"]!)
        }
    }
    func existingOutcomeParagraphClaim(attemptID:String,partIndex:Int) throws -> String? {
        guard let parent=try db.query("SELECT * FROM discussion_attempts WHERE id=? AND state='completed'",[attemptID]).first else { return nil }
        let parts=try Self.discussionParts(parent)
        guard parts.indices.contains(partIndex),parts[partIndex].kind == .aiSuggestion else { return nil }
        for row in try db.query("SELECT o.result_json,c.id,c.ordinal,c.statement FROM conversation_outcome_attempts o JOIN model_attempts m ON m.id=o.id JOIN claims c ON c.attempt_id=o.id WHERE o.conversation_id=? AND m.state='completed' AND c.ownership='ai_candidate'",[parent["conversation_id"]]) {
            let proposals=try JSONDecoder().decode([ConversationOutcomeProposal].self,from:Data(row["result_json"]!.utf8))
            guard let index=row["ordinal"].flatMap(Int.init),proposals.indices.contains(index) else { throw VoiceOSError("成果候选位置不符") }
            if row["statement"] == parts[partIndex].text,proposals[index].replyEvidence.contains(where: { $0.attemptID == attemptID && $0.partIndex == partIndex && $0.quote == parts[partIndex].text }) { return row["id"] }
        }
        return nil
    }
    static func discussionDerivedProposal(snapshot:DiscussionSnapshot,part:DiscussionPart) throws -> (ClaimProposal,String) {
        guard part.kind == .aiSuggestion else { throw VoiceOSError("原话引用不是AI候选") }
        var refs=part.references
        let kind=refs.isEmpty ? "context_anchor" : "model_citation"
        if refs.isEmpty {
            guard let last=snapshot.input.userTurns.last,let source=snapshot.context.sources.first(where: { $0.sourceID == last.sourceID && $0.transcriptVersionID == last.transcriptVersionID }),let span=source.spans.first else { throw VoiceOSError("AI段落缺少对应讨论触发原文") }
            refs=[ClaimReference(sourceID:source.sourceID,transcriptVersionID:source.transcriptVersionID,spanID:span.id)]
        }
        let proposal=ClaimProposal(statement:part.text,ownership:.aiCandidate,references:refs)
        try validateProposals([proposal],context:snapshot.context)
        return (proposal,kind)
    }
    func freezeDiscussionDerivations() throws {
        try db.execute("UPDATE contexts SET state='stale' WHERE id IN (SELECT m.context_id FROM discussion_claim_derivations d JOIN model_attempts m ON m.id=d.model_attempt_id JOIN discussion_attempts a ON a.id=d.discussion_attempt_id WHERE a.validity='frozen')")
        try db.execute("UPDATE claims SET validity='frozen' WHERE attempt_id IN (SELECT d.model_attempt_id FROM discussion_claim_derivations d JOIN discussion_attempts a ON a.id=d.discussion_attempt_id WHERE a.validity='frozen')")
        try db.execute("UPDATE actions SET validity='frozen' WHERE claim_id IN (SELECT c.id FROM claims c JOIN discussion_claim_derivations d ON d.claim_id=c.id JOIN discussion_attempts a ON a.id=d.discussion_attempt_id WHERE a.validity='frozen')")
    }
    static func validateStoredDiscussionDerivations(_ db:Database) throws {
        guard try db.query("SELECT m.id FROM model_attempts m LEFT JOIN discussion_claim_derivations d ON d.model_attempt_id=m.id WHERE (m.execution_kind='discussion_derivation' AND d.id IS NULL) OR (m.provider='discussion_derivation' AND m.execution_kind!='discussion_derivation')").isEmpty else { throw VoiceOSError("本地派生不能冒充模型调用或缺少出处关系") }
        for d in try db.query("SELECT * FROM discussion_claim_derivations") {
            guard let parent=try db.query("SELECT * FROM discussion_attempts WHERE id=? AND state='completed'",[d["discussion_attempt_id"]]).first,
                  let index=d["part_index"].flatMap(Int.init),
                  let attempt=try db.query("SELECT * FROM model_attempts WHERE id=?",[d["model_attempt_id"]]).first,
                  attempt["execution_kind"] == "discussion_derivation",attempt["provider"] == "discussion_derivation",attempt["model"] == "discussion-part-copy-v1",
                  attempt["prompt_version"] == "not_applicable",attempt["schema_version"] == "ai-candidate-v1",attempt["usage_json"] == nil,
                  let context=try db.query("SELECT * FROM contexts WHERE id=? AND destination='local'",[attempt["context_id"]]).first else { throw VoiceOSError("讨论派生没有对应回复或本地提交身份") }
            let parts=try discussionParts(parent),snapshot=try JSONDecoder().decode(DiscussionSnapshot.self,from:Data(parent["snapshot_json"]!.utf8))
            guard parts.indices.contains(index),d["part_digest"] == relevanceHash(Data(try relevanceJSON(parts[index]).utf8)),context["snapshot_json"] == (try relevanceJSON(snapshot.context)) else { throw VoiceOSError("派生段落或完整来源快照不符") }
            let (proposal,kind)=try discussionDerivedProposal(snapshot:snapshot,part:parts[index])
            guard kind == d["reference_kind"] else { throw VoiceOSError("派生引用语义不符") }
            let claims=try db.query("SELECT * FROM claims WHERE attempt_id=?",[attempt["id"]])
            if d["state"] == "pending" {
                guard d["claim_id"] == nil,claims.isEmpty,["reserved","unknown"].contains(attempt["state"] ?? ""),attempt["result_digest"] == nil else { throw VoiceOSError("未完成派生不能带已提交候选") }
            } else {
                guard d["state"] == "completed",claims.count == 1,let claim=claims.first,claim["id"] == d["claim_id"],claim["ordinal"] == "0",claim["statement"] == proposal.statement,
                      claim["ownership"] == "ai_candidate",claim["evidence_state"] == "unverified",claim["action_json"] == nil,
                      claim["refs_json"] == (try relevanceJSON(proposal.references)),attempt["state"] == "completed",
                      attempt["result_digest"] == relevanceHash(Data(try relevanceJSON([proposal]).utf8)),
                      parent["validity"] != "frozen" || (claim["validity"] == "frozen" && context["state"] == "stale") else { throw VoiceOSError("已完成派生的候选、归属或原子状态不符") }
            }
        }
    }
}
