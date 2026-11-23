import Foundation

/// A first-person, article-shaped note distilled from one expression's member
/// sources. Paragraphs keep the quotes they were grounded in; a missing span
/// ID records an anchor that could not be located, while a missing transcript
/// version records an anchor whose version was not known at generation time.
public struct MaterialNote: Codable, Sendable, Equatable {
    public struct Paragraph: Codable, Sendable, Equatable {
        public let text: String
        public let anchors: [Anchor]
        /// 段落包含整理时补充的关联（不是材料明说的意思），阅读界面可轻标。
        public let inferred: Bool?
        public init(text: String, anchors: [Anchor] = [], inferred: Bool? = nil) {
            self.text = text
            self.anchors = anchors
            self.inferred = inferred
        }
    }
    public struct Anchor: Codable, Sendable, Equatable {
        public let quote: String
        public let sourceID: String
        public let transcriptVersionID: String?
        public let spanID: String?
        public init(quote: String, sourceID: String, transcriptVersionID: String? = nil, spanID: String? = nil) {
            self.quote = quote
            self.sourceID = sourceID
            self.transcriptVersionID = transcriptVersionID
            self.spanID = spanID
        }
    }
    public struct Section: Codable, Sendable, Equatable {
        public let heading: String?
        public let paragraphs: [Paragraph]
        public init(heading: String? = nil, paragraphs: [Paragraph]) {
            self.heading = heading
            self.paragraphs = paragraphs
        }
    }
    public let title: String
    public let lead: String?
    public let sections: [Section]
    public init(title: String, lead: String? = nil, sections: [Section]) {
        self.title = title
        self.lead = lead
        self.sections = sections
    }
}

/// One saved revision. Saves are append-only: `expressionKey` identifies the
/// member set and `createdAt` (with rowid as tie-breaker) picks the latest.
public struct StoredMaterialNote: Sendable, Equatable {
    public let id: String
    public let expressionKey: String
    public let note: MaterialNote
    public let transcriptVersions: [String: String]
    public let modelIdentity: String?
    public let createdAt: String
}

extension VoiceOSStore {
    /// Canonical member-set identity: sorted, de-duplicated source IDs joined by `|`.
    /// Views that only hold a source ID use it to look the same note up in batch.
    public static func materialNoteExpressionKey(_ memberSourceIDs: [String]) -> String {
        Set(memberSourceIDs).sorted().joined(separator: "|")
    }

    /// Appends a new revision; earlier revisions stay queryable as history.
    @discardableResult
    public func saveMaterialNote(memberSourceIDs: [String], note: MaterialNote, transcriptVersions: [String: String], modelIdentity: String?) throws -> StoredMaterialNote {
        let id = UUID().uuidString
        let expressionKey = Self.materialNoteExpressionKey(memberSourceIDs)
        let createdAt = Self.now()
        try db.execute("INSERT INTO material_notes(id,expression_key,transcript_versions_json,model_identity,created_at,note_json) VALUES(?,?,?,?,?,?)",
                       [id, expressionKey, try Self.relevanceJSON(transcriptVersions), modelIdentity, createdAt, try Self.relevanceJSON(note)])
        return StoredMaterialNote(id: id, expressionKey: expressionKey, note: note, transcriptVersions: transcriptVersions, modelIdentity: modelIdentity, createdAt: createdAt)
    }

