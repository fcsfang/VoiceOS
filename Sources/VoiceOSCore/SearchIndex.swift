import Foundation

public struct SearchHit: Sendable {
    public enum Kind: String, Sendable, Equatable {
        case material
        case claim
        case action
        case topic
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
        let tokens = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return [] }
        if tokens.contains(where: { $0.count < 3 }) {
            return try searchBySubstring(tokens: tokens, limit: limit)
        }
        let expression = tokens.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: " ")
        return try db.query("""
        SELECT kind, ref_id, title, COALESCE(NULLIF(snippet(search_index, 3, '', '', '…', 24), ''), title) AS snippet
        FROM search_index WHERE search_index MATCH ? ORDER BY rank LIMIT ?
        """, [expression, String(limit)]).map(decodeHit)
    }

    private func searchBySubstring(tokens: [String], limit: Int) throws -> [SearchHit] {
        let conditions = Array(repeating: "(title LIKE ? ESCAPE '\\' OR body LIKE ? ESCAPE '\\')", count: tokens.count).joined(separator: " AND ")
        var binds: [String] = [tokens[0], tokens[0]]
        for token in tokens {
            let pattern = substringPattern(token)
            binds.append(pattern); binds.append(pattern)
        }
        binds.append(substringPattern(tokens[0]))
        binds.append(String(limit))
        return try db.query("""
        SELECT kind, ref_id, title,
               CASE WHEN instr(body, ?) > 0 THEN substr(body, MAX(1, instr(body, ?) - 20), 60) ELSE title END AS snippet
        FROM search_index WHERE \(conditions)
        ORDER BY CASE WHEN title LIKE ? ESCAPE '\\' THEN 0 ELSE 1 END
        LIMIT ?
        """, binds).map(decodeHit)
    }

    private func substringPattern(_ token: String) -> String {
        var escaped = token.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "%", with: "\\%")
        escaped = escaped.replacingOccurrences(of: "_", with: "\\_")
        return "%\(escaped)%"
    }

    private func decodeHit(_ row: [String: String]) throws -> SearchHit {
        guard let kind = row["kind"].flatMap(SearchHit.Kind.init(rawValue:)), let refID = row["ref_id"], let title = row["title"] else {
            throw VoiceOSError("检索结果损坏")
        }
        return SearchHit(kind: kind, refID: refID, title: title, snippet: row["snippet"] ?? "")
    }

    public func rebuildSearchIndexIfNeeded() throws {
        let dirty = try db.query("SELECT value FROM search_index_meta WHERE key='dirty'").first?["value"]
        if dirty != "1" {
            let stored = try db.query("SELECT value FROM search_index_meta WHERE key='fingerprint'").first?["value"]
            guard stored != (try searchFingerprint()) else { return }
        }
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
            WHERE s.state != 'trashed'
            GROUP BY s.id
            """)
            try db.execute("INSERT INTO search_index(kind, ref_id, title, body) SELECT 'claim', id, statement, statement FROM claims")
            try db.execute("INSERT INTO search_index(kind, ref_id, title, body) SELECT 'action', id, title, note FROM actions")
            try db.execute("INSERT INTO search_index(kind, ref_id, title, body) SELECT 'topic', id, title, title FROM reflection_questions")
            try db.execute("INSERT OR REPLACE INTO search_index_meta(key, value) VALUES('fingerprint', ?)", [fingerprint])
            try db.execute("DELETE FROM search_index_meta WHERE key='dirty'")
        }
    }

    private func searchFingerprint() throws -> String {
        var parts: [String] = []
        for table in ["sources", "claims", "actions", "transcript_versions", "reflection_questions"] {
            let row = try db.query("SELECT COUNT(*) AS count, COALESCE(MAX(created_at), '') AS latest FROM \(table)").first!
            var part = "\(row["count"]!):\(row["latest"]!)"
            // Topic renames update the row in place and no dirty trigger covers that
            // table, so updated_at carries those changes into the fingerprint.
            if table == "reflection_questions" {
                let updated = try db.query("SELECT COALESCE(MAX(updated_at), '') AS latest FROM reflection_questions").first!["latest"]!
                part += ":" + updated
            }
            parts.append(part)
        }
        return parts.joined(separator: "|")
    }
}
