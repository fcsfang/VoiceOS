import Foundation

public enum WorkspaceActionPauseReason: String, Sendable, Equatable, Hashable {
    case recordingActionReview
    case extractionPaused
}

public enum WorkspaceActionPause {
    public static func reason(for action: ActionRecord,
                              sources: [SourceRecord],
                              claims: [CandidateClaim],
                              currentClaimsBySource: [String: [CandidateClaim]],
                              actions: [ActionRecord],
                              ledgers: [String: ActionReviewLedger] = [:]) -> WorkspaceActionPauseReason? {
        if recordingReviewRequired(action: action, sources: sources, claims: claims, ledgers: ledgers) {
            return action.state == "open" ? .recordingActionReview : nil
        }
        guard action.validity != "current", action.state == "open" else { return nil }
        if actions.contains(where: { $0.claimID == action.claimID && $0.validity == "current" && $0.claimReviewVersion > action.claimReviewVersion }) {
            return nil
        }
        let references = claims.first(where: { $0.id == action.claimID })?.references ?? []
        // The latest completed extraction is shown at its source. Keep earlier records
        // in history instead of making the same recording ask for repair forever.
        let replaced = !references.isEmpty && references.allSatisfy { reference in
            let latest = currentClaimsBySource[reference.sourceID] ?? []
            return !latest.isEmpty && !latest.contains { $0.id == action.claimID }
        }
        return replaced ? nil : .extractionPaused
    }

    public static func recordingReviewRequired(action: ActionRecord,
                                               sources: [SourceRecord],
                                               claims: [CandidateClaim],
                                               ledgers: [String: ActionReviewLedger] = [:]) -> Bool {
        let sourceIDs = Set(claims.first(where: { $0.id == action.claimID })?.references.map(\.sourceID) ?? [])
        return sources.contains { source in
            guard let expression = source.presentation?.expression else { return false }
            guard sourceIDs.contains(source.id) || expression.previousActionIDs.contains(action.id) else { return false }
            return ledgers[expression.id]?.requiresReview(actionID: action.id) ?? true
        }
    }

    public static func evaluate(actionIDs: [String],
                                sources: [SourceRecord],
                                claims: [CandidateClaim],
                                currentClaimsBySource: [String: [CandidateClaim]],
                                actions: [ActionRecord],
                                ledgers: [String: ActionReviewLedger] = [:]) -> (resolved: [String], remaining: [String], reasons: [String: WorkspaceActionPauseReason]) {
        let actionsByID = Dictionary(uniqueKeysWithValues: actions.map { ($0.id, $0) })
        let gate = Gate(sources: sources, claims: claims, currentClaimsBySource: currentClaimsBySource,
                        actions: actions, ledgers: ledgers)
        var resolved: [String] = []
        var remaining: [String] = []
        var reasons: [String: WorkspaceActionPauseReason] = [:]
        for id in actionIDs {
            guard let action = actionsByID[id],
                  let reason = gate.reason(for: action) else {
                resolved.append(id)
                continue
            }
            remaining.append(id)
            reasons[id] = reason
        }
        return (resolved, remaining, reasons)
    }

    /// Per-snapshot dictionary reads. `reason(for:)` above stays the reference
    /// implementation; this gate makes repeated reads constant time.
    struct Gate {
        private let claimsByID: [String: CandidateClaim]
        private let expressionsBySourceID: [String: [RecordingExpression]]
        private let expressionsByPreviousActionID: [String: [RecordingExpression]]
        private let latestCurrentReviewVersionByClaimID: [String: Int]
        private let replacedClaimIDs: Set<String>
        private let ledgers: [String: ActionReviewLedger]

        init(sources: [SourceRecord], claims: [CandidateClaim],
             currentClaimsBySource: [String: [CandidateClaim]],
             actions: [ActionRecord], ledgers: [String: ActionReviewLedger]) {
            var claimsByID: [String: CandidateClaim] = [:]
            for claim in claims where claimsByID[claim.id] == nil { claimsByID[claim.id] = claim }
            self.claimsByID = claimsByID
            var bySource: [String: [RecordingExpression]] = [:]
            var byPreviousAction: [String: [RecordingExpression]] = [:]
            for source in sources {
                guard let expression = source.presentation?.expression else { continue }
                bySource[source.id, default: []].append(expression)
                for actionID in expression.previousActionIDs {
                    byPreviousAction[actionID, default: []].append(expression)
                }
            }
            expressionsBySourceID = bySource
            expressionsByPreviousActionID = byPreviousAction
            var latest: [String: Int] = [:]
            for action in actions where action.validity == "current" {
                latest[action.claimID] = max(latest[action.claimID] ?? Int.min, action.claimReviewVersion)
            }
            latestCurrentReviewVersionByClaimID = latest
            var replaced: Set<String> = []
            for claim in claimsByID.values where !claim.references.isEmpty {
                let gone = claim.references.allSatisfy { reference in
                    let latestClaims = currentClaimsBySource[reference.sourceID] ?? []
                    return !latestClaims.isEmpty && !latestClaims.contains { $0.id == claim.id }
                }
                if gone { replaced.insert(claim.id) }
            }
            replacedClaimIDs = replaced
            self.ledgers = ledgers
        }

        func reason(for action: ActionRecord) -> WorkspaceActionPauseReason? {
            if recordingReviewRequired(action) {
                return action.state == "open" ? .recordingActionReview : nil
            }
            guard action.validity != "current", action.state == "open" else { return nil }
            if let latest = latestCurrentReviewVersionByClaimID[action.claimID],
               latest > action.claimReviewVersion { return nil }
            return replacedClaimIDs.contains(action.claimID) ? nil : .extractionPaused
        }

        private func recordingReviewRequired(_ action: ActionRecord) -> Bool {
            if let claim = claimsByID[action.claimID] {
                for reference in claim.references {
                    if expressionsBySourceID[reference.sourceID]?.contains(where: { requiresReview($0, action.id) }) == true {
                        return true
                    }
                }
            }
            return expressionsByPreviousActionID[action.id]?.contains(where: { requiresReview($0, action.id) }) == true
        }

        private func requiresReview(_ expression: RecordingExpression, _ actionID: String) -> Bool {
            ledgers[expression.id]?.requiresReview(actionID: actionID) ?? true
        }
    }
}
