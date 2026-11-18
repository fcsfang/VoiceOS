import Foundation
import NaturalLanguage

public enum SourceEntityKind: String, Codable, Sendable, CaseIterable, Equatable, Hashable { case person, organization, term }

public struct SourceEntity: Identifiable, Sendable, Equatable {
    public var id: String { sourceID + ":" + name }
    public let sourceID: String
    public let name: String
    public let kind: SourceEntityKind
    public let sentenceIDs: [String]
    public let mentionCount: Int
    public init(sourceID: String, name: String, kind: SourceEntityKind, sentenceIDs: [String], mentionCount: Int) {
        self.sourceID = sourceID; self.name = name; self.kind = kind; self.sentenceIDs = sentenceIDs; self.mentionCount = mentionCount
    }
}

extension VoiceOSStore {
    private static let maxTaggedCandidates = 64
    private static let maxTermCandidates = 20
    private static let maxSentenceIDs = 3

    public func entities(sourceID: String) throws -> [SourceEntity] {
        try db.query("SELECT * FROM source_entities WHERE source_id=? ORDER BY mention_count DESC,name", [sourceID]).map { row in
            guard let name = row["name"], let kind = row["kind"].flatMap(SourceEntityKind.init(rawValue:)),
                  let sentenceJSON = row["sentence_ids"], let mentionCount = row["mention_count"].flatMap(Int.init) else {
                throw VoiceOSError("实体记录损坏")
            }
            return SourceEntity(sourceID: sourceID, name: name, kind: kind, sentenceIDs: try JSONDecoder().decode([String].self, from: Data(sentenceJSON.utf8)), mentionCount: mentionCount)
        }
    }

    public func replaceEntities(sourceID: String, entries: [SourceEntity]) throws {
        guard try db.query("SELECT id FROM sources WHERE id=?", [sourceID]).first != nil else { throw VoiceOSError("来源不存在") }
        var names = Set<String>()
        let prepared = try entries.map { entry -> (String, String, String, Int) in
            let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.unicodeScalars.count <= 200 else { throw VoiceOSError("实体名称需为 1 到 200 字") }
            guard names.insert(name).inserted else { throw VoiceOSError("实体名称重复") }
            guard entry.mentionCount >= 0 else { throw VoiceOSError("实体出现次数不能为负") }
            return (name, entry.kind.rawValue, String(decoding: try JSONEncoder().encode(entry.sentenceIDs), as: UTF8.self), entry.mentionCount)
        }
        try db.transaction {
            try db.execute("DELETE FROM source_entities WHERE source_id=?", [sourceID])
            for entry in prepared {
                try db.execute("INSERT INTO source_entities(source_id,name,kind,sentence_ids,mention_count) VALUES(?,?,?,?,?)", [sourceID, entry.0, entry.1, entry.2, String(entry.3)])
            }
        }
    }

    @discardableResult
    public func refreshEntities(sourceID: String) throws -> [SourceEntity] {
        guard let source = try sources().first(where: { $0.id == sourceID }) else { throw VoiceOSError("来源不存在") }
        let statements = try statementTexts(sourceID: sourceID, transcriptVersionID: source.transcriptVersionID)
        let entries = Self.extractedEntities(sourceID: sourceID, transcript: source.transcript ?? "", spans: source.spans, statements: statements)
        try replaceEntities(sourceID: sourceID, entries: entries)
        return entries
    }

    private func statementTexts(sourceID: String, transcriptVersionID: String?) throws -> [String] {
        try db.query("SELECT statement,refs_json FROM claims WHERE validity='current' AND content_kind='statement' ORDER BY created_at,id").compactMap { row in
            guard let statement = row["statement"], let refs = row["refs_json"] else { return nil }
            let references = (try? JSONDecoder().decode([ClaimReference].self, from: Data(refs.utf8))) ?? []
            guard references.contains(where: { $0.sourceID == sourceID && (transcriptVersionID == nil || $0.transcriptVersionID == transcriptVersionID) }) else { return nil }
            return statement
        }
    }

