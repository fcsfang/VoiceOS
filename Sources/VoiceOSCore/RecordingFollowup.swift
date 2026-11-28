import Foundation
import CryptoKit

public struct FollowupEvidence: Codable, Sendable, Equatable {
    public let reference: ClaimReference
    public let quote: String
    public let policyVersion: Int
}
public struct RememberedThought: Codable, Sendable, Equatable {
    public let id: String
    public let reviewVersion: Int
    public let statement: String
    public let evidence: [FollowupEvidence]
}
public struct FollowupTask: Codable, Sendable, Equatable {
    public let id: String
    public let version: Int
    public let title: String
    public let state: String
    public let goalID: String?
    public let feedback: [String]
}
public struct FollowupGoal: Codable, Sendable {
    public let id: String
    public let version: Int
    public let thought: RememberedThought
    public let title: String
    public var previousPlan: GoalPlan? = nil
}
public struct PracticeHistory: Codable, Sendable {
    public let sourceID: String
    public let transcriptVersionID: String
    public let text: String
    public let feedback: String
    public let policyVersion: Int
}
public struct RecordingFollowupInput: Codable, Sendable {
    public let current: LocalTranscriptContext
    public let policyVersion: Int
    public let recordedAt: String
    public let thoughts: [RememberedThought]
    public let goals: [FollowupGoal]
    public let tasks: [FollowupTask]
    public let practices: [PracticeHistory]
    public var currentUnderstanding: [String]? = nil
    public var feedbackActionID: String? = nil
    public var continuousExpression: ContinuousRecordingContext? = nil
}
public struct ThoughtUpdate: Codable, Sendable {
    public let claimID: String
    public let currentQuote: String
    public let historicalQuote: String
    public let relation: String
    public let understanding: String
    public let reason: String
}
public struct GoalStep: Codable, Sendable, Equatable {
    public let title: String
    public let condition: String
    public let existingTaskID: String
}
public struct GoalPhase: Codable, Sendable, Equatable {
    public let title: String
    public let steps: [GoalStep]
}
public struct GoalPlan: Codable, Sendable, Equatable {
    public let goalID: String
    public let summary: String
    public let adjustment: String
    public let phases: [GoalPhase]
    public let nextStep: GoalStep
}
public struct PracticeSuggestion: Codable, Sendable {
    public let original: String
    public let suggested: String
    public let explanation: String
    public let possibleTranscriptIssue: Bool
}
public struct PracticeComparison: Codable, Sendable {
    public let priorSourceID: String
    public let priorQuote: String
    public let currentQuote: String
    public let change: String
    public let explanation: String
}
public struct PracticeFollowup: Codable, Sendable {
    public let isPractice: Bool
    public let evidenceQuote: String
    public let suggestions: [PracticeSuggestion]
    public let comparisons: [PracticeComparison]
    public let nextExercise: String
}
public struct RecordingFollowupResult: Codable, Sendable {
    public let thoughtUpdates: [ThoughtUpdate]
    public let goalPlans: [GoalPlan]
    public let english: PracticeFollowup
}
public enum RecordingFollowupStage: String, Codable, Sendable {
    case selectHistory, generateFollowup
}
public struct RecordingFollowupRejectedResponse: Codable, Sendable {
    public let stage: RecordingFollowupStage
    public let wireAttempt: Int
    public let responseID: String?
    public let path: String
    public let diagnostic: String
    public let rawResponse: Data
}
public struct RecordingFollowupGeneration: Sendable {
    public let result: RecordingFollowupResult
    public let responseIDs: [String]
    public let rejectedResponses: [RecordingFollowupRejectedResponse]
    public init(result: RecordingFollowupResult, responseIDs: [String], rejectedResponses: [RecordingFollowupRejectedResponse] = []) {
        self.result = result; self.responseIDs = responseIDs; self.rejectedResponses = rejectedResponses
    }
}
struct RecordingFollowupGenerationFailure: LocalizedError {
    let underlying: Error
    let stage: RecordingFollowupStage?
    let responseIDs: [String]
    let rejectedResponses: [RecordingFollowupRejectedResponse]
    var errorDescription: String? {
        let stageName = stage == .selectHistory ? "相关历史选择" : "自动跟进"
        return stageName + "失败：" + underlying.localizedDescription
    }
}
public struct RecordingFollowupReceipt: Codable, Sendable, Identifiable {
    public let id: String
    public let inputDigest: String
    public var input: RecordingFollowupInput
    public var state: String
    public var result: RecordingFollowupResult?
    public var responseIDs: [String]
    public var error: String?
    public let createdAt: String
    public var retryCount: Int? = nil
    public var retryAt: String? = nil
    public var rejectedResponses: [RecordingFollowupRejectedResponse]? = nil
    public var sourceID: String { input.current.sources[0].sourceID }
}
/// Versioned launch summary of stored receipts. It keeps everything the
/// workspace renders, but drops transcript texts and spans so a large archive
/// never needs a full JSON decode at startup.
public struct FollowupReceiptDigest: Codable, Sendable {
    public static let currentVersion = 1
    public let version: Int
    public let receipts: [RecordingFollowupReceipt]
    public init(version: Int = FollowupReceiptDigest.currentVersion, receipts: [RecordingFollowupReceipt]) {
        self.version = version; self.receipts = receipts
    }
}
public struct RecordingFollowupValidity: Sendable {
    public let sourceCurrent: Bool
    public let thoughtClaimIDs: Set<String>
    public let goalIDs: Set<String>
    public let english: Bool
    public func thoughtIsCurrent(_ claimID: String) -> Bool { sourceCurrent && thoughtClaimIDs.contains(claimID) }
    public func goalIsCurrent(_ goalID: String) -> Bool { sourceCurrent && goalIDs.contains(goalID) }
}
public struct RecordingFollowupTransientError: LocalizedError {
    public let status: Int
    public var errorDescription: String? { "自动跟进模型 HTTP \(status)，服务暂时不可用，原件已保存" }
}
struct RecordingFollowupConformanceFailure: LocalizedError {
    let underlying: Error
    var errorDescription: String? { underlying.localizedDescription }
}
public protocol RecordingFollowupPort: Sendable {
    func generate(_ input: RecordingFollowupInput) async throws -> RecordingFollowupGeneration
}

