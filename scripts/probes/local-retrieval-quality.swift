// Synthetic local quality probe; no assets request or cloud call. Run with the macOS Swift SDK.
import Foundation
import NaturalLanguage
guard let e=NLContextualEmbedding(language:.simplifiedChinese) else { print("{\"status\":\"not_run\",\"reason\":\"unsupported Chinese model\",\"download_requested\":false}"); exit(0) }
guard e.hasAvailableAssets else { print("{\"assets_available\":false,\"status\":\"not_run\",\"download_requested\":false}"); exit(0) }
try e.load();defer{e.unload()}
func mean(_ text:String) throws -> [Double] {
 let r=try e.embeddingResult(for:text,language:.simplifiedChinese);var v=Array(repeating:0.0,count:e.dimension);var n=0
 r.enumerateTokenVectors(in:text.startIndex..<text.endIndex){a,_ in for i in v.indices{v[i]+=a[i]};n+=1;return true}
 let norm=sqrt(v.reduce(0){$0+$1*$1});return v.map{$0/norm}
}
let texts=(0..<1000).map { i in i==999 ? "旧想法：按遗忘曲线安排检索练习。" : (i==0 ? "更大的上下文未必有益。" : (i==1 ? "学习做饭要练刀工。" : "合成无关记录 \(i)：今天整理了厨房橱柜和购物收据。")) }
let vectors=try texts.map(mean);var reports:[[String:Any]]=[]
for (id,q,target) in [("RT-01","把提取训练放到容易忘的时候会不会更有效？",999),("RT-02","我想研究检索增强生成的学习策略。",1),("RT-03","某些检索可靠的任务确实受益，但不是越大越好。",0)] {
 let qv=try mean(q);let distances=vectors.map{v in 1-zip(qv,v).reduce(0){$0+$1.0*$1.1}}
 let ordered=texts.indices.sorted{distances[$0]<distances[$1]}
 reports.append(["case":id,"target_rank":ordered.firstIndex(of:target)!+1,"target_distance":distances[target],"top_20":ordered.prefix(20).map{["position":$0,"text":texts[$0],"distance":distances[$0]] as [String:Any]}])
}
print(String(data:try JSONSerialization.data(withJSONObject:["history_count":1000,"synthetic":true,"assets_downloaded":false,"model":e.modelIdentifier,"pooling":"mean_then_normalize","cases":reports],options:[.sortedKeys,.prettyPrinted]),encoding:.utf8)!)