    static func extractedEntities(sourceID: String, transcript: String, spans: [TranscriptSpan], statements: [String]) -> [SourceEntity] {
        let scalars = Array(transcript.unicodeScalars)
        let spanTexts = spans.map { span -> (String, String) in
            let start = min(max(span.textStart, 0), scalars.count), end = min(max(span.textEnd, start), scalars.count)
            return (span.id, String(String.UnicodeScalarView(scalars[start..<end])))
        }
        func sentenceIDs(_ name: String) -> [String] {
            var ids: [String] = []
            for (id, text) in spanTexts where text.contains(name) {
                ids.append(id)
                if ids.count == Self.maxSentenceIDs { break }
            }
            return ids
        }
        var entries: [String: SourceEntity] = [:]
        for (name, kind) in taggedNames(transcript).prefix(Self.maxTaggedCandidates) where entries[name] == nil {
            let count = occurrences(of: name, in: transcript)
            guard count > 0 else { continue }
            entries[name] = SourceEntity(sourceID: sourceID, name: name, kind: kind, sentenceIDs: sentenceIDs(name), mentionCount: count)
        }
        for (name, kind, count) in termCandidates(statements) where entries[name] == nil {
            entries[name] = SourceEntity(sourceID: sourceID, name: name, kind: kind, sentenceIDs: sentenceIDs(name), mentionCount: count)
        }
        return entries.values.sorted { $0.mentionCount == $1.mentionCount ? $0.name < $1.name : $0.mentionCount > $1.mentionCount }
    }

    static func taggedNames(_ text: String) -> [(String, SourceEntityKind)] {
        guard !text.isEmpty, NLTagger.availableTagSchemes(for: .word, language: .simplifiedChinese).contains(.nameType) else { return [] }
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var names: [(String, SourceEntityKind)] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            let name = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return true }
            if tag == .personalName { names.append((name, .person)) }
            else if tag == .organizationName { names.append((name, .organization)) }
            return true
        }
        return names
    }

    static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var range = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, range: range) {
            count += 1
            range = haystack.index(after: found.lowerBound)..<haystack.endIndex
        }
        return count
    }

    static func termCandidates(_ statements: [String]) -> [(name: String, kind: SourceEntityKind, count: Int)] {
        var counts: [String: (kind: SourceEntityKind, count: Int, order: Int)] = [:]
        var order = 0
        func add(_ name: String, _ kind: SourceEntityKind) {
            order += 1
            if var existing = counts[name] {
                existing.count += 1
                counts[name] = existing
            } else {
                counts[name] = (kind, 1, order)
            }
        }
        for statement in statements {
            for run in hanRuns(statement) {
                let characters = Array(run)
                guard characters.count >= 2 else { continue }
                for length in 2...min(12, characters.count) {
                    for start in 0...(characters.count - length) {
                        add(String(characters[start..<start + length]), .term)
                    }
                }
            }
            for word in latinWords(statement) { add(word, .term) }
        }
        let ranked = counts.filter { $0.value.count >= 2 }.map { (name: $0.key, kind: $0.value.kind, count: $0.value.count, order: $0.value.order) }.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            if $0.name.count != $1.name.count { return $0.name.count > $1.name.count }
            return $0.order < $1.order
        }
        var selected: [(String, SourceEntityKind, Int)] = []
        for candidate in ranked where selected.count < Self.maxTermCandidates {
            guard !selected.contains(where: { $0.0.contains(candidate.name) }) else { continue }
            selected.append((candidate.name, candidate.kind, candidate.count))
        }
        return selected
    }

    static func hanRuns(_ text: String) -> [String] {
        var runs: [String] = []
        var current = ""
        for character in text {
            if character.unicodeScalars.allSatisfy({ (0x4E00...0x9FFF).contains($0.value) }) {
                current.append(character)
            } else if !current.isEmpty {
                runs.append(current)
                current = ""
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    static func latinWords(_ text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "[A-Za-z][A-Za-z0-9_'-]*") else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]).lowercased() }
        }.filter { $0.count >= 2 }
    }
}
