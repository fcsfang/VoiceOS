import Foundation

/// Physical pairing is separate from user-only semantic expression membership.
public struct RecordingContext: Codable, Sendable {
    public let personalSourceID: String
    public let externalSourceID: String
    public let sessionID: String
    /// Add this offset to the external clip time to obtain personal clip time.
    public let offsetMS: Int
    public let personalVersionID: String
    public let externalVersionID: String
    public let personalPolicyVersion: Int
    public let externalPolicyVersion: Int
}
public struct RecordingContextSnapshot: Codable, Sendable {
    public let pairing: RecordingContext
    public let context: LocalTranscriptContext
}
public struct RecordingContextLink: Codable, Sendable {
    public let personalClaimID: String
    public let externalClaimID: String
    public let relation: String
    public let explanation: String
    public let personalQuote: String
    public let externalQuote: String
    public let pairing: RecordingContext
    public let responseIDs: [String]
    public var personalReviewVersion: Int? = nil
    public var externalReviewVersion: Int? = nil
}
public extension SourceRecord {
    /// Views verify all companions using the same loaded catalog, including
    /// program permissions, before presenting a saved whole-expression summary.
    func recordingExpression(in catalog:[String:SourceRecord]) -> RecordingExpression? {
        guard let expression=recordingExpression,
              expression.sourceIDs.allSatisfy({ id in
                  guard let member=catalog[id],member.recordingExpression?.digest == expression.digest else { return false }
                  if let pair=member.presentation?.recordingContext {
                      return expression.externalVersions?[pair.externalSourceID] == pair.externalVersionID && expression.externalPolicies?[pair.externalSourceID] == pair.externalPolicyVersion
                  }
                  return true
              }),
              (expression.externalVersions ?? [:]).allSatisfy({ id,version in
                  guard let external=catalog[id] else { return false }
                  return external.transcriptVersionID == version && external.policyVersion == expression.externalPolicies?[id] && !external.localOnly && !external.needsTranscriptionReview
              }) else { return nil }
        return expression
    }
}

/// Everything the source page reads, derived once per workspace snapshot.
public struct SourcePageIndex: Sendable {
    public let recordsByID: [String: SourceRecord]
    private let expressionBySourceID: [String: RecordingExpression]
    private let claimByID: [String: CandidateClaim]
    private let actionByID: [String: ActionRecord]
    private let actionPositionByID: [String: Int]
    private let actionIDsBySourceID: [String: [String]]
    private let reviewRequiredActionIDs: Set<String>

    public init(records: [SourceRecord] = [], claims: [CandidateClaim] = [], actions: [ActionRecord] = [],
                currentClaimsBySource: [String: [CandidateClaim]] = [:],
                ledgers: [String: ActionReviewLedger] = [:]) {
        let recordsByID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.recordsByID = recordsByID
        var expressions: [String: RecordingExpression] = [:]
        for record in records {
            if let expression = record.recordingExpression(in: recordsByID) { expressions[record.id] = expression }
        }
        expressionBySourceID = expressions

        var claimByID: [String: CandidateClaim] = [:]
        var actionsByClaimID: [String: [ActionRecord]] = [:]
        for claim in claims { claimByID[claim.id] = claim }
        self.claimByID = claimByID
        var positions: [String: Int] = [:]
        for (offset, action) in actions.enumerated() {
            actionsByClaimID[action.claimID, default: []].append(action)
            positions[action.id] = offset
        }
        var actionIDsBySourceID: [String: [String]] = [:]
        var actionByID: [String: ActionRecord] = [:]
        for action in actions where action.state != "dismissed" {
            actionByID[action.id] = action
            guard let claim = claimByID[action.claimID] else { continue }
            for sourceID in Set(claim.references.map(\.sourceID)) {
                actionIDsBySourceID[sourceID, default: []].append(action.id)
            }
        }
        self.actionByID = actionByID
        actionPositionByID = positions
        self.actionIDsBySourceID = actionIDsBySourceID

        // The pause gate only reads sources that carry an expression, and the
        // other two arguments narrow to this action's own claim and actions.
        let expressionSources = records.filter { $0.presentation?.expression != nil }
        var reviewRequired: Set<String> = []
        for action in actionByID.values {
            let claim = claimByID[action.claimID]
            if WorkspaceActionPause.reason(for: action, sources: expressionSources,
                                           claims: claim.map { [$0] } ?? [],
                                           currentClaimsBySource: currentClaimsBySource,
                                           actions: actionsByClaimID[action.claimID] ?? [],
                                           ledgers: ledgers) != nil {
                reviewRequired.insert(action.id)
            }
        }
        reviewRequiredActionIDs = reviewRequired
    }

    /// The validated expression for a source, or nil when members or
    /// permissions changed since it was saved.
    public func expression(for sourceID: String) -> RecordingExpression? {
        expressionBySourceID[sourceID]
    }

    public func claim(for claimID: String) -> CandidateClaim? {
        claimByID[claimID]
    }

    public func activeAction(for actionID: String) -> ActionRecord? {
        actionByID[actionID]
    }

