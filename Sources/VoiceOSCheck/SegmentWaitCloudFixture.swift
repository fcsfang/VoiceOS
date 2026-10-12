import Foundation
import VoiceOSCore
import VoiceOSPlatform

/// New, clearly synthetic long text; never a resend of personal unknown input.
func runSegmentWaitCloudFixture(_ args: [String]) async throws {
    guard (args.count==4 || args.count==5), args[3]=="--authorize-synthetic-text",
          args.count==4 || ["--compact-segments","--stream-segments"].contains(args[4]) else { throw VoiceOSError("segment-wait-cloud-fixture requires new runtime root, config and synthetic text grant") }
    let compact=args.count==5 && args[4]=="--compact-segments", streaming=args.count==5 && args[4]=="--stream-segments"
    let root=URL(fileURLWithPath:args[1]).standardizedFileURL.resolvingSymlinksInPath()
    let base=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("runtime").resolvingSymlinksInPath()
    guard root.path.hasPrefix(base.path+"/"),!FileManager.default.fileExists(atPath:root.path) else { throw VoiceOSError("等待窗口试验需要全新runtime资料库，禁止重发已有试验") }
    let diagnostics=ModelHTTPDiagnostics()
    let suite=try LocalTextModel.loadSuite(from:URL(fileURLWithPath:args[2]),compactSegmentExtraction:compact,compactSegmentAggregation:compact,segmentRequestTimeout:600,segmentTransport:DirectModelHTTPTransport(diagnostics:diagnostics),segmentStreaming:streaming)
    let store=try VoiceOSStore(root:root,inspector:NativeMediaInspector());try await store.recover()
    let topics=["原件保存","逐字稿版本","条件保留","否定识别","引用归属","任务候选","历史检索","关联反馈","外部回读","取消恢复","来源授权","数据迁移","模块边界","测量口径","长文字处理","错误分类"]
    var paragraphs:[String]=[]
    for (index,topic) in topics.enumerated() {
        let label=String(format:"场景%02d",index+1)
        let prefix = streaming ? "我在\(label)讨论\(topic)" : "\(label)讨论\(topic)"
        let identity = streaming ? "这是我的工程记录和操作要求" : "这是一份合成工程资料，用来观察等待窗口，并不是个人实际观点、承诺或操作指令"
        paragraphs.append("\(prefix)。\(identity)。对于\(topic)，我首先要保存输入和处理身份，然后核对输出来自哪一个版本。\(label)中的条件是只有来源有效且相关证据完整时才可以接纳结果；缺少条件不应靠猜测补齐。\(label)提出的问题是如何在不丢失原话的情况下保留限制。这里描述一种可能的工程解释：观察到阶段完成，可能有助于定位问题，但不能直接推导最终质量已经通过。\(label)明确否定了只看流畅总结就认定可靠的做法。假设后续发现新的反例，旧解释仍应作为历史保存，不能修改成从未发生过。对于\(topic)的判断，本段仅要求保留问题、条件、否定和不确定性，没有要求创建真实任务或调用外部工具。\(label)的结论保持暂定；后续测量需要区分结构校验、真实响应和人工语义评估。")
    }
    let text=paragraphs.joined(separator:"\n")
    let source=try await store.recordUserExpression("合成等待窗口试验资料。",commandID:"wait600-synthetic-source")
    let old=try await store.transcriptHistory(sourceID:source)[0].id
    _=try await store.correctTranscript(sourceID:source,expectedVersionID:old,text:text,commandID:"wait600-synthetic-long-text")
    _=try await store.setSourceLocalOnly(sourceID:source,expectedVersion:1,localOnly:false,commandID:"wait600-synthetic-grant")
    let scope=try await store.prepareSegmentedExpressionProcessingScope(sourceID:source,extraction:suite.segmentExtraction.configuration,aggregation:suite.segmentAggregation.configuration)
    let batchCommand=streaming ? "wait600-synthetic-stream-batch" : compact ? "wait600-synthetic-compact-batch":"wait600-synthetic-batch"
    let batch=try await store.enqueueSegmentedProcessingBatch(scope,commandID:batchCommand,extraction:suite.segmentExtraction.configuration,aggregation:suite.segmentAggregation.configuration)
    let start=Date()
    _=try? await store.processSegmentedCognition(batchID:batch.id,extraction:suite.segmentExtraction,aggregation:suite.segmentAggregation)
    let final=try await store.segmentedProcessingBatch(id:batch.id)
    let fragments=try await store.segmentExtractionAttempts(batchID:batch.id)
    let aggregate=try await store.segmentAggregationAttempt(batchID:batch.id)
    let timings=try JSONSerialization.jsonObject(with:JSONEncoder().encode(await diagnostics.records()))
    let report:[String:Any]=["synthetic_only":true,"personal_text_sent":false,"audio_uploaded":false,"external_task_writes":0,
        "source_id":source,"batch_id":batch.id,"source_scalars":text.unicodeScalars.count,"segment_scalars":scope.plan.segments.map { $0.text.unicodeScalars.count },
        "request_deadline_seconds":600,"compact_input":compact,"streaming":streaming,"provider":suite.segmentExtraction.configuration.provider,"model":suite.segmentExtraction.configuration.model,
        "extraction_version":scope.extraction.promptVersion,"aggregation_version":scope.aggregation.promptVersion,
        "elapsed_seconds":Date().timeIntervalSince(start),"parent_state":final.state.rawValue,"parent_error":final.error ?? "",
        "fragment_states":fragments.map { $0.state.rawValue },"fragment_usage":fragments.map { $0.usage ?? [:] },
        "aggregation_state":aggregate?.state.rawValue ?? "not_reserved","aggregation_usage":aggregate?.usage ?? [:],
        "claim_count":try await store.segmentedCognitiveClaimIDs(batchID:batch.id)?.count ?? 0,"transport_timings":timings,
        "integrity":try await store.integrityCheck(),"billing_state":"unknown","full_natural_case_A_complete":false]
    let data=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
    try data.write(to:root.appendingPathComponent("wait600-summary.json"),options:.atomic)
    print(String(decoding:data,as:UTF8.self))
}
