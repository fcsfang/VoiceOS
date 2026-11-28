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
/// The source fields shared by full records and targeted validation reads.
protocol RecordingSourceFacts {
    var id: String { get }
    var state: String { get }
    var origin: String { get }
    var speaker: String { get }
    var localOnly: Bool { get }
    var needsTranscriptionReview: Bool { get }
    var recordingTranscriptVersionID: String? { get }
    var policyVersion: Int { get }
    var presentation: RecordingPresentation? { get }
}

extension RecordingSourceFacts {
    var isPersonalRecording: Bool { origin == "user" && speaker == "user" }
    var isExternalRecording: Bool { origin == "external" && speaker != "user" }
    var canUseRecordingContextText: Bool { !localOnly && !needsTranscriptionReview }
}

extension SourceRecord: RecordingSourceFacts {
    var recordingTranscriptVersionID: String? { transcriptVersionID }
}

extension RecordingContext {
    func matchesCurrentRevisions<Source: RecordingSourceFacts>(personalSourceID: String,
                                                                 personal: Source, external: Source) -> Bool {
        self.personalSourceID == personalSourceID &&
            personal.canUseRecordingContextText && external.canUseRecordingContextText &&
            personal.recordingTranscriptVersionID == personalVersionID &&
            external.recordingTranscriptVersionID == externalVersionID &&
            personal.policyVersion == personalPolicyVersion &&
            external.policyVersion == externalPolicyVersion
    }

    func canSupplyContext<Source: RecordingSourceFacts>(personalSourceID: String,
                                                        personal: Source, external: Source) -> Bool {
        personal.isPersonalRecording && external.isExternalRecording &&
            matchesCurrentRevisions(personalSourceID: personalSourceID, personal: personal, external: external)
    }
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
        guard case .success(let expression) = resolveRecordingExpression(in: catalog) else { return nil }
        return expression
    }

    internal func resolveRecordingExpression(in catalog: [String: SourceRecord])
        -> Result<RecordingExpression, RecordingExpressionInvalidity>? {
        guard presentation?.expression != nil else { return nil }
        guard let expression = recordingExpression else { return .failure(.sourceChanged) }
        if let invalidity = expression.invalidity(in: catalog, for: .reading) { return .failure(invalidity) }
        return .success(expression)
    }
}

/// Finds the paragraph under one playback position without rescanning the
/// transcript on every tick. Sorted, non-overlapping paragraphs use binary
/// search; other layouts keep the original first-match scan.
public struct SourceParagraphWindow: Sendable {
    public struct Paragraph: Sendable, Hashable {
        public let id: String
        public let startMS: Int
        public let endMS: Int
        public init(id: String, startMS: Int, endMS: Int) {
            self.id = id; self.startMS = startMS; self.endMS = endMS
        }
    }
    private let paragraphs: [Paragraph]
    private let starts: [Int]?

    public init(paragraphs: [Paragraph]) {
        self.paragraphs = paragraphs
        var ordered = true
        for index in 1..<max(paragraphs.count, 1) where index < paragraphs.count {
            if paragraphs[index].startMS < paragraphs[index - 1].startMS ||
                paragraphs[index].startMS < paragraphs[index - 1].endMS {
                ordered = false
                break
            }
        }
        starts = ordered ? paragraphs.map(\.startMS) : nil
    }

