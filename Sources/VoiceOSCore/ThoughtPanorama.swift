import Foundation

/// A model quote that cannot be located in the current transcript. Unlike schema
/// errors this is stochastic: the same input can produce a locatable quote on a retry.
public struct PanoramaQuoteLocationFailure: Error, Sendable, LocalizedError {
    public let reason: String
    public var errorDescription: String? { reason }
}
/// A compact synthesis response that cites a question ID it was not given.
/// Retryable: the same input can produce valid refs on a retry.
struct PanoramaSynthesisReferenceFailure: Error, Sendable, LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}
public struct PanoramaSource: Codable, Sendable, Identifiable {
    public var id: String { transcript.sourceID }
    public let transcript: ContextTranscript
    public let title: String
    public let occurredAt: String
    public let policyVersion: Int
}
public struct PanoramaUnit: Codable, Sendable, Identifiable {
    public let id: String
    public let sourceIDs: [String]
    public let dependencyIDs: [String]
    public let producerID: String
    public let completionDigest: String
}
public struct PanoramaClaim: Codable, Sendable, Identifiable {
    public let id: String
    public let statement: String
    public let ownership: String
    public let reviewVersion: Int
    public let references: [ClaimReference]
}
public struct PanoramaExclusion: Codable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let reason: String
}
public struct PanoramaManifest: Codable, Sendable {
    public let digest: String
    public let sourceIDs: [String]
    public let claimIDs: [String]
    public let unitIDs: [String]
}
public struct PanoramaInput: Codable, Sendable {
    public let manifest: PanoramaManifest
    public let units: [PanoramaUnit]
    public let sources: [PanoramaSource]
    public let claims: [PanoramaClaim]
    public let exclusions: [PanoramaExclusion]
}
public struct PanoramaEvidence: Codable, Sendable {
    public let sourceID: String
    public let transcriptVersionID: String
    public let start: Int
    public let end: Int
    public let quote: String
    public let claimIDs: [String]
}
public struct PanoramaRegion: Codable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let summary: String
}
public struct PanoramaQuestion: Codable, Sendable, Identifiable {
    public let id: String
    public let regionID: String
    public let title: String
    public let summary: String
    public let evidence: [PanoramaEvidence]
}
public struct PanoramaRelation: Codable, Sendable, Identifiable {
    public let id: String
    public let from: String
    public let to: String
    public let label: String
    public let explanation: String
    public let fromEvidence: [PanoramaEvidence]
    public let toEvidence: [PanoramaEvidence]
}
public struct PanoramaUnrepresented: Codable, Sendable {
    public let id: String
    public let reason: String
}
public struct PanoramaProposal: Codable, Sendable {
    public let regions: [PanoramaRegion]
    public let questions: [PanoramaQuestion]
    public let relations: [PanoramaRelation]
    public let unrepresentedSources: [PanoramaUnrepresented]
    public let unrepresentedClaims: [PanoramaUnrepresented]
}
public struct PanoramaReceipt: Codable, Sendable {
    public let responseID: String
    public let model: String
    public let createdAt: String
    public let inputTokens: Int?
    public let outputTokens: Int?
    /// Ordered real provider response IDs a composite receipt is made of.
    public let sourceResponseIDs: [String]?
    /// Non-nil only on composite receipts; the identity used to generate them.
    public let generationIdentity: String?
    public init(responseID: String, model: String, createdAt: String, inputTokens: Int? = nil, outputTokens: Int? = nil,
                sourceResponseIDs: [String]? = nil, generationIdentity: String? = nil) {
        self.responseID=responseID; self.model=model; self.createdAt=createdAt; self.inputTokens=inputTokens; self.outputTokens=outputTokens
        self.sourceResponseIDs=sourceResponseIDs; self.generationIdentity=generationIdentity
    }
}
public struct PanoramaDecision: Codable, Sendable {
    public let id: String
    public let accepted: Bool
    public let reason: String
}
public struct PanoramaReview: Codable, Sendable {
    public let questions: [PanoramaDecision]
    public let relations: [PanoramaDecision]
    public let coverageAccepted: Bool
    public let reason: String
}
public struct PanoramaRejection: Codable, Sendable {
    public let proposal: PanoramaProposal
    public let review: PanoramaReview
}
public struct PanoramaCoverage: Codable, Sendable {
    public let submittedSourceIDs: [String]
    public let submittedClaimIDs: [String]
    public let representedSourceIDs: [String]
    public let representedClaimIDs: [String]
    public let unrepresentedSources: [PanoramaUnrepresented]
    public let unrepresentedClaims: [PanoramaUnrepresented]
}
public enum PanoramaPhase: String, Codable, Sendable {
    case units, synthesis, evidence, coverage, consistency, completed
}
public struct PanoramaStepReceipt: Codable, Sendable {
    public let stage: String
    public let scopeID: String
    public let receipt: PanoramaReceipt
}
public struct PanoramaUnitProposal: Codable, Sendable {
    public let unitID: String
    public let proposal: PanoramaProposal
}
public struct PanoramaScopedReview: Codable, Sendable {
    public let stage: String
    public let scopeID: String
    public let review: PanoramaReview
    public let receipt: PanoramaReceipt
    public let target: PanoramaCoverageTarget?
    public init(stage: String, scopeID: String, review: PanoramaReview, receipt: PanoramaReceipt, target: PanoramaCoverageTarget? = nil) {
        self.stage=stage; self.scopeID=scopeID; self.review=review; self.receipt=receipt; self.target=target
    }
}
public struct PanoramaCoverageTarget: Codable, Sendable {
    public let sourceIDs: [String]
    public let claimIDs: [String]
}
public struct PanoramaWorkflow: Codable, Sendable {
    public let phase: PanoramaPhase
    public let verifiedUnitIDs: [String]
    public let totalUnitCount: Int
    public let receipts: [PanoramaStepReceipt]
    public var isComplete: Bool { phase == .completed }
}
public struct PanoramaProgress: Sendable {
    public let phase: PanoramaPhase
    public let verifiedUnitCount: Int
    public let totalUnitCount: Int
    public let activeStage: String?
}
public struct PanoramaSnapshot: Codable, Sendable, Identifiable {
    public let id: String
    public let createdAt: String
    public let input: PanoramaInput
    public let proposal: PanoramaProposal
    public let coverage: PanoramaCoverage
    public let generation: PanoramaReceipt
    public let verification: PanoramaReceipt
    public let review: PanoramaReview
    public let workflow: PanoramaWorkflow?
    public var isPartial: Bool { workflow.map { !$0.isComplete } ?? false }
    public init(id: String, createdAt: String, input: PanoramaInput, proposal: PanoramaProposal, coverage: PanoramaCoverage,
                generation: PanoramaReceipt, verification: PanoramaReceipt, review: PanoramaReview, workflow: PanoramaWorkflow? = nil) {
        self.id=id; self.createdAt=createdAt; self.input=input; self.proposal=proposal; self.coverage=coverage
        self.generation=generation; self.verification=verification; self.review=review; self.workflow=workflow
    }
}
public enum PanoramaSelection: Hashable, Sendable {
    case question(String), relation(String)
}
public struct PanoramaState: Sendable {
    public let input: PanoramaInput
    public let snapshot: PanoramaSnapshot?
    public let status: String
    public let error: String?
    public let progress: PanoramaProgress?
    public init(input: PanoramaInput, snapshot: PanoramaSnapshot?, status: String, error: String?, progress: PanoramaProgress? = nil) {
        self.input=input; self.snapshot=snapshot; self.status=status; self.error=error; self.progress=progress
    }
    public var canGenerate: Bool { !input.units.isEmpty && !["completed", "running", "failed", "unknown"].contains(status) }
}
public struct PanoramaDiscussion: Sendable {
    public let conversation: ConversationRecord
    public let draft: String
}
public protocol PanoramaModelPort: Sendable {
    var configurationIdentity: String { get }
    func generate(_ input: PanoramaInput) async throws -> (PanoramaProposal, PanoramaReceipt)
    func generate(_ input: PanoramaInput, focus: PanoramaGenerationFocus, target: PanoramaCoverageTarget) async throws -> (PanoramaProposal, PanoramaReceipt)
    func synthesize(_ proposals: [PanoramaUnitProposal], input: PanoramaInput) async throws -> (PanoramaProposal, PanoramaReceipt)
    func repairSynthesis(_ proposal: PanoramaProposal, input: PanoramaInput, context: PanoramaInput, rejection: PanoramaRejection) async throws -> (PanoramaProposal, PanoramaReceipt)
    func verifyEvidence(_ proposal: PanoramaProposal, input: PanoramaInput) async throws -> (PanoramaReview, PanoramaReceipt)
    func verifyCoverage(_ proposal: PanoramaProposal, input: PanoramaInput, target: PanoramaCoverageTarget, rejections: [PanoramaRejection]) async throws -> (PanoramaReview, PanoramaReceipt)
    func verifyConsistency(_ proposal: PanoramaProposal, input: PanoramaInput, unitProposals: [PanoramaUnitProposal], reviews: [PanoramaScopedReview], rejections: [PanoramaRejection]) async throws -> (PanoramaReview, PanoramaReceipt)
    func repair(_ proposal: PanoramaProposal, input: PanoramaInput, review: PanoramaReview) async throws -> (PanoramaProposal, PanoramaReceipt)
    func verify(_ proposal: PanoramaProposal, input: PanoramaInput, priorRejection: PanoramaRejection?) async throws -> (PanoramaReview, PanoramaReceipt)
}

