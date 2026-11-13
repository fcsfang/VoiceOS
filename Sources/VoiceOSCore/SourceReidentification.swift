import Foundation

public struct SourceReidentificationRequest: Sendable {
    public let sourceID: String
    public let pausedActionIDs: [String]
    public let cognition: ModelConfiguration
    public let association: ModelConfiguration?
    public let semantic: Bool
    public init(sourceID: String, pausedActionIDs: [String], cognition: ModelConfiguration,
                association: ModelConfiguration?, semantic: Bool) {
        self.sourceID = sourceID
        self.pausedActionIDs = pausedActionIDs
        self.cognition = cognition
        self.association = association
        self.semantic = semantic
    }
}

public struct SourceReidentificationReport: Sendable, Equatable {
    public let claimIDs: [String]
    public let reused: Bool
    public let resolvedActionIDs: [String]
    public let remainingActionIDs: [String]
}

public enum SourceReidentificationResult: Sendable, Equatable {
    case completed(SourceReidentificationReport)
    case skipped(PausedActionBatchSkipReason)
    case failed(String)
}

extension VoiceOSStore {
    public func reidentifySource(_ request: SourceReidentificationRequest,
                                 cognitionPort: any ModelPort,
                                 associationPort: (any ExpressionAssociationPort)?,
                                 retrieval: any LocalRetrievalPort) async throws -> SourceReidentificationResult {
        try Task.checkCancellation()
        guard let source = try sources().first(where: { $0.id == request.sourceID }) else { return .skipped(.unavailableSource) }
        if source.state == "quarantined" { return .skipped(.quarantined) }
        guard ["saved", "reference_only"].contains(source.state) else { return .skipped(.unavailableSource) }
        guard let transcript = source.transcript, !transcript.isEmpty else { return .skipped(.missingTranscript) }
        guard !source.localOnly else { return .skipped(.localOnly) }
        var snapshot = try workspaceSnapshot()
        if !request.pausedActionIDs.isEmpty {
            let evaluation = WorkspaceActionPause.evaluate(actionIDs: request.pausedActionIDs, sources: snapshot.sources,
                                                           claims: snapshot.claims,
                                                           currentClaimsBySource: snapshot.currentClaimsBySource,
                                                           actions: snapshot.actions,
                                                           ledgers: snapshot.actionReviewLedgers)
            if evaluation.remaining.isEmpty { return .skipped(.noLongerPaused) }
        }
        let personal = source.origin == "user" && source.speaker == "user" && ["user_text", "audio"].contains(source.kind)
        let reused: Bool
        if personal {
            guard let association = request.association, let associationPort else {
                throw VoiceOSError("关联模型尚未配置；个人表达尚未排队")
            }
            let previousClaimIDs = Set(snapshot.currentClaimsBySource[request.sourceID]?.map(\.id) ?? [])
            let prepared = try prepareExpressionProcessingIntent(sourceID: request.sourceID,
                                                                 cognition: request.cognition,
                                                                 association: association)
            let intent = try enqueueExpressionProcessingIntent(prepared,
                                                              commandID: "understand:" + request.sourceID + ":" + prepared.contentDigest,
                                                              cognition: request.cognition,
                                                              association: association)
            let record = try await runExpressionProcessingIntent(id: intent.id, retrieval: retrieval,
                                                                 cognitionPort: cognitionPort,
                                                                 associationPort: associationPort,
                                                                 semantic: request.semantic)
            switch record.state {
            case .completed:
                snapshot = try workspaceSnapshot()
                let claimIDs = Set(snapshot.currentClaimsBySource[request.sourceID]?.map(\.id) ?? [])
                reused = !previousClaimIDs.isEmpty && previousClaimIDs == claimIDs
            case .cancelled:
                return .failed("已有处理记录：cancelled，不会自动重发")
            default:
                return .failed("已有处理记录：" + record.state.rawValue + (record.error.map { "：" + $0 } ?? ""))
            }
        } else {
            let continuation = try await continueSourceUnderstanding(sourceID: request.sourceID, using: cognitionPort)
            guard continuation.state == "completed" || continuation.state == "discussion_completed" else {
                return .failed("已有理解记录：" + continuation.state + "；未重发")
            }
            reused = continuation.reused
        }
        snapshot = try workspaceSnapshot()
        let evaluation = WorkspaceActionPause.evaluate(actionIDs: request.pausedActionIDs, sources: snapshot.sources,
                                                       claims: snapshot.claims,
                                                       currentClaimsBySource: snapshot.currentClaimsBySource,
                                                       actions: snapshot.actions,
                                                       ledgers: snapshot.actionReviewLedgers)
        return .completed(SourceReidentificationReport(
            claimIDs: snapshot.currentClaimsBySource[request.sourceID]?.map(\.id) ?? [],
            reused: reused,
            resolvedActionIDs: evaluation.resolved,
            remainingActionIDs: evaluation.remaining))
    }
}
