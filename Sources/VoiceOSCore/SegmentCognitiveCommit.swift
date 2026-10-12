import Foundation

/// Final cognitive proposal anchored to the complete ledger, not model summary text.
public struct SegmentFinalClaim: Codable, Sendable {
    public let statement: String
    public let ownership: CandidateOwnership
    public let contentKind: CognitiveContentKind?
    public let evidenceIDs: [String]
    public let actionEvidenceID: String?
    public let action: ExtractedAction?
    public init(statement: String, ownership: CandidateOwnership = .userTentative, contentKind: CognitiveContentKind? = .statement,
                evidenceIDs: [String], actionEvidenceID: String? = nil, action: ExtractedAction? = nil) {
        self.statement=statement; self.ownership=ownership; self.contentKind=contentKind
        self.evidenceIDs=evidenceIDs; self.actionEvidenceID=actionEvidenceID; self.action=action
    }
}
extension VoiceOSStore {
    static func segmentedCommitContext(_ batch: SegmentedProcessingBatch) throws -> LocalTranscriptContext {
        let sources=[batch.scope.plan.source]
        // A local provenance snapshot only. It is never sent as a whole model input.
        return .init(sources:sources,scalarBudget:max(1,sources[0].text.unicodeScalars.count),contentDigest:try segmentValueDigest(sources))
    }
    static func segmentFinalProposals(_ response: SegmentAggregationResponse, batch: SegmentedProcessingBatch,
                                      ledger: SegmentedEvidenceLedger) throws -> [ClaimProposal] {
        _ = try validateSegmentAggregationReview(response.review,ledger:ledger)
        guard let final=response.finalClaims else { throw VoiceOSError("旧聚合仅有判断，缺少最终认知提案；未自动补发") }
        let evidence=Dictionary(uniqueKeysWithValues:ledger.evidence.map { ($0.id,$0) })
        let decisions=Dictionary(uniqueKeysWithValues:response.review.actionDecisions.map { ($0.evidenceID,$0) })
        let source=batch.scope.plan.source
        var handled: Set<String>=[], proposals: [ClaimProposal]=[]
        for claim in final {
            var claimEvidenceIDs = claim.evidenceIDs
            if let actionID = claim.actionEvidenceID, let decision = decisions[actionID] {
                // Keep an action's supporting provenance inside the committed
                // claim when the model omitted one of those IDs from
                // evidenceIDs. Added IDs still come only from the immutable
                // ledger; no evidence is synthesized locally.
                for id in decision.supportingEvidenceIDs where !claimEvidenceIDs.contains(id) { claimEvidenceIDs.append(id) }
            }
            guard !claimEvidenceIDs.isEmpty, Set(claimEvidenceIDs).count == claimEvidenceIDs.count,
                  claimEvidenceIDs.allSatisfy({ evidence[$0] != nil }) else { throw VoiceOSError("最终认知缺少有效原话证据或重复引用") }
            let spanIDs=Set(claimEvidenceIDs.flatMap { evidence[$0]!.references.map(\.spanID) })
            let refs=source.spans.filter { spanIDs.contains($0.id) }.map { ClaimReference(sourceID:source.sourceID,transcriptVersionID:source.transcriptVersionID,spanID:$0.id) }
            if let action=claim.action {
                guard let id=claim.actionEvidenceID,claimEvidenceIDs.contains(id),handled.insert(id).inserted,
                      let decision=decisions[id],let original=evidence[id],original.proposal.kind == .possibleAction,
                      [.accept,.ambiguous].contains(decision.disposition),
                      decision.supportingEvidenceIDs.allSatisfy({ claimEvidenceIDs.contains($0) }),
                      original.proposal.quote.contains(action.quote), !action.quote.isEmpty,
                      action.kind != .aiSuggestion,
                      decision.disposition != .ambiguous || (action.kind == .opportunity && !action.autoSend) else {
                    throw VoiceOSError("最终行动与整篇判断或原话不一致，不能释放拒绝、重复或模糊任务")
                }
            } else if claim.actionEvidenceID != nil { throw VoiceOSError("行动身份缺少最终行动") }
            // A user transcript can quote an external person, but it is still
            // a user-owned source. Preserve the claim while refusing to treat
            // it as an externally sourced fact; unresolved is the safe local
            // projection until an external source is linked.
            let ownership: CandidateOwnership
            if claim.ownership == .external && source.origin == "user" {
                ownership = .unresolved
            } else if claim.ownership == .unresolved, let action = claim.action,
                      action.kind == .opportunity, !action.autoSend, source.origin == "user" {
                // An explicitly user-spoken "record this" opportunity can be
                // retained as a non-executable user task candidate even when
                // the model marked its ownership unresolved.
                ownership = .userTentative
            } else {
                ownership = claim.ownership
            }
            proposals.append(.init(statement:claim.statement,ownership:ownership,references:refs,action:claim.action,contentKind:claim.contentKind))
        }
        let retained=Set(response.review.actionDecisions.filter { [.accept,.ambiguous].contains($0.disposition) }.map(\.evidenceID))
        guard handled == retained else { throw VoiceOSError("最终提案必须恰好覆盖全部保留或待明确行动") }
        let context=try segmentedCommitContext(batch)
        guard context.scalarBudget<=12000 || !proposals.contains(where:{ $0.contentKind == .question }) else {
            throw VoiceOSError("超出当前问题上下文预算；完整结果保留，未丢弃问题或部分提交")
        }
        try validateProposals(proposals,context:context)
        return proposals
    }
    /// Single atomic local projection. Model receipt and billing remain in the
    /// aggregation table; the derived producer is not another model invocation.
    public func commitSegmentedCognition(batchID: String, extraction: ModelConfiguration,
                                         aggregation: ModelConfiguration) throws -> [String] {
        guard ready else { throw VoiceOSError("资料库尚未准备好") }
        if let prior=try db.query("SELECT * FROM segmented_cognitive_commits WHERE batch_id=?",[batchID]).first {
            try Self.validateStoredSegmentCognitiveCommits(db)
            return try db.query("SELECT id FROM claims WHERE attempt_id=? ORDER BY id",[prior["model_attempt_id"]]).map { $0["id"]! }
        }
        let batch=try checkSegmentedProcessingBatch(id:batchID,extraction:extraction,aggregation:aggregation)
        guard batch.state == .queued,let attempt=try segmentAggregationAttempt(batchID:batchID),
              attempt.state == .completed,attempt.validity == "current",let response=attempt.response else {
            throw VoiceOSError("整篇聚合尚未有效完成，不能提交认知")
        }
        let ledger=try preparePersistedSegmentedEvidenceLedger(batchID:batchID,extraction:extraction,aggregation:aggregation)
        let proposals=try Self.segmentFinalProposals(response,batch:batch,ledger:ledger)
        let context=try Self.segmentedCommitContext(batch), contextID=UUID().uuidString, modelID=UUID().uuidString, now=Self.processingNow()
        let ids=try db.transaction {
            try db.execute("INSERT INTO contexts(id,command_id,snapshot_json,digest,state,created_at,destination) VALUES(?,?,?,?,'current',?,'local')",
                [contextID,"segmented-commit:"+attempt.id,try Self.relevanceJSON(context),context.contentDigest,now])
            let source=batch.scope.plan.source
            try db.execute("INSERT INTO context_inputs(id,context_id,source_id,transcript_version_id,policy_version) VALUES(?,?,?,?,?)",
                [UUID().uuidString,contextID,source.sourceID,source.transcriptVersionID,String(batch.scope.plan.policyVersion)])
            try db.execute("INSERT INTO model_attempts(id,context_id,provider,model,prompt_version,schema_version,state,execution_kind,created_at,producer_sequence) VALUES(?,?,'segmented_derivation','whole-source-projection-v1','not_applicable','final-claims-v1','reserved','segmented_derivation',?,?)",
                [modelID,contextID,now,try db.nextModelProducerSequence()])
            try db.execute("INSERT INTO segmented_cognitive_commits(id,batch_id,model_attempt_id,proposals_json,proposals_digest,created_at) VALUES(?,?,?,?,?,?)",
                [attempt.id,batchID,modelID,try Self.relevanceJSON(proposals),try Self.segmentValueDigest(proposals),now])
            return try insertValidatedClaims(attemptID:modelID,proposals:proposals)
        }
        try checkpoint(.claimsCommitted)
        // Parent remains awaiting association; completion here is cognitive only.
        return ids
    }
    public func segmentedCognitiveClaimIDs(batchID: String) throws -> [String]? {
        try Self.validateStoredSegmentCognitiveCommits(db)
        guard let row=try db.query("SELECT model_attempt_id FROM segmented_cognitive_commits WHERE batch_id=?",[batchID]).first else { return nil }
        return try db.query("SELECT id FROM claims WHERE attempt_id=? ORDER BY id",[row["model_attempt_id"]]).map { $0["id"]! }
    }
    static func validateStoredSegmentCognitiveCommits(_ db: Database) throws {
        guard try db.query("SELECT m.id FROM model_attempts m LEFT JOIN segmented_cognitive_commits c ON c.model_attempt_id=m.id WHERE (m.execution_kind='segmented_derivation' AND c.id IS NULL) OR (m.provider='segmented_derivation' AND m.execution_kind!='segmented_derivation')").isEmpty else { throw VoiceOSError("整篇认知派生缺少聚合回执或冒充模型调用") }
        for row in try db.query("SELECT * FROM segmented_cognitive_commits") {
            guard let aggregate=try db.query("SELECT * FROM segmented_aggregation_attempts WHERE id=? AND batch_id=?",[row["id"],row["batch_id"]]).first,
                  let parent=try db.query("SELECT * FROM segmented_processing_batches WHERE id=?",[row["batch_id"]]).first,
                  let model=try db.query("SELECT * FROM model_attempts WHERE id=?",[row["model_attempt_id"]]).first,
                  let context=try db.query("SELECT * FROM contexts WHERE id=?",[model["context_id"]]).first else { throw VoiceOSError("整篇认知提交缺少原始生产者") }
            let batch=try segmentedBatchRecord(parent), attempt=try aggregationAttempt(aggregate)
            guard attempt.state == .completed,let response=attempt.response,
                  model["execution_kind"] == "segmented_derivation",model["provider"] == "segmented_derivation",
                  model["model"] == "whole-source-projection-v1",model["prompt_version"] == "not_applicable",model["schema_version"] == "final-claims-v1",
                  model["state"] == "completed",model["usage_json"] == nil,
                  let seq=model["producer_sequence"].flatMap(Int64.init),let aggregateSeq=aggregate["producer_sequence"].flatMap(Int64.init),seq>aggregateSeq,
                  context["destination"] == "local",context["command_id"] == "segmented-commit:"+attempt.id,
                  context["snapshot_json"] == (try relevanceJSON(segmentedCommitContext(batch))) else { throw VoiceOSError("整篇认知生产者身份、顺序或原文不一致") }
            let proposals=try segmentFinalProposals(response,batch:batch,ledger:attempt.request.ledger)
            let stored=try db.query("SELECT * FROM claims WHERE attempt_id=? ORDER BY ordinal",[model["id"]]).enumerated().map { index, claim -> ClaimProposal in
                guard claim["ordinal"] == String(index),let owner=CandidateOwnership(rawValue:claim["ownership"] ?? "") else { throw VoiceOSError("整篇认知候选身份或顺序无效") }
                return .init(statement:claim["statement"]!,ownership:owner,
                    references:try JSONDecoder().decode([ClaimReference].self,from:Data(claim["refs_json"]!.utf8)),
                    action:try claim["action_json"].map { try JSONDecoder().decode(ExtractedAction.self,from:Data($0.utf8)) },contentKind:claim["content_kind"].flatMap(CognitiveContentKind.init(rawValue:)))
            }
            guard try relevanceJSON(stored) == relevanceJSON(proposals) else { throw VoiceOSError("整篇认知候选与聚合原提案不一致") }
            guard row["proposals_json"] == (try relevanceJSON(proposals)),row["proposals_digest"] == (try segmentValueDigest(proposals)),
                  model["result_digest"] == (try segmentValueDigest(proposals)),
                  let input=try db.query("SELECT * FROM context_inputs WHERE context_id=? AND source_id=?",[model["context_id"],batch.scope.plan.source.sourceID]).first,
                  input["policy_version"] == String(batch.scope.plan.policyVersion), input["transcript_version_id"] == batch.scope.plan.source.transcriptVersionID else { throw VoiceOSError("整篇认知提交摘要或历史授权不一致") }
        }
    }
}
