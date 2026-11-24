import Foundation

public struct SearchHit: Sendable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
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

public struct SearchKindResult: Sendable {
    public let hits: [SearchHit]
    public let total: Int
    public init(hits: [SearchHit] = [], total: Int = 0) {
        self.hits = hits
        self.total = total
    }
    static let empty = SearchKindResult()
}

public struct SearchAllResult: Sendable {
    public let sections: [SearchHit.Kind: SearchKindResult]
    public init(sections: [SearchHit.Kind: SearchKindResult]) { self.sections = sections }
    public subscript(kind: SearchHit.Kind) -> SearchKindResult { sections[kind] ?? .empty }
    public func hits(for kind: SearchHit.Kind) -> [SearchHit] { self[kind].hits }
    public func total(for kind: SearchHit.Kind) -> Int { self[kind].total }
    static let empty = SearchAllResult(sections: Dictionary(uniqueKeysWithValues: SearchHit.Kind.allCases.map { ($0, .empty) }))
}

private struct RankedSearchRow {
    let kind: SearchHit.Kind
    let hit: SearchHit
}

/// A query split into tokens the trigram index can drive and tokens that can
/// only filter its candidates. CJK text is indexed with a space between every
/// pair of adjacent characters, so a two-character Chinese token becomes a
/// three-character phrase and matches the trigram index instead of forcing a
/// LIKE scan of every transcript.
private struct SearchTokens {
    let drivable: [String]
    let filters: [String]
    var isEmpty: Bool { drivable.isEmpty && filters.isEmpty }
    var matchExpression: String {
        drivable.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: " ")
    }
    var filterClause: String { filterClause(qualifyingWith: "") }
    func filterClause(qualifyingWith qualifier: String) -> String {
        filters.map { _ in "(instr(\(qualifier)title, ?) > 0 OR instr(\(qualifier)body, ?) > 0)" }.joined(separator: " AND ")
    }
    var filterBinds: [String] { filters.flatMap { [$0, $0] } }
}

extension VoiceOSStore {
    public func search(query: String, limit: Int = 50) throws -> [SearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, limit > 0 else { return [] }
        try prepareSearchIndexForQuery()
        let tokens = searchTokens(from: trimmed)
        return try rankedSearchRows(tokens).prefix(limit).map(\.hit)
    }

    public func searchAll(query: String, perKindLimit: Int) throws -> SearchAllResult {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, perKindLimit > 0 else { return .empty }
        try prepareSearchIndexForQuery()
        let rows = try rankedSearchRows(searchTokens(from: trimmed))
        var hits: [SearchHit.Kind: [SearchHit]] = [:]
        var totals: [SearchHit.Kind: Int] = [:]
        for row in rows {
            totals[row.kind, default: 0] += 1
            if hits[row.kind, default: []].count < perKindLimit { hits[row.kind, default: []].append(row.hit) }
        }
        return SearchAllResult(sections: Dictionary(uniqueKeysWithValues: SearchHit.Kind.allCases.map { kind in
            (kind, SearchKindResult(hits: hits[kind] ?? [], total: totals[kind] ?? 0))
        }))
    }

    private func rankedSearchRows(_ tokens: SearchTokens) throws -> [RankedSearchRow] {
        guard !tokens.isEmpty else { return [] }
        if tokens.drivable.isEmpty { return try substringSearchRows(tokens) }
        return try trigramSearchRows(tokens)
    }

    private func trigramSearchRows(_ tokens: SearchTokens) throws -> [RankedSearchRow] {
        let filters = tokens.filterClause.isEmpty ? "" : " AND " + tokens.filterClause
        // bm25 and snippet must stay in the CTE that uses MATCH. A recent edit
        // takes a 5 percent better score, which is scale-invariant and small
        // enough that relevance still leads; it only breaks near-ties.
        return try db.query("""
        WITH ranked AS (
          SELECT kind, ref_id, title,
                 COALESCE(NULLIF(snippet(search_index, 3, '', '', '…', 24), ''), title) AS snippet,
                 bm25(search_index) AS score
          FROM search_index
          WHERE search_index MATCH ?\(filters)
        )
        SELECT ranked.kind, ranked.ref_id, ranked.title, ranked.snippet
        FROM ranked
        LEFT JOIN sources src ON ranked.kind='material' AND src.id=ranked.ref_id
        LEFT JOIN claims cl ON ranked.kind='claim' AND cl.id=ranked.ref_id
        LEFT JOIN claim_reviews cr ON ranked.kind='claim' AND cr.claim_id=ranked.ref_id AND cr.version=cl.review_version
        LEFT JOIN actions ac ON ranked.kind='action' AND ac.id=ranked.ref_id
        LEFT JOIN reflection_questions rq ON ranked.kind='topic' AND rq.id=ranked.ref_id
        WHERE (ranked.kind!='claim' OR (cl.validity='current' AND COALESCE(cr.decision,'pending')!='rejected'))
          AND (ranked.kind!='action' OR ac.removed=0)
        ORDER BY CASE WHEN julianday(COALESCE(src.created_at, cl.created_at, ac.created_at, rq.updated_at)) >= julianday('now', '-30 days') THEN ranked.score * 1.05 ELSE ranked.score END,
                 ranked.ref_id
        """, [tokens.matchExpression] + tokens.filterBinds).map(decodeSearchRow)
    }

