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
    /// 归属与说话人（user/external/ai、user/unknown/assistant）。提示词据此
    /// 决定第一人称还是按角色转述；缺失时按「我」处理。
    public let origin: String?
    public let speaker: String?
    public init(sourceID: String, title: String, transcriptVersionID: String?, transcript: String, spans: [MaterialNoteSpan],
                origin: String? = nil, speaker: String? = nil) {
        self.sourceID = sourceID; self.title = title; self.transcriptVersionID = transcriptVersionID
        self.transcript = transcript; self.spans = spans
        self.origin = origin; self.speaker = speaker
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
    /// re-read against the source it came from. A quote that exists in the
    /// transcript but spans several timed spans keeps its anchor with a nil
    /// spanID; only quotes missing from the transcript entirely are dropped.
    public static func anchored(_ note: MaterialNote, members: [MaterialNoteMember]) -> MaterialNote {
        let bySource = Dictionary(members.map { ($0.sourceID, $0) }, uniquingKeysWith: { first, _ in first })
        let sections = note.sections.map { section in
            MaterialNote.Section(heading: section.heading, paragraphs: section.paragraphs.map { paragraph in
                // 同一段落内的锚点按叙述顺序推进：重复出现的短语优先选择上一个
                // 锚点之后、且上下文最接近的一次，而不是永远回到全篇最早一次。
                // 次序只在同一成员内有意义；切换到另一成员时重新从头算。
                var lastAnchor: (sourceID: String, index: Int)?
                let anchors = paragraph.anchors.compactMap { anchor -> MaterialNote.Anchor? in
                    guard let member = bySource[anchor.sourceID] else { return nil }
                    let needle = Self.normalized(anchor.quote)
                    guard !needle.isEmpty, Self.normalized(member.transcript).contains(needle) else { return nil }
                    let after = lastAnchor?.sourceID == anchor.sourceID ? (lastAnchor?.index ?? -1) : -1
                    let spanID = Self.resolveSpan(quote: anchor.quote, in: member,
                                                  paragraphText: paragraph.text, after: after)
                    if let spanID, let index = member.spans.firstIndex(where: { $0.id == spanID }) {
                        lastAnchor = (anchor.sourceID, index)
                    }
                    return MaterialNote.Anchor(quote: anchor.quote, sourceID: anchor.sourceID,
                                               transcriptVersionID: member.transcriptVersionID,
                                               spanID: spanID)
                }
                return MaterialNote.Paragraph(text: paragraph.text, anchors: anchors, inferred: paragraph.inferred,
                                              annotations: sanitizedAnnotations(paragraph.annotations, members: members),
                                              marks: sanitizedMarks(paragraph.marks, in: paragraph.text))
            })
        }
        return MaterialNote(title: note.title, lead: note.lead, sections: sections,
                            closing: sanitizedAnnotations(note.closing, members: members))
    }

    /// 行内标记必须逐字落在正文里；模型改写过的标记直接忽略，不破坏文字。
    private static func sanitizedMarks(_ marks: [MaterialNote.InlineMark]?, in text: String) -> [MaterialNote.InlineMark]? {
        guard let marks, !marks.isEmpty else { return nil }
        let kept = marks.filter { !$0.text.isEmpty && text.contains($0.text) }
        return kept.isEmpty ? nil : kept
    }

    /// 批注的引文只作定位：能在任一成员转写里逐字找到就保留，否则只清掉引文。
    /// 批注本体、类型、角色与理论出处一律不动。
    private static func sanitizedAnnotations(_ annotations: [MaterialNote.Annotation]?, members: [MaterialNoteMember]) -> [MaterialNote.Annotation]? {
        guard let annotations, !annotations.isEmpty else { return nil }
        let transcripts = members.map { normalized($0.transcript) }
        return annotations.map { annotation in
            guard let quote = annotation.quote, !quote.isEmpty else { return annotation }
            let needle = normalized(quote)
            guard !needle.isEmpty else { return annotation.clearingQuote() }
            return transcripts.contains { $0.contains(needle) } ? annotation : annotation.clearingQuote()
        }
    }

    /// 在成员的单个时间片里定位引文。多次出现时：先按段落内单调次序排除上一个
    /// 锚点之前的候选；仍有多个时，用段落上下文（去掉引文后的双字组）与各候选
    /// 时间片的重合度打分，同分取最早。全部候选都在上一个锚点之前时退回全量候选。
    private static func resolveSpan(quote: String, in member: MaterialNoteMember,
                                    paragraphText: String, after lastSpanIndex: Int) -> String? {
        let needle = normalized(quote)
        guard !needle.isEmpty else { return nil }
        let candidates = member.spans.enumerated().filter { normalized($0.element.text).contains(needle) }
        guard let first = candidates.first else { return nil }
        guard candidates.count > 1 else { return first.element.id }
        let forward = candidates.filter { $0.offset >= lastSpanIndex }
        let pool = forward.isEmpty ? candidates : forward
        guard pool.count > 1 else { return pool.first?.element.id }
        let context = Set(bigrams(normalized(paragraphText).replacingOccurrences(of: needle, with: "")))
        var best = pool[0]
        var bestScore = contextOverlap(Self.bigrams(normalized(best.element.text)), context)
        for candidate in pool.dropFirst() {
            let score = contextOverlap(Self.bigrams(normalized(candidate.element.text)), context)
            if score > bestScore { best = candidate; bestScore = score }
        }
        return best.element.id
    }

    private static func bigrams(_ text: String) -> Set<String> {
        let characters = Array(text)
        guard characters.count > 1 else { return [] }
        var grams: Set<String> = []
        for index in 0..<(characters.count - 1) {
            grams.insert(String(characters[index...(index + 1)]))
        }
        return grams
    }

    private static func contextOverlap(_ grams: Set<String>, _ context: Set<String>) -> Int {
        grams.intersection(context).count
    }

    private static func normalized(_ text: String) -> String {
        text.filter { !$0.isWhitespace }
    }
}
