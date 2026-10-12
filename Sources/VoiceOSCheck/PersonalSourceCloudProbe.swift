import Foundation
import VoiceOSCore
import VoiceOSPlatform

/// Existing authorized own-audio source; one durable command, no transcription
/// replay, raw audio upload, reminders write, or force-retry of unknown results.
func runPersonalSourceCloudProbe(_ args: [String]) async throws {
    guard [5,7,8].contains(args.count),args[4]=="--authorize-this-source-text",
          args.count==5 || (args[5]=="--semantic-model" && (args.count==7 || args[7]=="--association-only")) else {
        throw VoiceOSError("personal-source-cloud-probe requires isolated root, source ID, config, text grant, optional --semantic-model <root> [--association-only]")
    }
    let base=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("runtime").resolvingSymlinksInPath()
    let root=URL(fileURLWithPath:args[1]).standardizedFileURL.resolvingSymlinksInPath()
    guard root.path.hasPrefix(base.path+"/"),FileManager.default.fileExists(atPath:root.appendingPathComponent("voiceos.sqlite").path) else {
        throw VoiceOSError("Existing-source probe requires an existing runtime test library")
    }
    let store=try VoiceOSStore(root:root,inspector:NativeMediaInspector());try await store.recover()
    guard let source=try await store.sources().first(where:{$0.id==args[2]}),
          source.kind=="audio",source.origin=="user",source.speaker=="user",source.jobState=="completed",
          let text=source.transcript,!text.isEmpty,text.unicodeScalars.count<=4000,
          let version=source.transcriptVersionID else { throw VoiceOSError("Probe needs a completed own-audio transcript of 1–4000 scalars") }
    let suite=try LocalTextModel.loadSuite(from:URL(fileURLWithPath:args[3]))
    let semantic=args.count>=7
    let retrieval:any LocalRetrievalPort=semantic ? CoreMLRetrieval(root:URL(fileURLWithPath:args[6])) : NativeRetrieval()
    if source.localOnly {
        _=try await store.setSourceLocalOnly(sourceID:source.id,expectedVersion:source.policyVersion,localOnly:false,commandID:"personal-source-grant:"+source.id)
    }
    let current=try await store.sources().first(where:{$0.id==source.id})!
    let command="personal-source-cloud:"+source.id+":"+version+":"+String(current.policyVersion)
    let scope=try await store.prepareExpressionProcessingIntent(sourceID:source.id,cognition:suite.cognition.configuration,association:suite.association.configuration)
    let queue=try await store.enqueueExpressionProcessingIntent(scope,commandID:command,cognition:suite.cognition.configuration,association:suite.association.configuration)
    let start=Date()
    var associationState="not_run"
    if args.count==8 {
        // A completed cognition with no association request may continue the
        // distinct history stage. Never rerun cognition or unlock a terminal attempt.
        guard queue.state == .completed else { throw VoiceOSError("Association-only requires an already completed expression queue") }
        associationState=try await store.processExpressionAssociation(sourceID:source.id,retrieval:retrieval,semantic:true,model:suite.association).state.rawValue
    } else if queue.state == .queued {
        _=try await store.runExpressionProcessingIntent(id:queue.id,retrieval:retrieval,cognitionPort:suite.cognition,associationPort:suite.association,semantic:semantic)
    }
    let final=try await store.processingIntents().first(where:{$0.id==queue.id})!
    let attempts=try await store.modelAttempts(),claims=try await store.candidateClaims(),actions=try await store.actions()
    let sourceClaims=claims.filter { $0.references.contains { $0.sourceID==source.id } }
    let sourceClaimIDs=Set(sourceClaims.map(\.id))
    let sourceActions=actions.filter { sourceClaimIDs.contains($0.claimID) }
    let associations=try await store.expressionAssociationAttempts().filter { $0.snapshot.current.sources.first?.sourceID==source.id }
    let report: [String:Any]=["source_id":source.id,"transcript_version_id":version,"transcription_backend":source.transcriptionBackend ?? "unknown",
        "source_scalars":text.unicodeScalars.count,"queue_id":queue.id,"queue_state":final.state.rawValue,
        "elapsed_seconds":Date().timeIntervalSince(start),"claim_count":claims.count,"action_count":actions.count,
        "counts_scope":"library_total_unless_source_prefixed","source_claim_count":sourceClaims.count,"source_action_count":sourceActions.count,
        "source_auto_send_actions":sourceActions.filter(\.autoSend).count,"local_semantic_retrieval":semantic,
        "association_stage_state":associationState,"source_association_states":associations.map(\.state),
        "source_association_proposals":associations.reduce(0) { $0+$1.proposals.count },
        "source_association_usage":associations.map { $0.usage ?? [:] },
        "auto_send_actions":actions.filter(\.autoSend).count,"model_states":attempts.map(\.state),"model_usage":attempts.map{$0.usage ?? [:]},
        "integrity":try await store.integrityCheck(),"audio_uploaded":false,"external_task_writes":0,"billing_state":"unknown",
        "full_natural_case_A_complete":false]
    let data=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
    try data.write(to:root.appendingPathComponent("personal-source-cloud-summary.json"),options:.atomic)
    print(String(decoding:data,as:UTF8.self))
}