    /// Actions whose claim cites any of these sources, in workspace order.
    public func actions(for sourceIDs: Set<String>) -> [ActionRecord] {
        var seen: Set<String> = []
        var ids: [String] = []
        for sourceID in sourceIDs {
            for id in actionIDsBySourceID[sourceID] ?? [] {
                if seen.insert(id).inserted { ids.append(id) }
            }
        }
        ids.sort { (actionPositionByID[$0] ?? 0) < (actionPositionByID[$1] ?? 0) }
        return ids.compactMap { actionByID[$0] }
    }

    /// The same decision `ControlCenter.workspaceTaskRequiresReview` makes.
    public func requiresReview(_ actionID: String) -> Bool {
        reviewRequiredActionIDs.contains(actionID)
    }
}

extension VoiceOSStore {
    public func attachRecordingContext(personalSourceID: String, externalSourceID: String, sessionID: String, offsetMS: Int = 0) throws {
        let catalog = Dictionary(uniqueKeysWithValues: try sources().map { ($0.id, $0) })
        guard let personal=catalog[personalSourceID],let external=catalog[externalSourceID],
              personal.origin == "user",personal.speaker == "user",external.origin == "external",external.speaker != "user",
              !personal.localOnly,!external.localOnly,!sessionID.isEmpty,
              let personalVersion=personal.transcriptVersionID,let externalVersion=external.transcriptVersionID,
              !personal.needsTranscriptionReview,!external.needsTranscriptionReview,
              !(personal.transcript ?? "").isEmpty,!(external.transcript ?? "").isEmpty else { throw VoiceOSError("双轨配对需要已授权并完整核对的本人和节目原话") }
        var presentation=personal.presentation ?? RecordingPresentation()
        let pairing=RecordingContext(personalSourceID:personalSourceID,externalSourceID:externalSourceID,sessionID:sessionID,offsetMS:offsetMS,personalVersionID:personalVersion,externalVersionID:externalVersion,personalPolicyVersion:personal.policyVersion,externalPolicyVersion:external.policyVersion)
        if let old=presentation.recordingContext,try Self.relevanceJSON(old) == Self.relevanceJSON(pairing) { return }
        presentation.recordingContext=pairing;presentation.contextLinks=nil
        try saveExpressionPresentation(presentation,sourceID:personalSourceID)
    }
    public func recordingContext(sourceID: String) throws -> RecordingContext? {
        try recordingContext(sourceID: sourceID, catalog: Dictionary(uniqueKeysWithValues: try sources().map { ($0.id,$0) }))
    }
    public func recordingContext(sourceID: String, catalog:[String:SourceRecord]) throws -> RecordingContext? {
        guard let personal=catalog[sourceID],let pairing=personal.presentation?.recordingContext else { return nil }
        guard pairing.personalSourceID == sourceID,let external=catalog[pairing.externalSourceID],
              personal.origin == "user",personal.speaker == "user",external.origin == "external",external.speaker != "user",
              !personal.localOnly,!external.localOnly,!personal.needsTranscriptionReview,!external.needsTranscriptionReview,
              personal.transcriptVersionID == pairing.personalVersionID,external.transcriptVersionID == pairing.externalVersionID,
              personal.policyVersion == pairing.personalPolicyVersion,external.policyVersion == pairing.externalPolicyVersion else { throw VoiceOSError("双轨原话或许可已变化，需要重新关联后继续理解") }
        return pairing
    }
    public func recordingContextSourceIDs(sourceIDs: [String]) throws -> [String] {
        try recordingContextSourceIDs(sourceIDs: sourceIDs, catalog: Dictionary(uniqueKeysWithValues: try sources().map { ($0.id,$0) }))
    }
    public func recordingContextSourceIDs(sourceIDs: [String], catalog:[String:SourceRecord]) throws -> [String] {
        var result=sourceIDs,seen=Set(sourceIDs)
        for id in sourceIDs {
            if let pair=try recordingContext(sourceID:id,catalog:catalog),seen.insert(pair.externalSourceID).inserted { result.append(pair.externalSourceID) }
        }
        return result
    }
    public func prepareRecordingContext(sourceID: String) throws -> RecordingContextSnapshot? {
        guard let pairing=try recordingContext(sourceID:sourceID) else { return nil }
        let catalog=try sources().filter { $0.id == sourceID || $0.id == pairing.externalSourceID }
        let context=try prepareLocalTranscriptContext(sourceIDs:[sourceID,pairing.externalSourceID],scalarBudget:max(1,catalog.reduce(0) { $0 + ($1.transcript?.unicodeScalars.count ?? 0) }))
        return .init(pairing:pairing,context:context)
    }
    public func recordingContextLinks(sourceID: String) throws -> [RecordingContextLink] {
        guard let pair=try recordingContext(sourceID:sourceID),let source=try sources().first(where: { $0.id == sourceID }) else { return [] }
        let claims=Dictionary(uniqueKeysWithValues:try candidateClaims().map { ($0.id,$0) })
        return try (source.presentation?.contextLinks ?? []).filter { link in
            guard let personal=claims[link.personalClaimID],let external=claims[link.externalClaimID],
                  personal.reviewVersion == link.personalReviewVersion,external.reviewVersion == link.externalReviewVersion,
                  personal.ownership == "user_tentative",external.ownership == "external",
                  personal.reviewState != "rejected",external.reviewState != "rejected" else { return false }
            return try Self.relevanceJSON(link.pairing) == Self.relevanceJSON(pair)
        }
    }
}
