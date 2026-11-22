import Foundation

public struct MaterialNoteSpan: Sendable {
    public let id: String
    public let startMS: Int?
    public let endMS: Int?
    public let text: String
    public init(id: String, startMS: Int? = nil, endMS: Int? = nil, text: String) {
        self.id = id; self.startMS = startMS; self.endMS = endMS; self.text = text
    }
}

public struct MaterialNoteMember: Sendable {
    public let sourceID: String
    public let title: String
    public let transcriptVersionID: String?
    public let transcript: String
    public let spans: [MaterialNoteSpan]
    public init(sourceID: String, title: String, transcriptVersionID: String?, transcript: String, spans: [MaterialNoteSpan]) {
        self.sourceID = sourceID; self.title = title; self.transcriptVersionID = transcriptVersionID
        self.transcript = transcript; self.spans = spans
    }
}

public struct MaterialNoteRequest: Sendable {
    public let members: [MaterialNoteMember]
    public let expressionDate: String?
    public init(members: [MaterialNoteMember], expressionDate: String? = nil) {
        self.members = members; self.expressionDate = expressionDate
    }
}

public struct MaterialNoteAttemptIdentity: Sendable, Equatable {
    public let provider: String
    public let model: String
    public let promptVersion: String
    public let schemaVersion: String
    public init(provider: String, model: String, promptVersion: String, schemaVersion: String) {
        self.provider = provider; self.model = model; self.promptVersion = promptVersion; self.schemaVersion = schemaVersion
    }
}

public protocol MaterialNotePort: Sendable {
    func writeNote(_ request: MaterialNoteRequest) async throws -> MaterialNote
    var identity: MaterialNoteAttemptIdentity { get }
}

public enum MaterialNoteAnchoring {
    /// Returns the first span whose text contains the quote, or nil when no
    /// single span holds it. Whitespace is ignored entirely because spans wrap
    /// lines and pad gaps differently from how a quote is copied; every other
    /// character must match verbatim.
    public static func anchor(quote: String, in member: MaterialNoteMember) -> String? {
        let needle = normalized(quote)
        guard !needle.isEmpty else { return nil }
        return member.spans.first { normalized($0.text).contains(needle) }?.id
    }

    /// Drops anchors naming a member outside this expression or a quote absent
    /// from that member's transcript, and records the member's transcript
    /// version and the matched span on the rest, so a saved note can be
    /// re-read against the source it came from.
    public static func anchored(_ note: MaterialNote, members: [MaterialNoteMember]) -> MaterialNote {
        let bySource = Dictionary(members.map { ($0.sourceID, $0) }, uniquingKeysWith: { first, _ in first })
        let sections = note.sections.map { section in
            MaterialNote.Section(heading: section.heading, paragraphs: section.paragraphs.map { paragraph in
                MaterialNote.Paragraph(text: paragraph.text, anchors: paragraph.anchors.compactMap { anchor in
                    guard let member = bySource[anchor.sourceID], let spanID = Self.anchor(quote: anchor.quote, in: member) else { return nil }
                    return MaterialNote.Anchor(quote: anchor.quote, sourceID: anchor.sourceID,
                                               transcriptVersionID: member.transcriptVersionID, spanID: spanID)
                })
            })
        }
        return MaterialNote(title: note.title, lead: note.lead, sections: sections)
    }

    private static func normalized(_ text: String) -> String {
        text.filter { !$0.isWhitespace }
    }
}