/// Per-source transcript scalars, so validating many receipts for the same
/// recording does not re-split its text for every claim reference.
private final class FollowupTranscriptScalars {
    private var values: [String: [UnicodeScalar]] = [:]
    func scalars(sourceID: String, transcriptVersionID: String, text: String) -> [UnicodeScalar] {
        let key = sourceID + ":" + transcriptVersionID
        if let cached = values[key] { return cached }
        let computed = Array(text.unicodeScalars)
        values[key] = computed
        return computed
    }
}

extension VoiceOSStore {
    private func followupJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    private func rememberedThought(_ claim: CandidateClaim, catalog: [String: SourceRecord], scalarsCache: FollowupTranscriptScalars? = nil) throws -> RememberedThought? {
        guard claim.validity == "current", claim.ownership == "user_tentative", claim.reviewState != "rejected" else { return nil }
        var evidence: [FollowupEvidence] = []
        for ref in claim.references {
            guard let source = catalog[ref.sourceID], !source.localOnly,!source.needsTranscriptionReview, source.transcriptVersionID == ref.transcriptVersionID,
                  let span = source.spans.first(where: { $0.id == ref.spanID }), let text = source.transcript else { return nil }
            let scalars = scalarsCache?.scalars(sourceID: source.id, transcriptVersionID: ref.transcriptVersionID, text: text) ?? Array(text.unicodeScalars)
            evidence.append(.init(reference: ref, quote: String(String.UnicodeScalarView(scalars[span.textStart..<span.textEnd])), policyVersion: source.policyVersion))
        }
        guard !evidence.isEmpty else { return nil }
        return .init(id: claim.id, reviewVersion: claim.reviewVersion, statement: claim.statement, evidence: evidence)
    }

    private func followupFeedback(actions: [ActionRecord], claims: [String: CandidateClaim], catalog: [String: SourceRecord]) throws -> [String: [String]] {
        var feedback: [String: [String]] = [:]
        let versions = Dictionary(uniqueKeysWithValues: actions.map { ($0.id, $0.version) })
        for row in try db.query("""
        SELECT f.action_id,f.action_version,s.id,s.state,s.feedback_json,v.text FROM action_feedback f
        JOIN sources s ON s.id=f.source_id JOIN transcripts t ON t.source_id=s.id
        JOIN transcript_versions v ON v.id=t.current_version_id ORDER BY f.sequence
        """) {
            guard row["state"] == "saved", let sourceID = row["id"],catalog[sourceID]?.needsTranscriptionReview != true, let text = row["text"] else { continue }
            let intent = try Self.feedbackIntent(row["feedback_json"])
            if let claimID = intent?.organizedClaimID, claims[claimID]?.validity != "current" { continue }
            let original = intent?.recordingSourceID.flatMap { catalog[$0] }
            guard catalog[sourceID]?.localOnly == false || (original?.localOnly == false && original?.transcript?.contains(text) == true) else { continue }
            let actionID = row["action_id"]!, version = Int(row["action_version"]!)!
            let label = versions[actionID] == version ? "" : "[历史：第 \(version) 版行动的结果或反思，不代表本轮结果] "
            feedback[actionID, default: []].append(label + text)
        }
        return feedback
    }

    private func followupTasks(actions: [ActionRecord], claims: [String: CandidateClaim], catalog: [String: SourceRecord], goalIDByTaskID: [String: String], feedback preloaded: [String: [String]]? = nil, remembered: ((CandidateClaim) throws -> RememberedThought?)? = nil, scalarsCache: FollowupTranscriptScalars? = nil) throws -> [FollowupTask] {
        func thought(for claim: CandidateClaim) throws -> RememberedThought? {
            if let remembered { return try remembered(claim) }
            return try rememberedThought(claim, catalog: catalog, scalarsCache: scalarsCache)
        }
        let feedback = try preloaded ?? followupFeedback(actions: actions, claims: claims, catalog: catalog)
        return try actions.filter { $0.isCurrentTask && $0.intentActor == "user" && $0.state != "dismissed" }.compactMap { action in
            guard let claim = claims[action.claimID], try thought(for: claim) != nil else { return nil }
            return .init(id: action.id, version: action.version, title: action.title, state: action.state, goalID: action.intent?.goalID ?? goalIDByTaskID[action.id], feedback: feedback[action.id] ?? [])
        }.sorted { $0.id < $1.id }
    }

    private static func goalIDByTaskID(_ goals: [FollowupGoal]) -> [String: String] {
        var result: [String: String] = [:]
        for goal in goals {
            for step in goal.previousPlan?.phases.flatMap(\.steps) ?? [] where !step.existingTaskID.isEmpty {
                if result[step.existingTaskID] == nil { result[step.existingTaskID] = goal.id }
            }
        }
        return result
    }

