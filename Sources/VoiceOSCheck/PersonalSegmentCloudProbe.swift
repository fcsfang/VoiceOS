import Foundation
import VoiceOSCore
import VoiceOSPlatform

/// Explicit development probe for an already transcribed personal source.
/// No microphone, media upload, reminders connector or automatic retry.
func runPersonalSegmentCloudProbe(_ args: [String]) async throws {
    guard [5,6,8].contains(args.count), args[4] == "--authorize-this-source-text", args.count==5 || ["--compact-extraction","--compact-segments","--stream-segments","--stream-segments-v4","--compact-stream-segments","--compact-stream-v4","--compact-stream-v4-2400","--compact-stream-v4-4000","--compact-stream-v4-4000-strict","--compact-stream-v4-4000-strict-r2","--compact-stream-v4-4000-strict-r3","--compact-stream-v4-4000-strict-r4","--compact-stream-v4-4000-strict-r5","--compact-stream-v4-4000-strict-r6","--compact-stream-v4-4000-strict-r7","--compact-stream-v4-4000-strict-r8","--stream-extended","--stream-extended-v2","--stream-extended-1800","--compact-stream-1800","--compact-stream-1800-v2","--compact-stream-1800-v3","--compact-stream-2400","--compact-stream-2400-v2"].contains(args[5]),
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
    let compact=args.count>=6 && ["--compact-extraction","--compact-segments","--compact-stream-segments","--compact-stream-v4","--compact-stream-v4-2400","--compact-stream-v4-4000","--compact-stream-v4-4000-strict","--compact-stream-v4-4000-strict-r2","--compact-stream-v4-4000-strict-r3","--compact-stream-v4-4000-strict-r4","--compact-stream-v4-4000-strict-r5","--compact-stream-v4-4000-strict-r6","--compact-stream-v4-4000-strict-r7","--compact-stream-v4-4000-strict-r8","--compact-stream-1800","--compact-stream-1800-v2","--compact-stream-1800-v3","--compact-stream-2400","--compact-stream-2400-v2"].contains(args[5])
    let streaming=args.count>=6 && ["--stream-segments","--stream-segments-v4","--compact-stream-segments","--compact-stream-v4","--compact-stream-v4-2400","--compact-stream-v4-4000","--compact-stream-v4-4000-strict","--compact-stream-v4-4000-strict-r2","--compact-stream-v4-4000-strict-r3","--compact-stream-v4-4000-strict-r4","--compact-stream-v4-4000-strict-r5","--compact-stream-v4-4000-strict-r6","--compact-stream-v4-4000-strict-r7","--compact-stream-v4-4000-strict-r8","--stream-extended","--stream-extended-v2","--stream-extended-1800","--compact-stream-1800","--compact-stream-1800-v2","--compact-stream-1800-v3","--compact-stream-2400","--compact-stream-2400-v2"].contains(args[5])
    let suite=try LocalTextModel.loadSuite(from:URL(fileURLWithPath:args[3]),compactSegmentExtraction:compact,compactSegmentAggregation:compact,segmentRequestTimeout:streaming ? 600:120,segmentStreaming:streaming,expandAmbiguousQuotes:args.count>=6 && ["--stream-segments-v4","--compact-stream-v4","--compact-stream-v4-2400","--compact-stream-v4-4000","--compact-stream-v4-4000-strict","--compact-stream-v4-4000-strict-r2","--compact-stream-v4-4000-strict-r3","--compact-stream-v4-4000-strict-r4","--compact-stream-v4-4000-strict-r5","--compact-stream-v4-4000-strict-r6","--compact-stream-v4-4000-strict-r7","--compact-stream-v4-4000-strict-r8"].contains(args[5]),strictSegmentAggregation:args.count>=6 && ["--compact-stream-v4-4000-strict","--compact-stream-v4-4000-strict-r2","--compact-stream-v4-4000-strict-r3","--compact-stream-v4-4000-strict-r4","--compact-stream-v4-4000-strict-r5","--compact-stream-v4-4000-strict-r6","--compact-stream-v4-4000-strict-r7","--compact-stream-v4-4000-strict-r8"].contains(args[5]))
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
    let command="personal-cloud-segment:"+source.id+":"+String(current.policyVersion)+":"+(args.count>=6 ? args[5] : "v2")
    let prior=try await store.segmentedProcessingBatches().first(where:{$0.commandID == command})
    let batch:SegmentedProcessingBatch
    if let prior {
        guard prior.scope.plan.scalarBudget == budget else { throw VoiceOSError("既有探针不能改变片段预算；保留原请求") }
        try await store.validateSegmentedExpressionProcessingScope(prior.scope,extraction:suite.segmentExtraction.configuration,aggregation:suite.segmentAggregation.configuration)
        batch=prior
    }
    else {
        let scope=try await store.prepareSegmentedExpressionProcessingScope(sourceID:source.id,extraction:suite.segmentExtraction.configuration,aggregation:suite.segmentAggregation.configuration,segmentScalarBudget:args.count>=6 && ["--stream-extended-1800","--compact-stream-1800","--compact-stream-1800-v2","--compact-stream-1800-v3"].contains(args[5]) ? 1800 : args.count>=6 && ["--compact-stream-v4-4000","--compact-stream-v4-4000-strict","--compact-stream-v4-4000-strict-r2","--compact-stream-v4-4000-strict-r3","--compact-stream-v4-4000-strict-r4","--compact-stream-v4-4000-strict-r5","--compact-stream-v4-4000-strict-r6","--compact-stream-v4-4000-strict-r7","--compact-stream-v4-4000-strict-r8"].contains(args[5]) ? 4000 : args.count>=6 && ["--compact-stream-v4-2400","--compact-stream-2400","--compact-stream-2400-v2"].contains(args[5]) ? 2400:budget)
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
