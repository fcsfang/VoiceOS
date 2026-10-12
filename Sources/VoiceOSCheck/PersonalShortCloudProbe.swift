import Foundation
import VoiceOSCore
import VoiceOSPlatform

/// A separate natural recording, not a replay of any unknown long request.
func runPersonalShortCloudProbe(_ args:[String]) async throws {
    guard args.count == 5,args[4] == "--authorize-this-source-text" else { throw VoiceOSError("personal-short-cloud requires new isolated root, own-voice audio, config and explicit text authorization") }
    let allowed=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("runtime").resolvingSymlinksInPath()
    let root=URL(fileURLWithPath:args[1]).standardizedFileURL.resolvingSymlinksInPath()
    let audio=URL(fileURLWithPath:args[2]).standardizedFileURL.resolvingSymlinksInPath()
    guard root.path.hasPrefix(allowed.path+"/"),audio.path.hasPrefix(allowed.path+"/"),!FileManager.default.fileExists(atPath:root.path) else { throw VoiceOSError("短录音探针需要runtime内新独立库及明确本人音频，不自动重试旧资料库") }
    let suite=try LocalTextModel.loadSuite(from:URL(fileURLWithPath:args[3]))
    let store=try VoiceOSStore(root:root,inspector:NativeMediaInspector());try await store.recover()
    let source=try await store.importPersonalAudio(audio,commandID:"personal-short-import")
    try await store.processTranscriptions(using:NativeSpeechPort())
    guard let current=try await store.sources().first(where:{$0.id == source}),let text=current.transcript,!text.isEmpty,text.unicodeScalars.count<=4000 else { throw VoiceOSError("短录音没有可用于本次明确处理的完整文字") }
    _=try await store.setSourceLocalOnly(sourceID:source,expectedVersion:current.policyVersion,localOnly:false,commandID:"personal-short-text-grant")
    let scope=try await store.prepareExpressionProcessingIntent(sourceID:source,cognition:suite.cognition.configuration,association:suite.association.configuration)
    let queue=try await store.enqueueExpressionProcessingIntent(scope,commandID:"personal-short-cloud-process",cognition:suite.cognition.configuration,association:suite.association.configuration)
    let start=Date()
    do { _=try await store.runExpressionProcessingIntent(id:queue.id,retrieval:NativeRetrieval(),cognitionPort:suite.cognition,associationPort:suite.association) }
    catch { /* Durable queue and sanitized receipts are the authority. */ }
    let final=try await store.processingIntents().first(where:{$0.id == queue.id})!
    let claims=try await store.candidateClaims(),actions=try await store.actions(),attempts=try await store.modelAttempts()
    let report:[String:Any]=["source_id":source,"queue_id":queue.id,"source_scalars":text.unicodeScalars.count,
        "queue_state":final.state.rawValue,"elapsed_seconds":Date().timeIntervalSince(start),"claims":claims.count,
        "actions":actions.count,"model_states":attempts.map{$0.state},"model_usage":attempts.map{$0.usage ?? [:]},
        "integrity":try await store.integrityCheck(),"audio_uploaded":false,"external_task_writes":0,"billing_state":"unknown",
        "natural_semantic_quality_reviewed":false]
    let data=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
    try data.write(to:root.appendingPathComponent("personal-short-cloud-summary.json"),options:.atomic)
    print(String(decoding:data,as:UTF8.self))
}