    /// Appends a new revision only while every expected member still matches
    /// the library. The snapshot comparison and the insert run in one actor
    /// turn, so a transcript or permission change cannot land in between.
    @discardableResult
    public func saveMaterialNote(memberSourceIDs: [String], note: MaterialNote, transcriptVersions: [String: String], modelIdentity: String?, ifMembersStillMatch expected: [MaterialNoteMemberSnapshot]) throws -> StoredMaterialNote? {
        let catalog = Dictionary(try sources().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard expected.allSatisfy({ $0.matches(catalog[$0.sourceID]) }) else { return nil }
        return try saveMaterialNote(memberSourceIDs: memberSourceIDs, note: note,
                                    transcriptVersions: transcriptVersions, modelIdentity: modelIdentity)
    }

    /// The newest revision for the member set; empty members have no note.
    public func latestMaterialNote(memberSourceIDs: [String]) throws -> StoredMaterialNote? {
        guard !memberSourceIDs.isEmpty else { return nil }
        let expressionKey = Self.materialNoteExpressionKey(memberSourceIDs)
        guard let row = try db.query("SELECT * FROM material_notes WHERE expression_key=? ORDER BY created_at DESC, rowid DESC LIMIT 1", [expressionKey]).first else { return nil }
        return try Self.storedMaterialNote(row)
    }

    /// The newest revision for each expression key, in one query. Keys with no
    /// saved note are absent; an empty input reads nothing. History is
    /// append-only, so each key's latest row is picked in SQL: the correlated
    /// subquery walks the (expression_key, created_at) index and reads exactly
    /// one row per key instead of materializing every revision's note_json.
    public func latestMaterialNotes(expressionKeys: [String]) throws -> [String: StoredMaterialNote] {
        let keys = Set(expressionKeys)
        guard !keys.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: keys.count).joined(separator: ",")
        let rows = try db.query(
            """
            SELECT * FROM material_notes m
            WHERE m.expression_key IN (\(placeholders))
              AND m.rowid = (SELECT rowid FROM material_notes
                             WHERE expression_key = m.expression_key
                             ORDER BY created_at DESC, rowid DESC LIMIT 1)
            """,
            keys.sorted().map { $0 as String? })
        var latest: [String: StoredMaterialNote] = [:]
        for row in rows {
            guard let key = row["expression_key"], latest[key] == nil else { continue }
            // 单条损坏只让该表达的标题/预览回退，不能拖垮其余笔记。
            if let stored = try? Self.storedMaterialNote(row) { latest[key] = stored }
        }
        return latest
    }

    /// 最近更新的笔记：每个表达取最新一版，按保存时间倒序。首页「最近笔记」
    /// 用它——旧录音今天才整理出的笔记，也能凭整理时间浮现，而不是按录音日期。
    public func recentMaterialNotes(limit: Int = 8) throws -> [StoredMaterialNote] {
        guard limit > 0 else { return [] }
        let rows = try db.query(
            """
            SELECT * FROM material_notes m
            WHERE m.rowid = (SELECT rowid FROM material_notes
                             WHERE expression_key = m.expression_key
                             ORDER BY created_at DESC, rowid DESC LIMIT 1)
            ORDER BY m.created_at DESC, m.rowid DESC LIMIT ?
            """,
            [String(limit)])
        return rows.compactMap { try? Self.storedMaterialNote($0) }
    }

    /// Current only while every member's transcript version still matches the
    /// version recorded at save time; a member missing from the current library
    /// invalidates the note.
    public func materialNoteIsCurrent(_ stored: StoredMaterialNote, currentTranscriptVersions: [String: String]) -> Bool {
        stored.transcriptVersions.allSatisfy { currentTranscriptVersions[$0.key] == $0.value }
    }

    private static func storedMaterialNote(_ row: [String: String]) throws -> StoredMaterialNote {
        guard let id = row["id"], let expressionKey = row["expression_key"], let createdAt = row["created_at"],
              let versionsJSON = row["transcript_versions_json"], let noteJSON = row["note_json"] else {
            throw VoiceOSError("笔记记录损坏")
        }
        return StoredMaterialNote(id: id, expressionKey: expressionKey,
                                  note: try JSONDecoder().decode(MaterialNote.self, from: Data(noteJSON.utf8)),
                                  transcriptVersions: try JSONDecoder().decode([String: String].self, from: Data(versionsJSON.utf8)),
                                  modelIdentity: row["model_identity"], createdAt: createdAt)
    }
}