    public func activeID(at milliseconds: Int?) -> String? {
        guard let milliseconds else { return nil }
        guard let starts else {
            return paragraphs.first { milliseconds >= $0.startMS && milliseconds < $0.endMS }?.id
        }
        var low = 0, high = starts.count - 1, found: Int?
        while low <= high {
            let middle = (low + high) / 2
            if starts[middle] <= milliseconds {
                found = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        guard let found, milliseconds < paragraphs[found].endMS else { return nil }
        return paragraphs[found].id
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
    private let openActionIDsBySourceID: [String: Set<String>]
    private let allActionByID: [String: ActionRecord]
    /// Task-kind actions that need review, in workspace order. The same set
    /// `workspacePausedTasks` derives; dismissed actions never pause.
    public let pausedTasks: [ActionRecord]
    private let expressionIssueBySourceID: [String: String]
    private let correctionGroupOwnerIDs: Set<String>
    private let correctionAffectedSourceIDs: Set<String>
    /// Materials with unresolved transcription doubts, derived once per
    /// snapshot instead of once per sidebar and processing-page body.
    public let transcriptReviewPoints: [WorkspaceTranscriptReviewPoint]
    /// Record-only attention gates: failed or blocked jobs, interrupted or
    /// quarantined materials, and empty transcriptions awaiting review.
    public let recordsNeedAttention: Bool
    /// Open next steps per outcome, counted once per snapshot.
    public let nextStepCounts: [String: Int]
    /// The action revision key the actions page uses to refetch focus.
    public let actionRevisionKey: String
    private let actionsInOrder: [ActionRecord]

    public init(records: [SourceRecord] = [], claims: [CandidateClaim] = [], actions: [ActionRecord] = [],
                currentClaimsBySource: [String: [CandidateClaim]] = [:],
                ledgers: [String: ActionReviewLedger] = [:]) {
        let recordsByID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.recordsByID = recordsByID
        var expressions: [String: RecordingExpression] = [:]
        var issues: [String: String] = [:]
        for record in records {
            switch record.resolveRecordingExpression(in: recordsByID) {
            case .success(let expression): expressions[record.id] = expression
            case .failure(let invalidity):
                if let saved = record.presentation?.expression, saved.sourceIDs.count > 1 {
                    issues[record.id] = invalidity.message
                }
            case nil: break
            }
        }
        expressionBySourceID = expressions
        expressionIssueBySourceID = issues.filter { expressions[$0.key] == nil }

        let correctionGroups = records.compactMap { RecordingCorrectionGroup(ownerID: $0.id, presentation: $0.presentation) }
        correctionGroupOwnerIDs = Set(correctionGroups.map(\.ownerID))
        correctionAffectedSourceIDs = Set(correctionGroups.flatMap(\.memberIDs)).union(correctionGroups.compactMap(\.programmeID))

        var claimByID: [String: CandidateClaim] = [:]
        for claim in claims { claimByID[claim.id] = claim }
        self.claimByID = claimByID
        var positions: [String: Int] = [:]
        for (offset, action) in actions.enumerated() {
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
        var allActionByID: [String: ActionRecord] = [:]
        for action in actions where allActionByID[action.id] == nil { allActionByID[action.id] = action }
        self.allActionByID = allActionByID

        // Indexed once per snapshot; each action read is a dictionary lookup.
        let gate = WorkspaceActionPause.Gate(sources: records, claims: claims,
                                             currentClaimsBySource: currentClaimsBySource,
                                             actions: actions, ledgers: ledgers)
        var reviewRequired: Set<String> = []
        for action in actionByID.values where gate.reason(for: action) != nil {
            reviewRequired.insert(action.id)
        }
        reviewRequiredActionIDs = reviewRequired
        var paused: [ActionRecord] = []
        for action in actions where action.kind == "task" && reviewRequired.contains(action.id) { paused.append(action) }
        pausedTasks = paused

        var openActionIDsBySourceID: [String: Set<String>] = [:]
        for action in actionByID.values where action.isCurrentOpenTask && !reviewRequired.contains(action.id) {
            guard let claim = claimByID[action.claimID] else { continue }
            for sourceID in Set(claim.references.map(\.sourceID)) {
                openActionIDsBySourceID[sourceID, default: []].insert(action.id)
            }
        }
        self.openActionIDsBySourceID = openActionIDsBySourceID

        transcriptReviewPoints = records.compactMap { source -> WorkspaceTranscriptReviewPoint? in
            guard !source.isTrashed, !source.isArchived else { return nil }
            let count = source.unresolvedTranscriptionIssueCount
            guard count > 0 else { return nil }
            return WorkspaceTranscriptReviewPoint(source: source, count: count)
        }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.source.displayTitle < $1.source.displayTitle }
        var needsAttention = false
        for record in records {
            if ["failed", "blocked"].contains(record.jobState ?? "")
                || ["interrupted", "quarantined"].contains(record.state)
                || record.needsEmptyTranscriptionReview {
                needsAttention = true
                break
            }
        }
        recordsNeedAttention = needsAttention
        nextStepCounts = ActionRowLayout.nextStepCounts(actions)
        actionRevisionKey = actions.map {
            $0.id + String($0.version) + $0.state + $0.validity
        }.joined(separator: "|")
        actionsInOrder = actions
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

    /// Every action including dismissed ones, for task pages and discussion
    /// entry that must open dismissed history; `activeAction(for:)` stays live-only.
    public func allAction(for actionID: String) -> ActionRecord? {
        allActionByID[actionID]
    }

    /// The saved-expression issue for a source, decided once per snapshot.
    public func expressionIssue(for sourceID: String) -> String? {
        expressionIssueBySourceID[sourceID]
    }

    public func isRecordingUnderstandingPending(for sourceID: String) -> Bool {
        if correctionAffectedSourceIDs.contains(sourceID) { return true }
        if let expression = expressionBySourceID[sourceID] {
            return expression.sourceIDs.contains(where: correctionGroupOwnerIDs.contains)
        }
        return correctionGroupOwnerIDs.contains(sourceID)
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

    /// Open, current tasks still to do for any of these materials. One
    /// snapshot lookup per source; expression rows union their members.
    public func openActionCount(for sourceIDs: Set<String>) -> Int {
        var ids: Set<String> = []
        for sourceID in sourceIDs { ids.formUnion(openActionIDsBySourceID[sourceID] ?? []) }
        return ids.count
    }

    /// Expressions validated for the source page, keyed by source. Materials
    /// grouping reuses this map instead of revalidating each expression.
    public var expressionsBySourceID: [String: RecordingExpression] { expressionBySourceID }

    /// Topic load keys for the given actions in workspace order. Same filter
    /// and order as the topic action list, without joining the whole list.
    public func currentActionKeys(for actionIDs: Set<String>) -> [String] {
        actionsInOrder.compactMap { action in
            guard actionIDs.contains(action.id), action.validity == "current",
                  action.state != "dismissed" else { return nil }
            return action.id + String(action.version)
        }
    }
}

extension VoiceOSStore {
    /// A recording's context can use only its directly paired programme.
    func recordingContextCatalog(sourceIDs: [String]) throws -> [String: SourceRecord] {
        let sources = try sourceRecords(ids: Array(Set(sourceIDs)))
        let companionIDs = Set(sources.compactMap { $0.presentation?.recordingContext?.externalSourceID })
            .subtracting(sources.map(\.id))
        let companions = try sourceRecords(ids: Array(companionIDs))
        return Dictionary(uniqueKeysWithValues: (sources + companions).map { ($0.id, $0) })
    }

    public func attachRecordingContext(personalSourceID: String, externalSourceID: String, sessionID: String, offsetMS: Int = 0) throws {
        let catalog = Dictionary(try sourceRecords(ids: [personalSourceID, externalSourceID]).map { ($0.id, $0) },
                                 uniquingKeysWith: { first, _ in first })
        guard let personal=catalog[personalSourceID],let external=catalog[externalSourceID],
              personal.isPersonalRecording, external.isExternalRecording,
              personal.canUseRecordingContextText, external.canUseRecordingContextText, !sessionID.isEmpty,
              let personalVersion=personal.transcriptVersionID,let externalVersion=external.transcriptVersionID,
              !(personal.transcript ?? "").isEmpty,!(external.transcript ?? "").isEmpty else { throw VoiceOSError("双轨配对需要已授权并完整核对的本人和节目原话") }
        var presentation=personal.presentation ?? RecordingPresentation()
        let pairing=RecordingContext(personalSourceID:personalSourceID,externalSourceID:externalSourceID,sessionID:sessionID,offsetMS:offsetMS,personalVersionID:personalVersion,externalVersionID:externalVersion,personalPolicyVersion:personal.policyVersion,externalPolicyVersion:external.policyVersion)
        if let old=presentation.recordingContext,try Self.relevanceJSON(old) == Self.relevanceJSON(pairing) { return }
        presentation.recordingContext=pairing;presentation.contextLinks=nil
        try saveExpressionPresentation(presentation,sourceID:personalSourceID)
    }
    public func recordingContext(sourceID: String) throws -> RecordingContext? {
        try recordingContext(sourceID: sourceID, catalog: recordingContextCatalog(sourceIDs: [sourceID]))
    }
    public func recordingContext(sourceID: String, catalog:[String:SourceRecord]) throws -> RecordingContext? {
        guard let personal=catalog[sourceID],let pairing=personal.presentation?.recordingContext else { return nil }
        guard let external = catalog[pairing.externalSourceID],
              pairing.canSupplyContext(personalSourceID: sourceID, personal: personal, external: external) else {
            throw VoiceOSError("双轨原话或许可已变化，需要重新关联后继续理解")
        }
        return pairing
    }
    public func recordingContextSourceIDs(sourceIDs: [String]) throws -> [String] {
        try recordingContextSourceIDs(sourceIDs: sourceIDs, catalog: recordingContextCatalog(sourceIDs: sourceIDs))
    }
    public func recordingContextSourceIDs(sourceIDs: [String], catalog:[String:SourceRecord]) throws -> [String] {
        var result=sourceIDs,seen=Set(sourceIDs)
        for id in sourceIDs {
            if let pair=try recordingContext(sourceID:id,catalog:catalog),seen.insert(pair.externalSourceID).inserted { result.append(pair.externalSourceID) }
        }
        return result
    }
    public func prepareRecordingContext(sourceID: String) throws -> RecordingContextSnapshot? {
        try prepareRecordingContext(sourceID: sourceID, catalog: recordingContextCatalog(sourceIDs: [sourceID]))
    }
    func prepareRecordingContext(sourceID: String, catalog: [String: SourceRecord]) throws -> RecordingContextSnapshot? {
        guard let pairing=try recordingContext(sourceID:sourceID,catalog:catalog) else { return nil }
        let members = [sourceID, pairing.externalSourceID]
        let budget = members.reduce(0) { $0 + (catalog[$1]?.transcript?.unicodeScalars.count ?? 0) }
        let context=try prepareLocalTranscriptContext(sourceIDs:members,scalarBudget:max(1,budget))
        return .init(pairing:pairing,context:context)
    }
    public func recordingContextLinks(sourceID: String) throws -> [RecordingContextLink] {
        let catalog = try recordingContextCatalog(sourceIDs: [sourceID])
        return try recordingContextLinks(sourceIDs: [sourceID], catalog: catalog)
    }
    /// One catalog and one claim read serve every source on the page.
    public func recordingContextLinks(sourceIDs: [String], catalog: [String: SourceRecord]) throws -> [RecordingContextLink] {
        let claims = Dictionary(try candidateClaims().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return try recordingContextLinks(sourceIDs: sourceIDs, catalog: catalog, claimsByID: claims)
    }
    func recordingContextLinks(sourceIDs: [String], catalog: [String: SourceRecord],
                               claimsByID: [String: CandidateClaim]) throws -> [RecordingContextLink] {
        var result: [RecordingContextLink] = []
        for sourceID in sourceIDs {
            guard let source = catalog[sourceID],
                  let pair = try recordingContext(sourceID: sourceID, catalog: catalog) else { continue }
            result += try Self.validContextLinks(source: source, claimsByID: claimsByID, pairing: pair)
        }
        return result
    }
    static func validContextLinks(source: SourceRecord, claimsByID: [String: CandidateClaim],
                                  pairing: RecordingContext) throws -> [RecordingContextLink] {
        try (source.presentation?.contextLinks ?? []).filter { link in
            guard let personal = claimsByID[link.personalClaimID], let external = claimsByID[link.externalClaimID],
                  personal.reviewVersion == link.personalReviewVersion, external.reviewVersion == link.externalReviewVersion,
                  personal.ownership == "user_tentative", external.ownership == "external",
                  personal.reviewState != "rejected", external.reviewState != "rejected" else { return false }
            return try Self.relevanceJSON(link.pairing) == Self.relevanceJSON(pairing)
        }
    }
}
