import Foundation
import VoiceOSCore
import VoiceOSPlatform

private struct BGEEvaluationFixture: Decodable {
    struct Document: Decodable { let id: String; let text: String }
    struct Query: Decodable { let id: String; let text: String; let relevant: [String] }
    let synthetic: Bool
    let documents: [Document]
    let queries: [Query]
}
private struct BGEParityFixture: Decodable { let text: String; let token_ids: [Int]; let reference_vector: [Double] }
func runBGEEvaluation(_ args:[String]) async throws {
    guard args.count == 5 || args.count == 7 && args[5] == "--cloud-config" else { throw VoiceOSError("bge-eval <model-dir> <parity-json> <synthetic-fixture> <new-output-root> [--cloud-config <local-config>]") }
    let root = URL(fileURLWithPath:args[4],isDirectory:true)
    guard !FileManager.default.fileExists(atPath:root.path) else { throw VoiceOSError("requires new evaluation root") }
    let fixture = try JSONDecoder().decode(BGEEvaluationFixture.self,from:Data(contentsOf:URL(fileURLWithPath:args[3])))
    guard fixture.synthetic, fixture.documents.count <= 1000, fixture.queries.count <= 100,
          Set(fixture.documents.map(\.id)).count == fixture.documents.count else { throw VoiceOSError("requires bounded synthetic fixture") }
    let port = CoreMLRetrieval(root:URL(fileURLWithPath:args[1]))
    var parity: [[String:Any]] = []
    let cases = try JSONDecoder().decode([BGEParityFixture].self,from:Data(contentsOf:URL(fileURLWithPath:args[2])))
    for item in cases {
        let tokens = try await port.tokenIDs(item.text), vector = try await port.encode(item.text)
        guard tokens == item.token_ids, vector.count == item.reference_vector.count else { throw VoiceOSError("native tokenizer parity failed") }
        let cosine = zip(vector,item.reference_vector).reduce(0) { $0 + $1.0*$1.1 }
        guard cosine > 0.99999 else { throw VoiceOSError("native CoreML vector parity failed") }
        parity.append(["tokens":tokens.count,"cosine":cosine,"passed":true])
    }
    let store = try VoiceOSStore(root:root,inspector:NativeMediaInspector()); try await store.recover()
    var originals: [String:String] = [:]
    for d in fixture.documents { originals[try await store.recordUserExpression(d.text,commandID:d.id)] = d.id }
    var reports: [[String:Any]] = [], relevant = 0, recalled = 0
    for q in fixture.queries {
        let started = Date()
        let result = try await store.retrieve(q.text,semantic:true,limit:8,using:port)
        let returned = result.hits.map { originals[$0.document.sourceID]! }
        let found = Set(returned).intersection(q.relevant).count
        relevant += q.relevant.count; recalled += found
        reports.append(["id":q.id,"expected":q.relevant,"returned":returned,"relevant_found":found,"scanned_sources":result.scannedSources,"scanned_fragments":result.scannedFragments,"elapsed_ms":Date().timeIntervalSince(started)*1000,"hits":result.hits.map { ["id":originals[$0.document.sourceID]!,"score":$0.score,"start":$0.document.textStart,"end":$0.document.textEnd] as [String:Any] }])
    }
    let report: [String:Any] = ["synthetic":true,"identity":port.identity,"parity":parity,"documents":fixture.documents.count,"queries":reports,"relevant_total":relevant,"relevant_recalled":recalled,"recall_top8":relevant == 0 ? 0 : Double(recalled)/Double(relevant),"cloud_calls":0,"external_writes":0,"relations_created":0]
    let data = try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
    try data.write(to:root.appendingPathComponent("report.json"))
    if args.count == 7 {
        let selector = try LocalTextModel.loadRelevance(from:URL(fileURLWithPath:args[6]))
        guard let query = fixture.queries.first(where:{ !$0.relevant.isEmpty }) else { throw VoiceOSError("cloud probe requires positive synthetic query") }
        for source in try await store.sources() {
            _ = try await store.setSourceLocalOnly(sourceID:source.id,expectedVersion:source.policyVersion,localOnly:false)
        }
        let candidates = try await store.retrieve(query.text,semantic:true,limit:8,using:port).hits
        let snapshot = try await store.prepareRelevanceSnapshot(query:query.text,queryID:UUID(),candidates:candidates,destination:.cloud,cloudQueryAllowed:true)
        let result = try await store.performRelevanceSelection(snapshot,using:selector)
        let ids = result.map { originals[$0.document.sourceID]! }
        let attempts = try await store.relevanceAttempts()
        let cloud: [String:Any] = ["synthetic":true,"query_id":query.id,"selected":ids,"expected":query.relevant,"quality_passed":Set(ids) == Set(query.relevant),"candidate_count":candidates.count,"text_scalars":snapshot.query.unicodeScalars.count + candidates.reduce(0) { $0 + $1.document.text.unicodeScalars.count },"attempts":attempts.count,"state":attempts[0].state,"usage":attempts[0].usage ?? [:],"billing_state":"unknown","claims_created":try await store.candidateClaims().count,"actions_created":try await store.actions().count]
        try JSONSerialization.data(withJSONObject:cloud,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("cloud-report.json"))
        print(String(decoding:try JSONSerialization.data(withJSONObject:cloud,options:[.sortedKeys]),as:UTF8.self))
    }
    print(String(decoding:try JSONSerialization.data(withJSONObject:["documents":fixture.documents.count,"parity_passed":true,"recall_top8":report["recall_top8"]!]),as:UTF8.self))
}
