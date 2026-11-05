import Foundation

public enum SourceReidentifyRoute: String, Sendable, Codable, Equatable {
    case textUnderstanding
    case segmented
    case wholeRecording
}

public enum PausedActionBatchSkipReason: String, Sendable, Codable, Equatable {
    case quarantined
    case unavailableSource
    case missingTranscript
    case localOnly
    case busy
    case noLongerPaused
}

public struct PausedActionBatchTarget: Identifiable, Sendable, Equatable {
    public let sourceID: String
    public let route: SourceReidentifyRoute
    public let actionIDs: [String]
    public let causes: Set<WorkspaceActionPauseReason>
    public var id: String { sourceID }
}

public struct PausedActionBatchSkip: Identifiable, Sendable, Equatable {
    public let sourceID: String
    public let actionIDs: [String]
    public let reason: PausedActionBatchSkipReason
    public var id: String { sourceID }
}

public struct PausedActionBatchPlan: Sendable, Equatable {
    public let targets: [PausedActionBatchTarget]
    public let skips: [PausedActionBatchSkip]
    public let reviewOnlyActionIDs: [String]
    public let withdrawnActionIDs: [String]
    public let unattachedActionIDs: [String]
    public var affectedMaterialCount: Int { targets.count }
    public var targetActionCount: Int { Set(targets.flatMap(\.actionIDs)).count }
    public var isBatchable: Bool { !targets.isEmpty }
}

public enum PausedActionBatch {
    public static func plan(snapshot: WorkspaceSnapshot,
                            additionallyBusySources: Set<String> = []) -> PausedActionBatchPlan {
        let actionsByID = Dictionary(uniqueKeysWithValues: snapshot.actions.map { ($0.id, $0) })
        let claimsByID = Dictionary(uniqueKeysWithValues: snapshot.claims.map { ($0.id, $0) })
        let sourcesByID = Dictionary(uniqueKeysWithValues: snapshot.sources.map { ($0.id, $0) })
        var reasonByActionID: [String: WorkspaceActionPauseReason] = [:]
        for action in snapshot.actions where action.kind == "task" {
            if let reason = WorkspaceActionPause.reason(for: action, sources: snapshot.sources, claims: snapshot.claims,
                                                        currentClaimsBySource: snapshot.currentClaimsBySource, actions: snapshot.actions) {
                reasonByActionID[action.id] = reason
            }
        }
        var actionIDsBySource: [String: Set<String>] = [:]
        var causesBySource: [String: Set<WorkspaceActionPauseReason>] = [:]
        var reviewOnly: [String] = []
        var withdrawn: [String] = []
        var unattached: [String] = []
        for actionID in reasonByActionID.keys.sorted() {
            guard let action = actionsByID[actionID], let reason = reasonByActionID[actionID] else { continue }
            if action.intent?.followupState == "withdrawn" {
                withdrawn.append(actionID)
                continue
            }
            if reason == .recordingActionReview {
                reviewOnly.append(actionID)
                continue
            }
            let sourceIDs = Set((claimsByID[action.claimID]?.references ?? []).map(\.sourceID))
            guard !sourceIDs.isEmpty else {
                unattached.append(actionID)
                continue
            }
            for sourceID in sourceIDs {
                actionIDsBySource[sourceID, default: []].insert(actionID)
                causesBySource[sourceID, default: []].insert(reason)
            }
        }
        let busy = busySourceIDs(snapshot: snapshot, additionallyBusySources: additionallyBusySources)
        let orderedSourceIDs = actionIDsBySource.keys.sorted { lhs, rhs in
            let left = sourcesByID[lhs]?.createdAt ?? ""
            let right = sourcesByID[rhs]?.createdAt ?? ""
            return left == right ? lhs < rhs : left < right
        }
        var targets: [PausedActionBatchTarget] = []
        var skips: [PausedActionBatchSkip] = []
        for sourceID in orderedSourceIDs {
            let actionIDs = actionIDsBySource[sourceID, default: []].sorted()
            func skip(_ reason: PausedActionBatchSkipReason) {
                skips.append(PausedActionBatchSkip(sourceID: sourceID, actionIDs: actionIDs, reason: reason))
            }
            guard let source = sourcesByID[sourceID] else {
                skip(.unavailableSource)
                continue
            }
            if source.state == "quarantined" {
                skip(.quarantined)
                continue
            }
            guard ["saved", "reference_only"].contains(source.state) else {
                skip(.unavailableSource)
                continue
            }
            guard let transcript = source.transcript, !transcript.isEmpty else {
                skip(.missingTranscript)
                continue
            }
            guard !source.localOnly else {
                skip(.localOnly)
                continue
            }
            guard !busy.contains(sourceID) else {
                skip(.busy)
                continue
            }
            targets.append(PausedActionBatchTarget(sourceID: sourceID, route: route(for: source),
                                                   actionIDs: actionIDs, causes: causesBySource[sourceID, default: []]))
        }
        return PausedActionBatchPlan(targets: targets, skips: skips,
                                     reviewOnlyActionIDs: reviewOnly.sorted(),
                                     withdrawnActionIDs: withdrawn.sorted(),
                                     unattachedActionIDs: unattached.sorted())
    }

    public static func route(for source: SourceRecord) -> SourceReidentifyRoute {
        if source.origin == "user", source.transcriptionBackend?.hasPrefix("Qwen3-ASR") == true {
            return .wholeRecording
        }
        if source.origin == "user", (source.transcript?.unicodeScalars.count ?? 0) > 4000 {
            return .segmented
        }
        return .textUnderstanding
    }

    private static func busySourceIDs(snapshot: WorkspaceSnapshot, additionallyBusySources: Set<String>) -> Set<String> {
        var busy = additionallyBusySources
        for intent in snapshot.processingIntents where intent.state == .queued || intent.state == .running {
            busy.insert(intent.sourceID)
        }
        for batch in snapshot.segmentedBatches where batch.state == .queued {
            busy.insert(batch.scope.plan.source.sourceID)
        }
        for request in snapshot.recordingRequests where request.state == "waiting" || request.state == "enqueued" {
            busy.insert(request.sourceID)
        }
        return busy
    }
}