extension PanoramaModelPort {
    public var configurationIdentity: String { String(reflecting: Self.self) }
    /// Deliberately separate from the single-request identity so completed
    /// single-request rows keep replaying byte for byte.
    public var focusConfigurationIdentity: String { configurationIdentity + "|unit-slices-v1" }
    /// Compact global synthesis copies evidence locally, so a shape change
    /// invalidates only synthesis rows and keeps verified unit receipts.
    public var synthesisConfigurationIdentity: String { configurationIdentity + "|compact-synthesis-v2" }
    public func generate(_ input: PanoramaInput, focus: PanoramaGenerationFocus, target: PanoramaCoverageTarget) async throws -> (PanoramaProposal, PanoramaReceipt) {
        throw VoiceOSError("当前模型端口尚不支持聚焦分片生成，完整单元未发布")
    }
    public func synthesize(_ proposals: [PanoramaUnitProposal], input: PanoramaInput) async throws -> (PanoramaProposal, PanoramaReceipt) {
        throw VoiceOSError("当前模型端口尚不支持跨单元全景核对，已核对区域保留")
    }
    public func repairSynthesis(_ proposal: PanoramaProposal, input: PanoramaInput, context: PanoramaInput, rejection: PanoramaRejection) async throws -> (PanoramaProposal, PanoramaReceipt) {
        throw VoiceOSError("当前模型端口尚不支持全景语义修复，已核对区域保留")
    }
    public func verifyEvidence(_ proposal: PanoramaProposal, input: PanoramaInput) async throws -> (PanoramaReview, PanoramaReceipt) {
        throw VoiceOSError("当前模型端口尚不支持逐问题与联系核对，已核对区域保留")
    }
    public func verifyCoverage(_ proposal: PanoramaProposal, input: PanoramaInput, target: PanoramaCoverageTarget, rejections: [PanoramaRejection]) async throws -> (PanoramaReview, PanoramaReceipt) {
        throw VoiceOSError("当前模型端口尚不支持逐单元全局覆盖核对，已核对区域保留")
    }
    public func verifyConsistency(_ proposal: PanoramaProposal, input: PanoramaInput, unitProposals: [PanoramaUnitProposal], reviews: [PanoramaScopedReview], rejections: [PanoramaRejection]) async throws -> (PanoramaReview, PanoramaReceipt) {
        throw VoiceOSError("当前模型端口尚不支持全景一致性核对，已核对区域保留")
    }
}

