import Foundation

public enum QuestionStatus: String, Codable, Sendable { case open, exploring, resolved, closed }
/// A classification candidate anchored to existing cognition, not an accepted question or state change.
public struct QuestionSeedSnapshot: Codable, Sendable {
    public let id: String
    public let claimID: String
    public let claimReviewVersion: Int
    public let statement: String
    public let ownership: String
    public let contentKind: CognitiveContentKind?
    public let original: OutcomeSourceEvidence
    public let context: LocalTranscriptContext
    public let policyVersions: [String: Int]
    public let contentDigest: String
}
public struct QuestionTransitionSnapshot: Codable, Sendable {
    public let seed: QuestionSeedSnapshot
    public let expectedVersion: Int
    public let from: QuestionStatus
    public let to: QuestionStatus
    public let reason: String
    public let resolution: OutcomeSourceEvidence?
    public let resolutionContext: LocalTranscriptContext?
    public let resolutionPolicyVersion: Int?
}
extension VoiceOSStore {
    /// Read-only; this never classifies punctuation, writes a question or invokes a model.
    public func prepareQuestionSeed(claimID: String, expectedReviewVersion: Int, original: OutcomeSourceEvidence, scalarBudget: Int = 8000) throws -> QuestionSeedSnapshot {
        guard ready, (1...12000).contains(scalarBudget), let claim = try candidateClaim(id: claimID),
              claim.reviewVersion == expectedReviewVersion, claim.reviewState != "rejected",
              claim.references.contains(where: { $0.sourceID == original.reference.sourceID && $0.transcriptVersionID == original.reference.transcriptVersionID && $0.spanID == original.reference.spanID }) else { throw VoiceOSError("问题候选的认知版本或出处已变化") }
        let ids = Array(Set(claim.references.map(\.sourceID))).sorted()
        let context = try prepareLocalTranscriptContext(sourceIDs: ids, scalarBudget: scalarBudget)
        try Self.validateQuestionEvidence(original, context: context, personal: claim.ownership == CandidateOwnership.userTentative.rawValue)
        var policies: [String: Int] = [:]
        for id in ids { policies[id] = try sourcePolicy(sourceID: id).version }
        let seed = QuestionSeedSnapshot(id: UUID().uuidString, claimID: claimID, claimReviewVersion: expectedReviewVersion, statement: claim.statement, ownership: claim.ownership, contentKind: claim.contentKind, original: original, context: context, policyVersions: policies, contentDigest: "")
        return .init(id: seed.id, claimID: seed.claimID, claimReviewVersion: seed.claimReviewVersion, statement: seed.statement, ownership: seed.ownership, contentKind: seed.contentKind, original: seed.original, context: seed.context, policyVersions: seed.policyVersions, contentDigest: try Self.questionSeedDigest(seed))
    }
    public func validateQuestionSeed(_ seed: QuestionSeedSnapshot) throws {
        guard UUID(uuidString: seed.id) != nil else { throw VoiceOSError("问题候选身份无效") }
        let actual = try prepareQuestionSeed(claimID: seed.claimID, expectedReviewVersion: seed.claimReviewVersion, original: seed.original, scalarBudget: seed.context.scalarBudget)
        guard actual.contentDigest == seed.contentDigest, try Self.questionSeedDigest(seed) == seed.contentDigest else { throw VoiceOSError("问题候选原文、归属或授权已变化") }
    }
    public func prepareQuestionTransition(seed: QuestionSeedSnapshot, expectedVersion: Int, from: QuestionStatus, to: QuestionStatus, reason: String, resolution: OutcomeSourceEvidence? = nil) throws -> QuestionTransitionSnapshot {
        try validateQuestionSeed(seed)
        guard expectedVersion > 0, expectedVersion < Int.max, from != to,
              !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, reason.unicodeScalars.count <= 2000,
              ![QuestionStatus.resolved, .closed].contains(from) || to == .open else { throw VoiceOSError("问题状态版本、转移或原因无效") }
        if to == .resolved {
            guard let resolution else { throw VoiceOSError("登记解决需要明确个人表达及答案依据") }
            guard resolution.reference.sourceID != seed.original.reference.sourceID ||
                  resolution.reference.transcriptVersionID != seed.original.reference.transcriptVersionID ||
                  resolution.reference.spanID != seed.original.reference.spanID else { throw VoiceOSError("原提问本身不能充当新增的答案依据") }
            let context = try prepareLocalTranscriptContext(sourceIDs: [resolution.reference.sourceID], scalarBudget: 8000)
            try Self.validateQuestionEvidence(resolution, context: context, personal: true)
            return .init(seed: seed, expectedVersion: expectedVersion, from: from, to: to, reason: reason, resolution: resolution, resolutionContext: context, resolutionPolicyVersion: try sourcePolicy(sourceID: resolution.reference.sourceID).version)
        }
        guard resolution == nil else { throw VoiceOSError("关闭、研究或重开不能冒充登记答案") }
        return .init(seed: seed, expectedVersion: expectedVersion, from: from, to: to, reason: reason, resolution: nil, resolutionContext: nil, resolutionPolicyVersion: nil)
    }
    public func validateQuestionTransition(_ input: QuestionTransitionSnapshot) throws {
        let actual = try prepareQuestionTransition(seed: input.seed, expectedVersion: input.expectedVersion, from: input.from, to: input.to, reason: input.reason, resolution: input.resolution)
        guard try Self.relevanceJSON(actual) == Self.relevanceJSON(input) else { throw VoiceOSError("问题答案依据或授权已变化") }
    }
    static func questionSeedDigest(_ seed: QuestionSeedSnapshot) throws -> String {
        struct Payload: Encodable {
            let claimID: String; let claimReviewVersion: Int; let statement: String; let ownership: String; let contentKind: CognitiveContentKind?
            let original: OutcomeSourceEvidence; let context: LocalTranscriptContext; let policyVersions: [String: Int]
        }
        return relevanceHash(Data(try relevanceJSON(Payload(claimID: seed.claimID, claimReviewVersion: seed.claimReviewVersion, statement: seed.statement, ownership: seed.ownership, contentKind: seed.contentKind, original: seed.original, context: seed.context, policyVersions: seed.policyVersions)).utf8))
    }
    static func validateQuestionEvidence(_ evidence: OutcomeSourceEvidence, context: LocalTranscriptContext, personal: Bool) throws {
        let ref = evidence.reference
        guard !evidence.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, evidence.quote.unicodeScalars.count <= 2000,
              let source = context.sources.first(where: { $0.sourceID == ref.sourceID && $0.transcriptVersionID == ref.transcriptVersionID }),
              !personal || (source.origin == "user" && source.speaker == "user"),
              let span = source.spans.first(where: { $0.id == ref.spanID }) else { throw VoiceOSError("问题依据的身份、归属或引文无效") }
        let scalars = Array(source.text.unicodeScalars)
        guard String(String.UnicodeScalarView(scalars[span.textStart..<span.textEnd])).contains(evidence.quote) else { throw VoiceOSError("问题依据不是连续原话") }
    }
}
