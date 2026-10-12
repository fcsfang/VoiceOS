import Foundation

extension VoiceOSStore {
    static func recordingSegmentIdentities(cognition: ProcessingModelIdentity, extraction: ModelConfiguration?, aggregation: ModelConfiguration?) throws -> (String,String)? {
        guard extraction != nil || aggregation != nil else { return nil }
        guard let extraction,let aggregation else { throw VoiceOSError("录制分段端口必须成对固定") }
        let e=ProcessingModelIdentity(extraction),a=ProcessingModelIdentity(aggregation)
        guard e.isValid,a.isValid,[e,a].allSatisfy({ $0.provider == cognition.provider && $0.model == cognition.model && $0.destination == cognition.destination }) else {
            throw VoiceOSError("录制分段端口不能改变已选模型服务或目的地")
        }
        return (try relevanceJSON(e),try relevanceJSON(a))
    }
    func reconcileLongRecordingRequest(_ request: [String:String],current: SourceRecord,
        extraction: ModelConfiguration?,aggregation: ModelConfiguration?) throws {
        guard let id=request["id"],let plan=try db.query("SELECT * FROM recording_segment_plans WHERE id=?",[id]).first,
              let extraction,let aggregation,
              plan["extraction_json"] == (try Self.relevanceJSON(ProcessingModelIdentity(extraction))),
              plan["aggregation_json"] == (try Self.relevanceJSON(ProcessingModelIdentity(aggregation))) else {
            throw VoiceOSError("长逐字稿缺少录制前固定的分段端口或配置已变；请另行明确处理")
        }
        let scope=try prepareSegmentedExpressionProcessingScope(sourceID:current.id,extraction:extraction,aggregation:aggregation)
        let batch=try enqueueSegmentedProcessingBatch(scope,commandID:"record-segment:"+id,extraction:extraction,aggregation:aggregation)
        // A crash between enqueue and linking reuses the same command, never a second batch.
        try checkpoint(.recordingRequestQueueCommitted)
        try db.transaction {
            try db.execute("UPDATE recording_segment_plans SET batch_id=? WHERE id=?",[batch.id,id])
            try setRecordingRequest(id,state:"enqueued")
        }
    }
    public func processRecordingSegmentPlan(requestID: String,extraction: any SegmentExtractionPort,aggregation: any SegmentAggregationPort,
        retrieval: any LocalRetrievalPort,semantic: Bool = false,association: (any ExpressionAssociationPort)?) async throws {
        guard let row=try db.query("SELECT p.*,r.state,r.association_json FROM recording_segment_plans p JOIN recording_processing_requests r ON r.id=p.id WHERE p.id=?",[requestID]).first,
              row["state"] == "enqueued",row["association_state"] == nil,let batchID=row["batch_id"] else { return }
        guard row["extraction_json"] == (try Self.relevanceJSON(ProcessingModelIdentity(extraction.configuration))),
              row["aggregation_json"] == (try Self.relevanceJSON(ProcessingModelIdentity(aggregation.configuration))) else { throw VoiceOSError("录制分段配置已变化，未发送") }
        if let association {
            guard row["association_json"] == (try Self.relevanceJSON(ProcessingModelIdentity(association.configuration))) else { throw VoiceOSError("录制关联配置已变化，未发送") }
        }
        let cognition=try await processSegmentedCognition(batchID:batchID,extraction:extraction,aggregation:aggregation)
        guard cognition.claimIDs != nil else { return }
        let result=try await processCommittedSegmentedAssociation(batchID:batchID,retrieval:retrieval,semantic:semantic,model:association)
        try db.execute("UPDATE recording_segment_plans SET association_state=? WHERE id=? AND association_state IS NULL",[String(describing:result.state),requestID])
    }
    static func validateStoredRecordingSegmentPlans(_ db: Database) throws {
        for row in try db.query("SELECT p.*,r.cognition_json,r.source_id,r.source_version_id,r.policy_version,r.processing_intent_id FROM recording_segment_plans p JOIN recording_processing_requests r ON r.id=p.id") {
            let c=try JSONDecoder().decode(ProcessingModelIdentity.self,from:Data(row["cognition_json"]!.utf8)),
                e=try JSONDecoder().decode(ProcessingModelIdentity.self,from:Data(row["extraction_json"]!.utf8)),
                a=try JSONDecoder().decode(ProcessingModelIdentity.self,from:Data(row["aggregation_json"]!.utf8))
            guard try recordingSegmentIdentities(cognition:c,extraction:processingIdentity(e),aggregation:processingIdentity(a)) != nil else { throw VoiceOSError("录制分段端口历史无效") }
            if let state=row["association_state"] {
                guard ["paused","localOnly","modelUnavailable","budgetExceeded","noCandidates","inFlight","completed","unknown","cancelled"].contains(state),row["batch_id"] != nil else { throw VoiceOSError("录制长关联阶段无效") }
            }
            if let batchID=row["batch_id"] {
                guard row["processing_intent_id"] == nil,let parent=try db.query("SELECT * FROM segmented_processing_batches WHERE id=?",[batchID]).first else { throw VoiceOSError("录制分段批次缺失或与普通队列冲突") }
                try validateStoredSegmentedBatch(db,row:parent)
                let b=try segmentedBatchRecord(parent),s=b.scope.plan.source
                guard b.commandID == "record-segment:"+row["id"]!,s.sourceID == row["source_id"],s.sourceVersionID == row["source_version_id"],
                      b.scope.plan.policyVersion == Int(row["policy_version"]!),b.scope.extraction == e,b.scope.aggregation == a,
                      let original=try db.query("SELECT version_no FROM transcript_versions WHERE id=?",[s.transcriptVersionID]).first,
                      original["version_no"] == "1" else { throw VoiceOSError("录制长文字与预先授权范围不一致") }
                if let state=row["association_state"],state != "cancelled" {
                    guard try !db.query("SELECT id FROM segmented_cognitive_commits WHERE batch_id=?",[batchID]).isEmpty else { throw VoiceOSError("录制关联阶段缺少整篇认知提交") }
                    if ["completed","unknown","inFlight"].contains(state) {
                        let matching=try db.query("SELECT state,snapshot_json FROM expression_association_attempts WHERE current_source_id=?",[s.sourceID]).filter {
                            let snapshot=try JSONDecoder().decode(ExpressionAssociationSnapshot.self,from:Data($0["snapshot_json"]!.utf8))
                            return snapshot.policyVersion == b.scope.plan.policyVersion && snapshot.current.sources.first?.transcriptVersionID == s.transcriptVersionID
                        }
                        guard matching.contains(where:{ state == "inFlight" || $0["state"] == state }) else { throw VoiceOSError("录制关联阶段没有对应尝试回执") }
                    }
                }
            }
        }
    }
}
