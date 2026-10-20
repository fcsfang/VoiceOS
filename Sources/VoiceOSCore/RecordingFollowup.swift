import Foundation
import CryptoKit

public struct FollowupEvidence: Codable, Sendable {
    public let reference: ClaimReference
    public let quote: String
    public let policyVersion: Int
}
public struct RememberedThought: Codable, Sendable {
    public let id: String
    public let reviewVersion: Int
    public let statement: String
    public let evidence: [FollowupEvidence]
}
public struct FollowupTask: Codable, Sendable {
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
public struct GoalStep: Codable, Sendable {
    public let title: String
    public let condition: String
    public let existingTaskID: String
}
public struct GoalPhase: Codable, Sendable {
    public let title: String
    public let steps: [GoalStep]
}
public struct GoalPlan: Codable, Sendable {
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
    public var sourceID: String { input.current.sources[0].sourceID }
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
public protocol RecordingFollowupPort: Sendable {
    func generate(_ input: RecordingFollowupInput) async throws -> (RecordingFollowupResult, [String])
}

extension VoiceOSStore {
    private func followupJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    private func rememberedThought(_ claim: CandidateClaim, catalog: [String: SourceRecord]) throws -> RememberedThought? {
        guard claim.validity == "current", claim.ownership == "user_tentative", claim.reviewState != "rejected" else { return nil }
        var evidence: [FollowupEvidence] = []
        for ref in claim.references {
            guard let source = catalog[ref.sourceID], !source.localOnly,!source.needsTranscriptionReview, source.transcriptVersionID == ref.transcriptVersionID,
                  let span = source.spans.first(where: { $0.id == ref.spanID }), let text = source.transcript else { return nil }
            let scalars = Array(text.unicodeScalars)
            evidence.append(.init(reference: ref, quote: String(String.UnicodeScalarView(scalars[span.textStart..<span.textEnd])), policyVersion: source.policyVersion))
        }
        guard !evidence.isEmpty else { return nil }
        return .init(id: claim.id, reviewVersion: claim.reviewVersion, statement: claim.statement, evidence: evidence)
    }

    private func followupTasks(actions: [ActionRecord], claims: [String: CandidateClaim], catalog: [String: SourceRecord]) throws -> [FollowupTask] {
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
        return try actions.filter { $0.validity == "current" && $0.kind == "task" && $0.intentActor == "user" && $0.state != "dismissed" }.compactMap { action in
            guard let claim = claims[action.claimID], try rememberedThought(claim, catalog: catalog) != nil else { return nil }
            return .init(id: action.id, version: action.version, title: action.title, state: action.state, goalID: action.intent?.goalID, feedback: feedback[action.id] ?? [])
        }.sorted { $0.id < $1.id }
    }

    public func prepareRecordingFollowup(sourceID: String) throws -> RecordingFollowupInput {
        let catalog = Dictionary(uniqueKeysWithValues: try sources().map { ($0.id, $0) })
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
        let historical = try claims.filter { currentThought($0) && !taskClaims.contains($0.id) && !$0.references.contains(where: { $0.sourceID == sourceID }) }.compactMap { try rememberedThought($0, catalog: catalog) }
        var goals = try actions.filter { $0.validity == "current" && $0.state == "open" && $0.intent?.intentType == "goal" && $0.intent?.uncertain == false }.compactMap { action -> FollowupGoal? in
            guard let claim = byID[action.claimID], currentThought(claim), claim.reviewVersion == action.claimReviewVersion, let thought = try rememberedThought(claim, catalog: catalog) else { return nil }
            return .init(id: action.id, version: action.version, thought: thought, title: action.title)
        }
        let tasks = try followupTasks(actions: actions, claims: byID, catalog: catalog)
        let priorFollowups = try recordingFollowups()
        for index in goals.indices {
            goals[index].previousPlan = priorFollowups.reversed().first(where: { prior in
                guard prior.state == "completed", let original = catalog[prior.sourceID], !original.localOnly,!original.needsTranscriptionReview,
                      original.policyVersion == prior.input.policyVersion, original.transcriptVersionID == prior.input.current.sources[0].transcriptVersionID,
                      let oldGoal = prior.input.goals.first(where: { $0.id == goals[index].id }), oldGoal.version == goals[index].version,
                      (try? followupJSON(oldGoal.thought)) == (try? followupJSON(goals[index].thought)) else { return false }
                return (prior.sourceID != sourceID || (try? followupJSON(prior.input.tasks)) != (try? followupJSON(tasks))) &&
                       prior.result?.goalPlans.contains(where: { $0.goalID == goals[index].id }) == true
            })?.result?.goalPlans.first(where: { $0.goalID == goals[index].id })
        }
        var practices: [PracticeHistory] = []
        for prior in priorFollowups.reversed() where prior.sourceID != sourceID && prior.state == "completed" && prior.result?.english.isPractice == true {
            guard !practices.contains(where: { $0.sourceID == prior.sourceID }), let old = catalog[prior.sourceID], !old.localOnly, old.policyVersion == prior.input.policyVersion, old.transcriptVersionID == prior.input.current.sources[0].transcriptVersionID,
                  let english = prior.result?.english else { continue }
            let feedback = try followupJSON(english)
            practices.append(.init(sourceID: old.id, transcriptVersionID: old.transcriptVersionID!, text: old.transcript!, feedback: feedback, policyVersion: old.policyVersion))
        }
        for prior in try englishFeedbackAttempts() where prior.validity == "current" && prior.state == "completed" && prior.currentSourceID != sourceID {
            guard !practices.contains(where: { $0.sourceID == prior.currentSourceID }), let old = catalog[prior.currentSourceID], !old.localOnly, let version = old.transcriptVersionID, let result = prior.result else { continue }
            practices.append(.init(sourceID: old.id, transcriptVersionID: version, text: old.transcript ?? "", feedback: try followupJSON(result), policyVersion: old.policyVersion))
        }
        return .init(current: current, policyVersion: source.policyVersion, recordedAt: source.createdAt, thoughts: historical, goals: goals, tasks: tasks, practices: practices, currentUnderstanding: (latestBySource[sourceID] ?? []).map(\.statement), feedbackActionID: source.feedbackActionID,continuousExpression:try continuousRecordingContext(sourceID:sourceID))
    }

