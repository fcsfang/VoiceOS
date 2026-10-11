import Foundation

/// Immutable producer identities only. Reviews, action state and endorsements stay in their
/// original histories; this catalog neither copies their text nor grants permission to send it.
public struct OutcomePriorResult:Codable,Sendable {
    public let attemptID:String
    public let producerSequence:Int64
    public let kind:String
    public let state:String
    public let contextID:String
    public let resultDigest:String?
    public let coveredTurnIDs:[String]
    public let claimIDs:[String]
    public let replyAttemptID:String?
    public let replyPartIndex:Int?
}
public struct ConversationOutcomeReusePlan:Codable,Sendable {
    public let conversationID:String
    public let conversationVersion:Int
    public let personalTargets:[ConversationTurnReference]
    public let priorResults:[OutcomePriorResult]
}
extension VoiceOSStore {
    /// Read-only output planning. Every source and AI reply remains in the full input snapshot.
    /// This is not an executable extraction grant; the durable shared-result journal is separate.
    public func conversationOutcomeReusePlan(for snapshot:ConversationOutcomeSnapshot) throws -> ConversationOutcomeReusePlan {
        try validateConversationOutcome(snapshot)
        guard try db.query("SELECT id FROM conversation_outcome_attempts WHERE conversation_id=?",[snapshot.input.conversationID]).isEmpty else { throw VoiceOSError("讨论已有成果尝试；请查看原回执，不重新规划发送") }
        return try Self.buildOutcomeReusePlan(db,snapshot:snapshot)
    }
    /// Re-read after await to detect another producer consuming a formerly available target.
    /// Existing review/action changes do not re-enable the original input or reset its identity.
    public func validateConversationOutcomeReusePlan(_ plan:ConversationOutcomeReusePlan,snapshot:ConversationOutcomeSnapshot) throws {
        let current=try conversationOutcomeReusePlan(for:snapshot)
        guard try Self.relevanceJSON(current) == Self.relevanceJSON(plan) else { throw VoiceOSError("讨论已有成果身份或新增目标已变化，请重新读取；不接纳旧计划") }
    }
    static func buildOutcomeReusePlan(_ db:Database,snapshot:ConversationOutcomeSnapshot,beforeSequence:Int64?=nil) throws -> ConversationOutcomeReusePlan {
        var prior:[OutcomePriorResult]=[],covered:Set<String>=[]
        // Conservative coverage matches the existing cross-entry barrier: any actual cognition
        // request using this exact personal version consumes it, even if its result is empty.
        let rows=try db.query("""
        SELECT DISTINCT m.* FROM conversation_user_turns t
        JOIN context_inputs original ON original.context_id=t.context_id
        JOIN context_inputs i ON i.source_id=t.source_id AND i.transcript_version_id=original.transcript_version_id
        JOIN model_attempts m ON m.context_id=i.context_id
        WHERE t.conversation_id=? AND m.execution_kind='model_request' AND (? IS NULL OR m.producer_sequence<?) ORDER BY m.producer_sequence
        """,[snapshot.input.conversationID,beforeSequence.map(String.init),beforeSequence.map(String.init)])
        for row in rows {
            guard ["completed","unknown","rejected"].contains(row["state"] ?? "") else { throw VoiceOSError("仍有个人理解在途，不准备跨入口成果") }
            let inputs=try db.query("SELECT source_id,transcript_version_id FROM context_inputs WHERE context_id=?",[row["context_id"]])
            let turns=snapshot.input.userTurns.filter { turn in inputs.contains { $0["source_id"] == turn.sourceID && $0["transcript_version_id"] == turn.transcriptVersionID } }.map(\.turnID)
            covered.formUnion(turns)
            let claims=try db.query("SELECT id FROM claims WHERE attempt_id=? ORDER BY ordinal",[row["id"]]).map { $0["id"]! }
            prior.append(OutcomePriorResult(attemptID:row["id"]!,producerSequence:Int64(row["producer_sequence"]!)!,kind:row["provider"]?.hasPrefix("discussion_outcome:") == true ? "discussion_outcome":"personal_understanding",state:row["state"]!,contextID:row["context_id"]!,resultDigest:row["result_digest"],coveredTurnIDs:turns,claimIDs:claims,replyAttemptID:nil,replyPartIndex:nil))
        }
        for row in try db.query("""
        SELECT d.*,m.id AS prior_attempt_id,m.producer_sequence,m.state AS model_state,m.context_id,m.result_digest AS model_digest
        FROM discussion_claim_derivations d JOIN discussion_attempts a ON a.id=d.discussion_attempt_id
        JOIN model_attempts m ON m.id=d.model_attempt_id WHERE a.conversation_id=? AND (? IS NULL OR m.producer_sequence<?) ORDER BY m.producer_sequence
        """,[snapshot.input.conversationID,beforeSequence.map(String.init),beforeSequence.map(String.init)]) {
            guard row["state"] == "completed",row["model_state"] == "completed",let claim=row["claim_id"],let index=row["part_index"].flatMap(Int.init) else { throw VoiceOSError("AI段落保留尚未完成，请先核对原复制回执") }
            prior.append(OutcomePriorResult(attemptID:row["prior_attempt_id"]!,producerSequence:Int64(row["producer_sequence"]!)!,kind:"ai_paragraph",state:"completed",contextID:row["context_id"]!,resultDigest:row["model_digest"],coveredTurnIDs:[],claimIDs:[claim],replyAttemptID:row["discussion_attempt_id"],replyPartIndex:index))
        }
        return ConversationOutcomeReusePlan(conversationID:snapshot.input.conversationID,conversationVersion:snapshot.input.conversationVersion,personalTargets:snapshot.input.userTurns.filter { !covered.contains($0.turnID) },priorResults:prior)
    }
    /// New user proposals must use unconsumed personal versions. AI may reinterpret the full
    /// discussion but an exact already-retained paragraph belongs to its existing candidate.
    public static func validateReusableConversationOutcomeProposals(_ proposals:[ConversationOutcomeProposal],snapshot:ConversationOutcomeSnapshot,plan:ConversationOutcomeReusePlan) throws {
        guard plan.conversationID == snapshot.input.conversationID,plan.conversationVersion == snapshot.input.conversationVersion,
              plan.personalTargets.allSatisfy({ snapshot.input.userTurns.contains($0) }) else { throw VoiceOSError("成果复用计划不属于当前输入") }
        try validateConversationOutcomeProposals(proposals,snapshot:snapshot)
        for proposal in proposals {
            if proposal.ownership == .userTentative {
                guard proposal.sourceEvidence.allSatisfy({ evidence in plan.personalTargets.contains { $0.sourceID == evidence.reference.sourceID && $0.transcriptVersionID == evidence.reference.transcriptVersionID } }) else { throw VoiceOSError("已整理个人版本只能关联原成果，不新增候选或任务") }
            }
            if proposal.ownership == .aiCandidate {
                for prior in plan.priorResults where prior.kind == "ai_paragraph" {
                    guard let reply=snapshot.replies.first(where: { $0.attemptID == prior.replyAttemptID }),let index=prior.replyPartIndex,reply.parts.indices.contains(index) else { throw VoiceOSError("既有AI候选不属于实际讨论段落") }
                    if proposal.statement == reply.parts[index].text,proposal.replyEvidence.contains(where: { $0.attemptID == reply.attemptID && $0.partIndex == index && $0.quote == reply.parts[index].text }) { throw VoiceOSError("完全相同AI段落已有候选，请关联原身份，不复制") }
                }
            }
        }
    }
}
