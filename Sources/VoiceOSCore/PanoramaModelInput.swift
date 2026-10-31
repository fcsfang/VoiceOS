import Foundation

struct PanoramaModelInput {
    struct Payload: Encodable {
        let units: [Unit]
        let sources: [Source]
        let claims: [Claim]
    }
    struct Unit: Encodable {
        let id: String
        let sourceIDs: [String]
        let dependencyIDs: [String]
    }
    struct Source: Encodable {
        let sourceID: String
        let sourceVersionID: String
        let transcriptVersionID: String
        let title: String
        let occurredAt: String
        let origin: String
        let speaker: String
        let text: String
        let transcriptionReview: Review?
    }
    struct Claim: Encodable {
        let id: String
        let statement: String
        let ownership: String
        let references: [Reference]
    }
    struct Reference: Encodable {
        let sourceID: String
        let transcriptVersionID: String
        let start: Int
        let end: Int
    }
    struct Review: Encodable {
        let transcriptVersionID: String
        let corrections: [Correction]
        let unresolvedIssues: [Issue]
    }
    struct Correction: Encodable {
        let start: Int
        let end: Int
        let before: String
        let after: String
        let context_quote: String?
        let reason: String
        let independent_reason: String?
    }
    struct Issue: Encodable {
        let start: Int
        let end: Int
        let reason: String
    }
    private struct Identities {
        let aliases: [String: String]
        let originals: [String: String]

        init(_ values: [String], prefix: String) throws {
            var aliases: [String: String] = [:], originals: [String: String] = [:]
            for (index, value) in values.enumerated() {
                guard !value.isEmpty, aliases[value] == nil else { throw VoiceOSError("全景模型输入身份为空或重复") }
                let alias = prefix + String(index + 1)
                aliases[value] = alias
                originals[alias] = value
            }
            self.aliases = aliases
            self.originals = originals
        }

        func alias(_ value: String) throws -> String {
            guard let result = aliases[value] else { throw VoiceOSError("全景模型输入含未知引用身份") }
            return result
        }

        func original(_ value: String) throws -> String {
            guard let result = originals[value] else { throw VoiceOSError("全景模型返回未知引用身份") }
            return result
        }
    }
    private enum Direction { case toModel, toCanonical }
    let payload: Payload
    private let sources: Identities
    private let versions: Identities
    private let claims: Identities
    private let sourceVersions: [String: String]
    private let unitIdentities: Identities

