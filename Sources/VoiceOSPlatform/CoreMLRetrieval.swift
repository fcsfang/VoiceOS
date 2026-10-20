import Foundation
import CoreML
import VoiceOSCore

/// Rebuildable in-memory projection only. All inference is local; no downloader.
public actor CoreMLRetrieval: LocalRetrievalPort {
    public nonisolated let semanticWindow = RetrievalWindow(scalars:256,overlap:96)
    public nonisolated let identity = "BAAI/bge-small-zh-v1.5@7999e1d3359715c523056ef9478215996d62a620:coreml-f32-v1"
    private let root: URL
    private var model: MLModel?
    private var tokenizer: BGEWordPiece?
    private var vectors: [String:[Double]] = [:]
    public init(root:URL) { self.root = root }
    private func load() throws {
        guard model == nil else { return }
        let assets = try BGEAssets(root:root)
        tokenizer = try BGEWordPiece(vocabulary:String(contentsOf:root.appendingPathComponent("vocab.txt"),encoding:.utf8))
        let configuration = MLModelConfiguration()
        // Freeze CPU/f32 first; accelerator/precision changes require parity measurements.
        configuration.computeUnits = .cpuOnly
        let value = try MLModel(contentsOf:assets.root.appendingPathComponent("Encoder.mlmodelc"),configuration:configuration)
        guard Set(value.modelDescription.inputDescriptionsByName.keys) == ["input_ids","attention_mask","token_type_ids"],
              value.modelDescription.outputDescriptionsByName["embedding"]?.multiArrayConstraint?.shape == [1,512] else { throw VoiceOSError("本地语义模型接口不符") }
        model = value
    }
    public func tokenIDs(_ text:String) throws -> [Int] { try load(); return try tokenizer!.encode(text) }
    public func encode(_ text:String) throws -> [Double] {
        try load()
        let ids = try tokenizer!.encode(text)
        var values: [String:MLFeatureValue] = [:]
        for name in ["input_ids","attention_mask","token_type_ids"] {
            let array = try MLMultiArray(shape:[1,NSNumber(value:ids.count)],dataType:.int32)
            for i in ids.indices { array[i] = NSNumber(value:name == "input_ids" ? ids[i] : (name == "attention_mask" ? 1 : 0)) }
            values[name] = MLFeatureValue(multiArray:array)
        }
        let prediction = try model!.prediction(from:MLDictionaryFeatureProvider(dictionary:values))
        guard let array = prediction.featureValue(for:"embedding")?.multiArrayValue, array.count == 512 else { throw VoiceOSError("本地语义模型输出维度不符") }
        let vector = (0..<array.count).map { array[$0].doubleValue }
        let norm = sqrt(vector.reduce(0) { $0 + $1*$1 })
        guard norm.isFinite, norm > 0, vector.allSatisfy(\.isFinite) else { throw VoiceOSError("本地语义模型输出无效") }
        return vector.map { $0/norm }
    }
    public func rank(query:String,documents:[RetrievalDocument],semantic:Bool) async throws -> [RetrievalMatch] {
        if !semantic { return documents.filter { $0.text.localizedCaseInsensitiveContains(query) }.map { RetrievalMatch(documentID:$0.id,score:1,method:"exact") } }
        guard query.unicodeScalars.contains(where:{ BGEWordPiece.chinese($0.value) }) else { throw VoiceOSError("当前本地语义召回验证范围为中文，请使用关键词查找") }
        try Task.checkCancellation()
        let q = try encode("为这个句子生成表示以用于检索相关文章：" + query)
        var results: [RetrievalMatch] = [], live: Set<String> = []
        for doc in documents {
            try Task.checkCancellation()
            let key = BGEAssets.hash(Data(doc.text.utf8)); live.insert(key)
            let vector: [Double]
            if let cached = vectors[key] { vector = cached }
            else {
                vector = try encode(doc.text)
                if vectors.count >= 10000 { vectors.removeAll(keepingCapacity:true) }
                vectors[key] = vector
            }
            let score = max(0,min(1,zip(q,vector).reduce(0) { $0+$1.0*$1.1 }))
            if doc.text.localizedCaseInsensitiveContains(query) { results.append(RetrievalMatch(documentID:doc.id,score:1,method:"exact")) }
            else { results.append(RetrievalMatch(documentID:doc.id,score:score,method:"local_semantic")) }
        }
        // Drop corrected/deleted content and bound memory to the supported projection.
        vectors = vectors.filter { live.contains($0.key) }
        if vectors.count > 10000 { vectors.removeAll() }
        return results
    }
}
