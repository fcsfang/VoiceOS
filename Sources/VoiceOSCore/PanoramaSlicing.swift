import Foundation

/// A bounded content range in FULL-source Unicode-scalar coordinates. It is a
/// citation/coverage contract, never a windowed transcript.
public struct PanoramaFocusRange: Codable, Sendable, Hashable {
    public let sourceID: String
    public let transcriptVersionID: String
    public let start: Int
    public let end: Int
    public init(sourceID: String, transcriptVersionID: String, start: Int, end: Int) {
        self.sourceID=sourceID; self.transcriptVersionID=transcriptVersionID; self.start=start; self.end=end
    }
}

public struct PanoramaGenerationFocus: Codable, Sendable, Hashable {
    public let unitID: String
    public let ordinal: Int
    public let count: Int
    public let ranges: [PanoramaFocusRange]
    public init(unitID: String, ordinal: Int, count: Int, ranges: [PanoramaFocusRange]) {
        self.unitID=unitID; self.ordinal=ordinal; self.count=count; self.ranges=ranges
    }
}

public struct PanoramaFocusViolation: Error, Sendable, LocalizedError {
    public let reason: String
    public init(reason: String) { self.reason=reason }
    public var errorDescription: String? { reason }
}

struct PanoramaUnitSlicePolicy: Codable, Sendable, Equatable {
    static let current=PanoramaUnitSlicePolicy(version: "panorama-unit-slices-v1", unitScalarThreshold: 16_000, focusScalarBudget: 8_000)
    let version: String
    let unitScalarThreshold: Int
    let focusScalarBudget: Int
}

struct PanoramaSliceGenerationInput: Codable, Sendable {
    let policy: String
    let planDigest: String
    let unitID: String
    let ordinal: Int
    let count: Int
    let focus: PanoramaGenerationFocus
    let target: PanoramaCoverageTarget
    let input: PanoramaInput
}

struct PanoramaSliceRepairInput: Codable, Sendable {
    let policy: String
    let planDigest: String
    let unitID: String
    let ordinal: Int
    let count: Int
    let focus: PanoramaGenerationFocus
    let target: PanoramaCoverageTarget
    let input: PanoramaInput
    let proposal: PanoramaProposal
    let review: PanoramaReview
}

struct PanoramaSlicedGenerationRecord: Codable, Sendable {
    static let kind="panorama-unit-slices-v1"
    let kind: String
    let policy: PanoramaUnitSlicePolicy
    let planDigest: String
    let input: PanoramaInput
    init(policy: PanoramaUnitSlicePolicy, planDigest: String, input: PanoramaInput) {
        kind=Self.kind; self.policy=policy; self.planDigest=planDigest; self.input=input
    }
}

struct PanoramaSlicedRepairRecord: Codable, Sendable {
    let kind: String
    let policy: PanoramaUnitSlicePolicy
    let planDigest: String
    let input: PanoramaInput
    let rejection: PanoramaRejection
    init(policy: PanoramaUnitSlicePolicy, planDigest: String, input: PanoramaInput, rejection: PanoramaRejection) {
        kind=PanoramaSlicedGenerationRecord.kind; self.policy=policy; self.planDigest=planDigest; self.input=input; self.rejection=rejection
    }
}

enum PanoramaUnitGenerationRecord: Sendable {
    case single(PanoramaInput)
    case sliced(PanoramaSlicedGenerationRecord)
    var input: PanoramaInput {
        switch self {
        case .single(let value): return value
        case .sliced(let record): return record.input
        }
    }
    static func decode(_ data: Data) throws -> PanoramaUnitGenerationRecord {
        struct Probe: Decodable { let kind: String }
        if let probe=try? JSONDecoder().decode(Probe.self, from: data), probe.kind == PanoramaSlicedGenerationRecord.kind {
            return .sliced(try JSONDecoder().decode(PanoramaSlicedGenerationRecord.self, from: data))
        }
        return .single(try JSONDecoder().decode(PanoramaInput.self, from: data))
    }
}

