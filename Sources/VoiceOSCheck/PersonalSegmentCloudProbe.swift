import Foundation
import VoiceOSCore
import VoiceOSPlatform

/// Explicit development probe for an already transcribed personal source.
/// No microphone, media upload, reminders connector or automatic retry.
func runPersonalSegmentCloudProbe(_ args: [String]) async throws {
    guard [5,6,8].contains(args.count), args[4] == "--authorize-this-source-text", args.count==5 || ["--compact-extraction","--compact-segments"].contains(args[5]),
          args.count != 8 || args[6]=="--segment-budget" else {
        throw VoiceOSError("personal-segment-cloud requires isolated root, source ID, config and explicit text authorization")
    }
    let root=URL(fileURLWithPath:args[1]).standardizedFileURL.resolvingSymlinksInPath()
    let allowed=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("runtime").standardizedFileURL.resolvingSymlinksInPath()
    guard root.path.hasPrefix(allowed.path+"/"),FileManager.default.fileExists(atPath:root.appendingPathComponent("voiceos.sqlite").path) else {
        throw VoiceOSError("真实文字探针仅接受项目runtime内的已有独立资料库")
    }
    let budget=args.count==8 ? Int(args[7]) ?? 0 : 4000
    guard (1...4000).contains(budget) else { throw VoiceOSError("片段预算必须为1–4000") }
    let suite=try LocalTextModel.loadSuite(from:URL(fileURLWithPath:args[3]),compactSegmentExtraction:args.count>=6,compactSegmentAggregation:args.count>=6 && args[5]=="--compact-segments")
    let store=try VoiceOSStore(root:root,inspector:NativeMediaInspector());try await store.recover()
    guard let source=try await store.sources().first(where:{$0.id == args[2]}),source.origin == "user",source.speaker == "user",source.kind == "audio",
          let text=source.transcript,text.unicodeScalars.count>budget,text.unicodeScalars.count<=8000 else {
        throw VoiceOSError("探针只接受已明确归属本人、超过片段预算且不超过8000字符的音频逐字稿")
    }
    // The command flag is a new source-level text grant, never an upgrade of an
    // old processing request or its fixed local-only model identity.
    if source.localOnly {
        _=try await store.setSourceLocalOnly(sourceID:source.id,expectedVersion:source.policyVersion,localOnly:false,commandID:"personal-cloud-text:"+source.id)
    }
    let current=try await store.sources().first(where:{$0.id == source.id})!
    let command="personal-cloud-segment:"+source.id+":"+String(current.policyVersion)
    let prior=try await store.segmentedProcessingBatches().first(where:{$0.commandID == command})
    let batch:SegmentedProcessingBatch
    if let prior {
        guard prior.scope.plan.scalarBudget == budget else { throw VoiceOSError("既有探针不能改变片段预算；保留原请求") }
        try await store.validateSegmentedExpressionProcessingScope(prior.scope,extraction:suite.segmentExtraction.configuration,aggregation:suite.segmentAggregation.configuration)
        batch=prior
    }
    else {
        let scope=try await store.prepareSegmentedExpressionProcessingScope(sourceID:source.id,extraction:suite.segmentExtraction.configuration,aggregation:suite.segmentAggregation.configuration,segmentScalarBudget:budget)
        batch=try await store.enqueueSegmentedProcessingBatch(scope,commandID:command,extraction:suite.segmentExtraction.configuration,aggregation:suite.segmentAggregation.configuration)
    }
    let start=Date();var accepted=false
    do { accepted=try await store.processSegmentedCognition(batchID:batch.id,extraction:suite.segmentExtraction,aggregation:suite.segmentAggregation).claimIDs != nil }
    catch { /* Read durable sanitized receipts, not arbitrary transport errors. */ }
    let final=try await store.segmentedProcessingBatch(id:batch.id)
    let fragments=try await store.segmentExtractionAttempts(batchID:batch.id)
    let aggregate=try await store.segmentAggregationAttempt(batchID:batch.id)
    let report:[String:Any]=["source_id":source.id,"batch_id":batch.id,"policy_version":current.policyVersion,
        "transcription_backend":source.transcriptionBackend ?? "unknown",
        "extraction_prompt_version":batch.scope.extraction.promptVersion,
        "extraction_schema_version":batch.scope.extraction.schemaVersion,
        "aggregation_prompt_version":batch.scope.aggregation.promptVersion,
        "aggregation_schema_version":batch.scope.aggregation.schemaVersion,
        "planned_segment_scalars":batch.scope.plan.segments.map { $0.text.unicodeScalars.count },
        "evidence_scalar_budget":batch.scope.evidenceScalarBudget,
        "source_scalars":text.unicodeScalars.count,"segments":batch.scope.plan.segments.count,"cognition_saved":accepted,
        "parent_state":final.state.rawValue,"elapsed_seconds":Date().timeIntervalSince(start),
        "fragment_states":fragments.map{$0.state.rawValue},"fragment_errors":fragments.map{$0.error ?? ""},
        "fragment_usage":fragments.map{$0.usage ?? [:]},"aggregation_state":aggregate?.state.rawValue ?? "not_reserved",
        "parent_error":final.error ?? "","aggregation_usage":aggregate?.usage ?? [:],
        "claim_count":try await store.segmentedCognitiveClaimIDs(batchID:batch.id)?.count ?? 0,
        "integrity":try await store.integrityCheck(),"audio_uploaded":false,"microphone_calls":0,"external_task_writes":0,
        "billing_state":"unknown","natural_semantic_quality_reviewed":false]
    let data=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
    try data.write(to:root.appendingPathComponent("personal-segment-cloud-summary.json"),options:.atomic)
    print(String(decoding:data,as:UTF8.self))
}
