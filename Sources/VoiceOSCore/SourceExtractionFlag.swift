import Foundation

/// A material can pass a complete organize run and still yield no attributable
/// viewpoint. That is a legitimate result, not a failure, so it gets no automatic
/// retry; it must stay visible when the expression-wide claim union would otherwise
/// read as "organized".
public enum SourceExtractionFlag: String, Codable, Sendable {
    case empty
    case acknowledged
}

/// The facts one material contributes to the empty-extraction decision.
/// `referenceCount` counts the claims of the latest completed organize attempt
/// that cite this material; `expressionState` is nil when the material belongs
/// to no recording expression.
public struct SourceExtractionFacts: Sendable, Equatable {
    public let origin: String
    public let speaker: String
    public let transcript: String?
    public let expressionState: String?
    public let referenceCount: Int
    public init(origin: String, speaker: String, transcript: String?, expressionState: String?, referenceCount: Int) {
        self.origin = origin; self.speaker = speaker; self.transcript = transcript
        self.expressionState = expressionState; self.referenceCount = referenceCount
    }
}

extension VoiceOSStore {
    /// Silence and external programme audio legitimately carry no viewpoint, so
    /// zero extraction never counts as a failed organize. Only the user's own
    /// substantive material, in a settled expression, with nothing attributed
    /// to it, becomes the visible `empty` state.
    public static func indicatesEmptyExtraction(_ facts: SourceExtractionFacts) -> Bool {
        guard facts.origin == "user", facts.speaker == "user" else { return false }
        let substantive = (facts.transcript ?? "").unicodeScalars.reduce(0) {
            CharacterSet.whitespacesAndNewlines.contains($1) ? $0 : $0 + 1
        }
        guard substantive >= 200 else { return false }
        guard facts.expressionState == nil || facts.expressionState == "completed" else { return false }
        return facts.referenceCount == 0
    }

    public func sourceExtractionFlags() throws -> [String: SourceExtractionFlag] {
        var flags: [String: SourceExtractionFlag] = [:]
        for row in try db.query("SELECT source_id,state FROM source_extraction_flags") {
            guard let id = row["source_id"], let state = row["state"].flatMap(SourceExtractionFlag.init(rawValue:)) else { continue }
            flags[id] = state
        }
        return flags
    }

    public func sourceExtractionFlag(sourceID: String) throws -> SourceExtractionFlag? {
        try db.query("SELECT state FROM source_extraction_flags WHERE source_id=?", [sourceID]).first?["state"].flatMap(SourceExtractionFlag.init(rawValue:))
    }

    /// `acknowledged` only follows `empty`: the user saw the zero-extraction
    /// result and accepted it. Any other transition is a no-op, so a racing
    /// re-organize cannot be acknowledged before it is detected.
    public func acknowledgeEmptyExtraction(sourceID: String) throws {
        guard try sourceExtractionFlag(sourceID: sourceID) == .empty else { return }
        try db.execute("UPDATE source_extraction_flags SET state='acknowledged',updated_at=? WHERE source_id=?", [Self.now(), sourceID])
    }

    /// Runs after a successful organize import, and again when an expression
    /// settles. An existing row is never rewritten: the user's acknowledgement
    /// outlives later zero-extraction runs, and an unresolved `empty` stays put.
    /// A material that now has references is resolved and loses the row.
    func evaluateSourceExtractionFlags(sourceIDs: Set<String>) throws {
        guard !sourceIDs.isEmpty else { return }
        let catalog = Dictionary(try sources().filter { sourceIDs.contains($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let existing = try sourceExtractionFlags()
        for id in sourceIDs.sorted() {
            guard let source = catalog[id] else { continue }
            let facts = SourceExtractionFacts(origin: source.origin, speaker: source.speaker, transcript: source.transcript,
                                               expressionState: source.presentation?.expression?.state,
                                               referenceCount: try organizedReferenceCount(sourceID: id))
            if Self.indicatesEmptyExtraction(facts) {
                guard existing[id] == nil else { continue }
                let now = Self.now()
                try db.execute("INSERT INTO source_extraction_flags(source_id,state,detected_at,updated_at) VALUES(?,'empty',?,?)", [id, now, now])
            } else if existing[id] != nil {
                try db.execute("DELETE FROM source_extraction_flags WHERE source_id=?", [id])
            }
        }
    }

    /// The organize output is immutable per attempt; counting its claims by
    /// citation is the persisted fact about what this material contributed.
    func organizedReferenceCount(sourceID: String) throws -> Int {
        guard let attempt = try db.query("""
            SELECT a.id FROM model_attempts a JOIN context_inputs i ON i.context_id=a.context_id
            WHERE i.source_id=? AND a.provider='organized_import' AND a.state='completed'
            ORDER BY a.producer_sequence DESC,a.created_at DESC,a.id DESC LIMIT 1
            """, [sourceID]).first?["id"] else { return 0 }
        var count = 0
        for row in try db.query("SELECT refs_json FROM claims WHERE attempt_id=?", [attempt]) {
            guard let json = row["refs_json"], let references = try? JSONDecoder().decode([ClaimReference].self, from: Data(json.utf8)) else { continue }
            if references.contains(where: { $0.sourceID == sourceID }) { count += 1 }
        }
        return count
    }
}
