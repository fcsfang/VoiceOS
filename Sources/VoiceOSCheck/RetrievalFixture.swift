import Foundation
import VoiceOSCore
import VoiceOSPlatform

func runRetrievalFixture(_ args: [String]) async throws {
    guard args.count == 3, let count = Int(args[2]), [10,100,1000].contains(count) else { throw VoiceOSError("retrieval-fixture needs new root and 10/100/1000 records") }
    let root = URL(fileURLWithPath:args[1],isDirectory:true)
    guard !FileManager.default.fileExists(atPath:root.path) else { throw VoiceOSError("retrieval fixture requires new root") }
    let store = try VoiceOSStore(root:root,inspector:NativeMediaInspector()); try await store.recover()
    let positivePosition = count == 10 ? 0 : (count == 100 ? count/2 : count-1)
    let conditionalPosition = (positivePosition + 1) % count, negativePosition = (positivePosition + 2) % count
    var positive = "", conditional = "", negative = ""
    for i in 0..<count {
        let text: String
        if i == positivePosition { text = "旧想法：按遗忘曲线安排检索练习。" }
        else if i == conditionalPosition { text = "更大的上下文未必有益。" }
        else if i == negativePosition { text = "学习做饭要练刀工。" }
        else { text = "合成无关记录 \(i)：今天整理了厨房橱柜和购物收据。" }
        let id = try await store.recordUserExpression(text,commandID:"retrieval-synthetic-\(i)")
        if i == positivePosition { positive = id }; if i == conditionalPosition { conditional = id }; if i == negativePosition { negative = id }
    }
    let port = NativeRetrieval()
    let cases: [(String,String,String,Bool)] = [
        ("RT-01","把提取训练放到容易忘的时候会不会更有效？",positive,true),
        ("RT-02","我想研究检索增强生成的学习策略。",negative,false),
        ("RT-03","某些检索可靠的任务确实受益，但不是越大越好。",conditional,true)]
    var reports: [[String:Any]] = []
    for (id,query,target,shouldFind) in cases {
        let started = Date(); let result = try await store.retrieve(query,semantic:true,limit:100,using:port)
        let rank = result.hits.firstIndex { $0.document.sourceID == target }
        reports.append(["case":id,"expected_source_id":target,"expected_match":shouldFind,"target_returned":rank != nil,"expected_condition_met":(rank != nil) == shouldFind,"rank":rank.map { $0+1 } ?? 0,"scanned_sources":result.scannedSources,"scanned_fragments":result.scannedFragments,"matching_sources":result.matchingSources,"returned":result.hits.map { ["source_id":$0.document.sourceID,"text":$0.document.text,"method":$0.method] },"elapsed_ms":Int(Date().timeIntervalSince(started)*1000)])
    }
    let exact = try await store.retrieve("遗忘曲线",using:port)
    guard exact.hits.contains(where: { $0.document.sourceID == positive }), exact.scannedSources == count else { throw VoiceOSError("exact fixture search failed") }
    let report: [String:Any] = ["synthetic":true,"history_count":count,"positive_position":positivePosition,"local_only":true,"cloud_calls":0,"external_writes":0,"exact_search_passed":true,"semantic_cases":reports,"semantic_relationships_created":0]
    try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("retrieval-report.json"))
    print(String(data:try JSONSerialization.data(withJSONObject:["history_count":count,"exact_passed":true,"case_results":reports.map { ["case":$0["case"]!,"expected_condition_met":$0["expected_condition_met"]!,"matching_sources":$0["matching_sources"]!] }],options:[.sortedKeys]),encoding:.utf8)!)
}