struct PanoramaUnitSlicePlan: Sendable {
    struct Slice: Sendable {
        let focus: PanoramaGenerationFocus
        let target: PanoramaCoverageTarget
        /// Full sources/claims/units for reading context, with the manifest
        /// narrowed to this focus's coverage target. Used only for local validation.
        let scope: PanoramaInput
        let stepInput: PanoramaSliceGenerationInput
    }
    let unitID: String
    let input: PanoramaInput
    let policy: PanoramaUnitSlicePolicy
    let slices: [Slice]
    let digest: String

    /// nil means the unit fits today's single request unchanged.
    static func make(unitID: String, input: PanoramaInput, policy: PanoramaUnitSlicePolicy = .current) throws -> PanoramaUnitSlicePlan? {
        let total=input.sources.reduce(0) { $0+$1.transcript.text.unicodeScalars.count }
        guard total > policy.unitScalarThreshold else { return nil }
        let submitted=Set(input.manifest.sourceIDs)
        guard input.sources.allSatisfy({ submitted.contains($0.id) }) else { throw VoiceOSError("全景分片来源超出当前完整输入") }
        var ranges: [PanoramaFocusRange]=[]
        for source in input.sources.sorted(by: { $0.id < $1.id }) {
            ranges.append(contentsOf: try focusRanges(source, budget: policy.focusScalarBudget))
        }
        guard !ranges.isEmpty else { return nil }
        var packed: [[PanoramaFocusRange]]=[], current: [PanoramaFocusRange]=[], currentCount=0
        for range in ranges {
            let count=range.end-range.start
            if !current.isEmpty, currentCount+count > policy.focusScalarBudget {
                packed.append(current); current=[]; currentCount=0
            }
            current.append(range); currentCount+=count
        }
        if !current.isEmpty { packed.append(current) }
        guard !packed.isEmpty else { return nil }

        let digest=try planDigest(unitID: unitID, policy: policy, manifestDigest: input.manifest.digest, ranges: ranges)
        let claims=Dictionary(uniqueKeysWithValues: input.claims.map { ($0.id,$0) })
        let sourceVersions=Dictionary(uniqueKeysWithValues: input.sources.map { ($0.id,$0.transcript.transcriptVersionID) })
        var spans: [String:[String:TranscriptSpan]]=[:]
        for source in input.sources { spans[source.id]=Dictionary(uniqueKeysWithValues: source.transcript.spans.map { ($0.id,$0) }) }
        let count=packed.count
        let slices=try packed.enumerated().map { index, ranges -> Slice in
            let ordinal=index+1
            let focus=PanoramaGenerationFocus(unitID: unitID, ordinal: ordinal, count: count, ranges: ranges)
            let target=try coverageTarget(ranges: ranges, claims: claims, spans: spans, sourceVersions: sourceVersions)
            let scope=scope(input: input, target: target, digest: sliceDigest(planDigest: digest, ordinal: ordinal))
            let step=PanoramaSliceGenerationInput(policy: policy.version, planDigest: digest, unitID: unitID, ordinal: ordinal, count: count,
                focus: focus, target: target, input: input)
            return Slice(focus: focus, target: target, scope: scope, stepInput: step)
        }
        return PanoramaUnitSlicePlan(unitID: unitID, input: input, policy: policy, slices: slices, digest: digest)
    }

