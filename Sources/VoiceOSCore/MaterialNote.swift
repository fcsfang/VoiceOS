import Foundation

/// A first-person, article-shaped note distilled from one expression's member
/// sources. Paragraphs keep the quotes they were grounded in; a missing span
/// ID records an anchor that could not be located, while a missing transcript
/// version records an anchor whose version was not known at generation time.
public struct MaterialNote: Codable, Sendable, Equatable {
    public struct Paragraph: Codable, Sendable, Equatable {
        public let text: String
        public let anchors: [Anchor]
        public init(text: String, anchors: [Anchor] = []) {
            self.text = text
            self.anchors = anchors
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
    static func materialNoteExpressionKey(_ memberSourceIDs: [String]) -> String {
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

    /// The newest revision for the member set; empty members have no note.
    public func latestMaterialNote(memberSourceIDs: [String]) throws -> StoredMaterialNote? {
        guard !memberSourceIDs.isEmpty else { return nil }
        let expressionKey = Self.materialNoteExpressionKey(memberSourceIDs)
        guard let row = try db.query("SELECT * FROM material_notes WHERE expression_key=? ORDER BY created_at DESC, rowid DESC LIMIT 1", [expressionKey]).first else { return nil }
        return try Self.storedMaterialNote(row)
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