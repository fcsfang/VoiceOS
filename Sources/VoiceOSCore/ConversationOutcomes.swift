import Foundation

public struct ConversationOutcomeRequest:Sendable {
    public let attemptID:String
    public let snapshot:ConversationOutcomeSnapshot
    public let configuration:ModelConfiguration
}
public struct ConversationOutcomeResponse:Sendable {
    public let status:ModelResponse.Status
    public let proposals:[ConversationOutcomeProposal]
    public let inputTokens:Int?
    public let outputTokens:Int?
    public init(status:ModelResponse.Status,proposals:[ConversationOutcomeProposal],inputTokens:Int?=nil,outputTokens:Int?=nil) {
        self.status=status;self.proposals=proposals;self.inputTokens=inputTokens;self.outputTokens=outputTokens
    }
}
/// One direct, text-only request. No tools, implicit resend or external task effects.
public protocol ConversationOutcomePort:Sendable {
    var configuration:ModelConfiguration { get }
    func extract(_ request:ConversationOutcomeRequest) async throws -> ConversationOutcomeResponse
}
public struct ConversationOutcomeRecord:Identifiable,Sendable {
    public let id:String
    public let state:String
    public let validity:String
    public let proposals:[ConversationOutcomeProposal]
    public let claimIDs:[String]
    public let priorClaimIDs:[String]
    public let usage:[String:Int]?
}
public struct ConversationOutcomeOrigin:Sendable {
    public let claimID:String
    public let conversationID:String
    public let proposalIndex:Int
    public let referenceKind:String
}
extension VoiceOSStore {
    public func performConversationOutcome(_ snapshot:ConversationOutcomeSnapshot,using port:any ConversationOutcomePort) async throws -> [String] {
        try Task.checkCancellation();try validateConversationOutcome(snapshot)
        let config=port.configuration,input=snapshot.input
        guard snapshot.sessionState == "ended",config.destination == input.destination,!config.provider.isEmpty,!config.provider.hasPrefix("discussion_outcome:"),
              !["local_fixture","discussion_derivation"].contains(config.provider),!config.model.isEmpty,!config.promptVersion.isEmpty,!config.schemaVersion.isEmpty else { throw VoiceOSError("请明确结束讨论后整理；成果端口身份或目的地无效") }
        guard try db.query("SELECT id FROM conversation_outcome_attempts WHERE conversation_id=?",[input.conversationID]).isEmpty else { throw VoiceOSError("本段讨论已有成果提取记录；请查看结果，不会重发") }
        if let plan=snapshot.reusePlan { try validateOutcomeReuseState(plan,snapshot:snapshot) } else { try validateOutcomeDerivationIsolation(input.conversationID) }
        let id=UUID().uuidString,json=try Self.relevanceJSON(snapshot)
        try db.transaction {
            try db.execute("INSERT INTO model_attempts(id,context_id,provider,model,prompt_version,schema_version,state,created_at,producer_sequence) VALUES(?,?,?,?,?,?,'reserved',?,?)",[id,input.contextID,"discussion_outcome:"+config.provider,config.model,config.promptVersion,config.schemaVersion,Self.now(),try db.nextModelProducerSequence()])
            try db.execute("INSERT INTO conversation_outcome_attempts(id,conversation_id,conversation_version,snapshot_json,snapshot_digest,created_at) VALUES(?,?,?,?,?,?)",[id,input.conversationID,String(input.conversationVersion),json,Self.relevanceHash(Data(json.utf8)),Self.now()])
        }
        try checkpoint(.outcomeReserved)
        let response:ConversationOutcomeResponse
        do {
            try Task.checkCancellation();try validateConversationOutcome(snapshot)
            response=try await port.extract(ConversationOutcomeRequest(attemptID:id,snapshot:snapshot,configuration:config))
        } catch ModelPortFailure.rejected(_,let inputTokens,let outputTokens) {
            if (inputTokens ?? 0) >= 0,(outputTokens ?? 0) >= 0 { try recordOutcomeUsage(id,inputTokens,outputTokens) }
            try db.execute("UPDATE model_attempts SET state='rejected',error='成果响应未接纳；不自动重发' WHERE id=? AND state='reserved'",[id]);throw VoiceOSError("成果响应未接纳，已保存已知用量")
        } catch {
            try db.execute("UPDATE model_attempts SET state='unknown',error='成果结果未知；不自动重发' WHERE id=? AND state='reserved'",[id]);throw VoiceOSError("成果结果未知，不自动重发")
        }
        let claims:[String]
        do {
            try recordOutcomeUsage(id,response.inputTokens,response.outputTokens)
            try Task.checkCancellation();try validateConversationOutcome(snapshot)
            if let plan=snapshot.reusePlan { try validateOutcomeReuseState(plan,snapshot:snapshot,excludingAttemptID:id) } else { try validateOutcomeDerivationIsolation(input.conversationID,excludingAttemptID:id) }
            guard response.status == .completed else { throw VoiceOSError("成果响应未完成") }
            if let plan=snapshot.reusePlan { try Self.validateReusableConversationOutcomeProposals(response.proposals,snapshot:snapshot,plan:plan) } else { try Self.validateConversationOutcomeProposals(response.proposals,snapshot:snapshot) }
            let mapped=try Self.outcomeClaimProposals(response.proposals,snapshot:snapshot),result=try Self.relevanceJSON(response.proposals)
            _=try commitClaims(attemptID:id,proposals:mapped,additionalCommit:{ _ in
                try db.execute("UPDATE conversation_outcome_attempts SET result_json=?,result_digest=? WHERE id=?",[result,Self.relevanceHash(Data(result.utf8)),id])
                try checkpoint(.outcomeUncommitted)
            })
            claims=try db.query("SELECT id FROM claims WHERE attempt_id=? ORDER BY ordinal",[id]).map { $0["id"]! }
        } catch {
            if try db.query("SELECT state FROM model_attempts WHERE id=?",[id]).first?["state"] == "completed" {
                return try db.query("SELECT id FROM claims WHERE attempt_id=? ORDER BY ordinal",[id]).map { $0["id"]! }
            }
            try db.execute("UPDATE model_attempts SET state='rejected',error='成果依据、格式或提交未接纳' WHERE id=? AND state='reserved'",[id]);throw VoiceOSError("成果未接纳；没有新增候选或任务")
        }
        try checkpoint(.outcomeCommitted)
        return claims
    }
    public func conversationOutcomes(conversationID:String) throws -> [ConversationOutcomeRecord] {
        _=try conversation(id:conversationID)
        return try db.query("SELECT o.*,m.state,m.usage_json,c.state AS context_state FROM conversation_outcome_attempts o JOIN model_attempts m ON m.id=o.id JOIN contexts c ON c.id=m.context_id WHERE o.conversation_id=?",[conversationID]).map { row in
            ConversationOutcomeRecord(id:row["id"]!,state:row["state"]!,validity:row["context_state"] == "current" ? "current":"frozen",
                proposals:try row["result_json"].map { try JSONDecoder().decode([ConversationOutcomeProposal].self,from:Data($0.utf8)) } ?? [],
                claimIDs:try db.query("SELECT id FROM claims WHERE attempt_id=? ORDER BY ordinal",[row["id"]]).map { $0["id"]! },
                priorClaimIDs:try JSONDecoder().decode(ConversationOutcomeSnapshot.self,from:Data(row["snapshot_json"]!.utf8)).reusePlan?.priorResults.flatMap(\.claimIDs) ?? [],
                usage:try row["usage_json"].map { try JSONDecoder().decode([String:Int].self,from:Data($0.utf8)) })
        }
    }
    public func conversationOutcomeOrigins() throws -> [ConversationOutcomeOrigin] {
        guard ready else { throw VoiceOSError("资料库尚未恢复") }
        var result:[ConversationOutcomeOrigin]=[]
        for row in try db.query("SELECT o.* FROM conversation_outcome_attempts o JOIN model_attempts m ON m.id=o.id WHERE m.state='completed'") {
            let proposals=try JSONDecoder().decode([ConversationOutcomeProposal].self,from:Data(row["result_json"]!.utf8)),snapshot=try JSONDecoder().decode(ConversationOutcomeSnapshot.self,from:Data(row["snapshot_json"]!.utf8))
            let claims=try db.query("SELECT id,ordinal FROM claims WHERE attempt_id=? ORDER BY ordinal",[row["id"]])
            for claim in claims {
                guard let index=claim["ordinal"].flatMap(Int.init),proposals.indices.contains(index) else { throw VoiceOSError("成果候选位置不符") }
                let proposal=proposals[index]
                var hasReplyCitation=false
                for evidence in proposal.replyEvidence {
                    guard let reply=snapshot.replies.first(where: { $0.attemptID == evidence.attemptID }),reply.parts.indices.contains(evidence.partIndex) else { throw VoiceOSError("成果AI引用位置不符") }
                    hasReplyCitation = hasReplyCitation || !reply.parts[evidence.partIndex].references.isEmpty
                }
                let kind=proposal.sourceEvidence.isEmpty ? (hasReplyCitation ? "model_citation":"context_anchor") : (proposal.replyEvidence.isEmpty ? "source_citation":"mixed_citation")
                result.append(ConversationOutcomeOrigin(claimID:claim["id"]!,conversationID:row["conversation_id"]!,proposalIndex:index,referenceKind:kind))
            }
        }
        return result
    }
    /// First durable slice cannot merge already-retained standalone claim identities.
    /// Refuse before the request (and recheck after await) rather than duplicate or reset reviews.
    private func validateOutcomeDerivationIsolation(_ conversationID:String,excludingAttemptID:String?=nil) throws {
        guard try db.query("""
        SELECT m.id FROM conversation_user_turns t JOIN context_inputs original ON original.context_id=t.context_id
        JOIN context_inputs i ON i.source_id=t.source_id AND i.transcript_version_id=original.transcript_version_id
        JOIN model_attempts m ON m.context_id=i.context_id
        WHERE t.conversation_id=? AND m.execution_kind='model_request' AND (? IS NULL OR m.id!=?) LIMIT 1
        """,[conversationID,excludingAttemptID,excludingAttemptID]).isEmpty else { throw VoiceOSError("个人原话已有理解记录；当前整段提取尚未接入跨入口成果复用，请沿用已有候选与行动，不新增调用") }
        guard try db.query("SELECT d.id FROM discussion_claim_derivations d JOIN discussion_attempts a ON a.id=d.discussion_attempt_id WHERE a.conversation_id=?",[conversationID]).isEmpty else { throw VoiceOSError("本段已有独立AI候选；请沿用原候选与个人回合整理。整段提取的候选复用尚未接入，不新增调用") }
    }
    private func recordOutcomeUsage(_ id:String,_ input:Int?,_ output:Int?) throws {
        guard (input ?? 0) >= 0,(output ?? 0) >= 0 else { throw VoiceOSError("成果用量无效") }
        var usage:[String:Int]=[:];if let input { usage["input_tokens"]=input };if let output { usage["output_tokens"]=output }
        if !usage.isEmpty { try db.execute("UPDATE model_attempts SET usage_json=? WHERE id=?",[try Self.relevanceJSON(usage),id]) }
    }
    /// AI action proposals stay candidate metadata. Only personally sourced actions use the
    /// existing action table; AI quotes are not fabricated as user source quotes.
    static func outcomeClaimProposals(_ proposals:[ConversationOutcomeProposal],snapshot:ConversationOutcomeSnapshot) throws -> [ClaimProposal] {
        try proposals.map { proposal in
            var refs=proposal.sourceEvidence.map(\.reference)
            for evidence in proposal.replyEvidence {
                guard let reply=snapshot.replies.first(where: { $0.attemptID == evidence.attemptID }),reply.parts.indices.contains(evidence.partIndex) else { throw VoiceOSError("成果AI出处不存在") }
                refs += reply.parts[evidence.partIndex].references
            }
            if refs.isEmpty {
                guard let last=snapshot.input.userTurns.last,let source=snapshot.context.sources.first(where: { $0.sourceID == last.sourceID && $0.transcriptVersionID == last.transcriptVersionID }),let span=source.spans.first else { throw VoiceOSError("成果缺少讨论触发点") }
                refs=[ClaimReference(sourceID:source.sourceID,transcriptVersionID:source.transcriptVersionID,spanID:span.id)]
            }
            // A personal claim keeps personal evidence only; AI provenance remains in result_json.
            if proposal.ownership == .userTentative { refs=proposal.sourceEvidence.map(\.reference) }
            var seen:Set<String>=[]
            refs=refs.filter { seen.insert($0.sourceID+":"+$0.transcriptVersionID+":"+$0.spanID).inserted }
            return ClaimProposal(statement:proposal.statement,ownership:proposal.ownership,references:refs,action:proposal.ownership == .aiCandidate ? nil:proposal.action)
        }
    }
    func freezeConversationOutcomes() throws {
        for row in try db.query("SELECT o.snapshot_json,m.context_id FROM conversation_outcome_attempts o JOIN model_attempts m ON m.id=o.id ORDER BY m.producer_sequence") {
            let snapshot=try JSONDecoder().decode(ConversationOutcomeSnapshot.self,from:Data(row["snapshot_json"]!.utf8))
            if let plan=snapshot.reusePlan {
                for prior in plan.priorResults where try db.query("SELECT state FROM contexts WHERE id=?",[prior.contextID]).first?["state"] != "current" {
                    try db.execute("UPDATE contexts SET state='stale' WHERE id=?",[row["context_id"]])
                }
            }
        }
        try db.execute("UPDATE contexts SET state='stale' WHERE id IN (SELECT m.context_id FROM conversation_outcome_attempts o JOIN model_attempts m ON m.id=o.id JOIN conversations c ON c.id=o.conversation_id WHERE c.validity='frozen')")
        try db.execute("UPDATE claims SET validity='frozen' WHERE attempt_id IN (SELECT o.id FROM conversation_outcome_attempts o JOIN model_attempts m ON m.id=o.id JOIN contexts c ON c.id=m.context_id WHERE c.state='stale')")
        try db.execute("UPDATE actions SET validity='frozen' WHERE claim_id IN (SELECT c.id FROM claims c JOIN conversation_outcome_attempts o ON o.id=c.attempt_id WHERE c.validity='frozen')")
    }
    static func validateStoredConversationOutcomes(_ db:Database) throws {
        guard try db.query("SELECT m.id FROM model_attempts m LEFT JOIN conversation_outcome_attempts o ON o.id=m.id WHERE substr(m.provider,1,19)='discussion_outcome:' AND o.id IS NULL").isEmpty else { throw VoiceOSError("讨论成果请求缺少完整快照") }
        for row in try db.query("SELECT * FROM conversation_outcome_attempts") {
            guard let model=try db.query("SELECT * FROM model_attempts WHERE id=?",[row["id"]]).first,model["execution_kind"] == "model_request",model["provider"]?.hasPrefix("discussion_outcome:") == true,(model["provider"]?.count ?? 0) > 19,
                  !(model["model"] ?? "").isEmpty,!(model["prompt_version"] ?? "").isEmpty,!(model["schema_version"] ?? "").isEmpty,
                  let context=try db.query("SELECT * FROM contexts WHERE id=?",[model["context_id"]]).first,
                  let session=try db.query("SELECT * FROM conversations WHERE id=?",[row["conversation_id"]]).first,session["state"] == "ended",
                  let json=row["snapshot_json"],row["snapshot_digest"] == relevanceHash(Data(json.utf8)) else { throw VoiceOSError("讨论成果请求身份或摘要不符") }
            if let usageJSON=model["usage_json"] {
                let usage=try JSONDecoder().decode([String:Int].self,from:Data(usageJSON.utf8))
                guard !usage.isEmpty,Set(usage.keys).isSubset(of:["input_tokens","output_tokens"]),usage.values.allSatisfy({ $0 >= 0 }) else { throw VoiceOSError("成果用量格式不符") }
            }
            let snapshot=try JSONDecoder().decode(ConversationOutcomeSnapshot.self,from:Data(json.utf8)),input=snapshot.input
            guard snapshot.sessionState == "ended",input.conversationID == row["conversation_id"],String(input.conversationVersion) == row["conversation_version"],session["version"] == row["conversation_version"],
                  input.contextID == model["context_id"],input.destination.rawValue == context["destination"],context["snapshot_json"] == (try relevanceJSON(snapshot.context)),
                  session["validity"] != "frozen" || context["state"] == "stale",
                  input.destination != .cloud || snapshot.context.sources.allSatisfy({ !$0.localOnly }) else { throw VoiceOSError("成果范围、目的地或冻结状态不符") }
            let turns=try db.query("SELECT * FROM conversation_user_turns WHERE conversation_id=? ORDER BY ordinal",[input.conversationID])
            let expectedTurns=try turns.map { turn -> ConversationTurnReference in
                guard let c=try db.query("SELECT snapshot_json FROM contexts WHERE id=?",[turn["context_id"]]).first?["snapshot_json"] else { throw VoiceOSError("成果个人回合缺少出处") }
                let source=try JSONDecoder().decode(LocalTranscriptContext.self,from:Data(c.utf8)).sources[0]
                return ConversationTurnReference(turnID:turn["id"]!,sourceID:source.sourceID,transcriptVersionID:source.transcriptVersionID)
            }
            guard !expectedTurns.isEmpty,input.userTurns == expectedTurns,
                  let entry=try db.query("SELECT snapshot_json FROM contexts WHERE id=?",[session["entry_context_id"]]).first?["snapshot_json"] else { throw VoiceOSError("成果个人回合目录缺少历史") }
            let history=try JSONDecoder().decode(LocalTranscriptContext.self,from:Data(entry.utf8)).sources
            var ids=history.map(\.sourceID)
            for turn in expectedTurns where !ids.contains(turn.sourceID) { ids.append(turn.sourceID) }
            guard input.historySourceIDs == history.map(\.sourceID),snapshot.context.sources.map(\.sourceID) == ids else { throw VoiceOSError("成果遗漏或混入实际来源") }
            for source in snapshot.context.sources {
                let original:ContextTranscript
                if let old=history.first(where: { $0.sourceID == source.sourceID }) { original=old }
                else {
                    guard let turn=turns.first(where: { $0["source_id"] == source.sourceID }),let c=try db.query("SELECT snapshot_json FROM contexts WHERE id=?",[turn["context_id"]]).first?["snapshot_json"] else { throw VoiceOSError("成果来源没有对应回合") }
                    original=try JSONDecoder().decode(LocalTranscriptContext.self,from:Data(c.utf8)).sources[0]
                }
                guard try relevanceJSON(original) == relevanceJSON(source) else { throw VoiceOSError("成果实际原文或身份不符") }
            }
            let replies=try db.query("SELECT a.* FROM discussion_attempts a JOIN conversation_user_turns t ON t.id=a.reply_to_turn_id WHERE a.conversation_id=? ORDER BY t.ordinal",[input.conversationID])
            guard replies.count == snapshot.replies.count else { throw VoiceOSError("成果遗漏最后AI或失败回执") }
            for (index,reply) in replies.enumerated() {
                let saved=snapshot.replies[index]
                guard reply["state"] != "reserved",["current","frozen"].contains(saved.validity),saved.state != "completed" || saved.validity == "current",saved.attemptID == reply["id"],saved.replyToTurnID == reply["reply_to_turn_id"],saved.state == reply["state"],saved.digest == reply["result_digest"],
                      try relevanceJSON(saved.parts) == relevanceJSON(discussionParts(reply)) else { throw VoiceOSError("成果AI目录、段落或调用状态不符") }
            }
            try validateOutcomeBudget(snapshot.context,snapshot.replies)
            if let plan=snapshot.reusePlan {
                guard let sequence=model["producer_sequence"].flatMap(Int64.init),
                      try relevanceJSON(buildOutcomeReusePlan(db,snapshot:snapshot,beforeSequence:sequence)) == relevanceJSON(plan) else { throw VoiceOSError("成果提取前的原身份目录或可新增目标不符") }
                for prior in plan.priorResults {
                    if try db.query("SELECT state FROM contexts WHERE id=?",[prior.contextID]).first?["state"] != "current",context["state"] != "stale" { throw VoiceOSError("原成果已冻结，共享成果不能继续执行") }
                }
            }
            let claims=try db.query("SELECT * FROM claims WHERE attempt_id=? ORDER BY ordinal",[model["id"]])
            if model["state"] == "completed" {
                guard let result=row["result_json"],row["result_digest"] == relevanceHash(Data(result.utf8)) else { throw VoiceOSError("成果结果缺少完整出处") }
                let proposals=try JSONDecoder().decode([ConversationOutcomeProposal].self,from:Data(result.utf8))
                if let plan=snapshot.reusePlan { try validateReusableConversationOutcomeProposals(proposals,snapshot:snapshot,plan:plan) } else { try validateConversationOutcomeProposals(proposals,snapshot:snapshot) }
                let mapped=try outcomeClaimProposals(proposals,snapshot:snapshot)
                guard claims.count == mapped.count,model["result_digest"] == relevanceHash(Data(try relevanceJSON(mapped).utf8)) else { throw VoiceOSError("成果候选与原子提交不符") }
                for (index,claim) in claims.enumerated() {
                    guard claim["ordinal"] == String(index),claim["statement"] == mapped[index].statement,claim["ownership"] == mapped[index].ownership.rawValue,
                          claim["refs_json"] == (try relevanceJSON(mapped[index].references)),claim["action_json"] == (try mapped[index].action.map { try relevanceJSON($0) }),
                          context["state"] != "stale" || claim["validity"] == "frozen" else { throw VoiceOSError("成果候选身份、出处或动作不符") }
                }
            } else {
                guard ["reserved","unknown","rejected"].contains(model["state"] ?? ""),row["result_json"] == nil,row["result_digest"] == nil,claims.isEmpty,model["result_digest"] == nil else { throw VoiceOSError("未完成成果不能带已提交候选") }
            }
        }
    }
}