    /// Pure, model-free merge. IDs are prefixed per part, coverage is recomputed
    /// as the exact complement over the full unit manifest.
    func merge(_ proposals: [PanoramaProposal]) throws -> PanoramaProposal {
        guard proposals.count == slices.count else { throw VoiceOSError("全景分片提案数量与计划不符") }
        var regions: [PanoramaRegion]=[], questions: [PanoramaQuestion]=[], relations: [PanoramaRelation]=[]
        var reasons: [String:String]=[:]
        for (index, proposal) in proposals.enumerated() {
            let prefix=Self.partPrefix(index+1)
            func name(_ value: String) -> String { value.hasPrefix(prefix) ? value : prefix+value }
            regions.append(contentsOf: proposal.regions.map { .init(id: name($0.id), title: $0.title, summary: $0.summary) })
            questions.append(contentsOf: proposal.questions.map {
                .init(id: name($0.id), regionID: name($0.regionID), title: $0.title, summary: $0.summary, evidence: $0.evidence)
            })
            relations.append(contentsOf: proposal.relations.map {
                .init(id: name($0.id), from: name($0.from), to: name($0.to), label: $0.label, explanation: $0.explanation,
                      fromEvidence: $0.fromEvidence, toEvidence: $0.toEvidence)
            })
            for item in proposal.unrepresentedSources+proposal.unrepresentedClaims where reasons[item.id] == nil {
                let reason=item.reason.trimmingCharacters(in: .whitespacesAndNewlines)
                if !reason.isEmpty { reasons[item.id]=item.reason }
            }
        }
        let evidence=questions.flatMap(\.evidence)+relations.flatMap { $0.fromEvidence+$0.toEvidence }
        // A known item takes its slice's real reason. The 16k unit was never generated, so an
        // item that no slice could place needs a deterministic, honest reason rather than a loop.
        let fixedReason="分片核对后仍未归入具体问题；完整原文与认识入口保留"
        func pending(_ submitted: [String], _ represented: Set<String>) -> [PanoramaUnrepresented] {
            submitted.sorted().filter { !represented.contains($0) }.map { .init(id: $0, reason: reasons[$0] ?? fixedReason) }
        }
        return .init(regions: regions, questions: questions, relations: relations,
            unrepresentedSources: pending(input.manifest.sourceIDs, Set(evidence.map(\.sourceID))),
            unrepresentedClaims: pending(input.manifest.claimIDs, Set(evidence.flatMap(\.claimIDs))))
    }

    func projectionIDs(_ proposal: PanoramaProposal, ordinal: Int) -> (questionIDs: Set<String>, relationIDs: Set<String>) {
        let prefix=Self.partPrefix(ordinal)
        return (Set(proposal.questions.map(\.id).filter { $0.hasPrefix(prefix) }),
                Set(proposal.relations.map(\.id).filter { $0.hasPrefix(prefix) }))
    }

    func projectReview(_ review: PanoramaReview, ordinal: Int) -> PanoramaReview {
        let prefix=Self.partPrefix(ordinal)
        let questions=review.questions.filter { $0.id.hasPrefix(prefix) }
        let relations=review.relations.filter { $0.id.hasPrefix(prefix) }
        return .init(questions: questions, relations: relations,
            coverageAccepted: (questions+relations).allSatisfy(\.accepted), reason: review.reason)
    }

    static func partPrefix(_ ordinal: Int) -> String { "part[\(ordinal)]/" }

    private static func focusRanges(_ source: PanoramaSource, budget: Int) throws -> [PanoramaFocusRange] {
        let transcript=source.transcript
        let count=transcript.text.unicodeScalars.count
        guard count > 0 else { return [] }
        let spans=transcript.spans.sorted { $0.textStart < $1.textStart }
        guard spans.allSatisfy({ $0.textStart >= 0 && $0.textEnd > $0.textStart && $0.textEnd <= count }) else {
            throw VoiceOSError("全景分片片段范围无效")
        }
        var result: [PanoramaFocusRange]=[]
        var cursor=0
        while cursor < count {
            let limit=min(count, cursor+budget)
            if let end=spans.lazy.map(\.textEnd).filter({ $0 > cursor && $0 <= limit }).max() {
                result.append(.init(sourceID: source.id, transcriptVersionID: transcript.transcriptVersionID, start: cursor, end: end))
                cursor=end
            } else {
                let end=characterSafeOffset(in: transcript.text, atOrBefore: limit, after: cursor)
                guard end > cursor else { throw VoiceOSError("全景分片无法在字符边界内切分原文") }
                result.append(.init(sourceID: source.id, transcriptVersionID: transcript.transcriptVersionID, start: cursor, end: end))
                cursor=end
            }
        }
        return result
    }

    /// Largest grapheme-cluster boundary at or before `target` and after `minimum`.
    private static func characterSafeOffset(in text: String, atOrBefore target: Int, after minimum: Int) -> Int {
        var offset = 0, best = -1
        for character in text {
            offset+=character.unicodeScalars.count
            if offset > target { break }
            if offset > minimum { best=offset }
        }
        return best
    }

