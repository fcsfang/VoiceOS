import Foundation

public struct SearchHit: Sendable {
    public enum Kind: String, Sendable, Equatable {
        case material
        case claim
        case action
    }
    public let kind: Kind
    public let refID: String
    public let title: String
    public let snippet: String
}

extension VoiceOSStore {
    public func search(query: String, limit: Int = 50) throws -> [SearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, limit > 0 else { return [] }
        try rebuildSearchIndexIfNeeded()
        let phrase = "\"" + trimmed.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        return try db.query("""
        SELECT kind, ref_id, title, COALESCE(NULLIF(snippet(search_index, 3, '', '', '…', 24), ''), title) AS snippet
        FROM search_index WHERE search_index MATCH ? ORDER BY rank LIMIT ?
        """, [phrase, String(limit)]).map { row in
            guard let kind = row["kind"].flatMap(SearchHit.Kind.init(rawValue:)), let refID = row["ref_id"], let title = row["title"] else {
                throw VoiceOSError("检索结果损坏")
            }
            return SearchHit(kind: kind, refID: refID, title: title, snippet: row["snippet"] ?? "")
        }
    }

    public func rebuildSearchIndexIfNeeded() throws {
        let stored = try db.query("SELECT value FROM search_index_meta WHERE key='fingerprint'").first?["value"]
        let fingerprint = try searchFingerprint()
        guard stored != fingerprint else { return }
        try rebuildSearchIndex()
    }

    public func rebuildSearchIndex() throws {
        let fingerprint = try searchFingerprint()
        try db.transaction {
            try db.execute("DELETE FROM search_index")
            try db.execute("""
            INSERT INTO search_index(kind, ref_id, title, body)
            SELECT 'material', s.id, s.name, COALESCE(GROUP_CONCAT(v.text, ' '), '')
            FROM sources s
            LEFT JOIN transcripts t ON t.source_id = s.id
            LEFT JOIN transcript_versions v ON v.id = t.current_version_id
            GROUP BY s.id
            """)
            try db.execute("INSERT INTO search_index(kind, ref_id, title, body) SELECT 'claim', id, statement, statement FROM claims")
            try db.execute("INSERT INTO search_index(kind, ref_id, title, body) SELECT 'action', id, title, note FROM actions")
            try db.execute("INSERT OR REPLACE INTO search_index_meta(key, value) VALUES('fingerprint', ?)", [fingerprint])
        }
    }

    private func searchFingerprint() throws -> String {
        var parts: [String] = []
        for table in ["sources", "claims", "actions"] {
            let row = try db.query("SELECT COUNT(*) AS count, COALESCE(MAX(created_at), '') AS latest FROM \(table)").first!
            parts.append("\(row["count"]!):\(row["latest"]!)")
        }
        return parts.joined(separator: "|")
    }
}
