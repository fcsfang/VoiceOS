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
        var resolved: [String] = []
        var remaining: [String] = []
        var reasons: [String: WorkspaceActionPauseReason] = [:]
        for id in actionIDs {
            guard let action = actionsByID[id],
                  let reason = reason(for: action, sources: sources, claims: claims,
                                      currentClaimsBySource: currentClaimsBySource, actions: actions,
                                      ledgers: ledgers) else {
                resolved.append(id)
                continue
            }
            remaining.append(id)
            reasons[id] = reason
        }
        return (resolved, remaining, reasons)
    }
}