    private func substringSearchRows(_ tokens: SearchTokens) throws -> [RankedSearchRow] {
        guard let first = tokens.filters.first else { return [] }
        var binds: [String] = [first, first]
        binds.append(contentsOf: tokens.filterBinds)
        binds.append(first)
        return try db.query("""
        SELECT s.kind, s.ref_id, s.title,
               COALESCE(NULLIF(CASE WHEN instr(s.body, ?) > 0 THEN substr(s.body, MAX(1, instr(s.body, ?) - 20), 60) ELSE '' END, ''), s.title) AS snippet
        FROM search_index s
        LEFT JOIN sources src ON s.kind='material' AND src.id=s.ref_id
        LEFT JOIN claims cl ON s.kind='claim' AND cl.id=s.ref_id
        LEFT JOIN claim_reviews cr ON s.kind='claim' AND cr.claim_id=s.ref_id AND cr.version=cl.review_version
        LEFT JOIN actions ac ON s.kind='action' AND ac.id=s.ref_id
        LEFT JOIN reflection_questions rq ON s.kind='topic' AND rq.id=s.ref_id
        WHERE \(tokens.filterClause(qualifyingWith: "s."))
          AND (s.kind!='claim' OR (cl.validity='current' AND COALESCE(cr.decision,'pending')!='rejected'))
          AND (s.kind!='action' OR ac.removed=0)
        ORDER BY CASE WHEN instr(s.title, ?) > 0 THEN 0 ELSE 1 END,
                 julianday(COALESCE(src.created_at, cl.created_at, ac.created_at, rq.updated_at)) DESC,
                 s.ref_id
        """, binds).map(decodeSearchRow)
    }

