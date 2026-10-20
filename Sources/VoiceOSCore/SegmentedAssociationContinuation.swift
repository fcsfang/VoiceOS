import Foundation

extension VoiceOSStore {
    /// Reuse the existing complete-source association pipeline only after the
    /// exact segmented cognition is committed and its source/policy remain current.
    public func processCommittedSegmentedAssociation(batchID: String, retrieval: any LocalRetrievalPort,
        semantic: Bool = false, model: (any ExpressionAssociationPort)?) async throws -> ExpressionAssociationProcessing {
        try Task.checkCancellation()
        guard ready,try segmentedCognitiveClaimIDs(batchID:batchID) != nil,
              let commit=try db.query("SELECT model_attempt_id FROM segmented_cognitive_commits WHERE batch_id=?",[batchID]).first,
              let producer=try db.query("SELECT context_id FROM model_attempts WHERE id=?",[commit["model_attempt_id"]]).first else {
            throw VoiceOSError("整篇认知尚未提交，不能启动长表达关联")
        }
        let batch=try checkSegmentedProcessingBatch(id:batchID,extraction:Self.processingIdentity(try segmentedProcessingBatch(id:batchID).scope.extraction),
            aggregation:Self.processingIdentity(try segmentedProcessingBatch(id:batchID).scope.aggregation))
        guard batch.state == .queued else { throw VoiceOSError("分段批次已停止、失效或冻结，未启动关联") }
        _ = try localContext(id:producer["context_id"]!)
        if let model {
            guard model.configuration.provider == batch.scope.aggregation.provider,model.configuration.model == batch.scope.aggregation.model,
                  model.configuration.destination == batch.scope.aggregation.destination else { throw VoiceOSError("关联模型服务或目的地与本批次不符，未发送") }
        }
        // Existing receipts are reused by source/version/policy, including unknown.
        // Its existing 8000-scalar whole-source budget is not silently enlarged.
        return try await processExpressionAssociation(sourceID:batch.scope.plan.source.sourceID,retrieval:SegmentedGuardedRetrieval(store:self,batchID:batchID,base:retrieval),semantic:semantic,model:model.map { SegmentedGuardedAssociation(store:self,batchID:batchID,base:$0) })
    }
    func ensureSegmentedAssociationCurrent(_ batchID: String) throws {
        let batch=try segmentedProcessingBatch(id:batchID)
        guard batch.state == .queued else { throw VoiceOSError("分段处理已停止，未继续关联") }
        try validateSegmentedExpressionProcessingScope(batch.scope,extraction:Self.processingIdentity(batch.scope.extraction),aggregation:Self.processingIdentity(batch.scope.aggregation))
    }
    func freezeReservedSegmentedAssociation(_ batch: SegmentedProcessingBatch) throws {
        for row in try db.query("SELECT id,snapshot_json FROM expression_association_attempts WHERE current_source_id=? AND state='reserved'",[batch.scope.plan.source.sourceID]) {
            let snapshot=try JSONDecoder().decode(ExpressionAssociationSnapshot.self,from:Data(row["snapshot_json"]!.utf8))
            if snapshot.policyVersion == batch.scope.plan.policyVersion,snapshot.current.sources.first?.transcriptVersionID == batch.scope.plan.source.transcriptVersionID {
                try db.execute("UPDATE expression_association_attempts SET validity='frozen' WHERE id=?",[row["id"]])
            }
        }
    }
    public func committedSegmentedAssociationAttempt(batchID: String) throws -> ExpressionAssociationAttempt? {
        guard try segmentedCognitiveClaimIDs(batchID:batchID) != nil else { return nil }
        let batch=try segmentedProcessingBatch(id:batchID)
        return try expressionAssociationAttempts().first {
            $0.currentSourceID == batch.scope.plan.source.sourceID && $0.snapshot.policyVersion == batch.scope.plan.policyVersion &&
            $0.snapshot.current.sources.first?.transcriptVersionID == batch.scope.plan.source.transcriptVersionID
        }
    }
}

private struct SegmentedGuardedRetrieval: LocalRetrievalPort {
    let store: VoiceOSStore
    let batchID: String
    let base: any LocalRetrievalPort
    var semanticWindow: RetrievalWindow { base.semanticWindow }
    func rank(query: String,documents: [RetrievalDocument],semantic: Bool) async throws -> [RetrievalMatch] {
        try await store.ensureSegmentedAssociationCurrent(batchID)
        let result=try await base.rank(query:query,documents:documents,semantic:semantic)
        try await store.ensureSegmentedAssociationCurrent(batchID)
        return result
    }
}
private struct SegmentedGuardedAssociation: ExpressionAssociationPort {
    let store: VoiceOSStore
    let batchID: String
    let base: any ExpressionAssociationPort
    var configuration: ModelConfiguration { base.configuration }
    func associate(_ request: ExpressionAssociationRequest) async throws -> ExpressionAssociationResponse {
        try await store.ensureSegmentedAssociationCurrent(batchID)
        let response=try await base.associate(request)
        do { try await store.ensureSegmentedAssociationCurrent(batchID) }
        catch { throw ModelPortFailure.rejected("分段处理已停止或来源已变化；保留已知用量",inputTokens:response.inputTokens,outputTokens:response.outputTokens) }
        return response
    }
}
