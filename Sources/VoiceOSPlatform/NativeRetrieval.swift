import Foundation
import NaturalLanguage
import CryptoKit
import VoiceOSCore

/// Ephemeral, bounded projections. No database or cloud dependency; never authoritative history.
public actor NativeRetrieval: LocalRetrievalPort {
    private var embedding: NLEmbedding?
    private var loaded = false
    private var vectors: [String:[Double]] = [:]
    public init() {}
    private func vector(_ text: String, using embedding: NLEmbedding) -> [Double]? {
        let key = SHA256.hash(data:Data(text.utf8)).map { String(format:"%02x",$0) }.joined()
        if let vector = vectors[key] { return vector }
        guard let vector = embedding.vector(for:text), !vector.isEmpty, vector.allSatisfy(\.isFinite) else { return nil }
        if vectors.count >= 4096 { vectors.removeAll(keepingCapacity:true) }
        vectors[key] = vector; return vector
    }
    public func rank(query: String, documents: [RetrievalDocument], semantic: Bool) async throws -> [RetrievalMatch] {
        let chinese = query.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) }
        if semantic && chinese && !loaded { embedding = NLEmbedding.sentenceEmbedding(for:.simplifiedChinese,revision:1); loaded = true }
        if semantic && !chinese { throw VoiceOSError("当前语义候选仅支持中文，请关闭语义选项使用文字查找") }
        if semantic && embedding == nil { throw VoiceOSError("本机中文语义资源不可用，请使用文字查找；不会自动改走云端") }
        let queryVector = semantic && chinese ? embedding.flatMap { vector(query,using:$0) } : nil
        var matches: [RetrievalMatch] = []
        for doc in documents {
            try Task.checkCancellation()
            if doc.text.localizedCaseInsensitiveContains(query) {
                matches.append(RetrievalMatch(documentID:doc.id,score:1,method:"exact")); continue
            }
            guard let embedding, let queryVector, let documentVector = vector(doc.text,using:embedding), documentVector.count == queryVector.count else { continue }
            var dot = 0.0, qNorm = 0.0, dNorm = 0.0
            for (q,d) in zip(queryVector,documentVector) { dot += q*d; qNorm += q*q; dNorm += d*d }
            guard qNorm > 0, dNorm > 0 else { continue }
            let distance = sqrt(max(0,2 * (1 - max(-1,min(1,dot / sqrt(qNorm*dNorm))))))
            // Conservative experimental Chinese gate, not confidence or a relation verdict.
            if distance <= 0.30 { matches.append(RetrievalMatch(documentID:doc.id,score:max(0,min(1,1-distance)),method:"local_semantic")) }
        }
        return matches
    }
}
