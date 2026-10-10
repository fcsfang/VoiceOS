import Foundation

public struct RetrievalDocument: Sendable, Identifiable {
    public let id: String
    public let sourceID: String
    public let sourceVersionID: String
    public let transcriptVersionID: String
    public let policyVersion: Int
    public let spanID: String
    public let textStart: Int
    public let textEnd: Int
    public let text: String
    public let name: String
    public let createdAt: String
    public let origin: String
    public let localOnly: Bool
}
public struct RetrievalMatch: Sendable {
    public let documentID: String
    public let score: Double
    public let method: String
    public init(documentID: String, score: Double, method: String) { self.documentID = documentID; self.score = score; self.method = method }
}
public protocol LocalRetrievalPort: Sendable {
    /// Implementations process locally; this boundary is never a cloud authorization.
    func rank(query: String, documents: [RetrievalDocument], semantic: Bool) async throws -> [RetrievalMatch]
}
public struct RetrievalHit: Sendable, Identifiable {
    public var id: String { document.id }
    public let document: RetrievalDocument
    public let method: String
    public let score: Double
}
public struct RetrievalResult: Sendable {
    public let hits: [RetrievalHit]
    public let scannedSources: Int
    public let scannedFragments: Int
    public let matchingSources: Int
}
extension VoiceOSStore {
    /// Read current originals, never frozen derived claims or old transcript versions.
    private func retrievalDocuments() throws -> [RetrievalDocument] {
        guard ready else { throw VoiceOSError("资料库尚未完成恢复") }
        let rows = try db.query("""
        SELECT s.*,v.id AS transcript_version_id,v.text,v.spans_json FROM sources s
        JOIN transcripts t ON t.source_id=s.id AND t.input_version_id=s.version_id
        JOIN transcript_versions v ON v.id=t.current_version_id AND v.transcript_id=t.id
        WHERE s.state IN ('saved','reference_only') ORDER BY s.created_at,s.id
        """)
        var docs: [RetrievalDocument] = []
        for row in rows {
            if row["state"] == "saved" {
                do { _ = try playableURL(sourceID:row["id"]!) } catch { continue }
            }
            let text = row["text"]!, scalars = Array(text.unicodeScalars)
            let spans = try JSONDecoder().decode([TranscriptSpan].self,from:Data(row["spans_json"]!.utf8))
            try SpeechText(text:text,spans:spans).validate(duration:row["duration"].flatMap(Double.init))
            for span in spans {
                // Overlap preserves nearby context at fragment boundaries. Every fragment retains exact scalar offsets.
                var start = span.textStart
                while start < span.textEnd {
                    let end = min(start + 800,span.textEnd)
                    docs.append(RetrievalDocument(id:row["id"]!+":"+row["transcript_version_id"]!+":"+String(start),sourceID:row["id"]!,sourceVersionID:row["version_id"]!,transcriptVersionID:row["transcript_version_id"]!,policyVersion:Int(row["policy_version"]!)!,spanID:span.id,textStart:start,textEnd:end,text:String(String.UnicodeScalarView(scalars[start..<end])),name:row["name"]!,createdAt:row["created_at"]!,origin:row["origin"]!,localOnly:row["local_only"] != "0"))
                    guard docs.count <= 10000 else { throw VoiceOSError("当前本地检索超过一万片段范围，请先缩小资料库；未按位置截断历史") }
                    if end == span.textEnd { break }; start = end - 512
                }
            }
        }
        return docs
    }
    public func validateRetrievalHit(_ hit: RetrievalHit) throws {
        let doc = hit.document
        guard let row = try db.query("""
        SELECT s.*,t.current_version_id,v.text,v.spans_json FROM sources s JOIN transcripts t ON t.source_id=s.id
        JOIN transcript_versions v ON v.id=t.current_version_id AND v.transcript_id=t.id
        WHERE s.id=? AND t.input_version_id=s.version_id AND s.state IN ('saved','reference_only')
        """,[doc.sourceID]).first,
          row["version_id"] == doc.sourceVersionID, row["current_version_id"] == doc.transcriptVersionID,
          row["policy_version"] == String(doc.policyVersion), (row["local_only"] != "0") == doc.localOnly else { throw VoiceOSError("检索出处或权限已变化，请重新查找") }
        if row["state"] == "saved" { _ = try playableURL(sourceID:doc.sourceID) }
        let scalars = Array(row["text"]!.unicodeScalars)
        let spans = try JSONDecoder().decode([TranscriptSpan].self,from:Data(row["spans_json"]!.utf8))
        guard doc.textStart >= 0, doc.textEnd > doc.textStart, doc.textEnd <= scalars.count,
              spans.contains(where: { $0.id == doc.spanID && $0.textStart <= doc.textStart && $0.textEnd >= doc.textEnd }),
              String(String.UnicodeScalarView(scalars[doc.textStart..<doc.textEnd])) == doc.text else { throw VoiceOSError("检索摘录与原文不一致") }
    }
    public func retrieve(_ query: String, semantic: Bool = false, limit: Int = 20, using port: any LocalRetrievalPort) async throws -> RetrievalResult {
        guard !query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, query.unicodeScalars.count <= 512, (1...100).contains(limit) else { throw VoiceOSError("请填写不超过 512 字的查询并使用有效结果数量") }
        let docs = try retrievalDocuments()
        let matches = try await port.rank(query:query,documents:docs,semantic:semantic)
        try Task.checkCancellation()
        let lookup = Dictionary(uniqueKeysWithValues:docs.map { ($0.id,$0) })
        guard Set(matches.map(\.documentID)).count == matches.count else { throw VoiceOSError("检索端口返回重复候选") }
        var hits: [RetrievalHit] = []
        for match in matches {
            guard let doc = lookup[match.documentID], match.score.isFinite, (0...1).contains(match.score), ["exact","local_semantic"].contains(match.method) else { throw VoiceOSError("检索端口返回无效候选") }
            let hit = RetrievalHit(document:doc,method:match.method,score:match.score)
            // A late result cannot resurrect corrected or newly restricted content.
            try validateRetrievalHit(hit); hits.append(hit)
        }
        hits.sort { if $0.method != $1.method { return $0.method == "exact" }; if $0.score != $1.score { return $0.score > $1.score }; return $0.id < $1.id }
        var seen: Set<String> = []
        let unique = hits.filter { seen.insert($0.document.sourceID).inserted }
        return RetrievalResult(hits:Array(unique.prefix(limit)),scannedSources:Set(docs.map(\.sourceID)).count,scannedFragments:docs.count,matchingSources:unique.count)
    }
}
