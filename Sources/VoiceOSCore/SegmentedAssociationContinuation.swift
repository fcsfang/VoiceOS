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
        return try await processExpressionAssociation(sourceID:batch.scope.plan.source.sourceID,retrieval:retrieval,semantic:semantic,model:model)
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