    private func searchTokens(from query: String) -> SearchTokens {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init).prefix(8)
        var drivable: [String] = []
        var filters: [String] = []
        for word in words {
            let spaced = searchSpaced(word)
            if spaced.count >= 3 { drivable.append(spaced) } else { filters.append(spaced) }
        }
        return SearchTokens(drivable: drivable, filters: filters)
    }

    private var searchIndexShape: String { "cjk-spaced-v6-reviewed-claims-" + TimeZone.current.identifier }

    private func searchSpaced(_ text: String) -> String {
        var result = ""
        var previous: Character?
        for character in text {
            if let previous, isCJK(previous), isCJK(character) { result.append(" ") }
            result.append(character)
            previous = character
        }
        return result
    }

    private func searchUnspaced(_ text: String) -> String {
        let characters = Array(text)
        guard characters.count > 2 else { return text }
        var result = ""
        result.reserveCapacity(characters.count)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == " ", index > 0, index + 1 < characters.count,
               isCJK(characters[index - 1]), isCJK(characters[index + 1]) {
                index += 1
                continue
            }
            result.append(character)
            index += 1
        }
        return result
    }

    private func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F: return true
            default: return false
            }
        }
    }

    private func decodeSearchRow(_ row: [String: String]) throws -> RankedSearchRow {
        guard let kind = row["kind"].flatMap(SearchHit.Kind.init(rawValue:)), let refID = row["ref_id"], let rawTitle = row["title"] else {
            throw VoiceOSError("检索结果损坏")
        }
        let title = searchUnspaced(rawTitle)
        let snippet = searchUnspaced(row["snippet"] ?? "")
        return RankedSearchRow(kind: kind, hit: SearchHit(kind: kind, refID: refID, title: title, snippet: snippet.isEmpty ? title : snippet))
    }

    public func rebuildSearchIndexIfNeeded() throws {
        guard try searchIndexNeedsRebuild() else { return }
        try rebuildSearchIndex()
    }

    private func searchIndexNeedsRebuild() throws -> Bool {
        if try db.query("SELECT value FROM search_index_meta WHERE key='dirty'").first?["value"] == "1" { return true }
        if try db.query("SELECT value FROM search_index_meta WHERE key='shape'").first?["value"] != searchIndexShape { return true }
        let stored = try db.query("SELECT value FROM search_index_meta WHERE key='fingerprint'").first?["value"]
        return stored != (try searchFingerprint())
    }

    private func prepareSearchIndexForQuery() throws {
        guard try searchIndexNeedsRebuild() else { return }
        do { try rebuildSearchIndex() }
        catch {
            try? scheduleSearchIndexRebuildIfNeeded()
            throw error
        }
    }

    private func scheduleSearchIndexRebuildIfNeeded() throws {
        guard try searchIndexNeedsRebuild() else { return }
        if try db.query("SELECT value FROM search_index_meta WHERE key='rebuild_pending'").first?["value"] == "1" { return }
        try db.execute("INSERT OR REPLACE INTO search_index_meta(key, value) VALUES('rebuild_pending', '1')")
        Task { [weak self] in await self?.rebuildSearchIndexAfterTyping() }
    }

    private func rebuildSearchIndexAfterTyping() async {
        try? await Task.sleep(for: .milliseconds(200))
        finishScheduledSearchRebuild()
    }

    private func finishScheduledSearchRebuild() {
        defer { try? db.execute("DELETE FROM search_index_meta WHERE key='rebuild_pending'") }
        do { try rebuildSearchIndexIfNeeded() }
        catch { NSLog("VoiceOS 搜索索引重建失败：\(error.localizedDescription)") }
    }

    public func rebuildSearchIndex() throws {
        let fingerprint = try searchFingerprint()
        // Titles come from the same funnel as the library row, decoded from these
        // rows instead of loading every source and transcript twice. One row per
        // transcript keeps each job's text; grouping below picks the version the
        // saved presentation names.
        let materials = try db.query("""
        SELECT s.id AS id, s.name AS stored_name, s.kind AS kind, s.created_at AS created_at,
               s.timezone AS timezone, s.presentation_json AS presentation_json, s.state AS state,
               t.current_version_id AS transcript_version_id, v.text AS transcript_text
        FROM sources s
        LEFT JOIN transcripts t ON t.source_id = s.id
        LEFT JOIN transcript_versions v ON v.id = t.current_version_id
        WHERE s.state != 'trashed'
        ORDER BY s.id, t.rowid
        """)
        struct MaterialGroup {
            let row: [String: String]
            var transcripts: [(versionID: String?, text: String?)]
        }
        func decodePresentation(_ row: [String: String]) -> RecordingPresentation? {
            row["presentation_json"].flatMap {
                try? JSONDecoder().decode(RecordingPresentation.self, from: Data($0.utf8))
            }
        }
        var groups: [MaterialGroup] = []
        for row in materials {
            let transcript = (versionID: row["transcript_version_id"], text: row["transcript_text"])
            if let last = groups.last, last.row["id"] == row["id"] {
                groups[groups.count - 1].transcripts.append(transcript)
            } else {
                groups.append(MaterialGroup(row: row, transcripts: [transcript]))
            }
        }
        var memberIDs: Set<String> = []
        for group in groups {
            guard let expression = decodePresentation(group.row)?.expression,
                  expression.sourceIDs.count > 1 else { continue }
            memberIDs.formUnion(expression.sourceIDs)
        }
        // The same member and permission check the library list runs, loaded only
        // for members of a saved multi-part expression.
        let catalog: [String: SourceRecord] = memberIDs.isEmpty ? [:] : Dictionary(
            try sourceRecords(ids: Array(memberIDs)).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        let claims = try db.query("""
            SELECT c.id, COALESCE(r.statement, c.statement) AS title
            FROM claims c LEFT JOIN claim_reviews r ON r.claim_id=c.id AND r.version=c.review_version
            WHERE c.validity='current' AND COALESCE(r.decision, 'pending') != 'rejected'
            """)
        let actions = try db.query("SELECT id, COALESCE(edited_title,title) AS title, COALESCE(edited_note,note) AS body FROM actions WHERE removed=0")
        let topics = try db.query("SELECT id, title, title AS body FROM reflection_questions")
        // 首页显示的是笔记标题；把每个表达最新一版的标题、导语与正文并入材料
        // 条目的搜索正文，否则按屏幕上看到的标题搜不到东西。
        let noteTexts: [String: String] = {
            guard let rows = try? db.query("""
                SELECT m.expression_key AS expression_key, m.note_json AS note_json
                FROM material_notes m
                WHERE m.rowid = (SELECT rowid FROM material_notes
                                 WHERE expression_key = m.expression_key
                                 ORDER BY created_at DESC, rowid DESC LIMIT 1)
                """) else { return [:] }
            var map: [String: String] = [:]
            for row in rows {
                guard let key = row["expression_key"], let json = row["note_json"],
                      let note = try? JSONDecoder().decode(MaterialNote.self, from: Data(json.utf8)) else { continue }
                map[key] = note.searchableText
            }
            return map
        }()
        let searchableSourceIDs = Set(groups.compactMap { $0.row["id"] })
        try db.transaction {
            try db.execute("DELETE FROM search_index")
            for group in groups {
                let row = group.row
                guard let id = row["id"] else { continue }
                let presentation = decodePresentation(row)
                var groupTitle: String?
                if let expression = presentation?.expression,
                   expression.sourceIDs.count > 1,
                   let source = catalog[id],
                   let valid = source.recordingExpression(in: catalog) {
                    groupTitle = valid.leadingDisplayTitle
                }
                // The stored name stays in the body so a file name or ISO
                // timestamp still finds the material after a rename.
                let storedName = row["stored_name"] ?? ""
                let body = group.transcripts.compactMap { $0.text }.joined(separator: " ")
                // 笔记按表达成员集键控；成员口径与笔记生成一致（本人各段在前，
                // 配对的外部来源按 sourceID 排序随后）。
                let memberIDs: [String]
                if let expression = presentation?.expression, !expression.sourceIDs.isEmpty {
                    let external = (expression.externalVersions ?? [:]).keys.sorted()
                    memberIDs = expression.sourceIDs + external.filter { !expression.sourceIDs.contains($0) }
                } else { memberIDs = [id] }
                let noteText = memberIDs.allSatisfy(searchableSourceIDs.contains)
                    ? noteTexts[Self.materialNoteExpressionKey(memberIDs)] : nil
                var selected = group.transcripts.last
                if let version = presentation?.transcriptVersionID,
                   let match = group.transcripts.last(where: { $0.versionID == version }) {
                    selected = match
                }
                // sources() exposes a transcript only for saved and reference-only
                // materials, so the title reads the same text the library row shows.
                var titleTranscript = ["saved", "reference_only"].contains(row["state"] ?? "") ? selected?.text : nil
                if titleTranscript?.isEmpty == true { titleTranscript = nil }
                let title = groupTitle ?? MaterialDisplayTitle.title(
                    name: storedName, kind: row["kind"] ?? "", createdAt: row["created_at"] ?? "",
                    timeZone: row["timezone"] ?? TimeZone.current.identifier,
                    presentation: presentation, transcript: titleTranscript,
                    transcriptVersionID: selected?.versionID)
                let indexTitle = MaterialNaming.displayName(MarkdownDocument.plainTitle(title))
                try db.execute("INSERT INTO search_index(kind, ref_id, title, body) VALUES('material', ?, ?, ?)",
                               [id, searchSpaced(indexTitle), searchSpaced(storedName + " " + body + " " + (noteText ?? ""))])
            }
            for row in claims {
                try db.execute("INSERT INTO search_index(kind, ref_id, title, body) VALUES('claim', ?, ?, ?)",
                               [row["id"], searchSpaced(row["title"] ?? ""), searchSpaced(row["title"] ?? "")])
            }
            for row in actions {
                try db.execute("INSERT INTO search_index(kind, ref_id, title, body) VALUES('action', ?, ?, ?)",
                               [row["id"], searchSpaced(row["title"] ?? ""), searchSpaced(row["body"] ?? "")])
            }
            for row in topics {
                try db.execute("INSERT INTO search_index(kind, ref_id, title, body) VALUES('topic', ?, ?, ?)",
                               [row["id"], searchSpaced(row["title"] ?? ""), searchSpaced(row["body"] ?? "")])
            }
            try db.execute("INSERT OR REPLACE INTO search_index_meta(key, value) VALUES('fingerprint', ?)", [fingerprint])
            try db.execute("INSERT OR REPLACE INTO search_index_meta(key, value) VALUES('shape', ?)", [searchIndexShape])
            try db.execute("DELETE FROM search_index_meta WHERE key='dirty'")
        }
    }

    private func searchFingerprint() throws -> String {
        var parts: [String] = []
        for table in ["sources", "claims", "claim_reviews", "actions", "transcript_versions", "reflection_questions", "material_notes"] {
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