    init(_ input: PanoramaInput) throws {
        let sources = try Identities(input.sources.map(\.id), prefix: "s")
        let versions = try Identities(input.sources.map { $0.transcript.transcriptVersionID }, prefix: "t")
        let claims = try Identities(input.claims.map(\.id), prefix: "c")
        let units = try Identities(input.units.map(\.id), prefix: "u")
        var sourceVersions: [String: String] = [:]
        var spans: [String: [String: TranscriptSpan]] = [:]
        for source in input.sources {
            sourceVersions[source.id] = source.transcript.transcriptVersionID
            var sourceSpans: [String: TranscriptSpan] = [:]
            let count = source.transcript.text.unicodeScalars.count
            for span in source.transcript.spans {
                guard sourceSpans[span.id] == nil, span.textStart >= 0, span.textEnd > span.textStart,
                      span.textEnd <= count else { throw VoiceOSError("全景模型输入片段身份或范围无效") }
                sourceSpans[span.id] = span
            }
            spans[source.id] = sourceSpans
        }
        func range(sourceID: String, versionID: String, spanID: String) throws -> TranscriptSpan {
            guard sourceVersions[sourceID] == versionID, let span = spans[sourceID]?[spanID] else {
                throw VoiceOSError("全景模型输入引用的来源、版本或片段不符")
            }
            return span
        }
        let wireSources = try input.sources.enumerated().map { index, source in
            let transcript = source.transcript
            let version = try versions.alias(transcript.transcriptVersionID)
            var review: Review?
            if let current = transcript.transcriptionReview {
                guard current.transcriptVersionID == transcript.transcriptVersionID else {
                    throw VoiceOSError("全景模型输入的转写核对版本不符")
                }
                review = try .init(transcriptVersionID: version, corrections: (current.corrections ?? []).map { correction in
                    let span = try range(sourceID: source.id, versionID: transcript.transcriptVersionID, spanID: correction.span_id)
                    return Correction(start: span.textStart, end: span.textEnd, before: correction.before, after: correction.after,
                                      context_quote: correction.context_quote, reason: correction.reason, independent_reason: correction.independent_reason)
                }, unresolvedIssues: (current.unresolved_issues ?? []).map { issue in
                    let span = try range(sourceID: source.id, versionID: transcript.transcriptVersionID, spanID: issue.span_id)
                    return Issue(start: span.textStart, end: span.textEnd, reason: issue.reason)
                })
            }
            return try Source(sourceID: sources.alias(source.id), sourceVersionID: "v" + String(index + 1), transcriptVersionID: version,
                              title: source.title, occurredAt: source.occurredAt, origin: transcript.origin, speaker: transcript.speaker,
                              text: transcript.text, transcriptionReview: review)
        }
        let wireClaims = try input.claims.map { claim in
            try Claim(id: claims.alias(claim.id), statement: claim.statement, ownership: claim.ownership, references: claim.references.map { reference in
                let span = try range(sourceID: reference.sourceID, versionID: reference.transcriptVersionID, spanID: reference.spanID)
                return try Reference(sourceID: sources.alias(reference.sourceID), transcriptVersionID: versions.alias(reference.transcriptVersionID),
                                     start: span.textStart, end: span.textEnd)
            })
        }
        let wireUnits = try input.units.map { unit in
            try Unit(id: units.alias(unit.id), sourceIDs: unit.sourceIDs.map(sources.alias), dependencyIDs: unit.dependencyIDs.map(sources.alias))
        }
        self.unitIdentities = units
        self.sources = sources
        self.versions = versions
        self.claims = claims
        self.sourceVersions = sourceVersions
        payload = .init(units: wireUnits, sources: wireSources, claims: wireClaims)
    }

    func proposalForModel(_ proposal: PanoramaProposal) throws -> PanoramaProposal {
        try map(proposal, direction: .toModel)
    }

    func proposalFromModel(_ proposal: PanoramaProposal) throws -> PanoramaProposal {
        try map(proposal, direction: .toCanonical)
    }

    func pendingFromModel(_ values: [PanoramaUnrepresented], claim: Bool) throws -> [PanoramaUnrepresented] {
        try values.map { .init(id: try (claim ? self.claims : sources).original($0.id), reason: $0.reason) }
    }

    func canonicalClaim(_ alias: String) throws -> String {
        try claims.original(alias)
    }

    private func map(_ proposal: PanoramaProposal, direction: Direction) throws -> PanoramaProposal {
        func identity(_ value: String, _ identities: Identities) throws -> String {
            switch direction {
            case .toModel: return try identities.alias(value)
            case .toCanonical: return try identities.original(value)
            }
        }
        func evidence(_ values: [PanoramaEvidence]) throws -> [PanoramaEvidence] {
            try values.map { value in
                let source = try identity(value.sourceID, sources)
                let version = try identity(value.transcriptVersionID, versions)
                let canonicalSource = direction == .toModel ? value.sourceID : source
                let canonicalVersion = direction == .toModel ? value.transcriptVersionID : version
                guard sourceVersions[canonicalSource] == canonicalVersion else { throw VoiceOSError("全景模型引用的来源与版本不匹配") }
                return try .init(sourceID: source, transcriptVersionID: version, start: value.start, end: value.end,
                                 quote: value.quote, claimIDs: value.claimIDs.map { try identity($0, claims) })
            }
        }
        return try .init(regions: proposal.regions, questions: proposal.questions.map {
            try .init(id: $0.id, regionID: $0.regionID, title: $0.title, summary: $0.summary, evidence: evidence($0.evidence))
        }, relations: proposal.relations.map {
            try .init(id: $0.id, from: $0.from, to: $0.to, label: $0.label, explanation: $0.explanation,
                      fromEvidence: evidence($0.fromEvidence), toEvidence: evidence($0.toEvidence))
        }, unrepresentedSources: proposal.unrepresentedSources.map {
            try .init(id: identity($0.id, sources), reason: $0.reason)
        }, unrepresentedClaims: proposal.unrepresentedClaims.map {
            try .init(id: identity($0.id, claims), reason: $0.reason)
        })
    }
}