    public func prepareRecordingFollowup(sourceID: String) throws -> RecordingFollowupInput {
        let catalog = Dictionary(try sources().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let scalarsCache = FollowupTranscriptScalars()
        guard let source = catalog[sourceID], !source.localOnly, source.origin == "user", source.speaker == "user", let text = source.transcript else { throw VoiceOSError("请先完成本人原话并允许文本模型处理") }
        try requireReviewedTranscriptions(sourceIDs:[sourceID],destination:.cloud)
        let current = try prepareLocalTranscriptContext(sourceIDs: [sourceID], scalarBudget: max(1, text.unicodeScalars.count))
        let claims = try candidateClaims(), actions = try actions(includeHistory: true)
        let latestBySource = try latestCandidateClaimsBySource()
        let latest = latestBySource.mapValues { Set($0.map(\.id)) }
        func currentThought(_ claim: CandidateClaim) -> Bool {
            claim.reviewState == "endorsed" || claim.references.allSatisfy { latest[$0.sourceID]?.contains(claim.id) == true }
        }
        let byID = Dictionary(uniqueKeysWithValues: claims.map { ($0.id, $0) })
        let taskClaims = Set(actions.filter { $0.kind == "task" }.map(\.claimID))
        let historical = try claims.filter { currentThought($0) && !taskClaims.contains($0.id) && !$0.references.contains(where: { $0.sourceID == sourceID }) }.compactMap { try rememberedThought($0, catalog: catalog, scalarsCache: scalarsCache) }
        var goals = try actions.filter { $0.validity == "current" && $0.state == "open" && $0.intent?.intentType == "goal" && $0.intent?.uncertain == false }.compactMap { action -> FollowupGoal? in
            guard let claim = byID[action.claimID], currentThought(claim), claim.reviewVersion == action.claimReviewVersion, let thought = try rememberedThought(claim, catalog: catalog, scalarsCache: scalarsCache) else { return nil }
            return .init(id: action.id, version: action.version, thought: thought, title: action.title)
        }
        let priorFollowups = try recordingFollowups()
        // Plan lookup compares against tasks before the plan-derived goal links,
        // because those links are read back from the plans chosen in this loop.
        let unlinkedTasks = try followupTasks(actions: actions, claims: byID, catalog: catalog, goalIDByTaskID: [:], scalarsCache: scalarsCache)
        for index in goals.indices {
            goals[index].previousPlan = priorFollowups.reversed().first(where: { prior in
                guard prior.state == "completed", let original = catalog[prior.sourceID], !original.localOnly,!original.needsTranscriptionReview,
                      original.policyVersion == prior.input.policyVersion, original.transcriptVersionID == prior.input.current.sources[0].transcriptVersionID,
                      let oldGoal = prior.input.goals.first(where: { $0.id == goals[index].id }), oldGoal.version == goals[index].version,
                      oldGoal.thought == goals[index].thought else { return false }
                return (prior.sourceID != sourceID || prior.input.tasks != unlinkedTasks) &&
                       prior.result?.goalPlans.contains(where: { $0.goalID == goals[index].id }) == true
            })?.result?.goalPlans.first(where: { $0.goalID == goals[index].id })
        }
        let tasks = try followupTasks(actions: actions, claims: byID, catalog: catalog, goalIDByTaskID: Self.goalIDByTaskID(goals), scalarsCache: scalarsCache)
        var practices: [PracticeHistory] = []
        for prior in priorFollowups.reversed() where prior.sourceID != sourceID && prior.state == "completed" && prior.result?.english.isPractice == true {
            guard !practices.contains(where: { $0.sourceID == prior.sourceID }), let old = catalog[prior.sourceID], !old.localOnly,
                  ["saved", "reference_only"].contains(old.state), !old.needsTranscriptionReview,
                  old.policyVersion == prior.input.policyVersion, let version = old.transcriptVersionID,
                  version == prior.input.current.sources[0].transcriptVersionID, let text = old.transcript,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  (try? followupContextIsCurrent(prior.input.current)) != nil,
                  (try? followupContinuousIsCurrent(prior.input.continuousExpression, sourceID: old.id)) != nil,
                  let english = prior.result?.english else { continue }
            let ownFeedback = PracticeFollowup(isPractice: english.isPractice, evidenceQuote: english.evidenceQuote,
                suggestions: english.suggestions, comparisons: [], nextExercise: english.nextExercise)
            practices.append(.init(sourceID: old.id, transcriptVersionID: version, text: text, feedback: try followupJSON(ownFeedback), policyVersion: old.policyVersion))
        }
        for prior in try englishFeedbackAttempts() where prior.validity == "current" && prior.state == "completed" && prior.currentSourceID != sourceID {
            guard !practices.contains(where: { $0.sourceID == prior.currentSourceID }), let old = catalog[prior.currentSourceID], !old.localOnly,
                  ["saved", "reference_only"].contains(old.state), !old.needsTranscriptionReview,
                  let version = old.transcriptVersionID, let text = old.transcript,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let result = prior.result else { continue }
            let ownFeedback = EnglishPracticeResponse(suggestions: result.suggestions, comparisons: [], inputTokens: result.inputTokens, outputTokens: result.outputTokens)
            practices.append(.init(sourceID: old.id, transcriptVersionID: version, text: text, feedback: try followupJSON(ownFeedback), policyVersion: old.policyVersion))
        }
        return .init(current: current, policyVersion: source.policyVersion, recordedAt: source.createdAt, thoughts: historical, goals: goals, tasks: tasks, practices: practices, currentUnderstanding: (latestBySource[sourceID] ?? []).map(\.statement), feedbackActionID: source.feedbackActionID,continuousExpression:try continuousRecordingContext(sourceID:sourceID))
    }

    /// An action change belongs to its goal's expression, never an arbitrary
    /// recent recording. Persist the work before starting the background worker.
    @discardableResult
    public func enqueueActionFollowups(actionIDs: Set<String>) throws -> [RecordingFollowupReceipt] {
        let actions = Dictionary(uniqueKeysWithValues: try actions(includeHistory: true).map { ($0.id, $0) })
        let claims = Dictionary(uniqueKeysWithValues: try candidateClaims().map { ($0.id, $0) })
        let catalog = Dictionary(try sources().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var sourceIDs = Set<String>()
        for id in actionIDs.sorted() {
            guard let action = actions[id], action.validity == "current" else { continue }
            let owner = action.intent?.goalID.flatMap { actions[$0] } ?? action
            guard let claim = claims[owner.claimID], claim.validity == "current",
                  let source = claim.references.compactMap({ catalog[$0.sourceID] }).first(where: {
                      !$0.localOnly && $0.origin == "user" && $0.speaker == "user" && $0.transcript != nil && ["saved", "reference_only"].contains($0.state)
                  }) else { continue }
            sourceIDs.insert(source.id)
        }
        return try sourceIDs.sorted().map { try enqueueRecordingFollowup(sourceID: $0) }
    }

    /// The stored digest is the archive identity. A cache hit reuses the decoded
    /// history without the body leaving SQLite; a row with a current receipt
    /// digest decodes only that small document. Only a missing or mismatched
    /// digest reads the body, then writes the receipt digest back once.
    public func recordingFollowups() throws -> [RecordingFollowupReceipt] {
        let rows = try db.query("SELECT id,followup_digest,followup_receipt_digest FROM sources WHERE followup_json IS NOT NULL ORDER BY created_at")
        var decoded: [RecordingFollowupReceipt] = []
        var cache = recordingFollowupDecodeCache
        var reused = 0, parsed = 0, digested = 0, backfilled = 0
        let token = StartupTrace.begin("followups.decode")
        for row in rows {
            guard let id = row["id"] else { continue }
            if let digest = row["followup_digest"], let cached = cache[id], cached.digest == digest {
                decoded.append(contentsOf: cached.receipts); reused += cached.receipts.count; continue
            }
            // The receipt digest is written together with the body hash. When
            // the hash is gone the body may have been replaced, so fall through.
            if let digest = row["followup_digest"], let stored = row["followup_receipt_digest"],
               let document = try? JSONDecoder().decode(FollowupReceiptDigest.self, from: Data(stored.utf8)),
               document.version == FollowupReceiptDigest.currentVersion {
                cache[id] = (digest, document.receipts)
                decoded.append(contentsOf: document.receipts); digested += document.receipts.count; continue
            }
            guard let json = try db.query("SELECT followup_json FROM sources WHERE id=?", [id]).first?["followup_json"] else { continue }
            let digest: String
            if let stored = row["followup_digest"] { digest = stored }
            else {
                digest = Self.relevanceHash(Data(json.utf8))
                backfilled += 1
            }
            let receipts: [RecordingFollowupReceipt]
            if let cached = cache[id], cached.digest == digest {
                receipts = cached.receipts; reused += receipts.count
            } else {
                receipts = try decodeWithPath([RecordingFollowupReceipt].self, from: Data(json.utf8), label: "跟进回执")
                parsed += receipts.count
            }
            let slim = Self.followupDigestReceipts(receipts)
            try db.execute("UPDATE sources SET followup_digest=?,followup_receipt_digest=? WHERE id=?", [digest, try Self.followupDigestJSON(receipts), id])
            cache[id] = (digest, slim)
            decoded.append(contentsOf: slim)
        }
        StartupTrace.end(token)
        let live = Set(rows.compactMap { $0["id"] })
        recordingFollowupDecodeCache = cache.filter { live.contains($0.key) }
        StartupTrace.mark("followups=\(decoded.count) reused=\(reused) parsed=\(parsed) digested=\(digested) backfilled=\(backfilled)")
        return decoded.sorted { $0.createdAt < $1.createdAt }
    }
    /// Requeues interrupted receipts and compacts legacy histories. Runs after the
    /// first workspace paint so a large follow-up archive never delays opening.
    @discardableResult
    public func recoverRecordingFollowups() throws -> Bool {
        let receipts = try recordingFollowups()
        var saves = 0
        for var receipt in receipts {
            if receipt.state == "running" {
                receipt.state = "queued"; receipt.error = "上次跟进被中断；录音和任务已保存，等待继续"
                try saveRecordingFollowup(receipt); saves += 1
            } else if receipt.state == "completed", receipt.result != nil {
                // Compaction only rewrites input, so compare that alone instead of
                // encoding the whole receipt twice on every launch.
                let compact = compactFollowup(receipt)
                if try followupJSON(compact.input) != followupJSON(receipt.input) {
                    try saveRecordingFollowup(receipt); saves += 1
                }
            }
        }
        return saves > 0
    }
    private func compactFollowup(_ value: RecordingFollowupReceipt) -> RecordingFollowupReceipt {
        guard value.state == "completed", let result = value.result else { return value }
        var receipt = value
        let input = value.input, thoughts = Set(result.thoughtUpdates.map(\.claimID)), goals = Set(result.goalPlans.map(\.goalID))
        let taskIDs = Set(result.goalPlans.flatMap { $0.phases.flatMap(\.steps).map(\.existingTaskID) })
        let practices = Set(result.english.comparisons.map(\.priorSourceID))
        receipt.input = .init(current: input.current, policyVersion: input.policyVersion, recordedAt: input.recordedAt,
            thoughts: input.thoughts.filter { thoughts.contains($0.id) }, goals: input.goals.filter { goals.contains($0.id) },
            tasks: input.tasks.filter { taskIDs.contains($0.id) || $0.goalID.map { goals.contains($0) } == true || $0.id == input.feedbackActionID },
            practices: input.practices.filter { practices.contains($0.sourceID) }, currentUnderstanding: input.currentUnderstanding,
            feedbackActionID: input.feedbackActionID,continuousExpression:input.continuousExpression)
        return receipt
    }
    @discardableResult
    public func enqueueRecordingFollowup(sourceID: String, retry: Bool = false) throws -> RecordingFollowupReceipt {
        let input = try prepareRecordingFollowup(sourceID: sourceID)
        let digest = Self.relevanceHash(Data(try followupJSON(input).utf8))
        if let old = try recordingFollowups().last(where: { $0.sourceID == sourceID && $0.inputDigest == digest }),
           ["queued", "running"].contains(old.state) || (!retry && old.state == "completed") { return old }
        let receipt = RecordingFollowupReceipt(id: UUID().uuidString, inputDigest: digest, input: input, state: "queued", result: nil, responseIDs: [], error: nil, createdAt: TimestampFormatting.isoFractional.string(from: Date()))
        try saveRecordingFollowup(receipt)
        return receipt
    }
    public func pendingRecordingFollowups() throws -> [RecordingFollowupReceipt] {
        var seen = Set<String>()
        let now = Date()
        return try recordingFollowups().reversed().filter {
            guard seen.insert($0.sourceID).inserted else { return false }
            if $0.state == "queued" { return true }
            guard $0.state == "failed", let retryAt = $0.retryAt,
                  let date = ISO8601DateFormatter().date(from: retryAt) else { return false }
            return date <= now
        }.reversed()
    }
    private func saveRecordingFollowup(_ value: RecordingFollowupReceipt) throws {
        var history = try db.query("SELECT followup_json FROM sources WHERE id=?", [value.sourceID]).first?["followup_json"].map { try decodeWithPath([RecordingFollowupReceipt].self, from: Data($0.utf8), label: "跟进回执") } ?? []
        var receipt = value
        // Callers that mutate a receipt read from the digest hand back a bodyless
        // copy; keep the full stored input so the archive retains source text.
        if Self.isDigestReceipt(receipt), let stored = history.first(where: { $0.id == receipt.id }), stored.inputDigest == receipt.inputDigest {
            receipt.input = stored.input
        }
        receipt = compactFollowup(receipt)
        if let index = history.firstIndex(where: { $0.id == receipt.id }) { history[index] = receipt } else { history.append(receipt) }
        let json = String(decoding: try JSONEncoder().encode(history), as: UTF8.self)
        let digest = Self.relevanceHash(Data(json.utf8))
        try db.execute("UPDATE sources SET followup_json=?,followup_digest=?,followup_receipt_digest=? WHERE id=?", [json, digest, try Self.followupDigestJSON(history), receipt.sourceID])
        recordingFollowupDecodeCache[receipt.sourceID] = (digest, Self.followupDigestReceipts(history))
    }
    /// Receipts the launch snapshot can render without transcript bodies: result
    /// and metadata stay, only long source texts, practices and spans are gone.
    static func followupDigestReceipts(_ receipts: [RecordingFollowupReceipt]) -> [RecordingFollowupReceipt] {
        receipts.map(digestReceipt)
    }
    static func followupDigestJSON(_ receipts: [RecordingFollowupReceipt]) throws -> String {
        try relevanceJSON(FollowupReceiptDigest(receipts: followupDigestReceipts(receipts)))
    }
    private static func digestReceipt(_ receipt: RecordingFollowupReceipt) -> RecordingFollowupReceipt {
        let input = receipt.input
        var slim = receipt
        slim.input = RecordingFollowupInput(current: digestContext(input.current), policyVersion: input.policyVersion, recordedAt: input.recordedAt,
            thoughts: input.thoughts, goals: input.goals, tasks: input.tasks,
            practices: input.practices.map { PracticeHistory(sourceID: $0.sourceID, transcriptVersionID: $0.transcriptVersionID, text: "", feedback: $0.feedback, policyVersion: $0.policyVersion) },
            currentUnderstanding: input.currentUnderstanding, feedbackActionID: input.feedbackActionID,
            continuousExpression: input.continuousExpression.map {
                ContinuousRecordingContext(expressionID: $0.expressionID, digest: $0.digest, context: digestContext($0.context), policies: $0.policies)
            })
        return slim
    }
    private static func digestContext(_ context: LocalTranscriptContext) -> LocalTranscriptContext {
        LocalTranscriptContext(sources: context.sources.map {
            ContextTranscript(sourceID: $0.sourceID, sourceVersionID: $0.sourceVersionID, transcriptVersionID: $0.transcriptVersionID,
                origin: $0.origin, speaker: $0.speaker, localOnly: $0.localOnly, text: "", spans: [], transcriptionReview: $0.transcriptionReview)
        }, scalarBudget: context.scalarBudget, contentDigest: context.contentDigest,
            conversationFocus: context.conversationFocus, reflectionFocus: context.reflectionFocus,
            recordingContexts: context.recordingContexts)
    }
    static func isDigestReceipt(_ receipt: RecordingFollowupReceipt) -> Bool { isDigestContext(receipt.input.current) }
    private static func isDigestContext(_ context: LocalTranscriptContext) -> Bool {
        !context.sources.isEmpty && context.sources.allSatisfy { $0.text.isEmpty }
    }
    /// Digest receipts carry no transcript text, so re-hash the current read and
    /// compare digests instead of re-hashing the stored sources.
    private func followupContextIsCurrent(_ context: LocalTranscriptContext) throws {
        guard Self.isDigestContext(context) else { try validateLocalTranscriptContext(context); return }
        let current = try prepareLocalTranscriptContext(sourceIDs: context.sources.map(\.sourceID), scalarBudget: context.scalarBudget)
        guard try Self.relevanceJSON(current.recordingContexts) == Self.relevanceJSON(context.recordingContexts),
              current.contentDigest == context.contentDigest else { throw VoiceOSError("上下文来源或逐字稿已变化，请重新准备") }
    }
    private func followupContinuousIsCurrent(_ input: ContinuousRecordingContext?, sourceID: String) throws {
        let catalog = try sourceCatalog()
        try followupContinuousIsCurrent(input, sourceID: sourceID, catalog: catalog,
                                       expressions: RecordingExpression.current(in: catalog))
    }
    private func followupContinuousIsCurrent(_ input: ContinuousRecordingContext?, sourceID: String, catalog: [String: SourceRecord], expressions: [RecordingExpression]) throws {
        guard let input, Self.isDigestContext(input.context) else {
            try validateContinuousRecordingContext(input, sourceID: sourceID, catalog: catalog, expressions: expressions); return
        }
        guard let current = try continuousRecordingContext(sourceID: sourceID, catalog: catalog, expressions: expressions),
              current.expressionID == input.expressionID, current.digest == input.digest,
              current.policies == input.policies, current.context.scalarBudget == input.context.scalarBudget,
              try Self.relevanceJSON(current.context.recordingContexts) == Self.relevanceJSON(input.context.recordingContexts),
              current.context.contentDigest == input.context.contentDigest else { throw VoiceOSError("连续表达的分段、原话或授权已变化") }
    }
    public func recordingFollowupValidity(_ receipt: RecordingFollowupReceipt) throws -> RecordingFollowupValidity {
        try recordingFollowupValidities([receipt])[receipt.id] ?? .init(sourceCurrent: false, thoughtClaimIDs: [], goalIDs: [], english: false)
    }
    public func recordingFollowupValidities(_ receipts: [RecordingFollowupReceipt]) throws -> [String: RecordingFollowupValidity] {
        try recordingFollowupValidities(receipts, catalogRows: nil, claimRows: nil, actionRows: nil)
    }
    /// Snapshot callers pass arrays they already read, and may pass the
    /// snapshot's latest-claim map too. Within one call every distinct source
    /// transcript and continuous-expression context is validated once, instead
    /// of once per receipt.
    public func recordingFollowupValidities(_ receipts: [RecordingFollowupReceipt], catalogRows preloadedCatalog: [SourceRecord]? = nil, claimRows preloadedClaims: [CandidateClaim]? = nil, actionRows preloadedActions: [ActionRecord]? = nil, latest preloadedLatest: [String: [CandidateClaim]]? = nil) throws -> [String: RecordingFollowupValidity] {
        try recordingFollowupValidities(receipts, catalogRows: preloadedCatalog, claimRows: preloadedClaims,
                                        actionRows: preloadedActions, latest: preloadedLatest, expressions: nil)
    }

    func recordingFollowupValidities(_ receipts: [RecordingFollowupReceipt], catalogRows preloadedCatalog: [SourceRecord]?,
                                     claimRows preloadedClaims: [CandidateClaim]?, actionRows preloadedActions: [ActionRecord]?,
                                     latest preloadedLatest: [String: [CandidateClaim]]?,
                                     expressions preloadedExpressions: [RecordingExpression]?) throws -> [String: RecordingFollowupValidity] {
        let completed = receipts.filter { $0.state == "completed" && $0.result != nil }
        guard !completed.isEmpty else { return [:] }
        let catalogRows: [SourceRecord]
        if let preloadedCatalog { catalogRows = preloadedCatalog; StartupTrace.mark("validity.reused") }
        else { catalogRows = try StartupTrace.measure("validity.sources") { try sources() } }
        let claimRows: [CandidateClaim]
        if let preloadedClaims { claimRows = preloadedClaims }
        else { claimRows = try StartupTrace.measure("validity.claims") { try candidateClaims() } }
        let actionRows: [ActionRecord]
        if let preloadedActions { actionRows = preloadedActions }
        else { actionRows = try StartupTrace.measure("validity.actions") { try self.actions(includeHistory: true) } }
        let catalog: [String: SourceRecord] = Dictionary(catalogRows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let claims: [String: CandidateClaim] = Dictionary(uniqueKeysWithValues: claimRows.map { ($0.id, $0) })
        let latest: [String: Set<String>]
        if let preloadedLatest {
            // Freezing a context cascades to its claims, so filtering the
            // snapshot map on claim validity matches the read below.
            latest = preloadedLatest.mapValues { Set($0.filter { $0.validity == "current" && $0.reviewState != "rejected" }.map(\.id)) }
            StartupTrace.mark("validity.latest.reused")
        } else {
            latest = try StartupTrace.measure("validity.latest") { try latestCandidateClaimsBySource() }.mapValues { Set($0.map(\.id)) }
        }
        let actions: [String: ActionRecord] = Dictionary(uniqueKeysWithValues: actionRows.map { ($0.id, $0) })
        let policies = Dictionary(catalogRows.map { ($0.id, $0.policyVersion) }, uniquingKeysWith: { first, _ in first })
        let feedback = try StartupTrace.measure("validity.feedback") { try followupFeedback(actions: actionRows, claims: claims, catalog: catalog) }
        let expressions = try StartupTrace.measure("validity.expressions") {
            if let preloadedExpressions { return preloadedExpressions }
            // A caller can preload a subset. Only a store-owned full catalog
            // can establish the complete set of workflow groups.
            if preloadedCatalog != nil { return try recordingExpressions() }
            return RecordingExpression.current(in: catalog)
        }
        let scalarsCache = FollowupTranscriptScalars()
        var rememberedCache: [String: RememberedThought?] = [:]
        func remembered(_ claim: CandidateClaim) throws -> RememberedThought? {
            if let cached = rememberedCache[claim.id] { return cached }
            let value = try rememberedThought(claim, catalog: catalog, scalarsCache: scalarsCache)
            rememberedCache[claim.id] = value
            return value
        }
        var contextValidity: [String: Bool] = [:]
        func contextIsCurrent(_ context: LocalTranscriptContext) -> Bool {
            let key = context.contentDigest + "|" + String(context.scalarBudget) + "|" + ((try? Self.relevanceJSON(context.recordingContexts)) ?? "")
            if let cached = contextValidity[key] { return cached }
            let current = (try? followupContextIsCurrent(context)) != nil
            contextValidity[key] = current
            return current
        }
        var continuousValidity: [String: Bool] = [:]
        func continuousIsCurrent(_ input: ContinuousRecordingContext?, _ sourceID: String) -> Bool {
            let key: String
            if let input {
                key = sourceID + "|" + input.expressionID + "|" + input.digest + "|" + ((try? Self.relevanceJSON(input.policies)) ?? "")
            } else { key = sourceID + "|none" }
            if let cached = continuousValidity[key] { return cached }
            let current = (try? followupContinuousIsCurrent(input, sourceID: sourceID, catalog: catalog, expressions: expressions)) != nil
            continuousValidity[key] = current
            return current
        }
        var result: [String: RecordingFollowupValidity] = [:]
        for receipt in completed {
            result[receipt.id] = try recordingFollowupValidity(receipt, catalog: catalog, claims: claims, latest: latest, actions: actions, policies: policies, feedback: feedback, remembered: remembered, contextIsCurrent: contextIsCurrent, continuousIsCurrent: continuousIsCurrent)
        }
        return result
    }
    private func recordingFollowupValidity(_ receipt: RecordingFollowupReceipt, catalog: [String: SourceRecord], claims: [String: CandidateClaim], latest: [String: Set<String>], actions: [String: ActionRecord], policies: [String: Int], feedback: [String: [String]]?, remembered: @escaping (CandidateClaim) throws -> RememberedThought?, contextIsCurrent: (LocalTranscriptContext) -> Bool, continuousIsCurrent: (ContinuousRecordingContext?, String) -> Bool) throws -> RecordingFollowupValidity {
        guard receipt.state == "completed", receipt.result != nil,catalog[receipt.sourceID]?.needsTranscriptionReview != true,
              contextIsCurrent(receipt.input.current),
              continuousIsCurrent(receipt.input.continuousExpression, receipt.sourceID),
              policies[receipt.sourceID] == receipt.input.policyVersion else {
            return .init(sourceCurrent: false, thoughtClaimIDs: [], goalIDs: [], english: false)
        }
        // Rebuild the plan-derived links from the stored input so this comparison
        // uses the same convention that produced input.tasks.
        let tasks = try followupTasks(actions: Array(actions.values), claims: claims, catalog: catalog,
                                      goalIDByTaskID: Self.goalIDByTaskID(receipt.input.goals), feedback: feedback, remembered: { try remembered($0) })
        func thought(_ item: RememberedThought) throws {
            guard let claim = claims[item.id] else { throw VoiceOSError("历史观点或原话已变化") }
            let actual = try remembered(claim)
            guard let actual, actual == item else { throw VoiceOSError("历史观点或原话已变化") }
            if claim.reviewState != "endorsed" {
                for id in Set(claim.references.map(\.sourceID)) {
                    guard latest[id]?.contains(claim.id) == true else { throw VoiceOSError("已有新的整理，旧初稿关联暂停使用") }
                }
            }
        }
        var thoughtClaimIDs = Set<String>()
        for update in receipt.result?.thoughtUpdates ?? [] {
            if let target = receipt.input.thoughts.first(where: { $0.id == update.claimID }),
               (try? thought(target)) != nil { thoughtClaimIDs.insert(update.claimID) }
        }
        var goalIDs = Set<String>()
        for plan in receipt.result?.goalPlans ?? [] {
            guard let goal = receipt.input.goals.first(where: { $0.id == plan.goalID }),
                  let action = actions[goal.id], action.validity == "current", action.state == "open", action.version == goal.version,
                  (try? thought(goal.thought)) != nil,
                  tasks.filter { $0.goalID == goal.id } == receipt.input.tasks.filter { $0.goalID == goal.id }.sorted { $0.id < $1.id },
                  plan.phases.flatMap(\.steps).allSatisfy({ step in
                      if step.existingTaskID.isEmpty { return true }
                      guard let expected = receipt.input.tasks.first(where: { $0.id == step.existingTaskID }),
                            let actual = actions[expected.id] else { return false }
                      return actual.validity == "current" && actual.state == "open" && actual.version == expected.version && actual.title == step.title
                  }) else { continue }
            goalIDs.insert(plan.goalID)
        }
        var english = true
        for comparison in receipt.result?.english.comparisons ?? [] {
            guard let prior = receipt.input.practices.first(where: { $0.sourceID == comparison.priorSourceID }), let old = catalog[prior.sourceID], !old.localOnly, old.transcriptVersionID == prior.transcriptVersionID, old.policyVersion == prior.policyVersion else { english = false; break }
        }
        return .init(sourceCurrent: true, thoughtClaimIDs: thoughtClaimIDs, goalIDs: goalIDs, english: english)
    }
    public func validateRecordingFollowup(_ receipt: RecordingFollowupReceipt) throws {
        let validity = try recordingFollowupValidity(receipt)
        guard validity.sourceCurrent else { throw VoiceOSError("录音原话或授权已变化") }
        guard receipt.result?.thoughtUpdates.allSatisfy({ validity.thoughtIsCurrent($0.claimID) }) == true else { throw VoiceOSError("历史观点或原话已变化") }
        guard receipt.result?.goalPlans.allSatisfy({ validity.goalIsCurrent($0.goalID) }) == true else { throw VoiceOSError("目标或阶段任务已变化") }
        guard validity.english else { throw VoiceOSError("旧练习已变化") }
    }
    public static func validateFollowupResult(_ result: RecordingFollowupResult, input: RecordingFollowupInput) throws {
        let text = input.current.sources[0].text
        func quote(_ value: String, in original: String) throws { guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, original.contains(value) else { throw VoiceOSError("跟进结果引用不是连续原话") } }
        var seen = Set<String>()
        for update in result.thoughtUpdates {
            guard seen.insert(update.claimID).inserted, let target = input.thoughts.first(where: { $0.id == update.claimID }), ["supports", "qualifies", "contradicts", "continues"].contains(update.relation), !update.understanding.isEmpty, !update.reason.isEmpty else { throw VoiceOSError("观点关联身份或关系不符") }
            try quote(update.currentQuote, in: text)
            guard target.evidence.contains(where: { $0.quote.contains(update.historicalQuote) }) else { throw VoiceOSError("旧观点引用不符") }
            try quote(update.historicalQuote, in: target.evidence.map(\.quote).joined(separator: "\n"))
        }
        let goalIDs = result.goalPlans.map(\.goalID)
        guard Set(goalIDs).count == goalIDs.count, Set(goalIDs).isSubset(of: Set(input.goals.map(\.id))) else { throw VoiceOSError("目标规划包含重复或不存在的目标") }
        let tasks = Dictionary(uniqueKeysWithValues: input.tasks.map { ($0.id, $0) })
        for plan in result.goalPlans {
            guard !plan.summary.isEmpty, !plan.phases.isEmpty, !plan.nextStep.title.isEmpty,
                  plan.phases.flatMap(\.steps).contains(where: { $0.title == plan.nextStep.title && $0.condition == plan.nextStep.condition && $0.existingTaskID == plan.nextStep.existingTaskID }) else { throw VoiceOSError("目标没有可执行的阶段和下一步") }
            for step in plan.phases.flatMap(\.steps) {
                guard !step.title.isEmpty, step.title.unicodeScalars.count <= 2000 else { throw VoiceOSError("目标步骤为空或过长") }
                if !step.existingTaskID.isEmpty { guard let task = tasks[step.existingTaskID], task.state == "open", task.title == step.title, (task.goalID == nil || task.goalID == plan.goalID) else { throw VoiceOSError("下一步应沿用同一目标的未完成任务") } }
            }
        }
        let english = result.english
        if !english.isPractice {
            guard english.evidenceQuote.isEmpty, english.suggestions.isEmpty, english.comparisons.isEmpty, english.nextExercise.isEmpty else { throw VoiceOSError("非练习录音不应生成英语反馈") }
        } else {
            try quote(english.evidenceQuote, in: text)
            guard !english.nextExercise.isEmpty else { throw VoiceOSError("英文练习缺少下一次练习建议") }
            for suggestion in english.suggestions { try quote(suggestion.original, in: text); guard !suggestion.suggested.isEmpty, !suggestion.explanation.isEmpty else { throw VoiceOSError("英文建议为空") } }
            for comparison in english.comparisons {
                guard let prior = input.practices.first(where: { $0.sourceID == comparison.priorSourceID }), ["repeated", "improved", "changed", "uncertain"].contains(comparison.change) else { throw VoiceOSError("英语历史比较不符") }
                try quote(comparison.priorQuote, in: prior.text); try quote(comparison.currentQuote, in: text)
            }
        }
    }
    public func processRecordingFollowup(sourceID: String, using port: any RecordingFollowupPort, retry: Bool = false) async throws -> RecordingFollowupReceipt {
        let queued = try pendingRecordingFollowups().last { $0.sourceID == sourceID }
        let input: RecordingFollowupInput
        do { input = try prepareRecordingFollowup(sourceID: sourceID) }
        catch {
            if var pending = queued {
                pending.state = "failed"; pending.error = error.localizedDescription; pending.retryAt = nil
                try saveRecordingFollowup(pending)
            }
            throw error
        }
        let digest = Self.relevanceHash(Data(try followupJSON(input).utf8))
        if let old = try recordingFollowups().last(where: { $0.sourceID == sourceID && $0.inputDigest == digest && $0.state == "completed" }), !retry, queued == nil {
            return old
        }
        let matching = queued?.inputDigest == digest ? queued : nil
        var receipt = RecordingFollowupReceipt(id: matching?.id ?? UUID().uuidString, inputDigest: digest, input: input, state: "running", result: nil, responseIDs: [], error: nil, createdAt: matching?.createdAt ?? TimestampFormatting.isoFractional.string(from: Date()), retryCount: matching?.retryCount, retryAt: nil, rejectedResponses: matching?.rejectedResponses)
        try saveRecordingFollowup(receipt)
        do {
            let generated = try await port.generate(input)
            receipt.responseIDs = generated.responseIDs
            let rejections = (receipt.rejectedResponses ?? []) + generated.rejectedResponses
            receipt.rejectedResponses = rejections.isEmpty ? nil : rejections
            let result = generated.result, ids = generated.responseIDs
            try Task.checkCancellation()
            guard !ids.isEmpty, ids.allSatisfy({ !$0.isEmpty }) else { throw RecordingFollowupConformanceFailure(underlying: VoiceOSError("跟进结果缺少模型回执")) }
            do { try Self.validateFollowupResult(result, input: input) }
            catch { throw RecordingFollowupConformanceFailure(underlying: error) }
            receipt.result = result; receipt.responseIDs = ids; receipt.state = "completed"
            guard try recordingFollowupValidity(receipt).sourceCurrent else { throw VoiceOSError("录音原话或授权已变化，请重新生成跟进") }
            try saveRecordingFollowup(receipt)
            return receipt
        } catch {
            if let failure = error as? RecordingFollowupGenerationFailure {
                receipt.responseIDs = failure.responseIDs
                let rejections = (receipt.rejectedResponses ?? []) + failure.rejectedResponses
                receipt.rejectedResponses = rejections.isEmpty ? nil : rejections
            }
            receipt.state = "failed"; receipt.error = error.localizedDescription
            if Self.conformanceRetryScheduled(afterFailure: error, retryCount: receipt.retryCount) {
                receipt.retryCount = 1
                receipt.retryAt = Self.conformanceRetryAt()
            } else if Self.isTransientFollowupError(error), (receipt.retryCount ?? 0) < 2 {
                let nextCount = (receipt.retryCount ?? 0) + 1
                receipt.retryCount = nextCount
                receipt.retryAt = Self.followupRetryAt(after: nextCount == 1 ? 60 : 300)
            }
            try saveRecordingFollowup(receipt)
            throw error
        }
    }
    static func conformanceRetryScheduled(afterFailure failure: Error, retryCount: Int?) -> Bool {
        // The real port wraps its validation failure in a generation failure.
        let error = (failure as? RecordingFollowupGenerationFailure)?.underlying ?? failure
        return error is RecordingFollowupConformanceFailure && (retryCount ?? 0) < 1
    }
    static func conformanceRetryAt(now: Date = Date()) -> String { followupRetryAt(now: now, after: 60) }
    static func followupRetryAt(now: Date = Date(), after seconds: TimeInterval) -> String {
        ISO8601DateFormatter().string(from: now.addingTimeInterval(seconds))
    }
    private static func isTransientFollowupError(_ failure: Error) -> Bool {
        let error = (failure as? RecordingFollowupGenerationFailure)?.underlying ?? failure
        if let error = error as? RecordingFollowupTransientError { return error.status == 429 || (500...599).contains(error.status) }
        guard let error = error as? URLError else { return false }
        return ResponsesRetry.isTransientConnection(error.code)
    }
    public func activateGoalStep(receiptID: String, goalID: String, step: GoalStep) throws -> String {
        guard let receipt = try recordingFollowups().first(where: { $0.id == receiptID }), receipt.state == "completed",
              let plan = receipt.result?.goalPlans.first(where: { $0.goalID == goalID }),
              plan.phases.flatMap(\.steps).contains(where: { $0.title == step.title && $0.condition == step.condition && $0.existingTaskID == step.existingTaskID }),
              let goal = receipt.input.goals.first(where: { $0.id == goalID }) else { throw VoiceOSError("目标步骤已变化") }
        let validity = try recordingFollowupValidity(receipt)
        let command = "goal-step:" + goalID + ":" + receipt.id + ":" + Self.relevanceHash(Data((step.title + "\n" + step.condition).utf8))
        if step.existingTaskID.isEmpty, validity.sourceCurrent,
           let id = try db.query("SELECT id FROM actions WHERE command_id=?", [command]).first?["id"],
           let existing = try self.action(id: id, includeHistory: true),
           existing.validity == "current", existing.state == "open", existing.intent?.goalID == goalID {
            return id
        }
        guard validity.goalIsCurrent(goalID) else { throw VoiceOSError("这个目标或阶段任务已变化，请更新建议") }
        if !step.existingTaskID.isEmpty {
            guard let task = try self.action(id: step.existingTaskID, includeHistory: true), task.validity == "current", task.state == "open" else { throw VoiceOSError("这个步骤已完成或发生变化，请刷新目标建议") }
            return step.existingTaskID
        }
        let id = try createAction(claimID: goal.thought.id, expectedClaimReviewVersion: goal.thought.reviewVersion, title: step.title, kind: .task, note: step.condition, commandID: command)
        let intent = ActionIntentMetadata(intentType: "task", followupState: "pending", uncertain: false, goalID: goalID)
        try db.execute("UPDATE actions SET intent_json=? WHERE id=?", [try followupJSON(intent), id])
        return id
    }
}