    private static func coverageTarget(ranges: [PanoramaFocusRange], claims: [String:PanoramaClaim],
        spans: [String:[String:TranscriptSpan]], sourceVersions: [String:String]) throws -> PanoramaCoverageTarget {
        var claimIDs: [String]=[]
        for claim in claims.values.sorted(by: { $0.id < $1.id }) {
            let overlaps=try claim.references.contains { reference in
                guard sourceVersions[reference.sourceID] == reference.transcriptVersionID else { throw VoiceOSError("全景分片观点引用版本不符") }
                guard let span=spans[reference.sourceID]?[reference.spanID] else { throw VoiceOSError("全景分片观点引用片段不存在") }
                return ranges.contains { $0.sourceID == reference.sourceID && $0.transcriptVersionID == reference.transcriptVersionID
                    && span.textEnd > $0.start && span.textStart < $0.end }
            }
            if overlaps { claimIDs.append(claim.id) }
        }
        return .init(sourceIDs: Array(Set(ranges.map(\.sourceID))).sorted(), claimIDs: claimIDs.sorted())
    }

    private static func scope(input: PanoramaInput, target: PanoramaCoverageTarget, digest: String) -> PanoramaInput {
        .init(manifest: .init(digest: digest, sourceIDs: target.sourceIDs, claimIDs: target.claimIDs, unitIDs: input.manifest.unitIDs),
              units: input.units, sources: input.sources, claims: input.claims, exclusions: [])
    }

    private static func planDigest(unitID: String, policy: PanoramaUnitSlicePolicy, manifestDigest: String, ranges: [PanoramaFocusRange]) throws -> String {
        let value=PanoramaUnitSlicePlanDigest(version: policy.version, unitScalarThreshold: policy.unitScalarThreshold,
            focusScalarBudget: policy.focusScalarBudget, unitID: unitID, manifestDigest: manifestDigest, ranges: ranges)
        return VoiceOSStore.relevanceHash(Data(try VoiceOSStore.relevanceJSON(value).utf8))
    }

    private static func sliceDigest(planDigest: String, ordinal: Int) -> String {
        VoiceOSStore.relevanceHash(Data(("panorama-unit-slice-v1|"+planDigest+"|"+String(ordinal)).utf8))
    }
}

private struct PanoramaUnitSlicePlanDigest: Encodable {
    let version: String
    let unitScalarThreshold: Int
    let focusScalarBudget: Int
    let unitID: String
    let manifestDigest: String
    let ranges: [PanoramaFocusRange]
}

extension VoiceOSStore {
    /// Structural validation against the slice's narrowed manifest, then focus
    /// containment for every quote on both relation sides.
    static func validatePanoramaFocused(_ proposal: PanoramaProposal, scope: PanoramaInput, focus: PanoramaGenerationFocus) throws -> PanoramaCoverage {
        let coverage=try validatePanorama(proposal, input: scope)
        let groups=Dictionary(grouping: focus.ranges, by: \.sourceID)
        func contained(_ item: PanoramaEvidence) -> Bool {
            groups[item.sourceID]?.contains { range in
                range.transcriptVersionID == item.transcriptVersionID && range.start <= item.start && item.end <= range.end
            } == true
        }
        let evidence=proposal.questions.flatMap(\.evidence)+proposal.relations.flatMap { $0.fromEvidence+$0.toEvidence }
        guard evidence.allSatisfy(contained) else { throw PanoramaFocusViolation(reason: "分片引文超出本次聚焦范围") }
        return coverage
    }
}

extension PanoramaReceipt {
    /// A receipt of receipts, not a provider response: every part receipt and its
    /// step row stays persisted and is listed in `sourceResponseIDs`.
    static func composite(parts: [PanoramaReceipt], identity: String, kind: String) throws -> PanoramaReceipt {
        guard let first=parts.first, let last=parts.last else { throw VoiceOSError("全景分片缺少真实完成回执") }
        let hash=VoiceOSStore.relevanceHash(Data((identity+"|"+parts.map(\.responseID).joined(separator: "|")).utf8))
        func tokens(_ values: [Int?]) -> Int? {
            values.allSatisfy { $0 != nil } ? values.compactMap { $0 }.reduce(0, +) : nil
        }
        return .init(responseID: "panorama-slices-v1:\(kind):\(String(hash.prefix(16)))", model: first.model, createdAt: last.createdAt,
            inputTokens: tokens(parts.map(\.inputTokens)), outputTokens: tokens(parts.map(\.outputTokens)),
            sourceResponseIDs: parts.map(\.responseID), generationIdentity: identity)
    }
}