    /// An action change belongs to its goal's expression, never an arbitrary
    /// recent recording. Persist the work before starting the background worker.
    @discardableResult
    public func enqueueActionFollowups(actionIDs: Set<String>) throws -> [RecordingFollowupReceipt] {
        let actions = Dictionary(uniqueKeysWithValues: try actions(includeHistory: true).map { ($0.id, $0) })
        let claims = Dictionary(uniqueKeysWithValues: try candidateClaims().map { ($0.id, $0) })
        let catalog = Dictionary(uniqueKeysWithValues: try sources().map { ($0.id, $0) })
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

    public func recordingFollowups() throws -> [RecordingFollowupReceipt] {
        try db.query("SELECT followup_json FROM sources WHERE followup_json IS NOT NULL ORDER BY created_at").flatMap { try JSONDecoder().decode([RecordingFollowupReceipt].self, from: Data($0["followup_json"]!.utf8)) }.sorted { $0.createdAt < $1.createdAt }
    }
    func recoverRecordingFollowups() throws {
        for var receipt in try recordingFollowups() {
            if receipt.state == "running" {
                receipt.state = "queued"; receipt.error = "上次跟进被中断；录音和任务已保存，等待继续"
                try saveRecordingFollowup(receipt)
            } else if try followupJSON(compactFollowup(receipt)) != followupJSON(receipt) {
                try saveRecordingFollowup(receipt)
            }
        }
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
        // inputDigest identifies the original generation input for deduplication.
        return receipt
    }
    @discardableResult
    public func enqueueRecordingFollowup(sourceID: String, retry: Bool = false) throws -> RecordingFollowupReceipt {
        let input = try prepareRecordingFollowup(sourceID: sourceID)
        let digest = Self.relevanceHash(Data(try followupJSON(input).utf8))
        if let old = try recordingFollowups().last(where: { $0.sourceID == sourceID && $0.inputDigest == digest }),
           ["queued", "running"].contains(old.state) || (!retry && old.state == "completed") { return old }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let receipt = RecordingFollowupReceipt(id: UUID().uuidString, inputDigest: digest, input: input, state: "queued", result: nil, responseIDs: [], error: nil, createdAt: formatter.string(from: Date()))
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
        // Generation sees the complete history directory. A completed result
        // only needs the evidence it actually uses, not a copy of the library.
        let receipt = compactFollowup(value)
        var history = try db.query("SELECT followup_json FROM sources WHERE id=?", [receipt.sourceID]).first?["followup_json"].map { try JSONDecoder().decode([RecordingFollowupReceipt].self, from: Data($0.utf8)) } ?? []
        if let index = history.firstIndex(where: { $0.id == receipt.id }) { history[index] = receipt } else { history.append(receipt) }
        try db.execute("UPDATE sources SET followup_json=? WHERE id=?", [String(decoding: try JSONEncoder().encode(history), as: UTF8.self), receipt.sourceID])
    }
    public func recordingFollowupValidity(_ receipt: RecordingFollowupReceipt) throws -> RecordingFollowupValidity {
        try recordingFollowupValidities([receipt])[receipt.id] ?? .init(sourceCurrent: false, thoughtClaimIDs: [], goalIDs: [], english: false)
    }
    public func recordingFollowupValidities(_ receipts: [RecordingFollowupReceipt]) throws -> [String: RecordingFollowupValidity] {
        let completed = receipts.filter { $0.state == "completed" && $0.result != nil }
        guard !completed.isEmpty else { return [:] }
        let catalog = Dictionary(uniqueKeysWithValues: try sources().map { ($0.id, $0) })
        let claims = Dictionary(uniqueKeysWithValues: try candidateClaims().map { ($0.id, $0) })
        let latest = try latestCandidateClaimsBySource().mapValues { Set($0.map(\.id)) }
        let actions = Dictionary(uniqueKeysWithValues: try actions(includeHistory: true).map { ($0.id, $0) })
        let tasks = try followupTasks(actions: Array(actions.values), claims: claims, catalog: catalog)
        return try Dictionary(uniqueKeysWithValues: completed.map { receipt in
            (receipt.id, try recordingFollowupValidity(receipt, catalog: catalog, claims: claims, latest: latest, actions: actions, tasks: tasks))
        })
    }
    private func recordingFollowupValidity(_ receipt: RecordingFollowupReceipt, catalog: [String: SourceRecord], claims: [String: CandidateClaim], latest: [String: Set<String>], actions: [String: ActionRecord], tasks: [FollowupTask]) throws -> RecordingFollowupValidity {
        guard receipt.state == "completed", receipt.result != nil,catalog[receipt.sourceID]?.needsTranscriptionReview != true,
              (try? validateLocalTranscriptContext(receipt.input.current)) != nil,
              (try? validateContinuousRecordingContext(receipt.input.continuousExpression,sourceID:receipt.sourceID)) != nil,
              (try? sourcePolicy(sourceID: receipt.sourceID).version) == receipt.input.policyVersion else {
            return .init(sourceCurrent: false, thoughtClaimIDs: [], goalIDs: [], english: false)
        }
        func thought(_ item: RememberedThought) throws {
            guard let claim = claims[item.id], let actual = try rememberedThought(claim, catalog: catalog), try followupJSON(actual) == followupJSON(item) else { throw VoiceOSError("历史观点或原话已变化") }
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
                  // A result, reopened step or newly selected task changes this
                  // goal's next move; unrelated goals remain usable.
                  try followupJSON(tasks.filter { $0.goalID == goal.id }) == followupJSON(receipt.input.tasks.filter { $0.goalID == goal.id }.sorted { $0.id < $1.id }),
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
                if !step.existingTaskID.isEmpty { guard let task = tasks[step.existingTaskID], task.state == "open", task.title == step.title else { throw VoiceOSError("下一步应沿用未完成任务的真实标题") } }
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
        let dateFormatter = ISO8601DateFormatter(); dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let matching = queued?.inputDigest == digest ? queued : nil
        var receipt = RecordingFollowupReceipt(id: matching?.id ?? UUID().uuidString, inputDigest: digest, input: input, state: "running", result: nil, responseIDs: [], error: nil, createdAt: matching?.createdAt ?? dateFormatter.string(from: Date()), retryCount: matching?.retryCount, retryAt: nil)
        try saveRecordingFollowup(receipt)
        do {
            let (result, ids) = try await port.generate(input)
            try Task.checkCancellation()
            guard !ids.isEmpty, ids.allSatisfy({ !$0.isEmpty }) else { throw VoiceOSError("跟进结果缺少模型回执") }
            try Self.validateFollowupResult(result, input: input)
            receipt.result = result; receipt.responseIDs = ids; receipt.state = "completed"
            // Keep independent results even if a referenced task changed while
            // the model was running. Each component is checked again before use.
            guard try recordingFollowupValidity(receipt).sourceCurrent else { throw VoiceOSError("录音原话或授权已变化，请重新生成跟进") }
            try saveRecordingFollowup(receipt)
            return receipt
        } catch {
            receipt.state = "failed"; receipt.error = error.localizedDescription
            if Self.isTransientFollowupError(error), (receipt.retryCount ?? 0) < 2 {
                let nextCount = (receipt.retryCount ?? 0) + 1
                receipt.retryCount = nextCount
                receipt.retryAt = ISO8601DateFormatter().string(from: Date().addingTimeInterval(nextCount == 1 ? 60 : 300))
            }
            try saveRecordingFollowup(receipt)
            throw error
        }
    }
    private static func isTransientFollowupError(_ error: Error) -> Bool {
        if let error = error as? RecordingFollowupTransientError { return error.status == 429 || (500...599).contains(error.status) }
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet, .dnsLookupFailed:
            return true
        default: return false
        }
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
           let existing = try actions(includeHistory: true).first(where: { $0.id == id }),
           existing.validity == "current", existing.state == "open", existing.intent?.goalID == goalID {
            return id
        }
        guard validity.goalIsCurrent(goalID) else { throw VoiceOSError("这个目标或阶段任务已变化，请更新建议") }
        if !step.existingTaskID.isEmpty {
            guard let task = try actions(includeHistory: true).first(where: { $0.id == step.existingTaskID }), task.validity == "current", task.state == "open" else { throw VoiceOSError("这个步骤已完成或发生变化，请刷新目标建议") }
            return step.existingTaskID
        }
        if let existing = try actions(includeHistory: true).first(where: { $0.validity == "current" && $0.state == "open" && $0.kind == "task" && $0.title == step.title }) { return existing.id }
        let id = try createAction(claimID: goal.thought.id, expectedClaimReviewVersion: goal.thought.reviewVersion, title: step.title, kind: .task, note: step.condition, commandID: command)
        let intent = ActionIntentMetadata(intentType: "task", followupState: "pending", uncertain: false, goalID: goalID)
        try db.execute("UPDATE actions SET intent_json=? WHERE id=?", [try followupJSON(intent), id])
        return id
    }
}