extension PanoramaModelInput {
    func coverageForModel(_ target: PanoramaCoverageTarget) throws -> PanoramaCoverageTarget {
        try .init(sourceIDs: target.sourceIDs.map(sources.alias), claimIDs: target.claimIDs.map(claims.alias))
    }
}

extension PanoramaModelInput {
    func payloadForScope(_ input: PanoramaInput) throws -> Payload {
        let sourceIDs=Set(try input.manifest.sourceIDs.map(sources.alias))
        let claimIDs=Set(try input.manifest.claimIDs.map(claims.alias))
        return .init(units: payload.units.filter { Set($0.sourceIDs + $0.dependencyIDs).isSubset(of: sourceIDs) },
            sources: payload.sources.filter { sourceIDs.contains($0.sourceID) }, claims: payload.claims.filter { claimIDs.contains($0.id) })
    }
}

extension PanoramaModelInput {
    func unitProposalForModel(_ value: PanoramaUnitProposal) throws -> PanoramaUnitProposal {
        try .init(unitID: unitIdentities.alias(value.unitID), proposal: proposalForModel(value.proposal))
    }
    func scopedReviewForModel(_ value: PanoramaScopedReview) throws -> PanoramaScopedReview {
        let scope=value.stage == "global.coverage" ? try unitIdentities.alias(value.scopeID) : value.scopeID
        return try .init(stage: value.stage, scopeID: scope, review: value.review, receipt: value.receipt, target: value.target.map(coverageForModel))
    }
}

struct PanoramaModelFocus: Encodable, Equatable {
    struct Range: Encodable, Equatable {
        let sourceID: String
        let transcriptVersionID: String
        let start: Int
        let end: Int
    }
    let unitID: String
    let ordinal: Int
    let count: Int
    let ranges: [Range]
}

extension PanoramaModelInput {
    /// Focus ranges use the same s/t identities as the payload and stay in
    /// full-text coordinates; an absent identity or invalid range throws.
    func focusForModel(_ focus: PanoramaGenerationFocus) throws -> PanoramaModelFocus {
        guard focus.ordinal >= 1, focus.count >= focus.ordinal, !focus.ranges.isEmpty else { throw VoiceOSError("全景分片聚焦范围无效") }
        let unit=try unitIdentities.alias(focus.unitID)
        let byAlias=Dictionary(uniqueKeysWithValues: payload.sources.map { ($0.sourceID,$0) })
        let ranges=try focus.ranges.map { range -> PanoramaModelFocus.Range in
            let source=try sources.alias(range.sourceID)
            guard sourceVersions[range.sourceID] == range.transcriptVersionID else { throw VoiceOSError("全景分片聚焦来源与版本不符") }
            let version=try versions.alias(range.transcriptVersionID)
            guard let wire=byAlias[source], wire.transcriptVersionID == version,
                  range.start >= 0, range.end > range.start, range.end <= wire.text.unicodeScalars.count else {
                throw VoiceOSError("全景分片聚焦范围无效")
            }
            return .init(sourceID: source, transcriptVersionID: version, start: range.start, end: range.end)
        }
        return .init(unitID: unit, ordinal: focus.ordinal, count: focus.count, ranges: ranges)
    }
}