extension VoiceOSStore {
    static func locatePanoramaQuotes(_ proposal: PanoramaProposal, input: PanoramaInput) throws -> PanoramaProposal {
        let sources = Dictionary(uniqueKeysWithValues: input.sources.map { ($0.id, $0.transcript) })
        func locate(_ evidence: [PanoramaEvidence]) throws -> [PanoramaEvidence] {
            try evidence.map { item in
                guard let source = sources[item.sourceID], source.transcriptVersionID == item.transcriptVersionID,
                      !item.quote.isEmpty else { throw PanoramaQuoteLocationFailure(reason: "全景引用来源、版本或原话无效") }
                let scalars = Array(source.text.unicodeScalars)
                if item.start >= 0, item.end > item.start, item.end <= scalars.count,
                   String(String.UnicodeScalarView(scalars[item.start..<item.end])) == item.quote { return item }
                guard let range = source.text.range(of: item.quote, options: .literal) else { throw PanoramaQuoteLocationFailure(reason: "全景引文不在当前完整原文中") }
                let next = source.text.unicodeScalars.index(after: range.lowerBound)
                guard source.text.range(of: item.quote, options: .literal, range: next..<source.text.endIndex) == nil else {
                    throw PanoramaQuoteLocationFailure(reason: "全景原话重复出现，必须给出有效的精确范围")
                }
                let start = source.text.unicodeScalars.distance(from: source.text.startIndex, to: range.lowerBound)
                let end = source.text.unicodeScalars.distance(from: source.text.startIndex, to: range.upperBound)
                guard String(String.UnicodeScalarView(scalars[start..<end])) == item.quote else { throw PanoramaQuoteLocationFailure(reason: "全景引文不能逐字定位") }
                return .init(sourceID: item.sourceID, transcriptVersionID: item.transcriptVersionID, start: start, end: end, quote: item.quote, claimIDs: item.claimIDs)
            }
        }
        return try .init(regions: proposal.regions, questions: proposal.questions.map {
            .init(id: $0.id, regionID: $0.regionID, title: $0.title, summary: $0.summary, evidence: try locate($0.evidence))
        }, relations: proposal.relations.map {
            .init(id: $0.id, from: $0.from, to: $0.to, label: $0.label, explanation: $0.explanation,
                  fromEvidence: try locate($0.fromEvidence), toEvidence: try locate($0.toEvidence))
        }, unrepresentedSources: proposal.unrepresentedSources, unrepresentedClaims: proposal.unrepresentedClaims)
    }
    public static func validatePanorama(_ proposal: PanoramaProposal, input: PanoramaInput) throws -> PanoramaCoverage {
        let sources=Dictionary(uniqueKeysWithValues: input.sources.map { ($0.id, $0.transcript) })
        let claims=Dictionary(uniqueKeysWithValues: input.claims.map { ($0.id, $0) })
        let regions=Set(proposal.regions.map(\.id)), questions=Dictionary(grouping: proposal.questions, by: \.id)
        func nonempty(_ value: String) -> Bool { !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard regions.count == proposal.regions.count, questions.count == proposal.questions.count,
              Set(proposal.relations.map(\.id)).count == proposal.relations.count,
              proposal.regions.allSatisfy({ nonempty($0.id) && nonempty($0.title) && nonempty($0.summary) }),
              proposal.regions.allSatisfy({ region in proposal.questions.contains { $0.regionID == region.id } }) else { throw VoiceOSError("全景区域或问题身份无效") }
        func validate(_ evidence: [PanoramaEvidence]) throws {
            guard !evidence.isEmpty else { throw VoiceOSError("全景问题或联系缺少真实原话") }
            for item in evidence {
                guard let source=sources[item.sourceID], source.transcriptVersionID == item.transcriptVersionID,
                      item.start >= 0, item.end > item.start, item.end <= source.text.unicodeScalars.count else { throw VoiceOSError("全景引用版本或范围不符") }
                let text=Array(source.text.unicodeScalars)
                guard String(String.UnicodeScalarView(text[item.start..<item.end])) == item.quote,
                      Set(item.claimIDs).count == item.claimIDs.count,
                      item.claimIDs.allSatisfy({ id in claims[id]?.references.contains { ref in
                          ref.sourceID == item.sourceID && ref.transcriptVersionID == item.transcriptVersionID &&
                          source.spans.contains { $0.id == ref.spanID && $0.textEnd > item.start && $0.textStart < item.end }
                      } == true }) else { throw VoiceOSError("全景引用不能逐字定位或观点归属不符") }
            }
        }
        for question in proposal.questions {
            guard nonempty(question.id), regions.contains(question.regionID), nonempty(question.title), nonempty(question.summary) else { throw VoiceOSError("全景问题缺少名称或区域") }
            try validate(question.evidence)
        }
        for relation in proposal.relations {
            guard nonempty(relation.id), relation.from != relation.to, let from=questions[relation.from]?.first,
                  let to=questions[relation.to]?.first, nonempty(relation.label), nonempty(relation.explanation) else { throw VoiceOSError("全景联系缺少真实端点或语义名称") }
            try validate(relation.fromEvidence); try validate(relation.toEvidence)
            for (endpoint,evidence) in [(from,relation.fromEvidence),(to,relation.toEvidence)] {
                guard evidence.allSatisfy({ item in endpoint.evidence.contains { $0.sourceID == item.sourceID && $0.transcriptVersionID == item.transcriptVersionID } }) else { throw VoiceOSError("全景联系引文不属于其问题端点") }
            }
        }
        let evidence=proposal.questions.flatMap(\.evidence) + proposal.relations.flatMap { $0.fromEvidence + $0.toEvidence }
        let representedSources=Set(evidence.map(\.sourceID)), representedClaims=Set(evidence.flatMap(\.claimIDs))
        func coverage(_ pending: [PanoramaUnrepresented], submitted: Set<String>, represented: Set<String>) throws {
            let ids=Set(pending.map(\.id))
            guard ids.count == pending.count, pending.allSatisfy({ nonempty($0.reason) }), represented.isSubset(of: submitted),
                  ids.isDisjoint(with: represented), ids.union(represented) == submitted else { throw VoiceOSError("全景覆盖清单遗漏或重复了材料、观点") }
        }
        try coverage(proposal.unrepresentedSources, submitted: Set(input.manifest.sourceIDs), represented: representedSources)
        try coverage(proposal.unrepresentedClaims, submitted: Set(input.manifest.claimIDs), represented: representedClaims)
        return .init(submittedSourceIDs: input.manifest.sourceIDs, submittedClaimIDs: input.manifest.claimIDs,
                     representedSourceIDs: representedSources.sorted(), representedClaimIDs: representedClaims.sorted(),
                     unrepresentedSources: proposal.unrepresentedSources, unrepresentedClaims: proposal.unrepresentedClaims)
    }
    static func validatePanoramaReview(_ review: PanoramaReview, proposal: PanoramaProposal, generation: PanoramaReceipt, verification: PanoramaReceipt) throws {
        guard !generation.responseID.isEmpty, !verification.responseID.isEmpty, generation.responseID != verification.responseID,
              !generation.model.isEmpty, !verification.model.isEmpty, review.coverageAccepted,
              Set(review.questions.map(\.id)) == Set(proposal.questions.map(\.id)), review.questions.count == proposal.questions.count,
              Set(review.relations.map(\.id)) == Set(proposal.relations.map(\.id)), review.relations.count == proposal.relations.count,
              (review.questions + review.relations).allSatisfy({ $0.accepted && !$0.reason.isEmpty }), !review.reason.isEmpty else { throw VoiceOSError("全景没有通过全部问题、联系与覆盖的独立语义核对") }
    }
}
