import Foundation

public struct TopicReadingEvidence: Codable, Sendable {
    public let sourceID: String
    public let quote: String
    public init(sourceID: String, quote: String) { self.sourceID=sourceID;self.quote=quote }
}
public struct TopicReadingSection: Codable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let summary: String
    public let claimIDs: [String]
    public let actionIDs: [String]
    public let evidence: [TopicReadingEvidence]
    public init(id:String,title:String,summary:String,claimIDs:[String],actionIDs:[String],evidence:[TopicReadingEvidence]) {
        self.id=id;self.title=title;self.summary=summary;self.claimIDs=claimIDs;self.actionIDs=actionIDs;self.evidence=evidence
    }
}
public struct TopicKnowledgeItem: Codable, Sendable {
    public let id: String
    public let statement: String
    public let ownership: String
    public let reviewVersion: Int
    public let sourceIDs: [String]
    /// Kept for the local body stage only; the skeleton request never carries it.
    public var references: [ClaimReference]? = nil
}
public struct TopicOrganizationSummary: Codable, Sendable {
    public let summary: String
    public var questions: [String]
    public let sourceVersions: [String: String]
    public let policyVersions: [String: Int]
    public let responseID: String
    public var taskStates: [String:String]? = nil
    public var discussionContextIDs: [String]? = nil
    public var sections: [TopicReadingSection]? = nil
    public var claimVersions: [String:Int]? = nil
    /// True between the skeleton and this topic's body batch. The topic page
    /// reads this as "正文整理中"; automatic retries only fill pending bodies.
    public var bodyPending: Bool? = nil
}
public struct TopicCatalogItem: Codable, Sendable {
    public let id: String
    public let title: String
    public let sourceIDs: [String]
    /// User-named topics participate in the skeleton stage key; AI topics the
    /// skeleton itself created must not invalidate a resume.
    public var isAIOrganized: Bool = false
}
public struct TopicTask: Codable, Sendable {
    public let id: String
    public let title: String
    public let state: String
    public let version: Int
    public let sourceIDs: [String]
    public let outcomeSourceIDs: [String]
    public var kind: String = "task"
    /// The viewpoint this action was extracted from, so a body batch receives
    /// exactly the actions owned by its topics.
    public var claimID: String? = nil
}
public struct TopicDiscussionReply: Codable, Sendable {
    public let id: String
    public let contextID: String
    public let replyToSourceID: String
    public let sourceIDs: [String]
    public let parts: [DiscussionPart]
}
public struct TopicOrganizationInput: Codable, Sendable {
    public let context: LocalTranscriptContext
    public let policyVersions: [String: Int]
    public let sourceDates: [String: String]
    public let topics: [TopicCatalogItem]
    public let tasks: [TopicTask]
    public let discussionReplies: [TopicDiscussionReply]
    public let digest: String
    public var knowledge: [TopicKnowledgeItem] = []
}
public struct TopicOrganizationProposal: Codable, Sendable {
    public let topicID: String
    public let title: String
    public let summary: String
    public let questions: [String]
    public let sourceIDs: [String]
    public var sections: [TopicReadingSection]? = nil
    public init(topicID: String = "", title: String, summary: String, questions: [String], sourceIDs: [String], sections:[TopicReadingSection]? = nil) {
        self.topicID=topicID; self.title=title; self.summary=summary; self.questions=questions; self.sourceIDs=sourceIDs
        self.sections=sections
    }
}
public struct TopicOrganizationResult: Codable, Sendable {
    public let briefing: String
    public let highlightSourceIDs: [String]
    public let topics: [TopicOrganizationProposal]
    public var responseID: String
    public init(briefing: String, highlightSourceIDs: [String], topics: [TopicOrganizationProposal], responseID: String) {
        self.briefing=briefing; self.highlightSourceIDs=highlightSourceIDs; self.topics=topics; self.responseID=responseID
    }
}
public struct WorkspaceBriefing: Codable, Sendable {
    public let digest: String
    public let result: TopicOrganizationResult
    public let createdAt: String
}
public struct TopicOrganizationAttemptIdentity: Sendable {
    public let provider: String
    public let model: String
    public let promptVersion: String
    public let schemaVersion: String
    public init(provider: String, model: String, promptVersion: String, schemaVersion: String) {
        self.provider=provider;self.model=model;self.promptVersion=promptVersion;self.schemaVersion=schemaVersion
    }
}
/// Three stages with separate identities: skeleton batches over viewpoints, a
/// merge over their candidates, then small body batches per topic. Attempt rows
/// record which stage produced them.
public protocol TopicOrganizationPort: Sendable {
    func organizeSkeleton(_ input: TopicSkeletonInput) async throws -> TopicSkeletonResult
    func organizeSkeletonMerge(_ input: TopicSkeletonMergeInput) async throws -> TopicSkeletonMergeResult
    func organizeBody(_ input: TopicBodyInput) async throws -> TopicBodyResult
    var skeletonIdentity: TopicOrganizationAttemptIdentity { get }
    var mergeIdentity: TopicOrganizationAttemptIdentity { get }
    var bodyIdentity: TopicOrganizationAttemptIdentity { get }
}
public extension TopicOrganizationPort {
    var skeletonIdentity: TopicOrganizationAttemptIdentity {
        .init(provider:"topic_skeleton",model:"unspecified",promptVersion:"topic-skeleton-v1",schemaVersion:"topics-v1")
    }
    var mergeIdentity: TopicOrganizationAttemptIdentity {
        .init(provider:"topic_skeleton_merge",model:"unspecified",promptVersion:"topic-skeleton-merge-v1",schemaVersion:"topics-v1")
    }
    var bodyIdentity: TopicOrganizationAttemptIdentity {
        .init(provider:"topic_body",model:"unspecified",promptVersion:"topic-body-v1",schemaVersion:"topics-v1")
    }
}

public struct TopicOrganizationFailure: Codable, Equatable, Sendable {
    public let reason: String
    public let failedAt: TimeInterval
    public init(reason: String, failedAt: TimeInterval) { self.reason=reason;self.failedAt=failedAt }
}

/// A failed run suppresses automatic retries for a while, so a launch or
/// refresh right after a failure does not buy the same failure again. Explicit
/// retries bypass it; completed topics stay visible throughout.
public struct TopicOrganizationCooldown {
    public static let window: TimeInterval = 6*60*60
    private let defaults: UserDefaults
    private let key: String
    private let clock: @Sendable () -> Date
    public init(defaults: UserDefaults = .standard, key: String = "voiceos.topics.lastFailure", clock: @escaping @Sendable () -> Date = { Date() }) {
        self.defaults=defaults;self.key=key;self.clock=clock
    }
    public func recordFailure(reason: String, at date: Date? = nil) {
        let failure=TopicOrganizationFailure(reason:reason,failedAt:(date ?? clock()).timeIntervalSince1970)
        if let data=try? JSONEncoder().encode(failure) { defaults.set(data,forKey:key) }
    }
    public func recordSuccess() { defaults.removeObject(forKey:key) }
    public func lastFailure() -> TopicOrganizationFailure? {
        guard let data=defaults.data(forKey:key) else { return nil }
        return try? JSONDecoder().decode(TopicOrganizationFailure.self,from:data)
    }
    public func remainingSeconds(now: Date? = nil) -> TimeInterval? {
        guard let failure=lastFailure() else { return nil }
        let elapsed=(now ?? clock()).timeIntervalSince1970-failure.failedAt
        guard elapsed<Self.window else { return nil }
        return max(0,Self.window-elapsed)
    }
    public func blocksAutomaticRetry(force: Bool = false, now: Date? = nil) -> Bool {
        !force && remainingSeconds(now: now) != nil
    }
    public func waitingMessage(now: Date? = nil) -> String? {
        guard let failure=lastFailure(),remainingSeconds(now:now) != nil else { return nil }
        return Self.failureMessage(reason:failure.reason)
    }
    public static func failureMessage(reason: String) -> String {
        let text=reason.trimmingCharacters(in:.whitespacesAndNewlines)
        return "主题整理上次失败（"+(text.isEmpty ? "原因未知" : text)+"），6 小时后自动重试；已完成的主题会保留，可手动补齐"
    }
}

extension VoiceOSStore {
    /// Cheap change detector for the briefing input. The schema keeps timestamps
    /// on only some contributing tables, so counts and sums stand in for the
    /// rest. A miss only delays a new briefing; organizeTopics still revalidates
    /// the full input before it writes anything.
    func topicOrganizationFingerprint() throws -> String {
        let row = try db.query("""
        SELECT
          (SELECT COUNT(*) FROM sources) AS sources,
          (SELECT COALESCE(SUM(CASE WHEN state='saved' THEN 1 ELSE 0 END),0) FROM sources) AS savedSources,
          (SELECT COALESCE(SUM(CASE WHEN state='reference_only' THEN 1 ELSE 0 END),0) FROM sources) AS referenceSources,
          (SELECT COALESCE(SUM(local_only),0) FROM sources) AS localOnlySources,
          (SELECT COALESCE(SUM(policy_version),0) FROM sources) AS sourcePolicies,
          (SELECT COUNT(*) FROM sources WHERE presentation_json IS NOT NULL) AS presentations,
          (SELECT COALESCE(SUM(LENGTH(presentation_json)),0) FROM sources) AS presentationBytes,
          (SELECT COUNT(*) FROM transcript_versions) AS transcriptVersions,
          (SELECT COALESCE(MAX(version_no),0) FROM transcript_versions) AS transcriptVersionMax,
          (SELECT COUNT(*) FROM contexts) AS contexts,
          (SELECT COALESCE(SUM(CASE WHEN state='current' THEN 1 ELSE 0 END),0) FROM contexts) AS currentContexts,
          (SELECT COUNT(*) FROM claims) AS claims,
          (SELECT COALESCE(SUM(review_version),0) FROM claims) AS claimReviewSum,
          (SELECT COALESCE(SUM(CASE WHEN validity='current' THEN 1 ELSE 0 END),0) FROM claims) AS currentClaims,
          (SELECT COUNT(*) FROM claim_reviews) AS claimReviews,
          (SELECT COUNT(*) FROM actions) AS actions,
          (SELECT COALESCE(SUM(version),0) FROM actions) AS actionVersions,
          (SELECT COALESCE(SUM(CASE WHEN validity='current' THEN 1 ELSE 0 END),0) FROM actions) AS currentActions,
          (SELECT COUNT(*) FROM action_feedback) AS feedback,
          (SELECT COALESCE(MAX(created_at),'') FROM action_feedback) AS feedbackAt,
          (SELECT COUNT(*) FROM reflection_question_entries WHERE state='inactive') AS inactiveEntries,
          (SELECT COUNT(*) FROM reflection_questions) AS questions,
          (SELECT COALESCE(MAX(updated_at),'') FROM reflection_questions) AS questionsAt,
          (SELECT COALESCE(SUM(ai_named),0) FROM reflection_questions) AS aiNamed,
          (SELECT COUNT(*) FROM reflection_question_sources) AS questionSources,
          (SELECT COUNT(*) FROM discussion_attempts) AS discussions,
          (SELECT COALESCE(SUM(CASE WHEN validity='current' AND state='completed' THEN 1 ELSE 0 END),0) FROM discussion_attempts) AS currentDiscussions
        """).first
        let keys = ["sources","savedSources","referenceSources","localOnlySources","sourcePolicies","presentations","presentationBytes","transcriptVersions","transcriptVersionMax","contexts","currentContexts","claims","claimReviewSum","currentClaims","claimReviews","actions","actionVersions","currentActions","feedback","feedbackAt","inactiveEntries","questions","questionsAt","aiNamed","questionSources","discussions","currentDiscussions"]
        return keys.map { row?[$0] ?? "" }.joined(separator: ":")
    }

    public func prepareTopicOrganization() throws -> TopicOrganizationInput? {
        guard ready else { throw VoiceOSError("资料库尚未打开") }
        let fingerprint = try StartupTrace.measure("briefing.fingerprint") { try topicOrganizationFingerprint() }
        if let cached = topicOrganizationCache, cached.fingerprint == fingerprint {
            StartupTrace.mark("briefing.reused")
            return cached.input
        }
        let input = try StartupTrace.measure("briefing.build") { try buildTopicOrganizationInput() }
        topicOrganizationCache = (fingerprint, input)
        StartupTrace.mark("briefing.recomputed")
        return input
    }

    public func prepareTopicSkeleton() throws -> TopicSkeletonInput? {
        guard let input = try prepareTopicOrganization(), !input.knowledge.isEmpty else { return nil }
        return topicSkeletonInput(input)
    }

    func topicSkeletonInput(_ input: TopicOrganizationInput) -> TopicSkeletonInput {
        let seeds = topicSkeletonSeeds(input), viewpoints = topicSkeletonViewpoints(input)
        // The stage key follows the viewpoints plus user-named topics. Topic
        // seeds the skeleton itself created must not invalidate a resume.
        let encoded = (try? Self.relevanceJSON(TopicSkeletonDigestInput(version: "topic-skeleton-v1", viewpoints: viewpoints, manualTopics: topicSkeletonManualSeeds(input)))) ?? ""
        return .init(digest: Self.relevanceHash(Data(encoded.utf8)), topics: seeds, viewpoints: viewpoints)
    }

    func topicSkeletonSeeds(_ input: TopicOrganizationInput) -> [TopicSkeletonTopicSeed] {
        input.topics.map { TopicSkeletonTopicSeed(id: $0.id, title: $0.title) }.sorted { $0.id < $1.id }
    }

    func topicSkeletonManualSeeds(_ input: TopicOrganizationInput) -> [TopicSkeletonTopicSeed] {
        input.topics.filter { !$0.isAIOrganized }
            .map { TopicSkeletonTopicSeed(id: $0.id, title: $0.title) }.sorted { $0.id < $1.id }
    }

    func topicSkeletonViewpoints(_ input: TopicOrganizationInput) -> [TopicSkeletonViewpoint] {
        input.knowledge.map { item -> TopicSkeletonViewpoint in
            let sourceID = item.sourceIDs.first ?? ""
            return .init(id: item.id,
                         statement: TopicOrganizationSlicePolicy.shortened(item.statement, scalars: TopicOrganizationSlicePolicy.statementScalarLimit),
                         sourceID: sourceID,
                         occurredAt: input.sourceDates[sourceID] ?? "")
        }.sorted { $0.id < $1.id }
    }

    /// One skeleton request per ≤150 viewpoints. A batch digest covers only
    /// that batch, so an unchanged batch resumes on its own.
    func topicSkeletonBatches(_ input: TopicOrganizationInput) throws -> [TopicSkeletonBatchPlan] {
        try TopicSkeletonBatching.plans(viewpoints: topicSkeletonViewpoints(input),
                                        seeds: topicSkeletonSeeds(input),
                                        manualTopics: topicSkeletonManualSeeds(input))
    }

    private func buildTopicOrganizationInput() throws -> TopicOrganizationInput? {
        let withdrawn=Set(try db.query("SELECT source_id FROM reflection_question_entries WHERE state='inactive'").compactMap { $0["source_id"] })
        let catalog = try sources().filter { !withdrawn.contains($0.id) && !$0.localOnly && !$0.needsTranscriptionReview && ($0.presentation?.automaticInput == nil || $0.recordingExpression?.state == "completed") && ["saved","reference_only"].contains($0.state) && !($0.transcript ?? "").isEmpty }
        guard !catalog.isEmpty else { return nil }
        let ids = catalog.map(\.id).sorted(), allowed = Set(ids)
        let budget = max(1, catalog.reduce(0) { $0 + ($1.transcript?.unicodeScalars.count ?? 0) })
        let context = try prepareLocalTranscriptContext(sourceIDs: ids, scalarBudget: budget)
        let policies = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id,$0.policyVersion) })
        let questions = try reflectionQuestions(includeSummaries: false)
        let links = try reflectionQuestionSources()
        let topics = questions.filter { allowed.contains($0.sourceID) }.map { question in
            TopicCatalogItem(id: question.id, title: question.title, sourceIDs: (links[question.id] ?? []).filter { allowed.contains($0) }.sorted(), isAIOrganized: question.isAIOrganized == true)
        }
        let claims = Dictionary(uniqueKeysWithValues: try candidateClaims().map { ($0.id,$0) })
        let knowledge=claims.values.compactMap { claim -> TopicKnowledgeItem? in
            let refs=Set(claim.references.map(\.sourceID))
            guard !refs.isEmpty,refs.isSubset(of:allowed) else { return nil }
            return .init(id:claim.id,statement:claim.statement,ownership:claim.ownership,reviewVersion:claim.reviewVersion,sourceIDs:refs.sorted(),references:claim.references)
        }.sorted { $0.id < $1.id }
        let tasks = try actions(includeHistory:true).compactMap { action -> TopicTask? in
            let refs = Set(claims[action.claimID]?.references.map(\.sourceID) ?? [])
            guard action.validity == "current",action.state != "dismissed", !refs.isEmpty, refs.isSubset(of: allowed) else { return nil }
            let outcomes=try actionFeedback(actionID:action.id).filter { $0.actionVersion == action.version && $0.sourceState != "frozen" && allowed.contains($0.sourceID) }.map(\.sourceID)
            return .init(id: action.id, title: action.title, state: action.state, version:action.version, sourceIDs: refs.sorted(),outcomeSourceIDs:outcomes,kind:action.kind,claimID:action.claimID)
        }.sorted { $0.id < $1.id }
        var replies:[TopicDiscussionReply]=[]
        for row in try db.query("SELECT a.*,t.source_id AS user_source_id FROM discussion_attempts a JOIN conversation_user_turns t ON t.id=a.reply_to_turn_id WHERE a.state='completed' AND a.validity='current' ORDER BY a.id") {
            guard let contextID=row["context_id"],let context=try? localContext(id:contextID),context.sources.allSatisfy({ allowed.contains($0.sourceID) }) else { continue }
            replies.append(.init(id:row["id"]!,contextID:contextID,replyToSourceID:row["user_source_id"]!,sourceIDs:context.sources.map(\.sourceID),parts:try Self.discussionParts(row)))
        }
        // AI labels and their own link updates must not wake another identical request.
        let manual = topics.filter { item in questions.contains { $0.id == item.id && $0.isAIOrganized != true } }
        let digest = Self.relevanceHash(Data(try Self.relevanceJSON(["topic-reading-v3",context.contentDigest,Self.relevanceJSON(policies),Self.relevanceJSON(knowledge),Self.relevanceJSON(tasks),Self.relevanceJSON(replies),Self.relevanceJSON(manual)]).utf8))
        return .init(context: context, policyVersions: policies, sourceDates:Dictionary(uniqueKeysWithValues: catalog.map { ($0.id,$0.expressedDate?.ISO8601Format() ?? $0.createdAt) }), topics: topics, tasks: tasks, discussionReplies:replies, digest: digest,knowledge:knowledge)
    }

    func topicSummaryIsCurrent(_ summary: TopicOrganizationSummary, catalog: [String: SourceRecord], linked: Set<String>) throws -> Bool {
        for (id,version) in summary.claimVersions ?? [:] {
            guard let claim=try db.query("SELECT review_version,validity FROM claims WHERE id=?",[id]).first,
                  claim["validity"] == "current",claim["review_version"] == String(version) else { return false }
        }
        for (id,version) in summary.taskStates ?? [:] {
            guard let action=try db.query("SELECT version,state,validity FROM actions WHERE id=?",[id]).first,
                  action["validity"] == "current",(action["version"]!+":"+action["state"]!) == version else { return false }
        }
        for contextID in summary.discussionContextIDs ?? [] {
            guard (try? localContext(id:contextID)) != nil,
                  try !db.query("SELECT id FROM discussion_attempts WHERE context_id=? AND state='completed' AND validity='current'",[contextID]).isEmpty else { return false }
        }
        return !summary.sourceVersions.isEmpty && summary.sourceVersions.allSatisfy { id, version in
            guard let source=catalog[id] else { return false }
            return linked.contains(id) && source.transcriptVersionID == version && source.policyVersion == summary.policyVersions[id] && !source.localOnly && ["saved","reference_only"].contains(source.state)
        }
    }

    func topicOrganizationsAreCurrent(input: TopicOrganizationInput) throws -> Bool {
        guard try workspaceBriefing()?.digest == input.digest else { return false }
        let catalog = Dictionary(uniqueKeysWithValues: try sources().map { ($0.id,$0) })
        let links = try reflectionQuestionSources()
        var assigned = Set<String>()
        for row in try db.query("SELECT id,organization_json FROM reflection_questions WHERE organization_json IS NOT NULL") {
            guard let id = row["id"], let json = row["organization_json"],
                  let summary = try? JSONDecoder().decode(TopicOrganizationSummary.self, from: Data(json.utf8)),
                  summary.bodyPending != true, summary.sections?.isEmpty == false,
                  (try? topicSummaryIsCurrent(summary, catalog: catalog, linked: Set(links[id] ?? []))) == true else { return false }
            if let versions = summary.claimVersions { assigned.formUnion(versions.keys) }
        }
        return assigned == Set(input.knowledge.map(\.id))
    }

    public func needsTopicOrganizationRefresh() throws -> Bool {
        // No knowledge guard here: a transcript correction freezes viewpoints and
        // the saved organization is still stale for reading; hiding that would
        // strand the topic until understanding re-runs.
        guard let input = try prepareTopicOrganization() else { return false }
        return try !topicOrganizationsAreCurrent(input: input)
    }

    /// Topics whose skeleton is saved but whose body batch has not completed.
    /// Processing and home surfaces read this instead of a corner status line.
    public func topicOrganizationPendingTopicCount() throws -> Int {
        try db.query("SELECT organization_json FROM reflection_questions WHERE organization_json IS NOT NULL").reduce(0) { count, row in
            guard let json = row["organization_json"],
                  let summary = try? JSONDecoder().decode(TopicOrganizationSummary.self, from: Data(json.utf8)),
                  summary.bodyPending == true else { return count }
            return count + 1
        }
    }

    public func workspaceBriefing() throws -> WorkspaceBriefing? {
        guard let row=try db.query("SELECT * FROM workspace_briefing WHERE id='00000000-0000-4000-8000-000000000001'").first,
              let json=row["result_json"], let contextID=row["context_id"] else { return nil }
        guard (try? localContext(id: contextID)) != nil else { return nil }
        let saved = try JSONDecoder().decode(WorkspaceBriefing.self,from:Data(json.utf8))
        guard try prepareTopicOrganization()?.digest == saved.digest else { return nil }
        return saved
    }

    /// Skeleton batches first, one merge over their candidates, then small body
    /// batches. Each finished stage is written before the next request, so a
    /// resume replays only the stages that never completed, and a failed batch
    /// leaves the rest of the run untouched.
    @discardableResult public func organizeTopics(using model: any TopicOrganizationPort, force: Bool = false, topUp: Bool = false) async throws -> Bool {
        guard let input = try prepareTopicOrganization(), !input.knowledge.isEmpty else { return false }
        if !force && !topUp, try topicOrganizationsAreCurrent(input: input) { return false }
        let reuseCompleted = !force
        let contextID = try persistLocalContext(input.context, destination: .cloud)
        let batchPlans = try topicSkeletonBatches(input)
        var outcomes: [TopicSkeletonBatchOutcome] = []
        var failedBatches: [(scope: String, reason: String)] = []
        for plan in batchPlans {
            try Task.checkCancellation()
            guard try prepareTopicOrganization()?.digest == input.digest else {
                throw TopicOrganizationInputChanged()
            }
            if reuseCompleted, let saved = try completedStage(digest: plan.digest, stage: "skeleton"),
               let result = try? JSONDecoder().decode(TopicSkeletonResult.self, from: Data(saved.utf8)) {
                outcomes.append(.init(plan: plan, result: result))
                continue
            }
            do {
                let result = try await requestSkeletonBatch(model, input: input, plan: plan, contextID: contextID)
                outcomes.append(.init(plan: plan, result: result))
            } catch is CancellationError {
                throw CancellationError()
            } catch is TopicOrganizationInputChanged {
                throw TopicOrganizationInputChanged()
            } catch {
                // Keep the port's rejection text: a batched failure aborts the
                // run, and the user-facing reason must name what the model said.
                let reason: String
                if case ModelPortFailure.rejected(let text, _, _) = error { reason = text }
                else if let truncated = error as? TopicSkeletonTruncated { reason = truncated.localizedDescription }
                else { reason = error.localizedDescription }
                failedBatches.append((plan.scope, reason))
            }
        }
        if !failedBatches.isEmpty {
            throw TopicOrganizationIncomplete(skeletonBatchCount: failedBatches.count,
                                              firstReason: failedBatches.first?.reason ?? "")
        }
        let merged = try await resolveSkeletonMerge(model, input: input, outcomes: outcomes,
                                                    contextID: contextID, reuseCompleted: reuseCompleted)
        let skeleton = merged.skeleton
        let applied = try db.transaction {
            let applied = try applyTopicSkeleton(skeleton, input: input)
            // Persist the topics' real IDs so a resumed run reuses them instead
            // of minting duplicates for proposals that started empty.
            let resolved = resolvedSkeleton(skeleton, applied: applied)
            try db.execute("UPDATE topic_organization_stages SET result_json=? WHERE digest=? AND stage='skeleton-merge'",
                           [try Self.relevanceJSON(resolved), merged.digest])
            return applied
        }
        // Skeleton links can extend an existing user topic, which changes the
        // full digest once. The running pass and its briefing use the digest
        // after that write so later batches compare against the stored state.
        let runInput = try prepareTopicOrganization() ?? input
        let runDigest = runInput.digest
        try persistTopicBriefing(skeleton, applied: applied, digest: runDigest, contextID: contextID)
        let plans = try topicBodyPlans(input: runInput)
        var failures: [(title: String, reason: String)] = [], failedTopicIDs = Set<String>()
        for plan in plans {
            try Task.checkCancellation()
            guard try prepareTopicOrganization()?.digest == runDigest else {
                throw TopicOrganizationInputChanged()
            }
            if reuseCompleted, let saved = try completedStage(digest: plan.digest, stage: "body"),
               let result = try? JSONDecoder().decode(TopicBodyResult.self, from: Data(saved.utf8)),
               let anchored = try? Self.validateTopicBody(result, input: plan.input, sources: runInput.context.sources) {
                try db.transaction { try applyTopicBody(anchored, plan: plan, input: runInput) }
                continue
            }
            let call: (result: TopicBodyResult, attemptID: String)
            do {
                call = try await requestTopicBody(model, plan: plan, contextID: contextID)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failedTopicIDs.formUnion(plan.input.topics.map(\.topicID))
                failures.append((title: plan.input.topics.map(\.title).joined(separator:"、"),
                                 reason: error.localizedDescription))
                continue
            }
            guard try prepareTopicOrganization()?.digest == runDigest else {
                try db.execute("UPDATE model_attempts SET state='rejected',error='资料或任务已变化；未接纳' WHERE id=? AND state='reserved'", [call.attemptID])
                throw TopicOrganizationInputChanged()
            }
            do {
                let anchored = try Self.validateTopicBody(call.result, input: plan.input, sources: runInput.context.sources)
                try db.transaction {
                    try applyTopicBody(anchored, plan: plan, input: runInput)
                    try saveStage(digest: plan.digest, stage: "body", scope: plan.scope, state: "completed",
                                  resultJSON: try Self.relevanceJSON(anchored), error: nil, attemptID: call.attemptID)
                    try db.execute("UPDATE model_attempts SET state='completed',result_digest=? WHERE id=? AND state='reserved'",
                                   [Self.relevanceHash(Data(("topic-body-v1|"+call.result.responseID).utf8)), call.attemptID])
                }
            } catch {
                try? db.execute("UPDATE model_attempts SET state='rejected',error='结果未接纳；不自动重发' WHERE id=? AND state='reserved'", [call.attemptID])
                try? saveStage(digest: plan.digest, stage: "body", scope: plan.scope, state: "failed",
                               resultJSON: nil, error: error.localizedDescription, attemptID: call.attemptID)
                failedTopicIDs.formUnion(plan.input.topics.map(\.topicID))
                failures.append((title: plan.input.topics.map(\.title).joined(separator:"、"),
                                 reason: error.localizedDescription))
                continue
            }
        }
        if !failures.isEmpty {
            throw TopicOrganizationIncomplete(topicCount: failedTopicIDs.count, firstReason: failures.first?.reason ?? "")
        }
        return true
    }

    // MARK: stage requests

    private func requestSkeletonBatch(_ model: any TopicOrganizationPort, input: TopicOrganizationInput,
                                      plan: TopicSkeletonBatchPlan, contextID: String) async throws -> TopicSkeletonResult {
        let identity = model.skeletonIdentity, attemptID = UUID().uuidString
        try db.execute("INSERT INTO model_attempts(id,context_id,provider,model,prompt_version,schema_version,state,created_at,producer_sequence) VALUES(?,?,?,?,?,?,'reserved',?,?)",
                       [attemptID, contextID, identity.provider, identity.model, identity.promptVersion, identity.schemaVersion, Self.now(), try db.nextModelProducerSequence()])
        try checkpoint(.modelReserved)
        let result: TopicSkeletonResult
        do { result = try await model.organizeSkeleton(plan.input) }
        catch let truncated as TopicSkeletonTruncated {
            // The server answered; the batch itself is too large. Never file
            // this as an unknown or time-out result.
            let reason = truncated.localizedDescription
            try db.execute("UPDATE model_attempts SET state='rejected',error=? WHERE id=? AND state='reserved'", [reason, attemptID])
            try saveStage(digest: plan.digest, stage: "skeleton", scope: plan.scope, state: "failed", resultJSON: nil, error: reason, attemptID: attemptID)
            throw truncated
        }
        catch ModelPortFailure.rejected(let reason, _, _) {
            try db.execute("UPDATE model_attempts SET state='rejected',error=? WHERE id=? AND state='reserved'", [reason, attemptID])
            try saveStage(digest: plan.digest, stage: "skeleton", scope: plan.scope, state: "failed", resultJSON: nil, error: reason, attemptID: attemptID)
            throw ModelPortFailure.rejected(reason)
        }
        catch {
            let reason = error is ModelDeadlineExceeded
                ? "主题骨架批整理超时未返回；服务端结果未知，不自动重发"
                : Task.isCancelled ? "主题骨架批整理已取消" : "主题骨架批未返回结果；服务端结果未知，不自动重发"
            try db.execute("UPDATE model_attempts SET state='unknown',error=? WHERE id=? AND state='reserved'", [reason, attemptID])
            try saveStage(digest: plan.digest, stage: "skeleton", scope: plan.scope, state: "failed", resultJSON: nil, error: reason, attemptID: attemptID)
            throw error
        }
        do {
            try TopicOrganizationSlicingValidation.skeleton(result, input: plan.input,
                                                            allowedSources: Set(input.context.sources.map(\.sourceID)))
            guard try prepareTopicOrganization()?.digest == input.digest else {
                throw TopicOrganizationInputChanged()
            }
            try db.transaction {
                try saveStage(digest: plan.digest, stage: "skeleton", scope: plan.scope, state: "completed",
                              resultJSON: try Self.relevanceJSON(result), error: nil, attemptID: attemptID)
                try db.execute("UPDATE model_attempts SET state='completed',result_digest=? WHERE id=? AND state='reserved'",
                               [Self.relevanceHash(Data(("topic-skeleton-v1|"+result.responseID).utf8)), attemptID])
            }
        } catch {
            try db.execute("UPDATE model_attempts SET state='rejected',error='结果未接纳；不自动重发' WHERE id=? AND state='reserved'", [attemptID])
            try saveStage(digest: plan.digest, stage: "skeleton", scope: plan.scope, state: "failed",
                          resultJSON: nil, error: error.localizedDescription, attemptID: attemptID)
            throw error
        }
        return result
    }

    /// One merge over every batch's candidates, then the local backstop: a
    /// merged list that dropped viewpoints gets one more skeleton request for
    /// each affected batch and one final merge; no viewpoint is ever silently
    /// lost. The completed stage stores the resolved final skeleton so a resume
    /// applies it without replaying any request.
    private func resolveSkeletonMerge(_ model: any TopicOrganizationPort, input: TopicOrganizationInput,
                                      outcomes: [TopicSkeletonBatchOutcome], contextID: String,
                                      reuseCompleted: Bool) async throws -> (skeleton: TopicSkeletonResult, digest: String) {
        var current = outcomes
        var mergeInput = try TopicSkeletonBatching.mergeInput(current)
        if reuseCompleted, let saved = try completedStage(digest: mergeInput.digest, stage: "skeleton-merge"),
           let assembled = try? JSONDecoder().decode(TopicSkeletonResult.self, from: Data(saved.utf8)) {
            return (assembled, mergeInput.digest)
        }
        var call = try await requestSkeletonMerge(model, mergeInput: mergeInput, contextID: contextID)
        var missing = TopicSkeletonBatching.missingViewpoints(call.result, outcomes: current)
        if !missing.isEmpty {
            try db.execute("UPDATE model_attempts SET state='rejected',error=? WHERE id=? AND state='reserved'",
                           ["合流遗漏 \(missing.count) 个观点，未接纳；按批补齐", call.attemptID])
            try saveStage(digest: mergeInput.digest, stage: "skeleton-merge", scope: "all", state: "failed",
                          resultJSON: nil, error: "合流遗漏 \(missing.count) 个观点", attemptID: call.attemptID)
            var retryFailures: [(scope: String, reason: String)] = []
            for index in current.indices where !Set(current[index].plan.input.viewpoints.map(\.id)).isDisjoint(with: missing) {
                try Task.checkCancellation()
                do {
                    let result = try await requestSkeletonBatch(model, input: input, plan: current[index].plan, contextID: contextID)
                    current[index] = .init(plan: current[index].plan, result: result)
                } catch is CancellationError {
                    throw CancellationError()
                } catch is TopicOrganizationInputChanged {
                    throw TopicOrganizationInputChanged()
                } catch {
                    retryFailures.append((current[index].plan.scope, error.localizedDescription))
                }
            }
            if !retryFailures.isEmpty {
                throw TopicOrganizationIncomplete(skeletonBatchCount: retryFailures.count,
                                                  firstReason: retryFailures.first?.reason ?? "")
            }
            mergeInput = try TopicSkeletonBatching.mergeInput(current)
            call = try await requestSkeletonMerge(model, mergeInput: mergeInput, contextID: contextID)
            missing = TopicSkeletonBatching.missingViewpoints(call.result, outcomes: current)
            guard missing.isEmpty else {
                try db.execute("UPDATE model_attempts SET state='rejected',error=? WHERE id=? AND state='reserved'",
                               ["合流后仍有 \(missing.count) 个观点未归组；不自动重发", call.attemptID])
                try saveStage(digest: mergeInput.digest, stage: "skeleton-merge", scope: "all", state: "failed",
                              resultJSON: nil, error: "合流后仍有 \(missing.count) 个观点未归组", attemptID: call.attemptID)
                throw VoiceOSError("合流后仍有 \(missing.count) 个观点未归组，未保存不完整归组")
            }
        }
        let assembled = TopicSkeletonBatching.assembledSkeleton(call.result, outcomes: current)
        try TopicOrganizationSlicingValidation.skeleton(assembled, input: topicSkeletonInput(input),
                                                        allowedSources: Set(input.context.sources.map(\.sourceID)))
        try db.transaction {
            try saveStage(digest: mergeInput.digest, stage: "skeleton-merge", scope: "all", state: "completed",
                          resultJSON: try Self.relevanceJSON(assembled), error: nil, attemptID: call.attemptID)
            try db.execute("UPDATE model_attempts SET state='completed',result_digest=? WHERE id=? AND state='reserved'",
                           [Self.relevanceHash(Data(("topic-skeleton-merge-v1|" + call.result.responseID).utf8)), call.attemptID])
        }
        return (assembled, mergeInput.digest)
    }

    private func requestSkeletonMerge(_ model: any TopicOrganizationPort, mergeInput: TopicSkeletonMergeInput,
                                      contextID: String) async throws -> (result: TopicSkeletonMergeResult, attemptID: String) {
        let identity = model.mergeIdentity, attemptID = UUID().uuidString
        try db.execute("INSERT INTO model_attempts(id,context_id,provider,model,prompt_version,schema_version,state,created_at,producer_sequence) VALUES(?,?,?,?,?,?,'reserved',?,?)",
                       [attemptID, contextID, identity.provider, identity.model, identity.promptVersion, identity.schemaVersion, Self.now(), try db.nextModelProducerSequence()])
        try checkpoint(.modelReserved)
        let result: TopicSkeletonMergeResult
        do { result = try await model.organizeSkeletonMerge(mergeInput) }
        catch ModelPortFailure.rejected(let reason, _, _) {
            try db.execute("UPDATE model_attempts SET state='rejected',error=? WHERE id=? AND state='reserved'", [reason, attemptID])
            try saveStage(digest: mergeInput.digest, stage: "skeleton-merge", scope: "all", state: "failed", resultJSON: nil, error: reason, attemptID: attemptID)
            throw ModelPortFailure.rejected(reason)
        }
        catch {
            let reason = error is ModelDeadlineExceeded
                ? "主题骨架合流超时未返回；服务端结果未知，不自动重发"
                : Task.isCancelled ? "主题骨架合流已取消" : "主题骨架合流未返回结果；服务端结果未知，不自动重发"
            try db.execute("UPDATE model_attempts SET state='unknown',error=? WHERE id=? AND state='reserved'", [reason, attemptID])
            try saveStage(digest: mergeInput.digest, stage: "skeleton-merge", scope: "all", state: "failed", resultJSON: nil, error: reason, attemptID: attemptID)
            throw error
        }
        do { try TopicOrganizationSlicingValidation.skeletonMerge(result, input: mergeInput) }
        catch {
            try db.execute("UPDATE model_attempts SET state='rejected',error='结果未接纳；不自动重发' WHERE id=? AND state='reserved'", [attemptID])
            try saveStage(digest: mergeInput.digest, stage: "skeleton-merge", scope: "all", state: "failed",
                          resultJSON: nil, error: error.localizedDescription, attemptID: attemptID)
            throw error
        }
        return (result, attemptID)
    }

    private func requestTopicBody(_ model: any TopicOrganizationPort, plan: TopicBodyPlan,
                                  contextID: String) async throws -> (TopicBodyResult, String) {
        let identity = model.bodyIdentity, attemptID = UUID().uuidString
        try db.execute("INSERT INTO model_attempts(id,context_id,provider,model,prompt_version,schema_version,state,created_at,producer_sequence) VALUES(?,?,?,?,?,?,'reserved',?,?)",
                       [attemptID, contextID, identity.provider, identity.model, identity.promptVersion, identity.schemaVersion, Self.now(), try db.nextModelProducerSequence()])
        let result: TopicBodyResult
        do { result = try await model.organizeBody(plan.input) }
        catch ModelPortFailure.rejected(let reason, _, _) {
            try db.execute("UPDATE model_attempts SET state='rejected',error=? WHERE id=? AND state='reserved'", [reason, attemptID])
            try saveStage(digest: plan.digest, stage: "body", scope: plan.scope, state: "failed", resultJSON: nil, error: reason, attemptID: attemptID)
            throw ModelPortFailure.rejected(reason)
        }
        catch {
            let reason = error is ModelDeadlineExceeded
                ? "主题正文整理超时未返回；服务端结果未知，不自动重发"
                : Task.isCancelled ? "主题正文整理已取消" : "主题正文未返回结果；服务端结果未知，不自动重发"
            try db.execute("UPDATE model_attempts SET state='unknown',error=? WHERE id=? AND state='reserved'", [reason, attemptID])
            try saveStage(digest: plan.digest, stage: "body", scope: plan.scope, state: "failed", resultJSON: nil, error: reason, attemptID: attemptID)
            throw error
        }
        do { try TopicOrganizationSlicingValidation.body(result, input: plan.input) }
        catch {
            try db.execute("UPDATE model_attempts SET state='rejected',error='结果未接纳；不自动重发' WHERE id=? AND state='reserved'", [attemptID])
            try saveStage(digest: plan.digest, stage: "body", scope: plan.scope, state: "failed", resultJSON: nil, error: error.localizedDescription, attemptID: attemptID)
            throw error
        }
        return (result, attemptID)
    }

    // MARK: stage records

    private func completedStage(digest: String, stage: String) throws -> String? {
        for row in try db.query("SELECT state,result_json FROM topic_organization_stages WHERE digest=? AND stage=? ORDER BY updated_at DESC", [digest, stage]) {
            if row["state"] == "completed", let json = row["result_json"] { return json }
        }
        return nil
    }

    private func saveStage(digest: String, stage: String, scope: String, state: String,
                           resultJSON: String?, error: String?, attemptID: String?) throws {
        try db.execute("INSERT OR REPLACE INTO topic_organization_stages(digest,stage,scope,state,result_json,error,attempt_id,updated_at) VALUES(?,?,?,?,?,?,?,?)",
                       [digest, stage, scope, state, resultJSON, error, attemptID, Self.now()])
    }

    // MARK: writes

    private func applyTopicSkeleton(_ skeleton: TopicSkeletonResult, input: TopicOrganizationInput) throws
        -> [(id: String, title: String, summary: String, questions: [String], sourceIDs: [String])] {
        let knowledge = Dictionary(uniqueKeysWithValues: input.knowledge.map { ($0.id, $0) })
        let bySource = Dictionary(uniqueKeysWithValues: input.context.sources.map { ($0.sourceID, $0) })
        var existing: [String: (title: String, aiNamed: Bool, json: String?)] = [:]
        for row in try db.query("SELECT id,title,ai_named,organization_json FROM reflection_questions") {
            guard let id = row["id"], let title = row["title"] else { continue }
            existing[id] = (title, row["ai_named"] == "1", row["organization_json"])
        }
        var applied: [(id: String, title: String, summary: String, questions: [String], sourceIDs: [String])] = []
        for proposal in skeleton.topics {
            let claims = proposal.viewpointIDs.compactMap { knowledge[$0] }
            let refs = Set(claims.flatMap(\.sourceIDs))
            guard !refs.isEmpty else { continue }
            let id = proposal.topicID.isEmpty ? UUID().uuidString : proposal.topicID
            let existingRow = existing[id]
            // A user-named topic keeps its title; AI topics take the proposal.
            let title = existingRow?.title ?? proposal.title
            let questions = proposal.questions ?? []
            let sourceVersions = Dictionary(uniqueKeysWithValues: refs.map { ($0, bySource[$0]!.transcriptVersionID) })
            let policyVersions = Dictionary(uniqueKeysWithValues: refs.map { ($0, input.policyVersions[$0] ?? 1) })
            let claimIDs = Set(proposal.viewpointIDs)
            let tasks = input.tasks.filter { task in
                if let claimID = task.claimID { return claimIDs.contains(claimID) }
                return !refs.isDisjoint(with: task.sourceIDs)
            }
            var summary = TopicOrganizationSummary(
                summary: proposal.summary, questions: questions,
                sourceVersions: sourceVersions, policyVersions: policyVersions,
                responseID: skeleton.responseID)
            summary.claimVersions = Dictionary(uniqueKeysWithValues: claims.map { ($0.id, $0.reviewVersion) })
            summary.taskStates = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, "\($0.version):\($0.state)") })
            summary.discussionContextIDs = input.discussionReplies.filter { !refs.isDisjoint(with: $0.sourceIDs) }.map(\.contextID)
            summary.sections = nil
            summary.bodyPending = true
            if let oldJSON = existingRow?.json,
               let old = try? JSONDecoder().decode(TopicOrganizationSummary.self, from: Data(oldJSON.utf8)),
               old.bodyPending != true, old.sections?.isEmpty == false,
               old.summary == summary.summary, old.questions == summary.questions,
               old.claimVersions == summary.claimVersions, old.sourceVersions == summary.sourceVersions,
               old.taskStates == summary.taskStates, old.discussionContextIDs == summary.discussionContextIDs {
                for sourceID in refs.sorted() {
                    try db.execute("INSERT OR IGNORE INTO reflection_question_sources(id,question_id,source_id) VALUES(?,?,?)", [UUID().uuidString, id, sourceID])
                    try db.execute("UPDATE assistant_executions SET question_id=? WHERE result_source_id=? AND question_id IS NULL AND validity='current'", [id, sourceID])
                }
                applied.append((id, title, summary.summary, questions, refs.sorted()))
                continue
            }
            let json = try Self.relevanceJSON(summary)
            if let existingRow {
                if existingRow.json != json {
                    try db.execute("UPDATE reflection_questions SET organization_json=?,updated_at=? WHERE id=?", [json, Self.now(), id])
                }
                existing[id] = (existingRow.title, existingRow.aiNamed, json)
            } else {
                guard let titleSource = claims.first?.sourceIDs.first else { continue }
                try db.execute("INSERT INTO reflection_questions(id,title,title_source_id,organization_json,ai_named,created_at,updated_at) VALUES(?,?,?,?,1,?,?)",
                               [id, title, titleSource, json, Self.now(), Self.now()])
                existing[id] = (title, true, json)
            }
            // Links land after the topic row exists: the FK on question_id aborts
            // the insert and INSERT OR IGNORE does not swallow FK failures.
            for sourceID in refs.sorted() {
                try db.execute("INSERT OR IGNORE INTO reflection_question_sources(id,question_id,source_id) VALUES(?,?,?)", [UUID().uuidString, id, sourceID])
                try db.execute("UPDATE assistant_executions SET question_id=? WHERE result_source_id=? AND question_id IS NULL AND validity='current'", [id, sourceID])
            }
            applied.append((id, title, summary.summary, questions, refs.sorted()))
        }
        return applied
    }

    private func resolvedSkeleton(_ skeleton: TopicSkeletonResult,
                                  applied: [(id: String, title: String, summary: String, questions: [String], sourceIDs: [String])]) -> TopicSkeletonResult {
        let topics = zip(skeleton.topics, applied).map { proposal, row in
            TopicSkeletonTopic(topicID: row.id, title: row.title, summary: proposal.summary,
                               questions: proposal.questions, viewpointIDs: proposal.viewpointIDs)
        }
        return .init(briefing: skeleton.briefing, highlightSourceIDs: skeleton.highlightSourceIDs,
                     topics: topics, responseID: skeleton.responseID)
    }

    private func persistTopicBriefing(_ skeleton: TopicSkeletonResult,
                                      applied: [(id: String, title: String, summary: String, questions: [String], sourceIDs: [String])],
                                      digest: String, contextID: String) throws {
        let proposals = applied.map { topic in
            TopicOrganizationProposal(topicID: topic.id, title: topic.title, summary: topic.summary,
                                      questions: topic.questions, sourceIDs: topic.sourceIDs)
        }
        let result = TopicOrganizationResult(briefing: skeleton.briefing, highlightSourceIDs: skeleton.highlightSourceIDs,
                                             topics: proposals, responseID: skeleton.responseID)
        if let row = try db.query("SELECT result_json FROM workspace_briefing WHERE id='00000000-0000-4000-8000-000000000001'").first,
           let oldJSON = row["result_json"],
           let old = try? JSONDecoder().decode(WorkspaceBriefing.self, from: Data(oldJSON.utf8)),
           old.digest == digest,
           (try? Self.relevanceJSON(old.result)) == (try? Self.relevanceJSON(result)) {
            return
        }
        let briefing = WorkspaceBriefing(digest: digest, result: result, createdAt: Self.now())
        try db.execute("INSERT OR REPLACE INTO workspace_briefing(id,context_id,result_json) VALUES('00000000-0000-4000-8000-000000000001',?,?)",
                       [contextID, try Self.relevanceJSON(briefing)])
    }

    func topicBodyPlans(input: TopicOrganizationInput) throws -> [TopicBodyPlan] {
        let knowledge = Dictionary(uniqueKeysWithValues: input.knowledge.map { ($0.id, $0) })
        let transcripts = Dictionary(uniqueKeysWithValues: input.context.sources.map { ($0.sourceID, $0) })
        var topics: [TopicBodyTopic] = []
        for row in try db.query("SELECT id,title,organization_json FROM reflection_questions WHERE organization_json IS NOT NULL ORDER BY id") {
            guard let id = row["id"], let title = row["title"], let json = row["organization_json"],
                  let summary = try? JSONDecoder().decode(TopicOrganizationSummary.self, from: Data(json.utf8)),
                  summary.bodyPending == true else { continue }
            let claims = (summary.claimVersions?.keys.sorted() ?? []).compactMap { knowledge[$0] }
            guard !claims.isEmpty else { continue }
            let refs = Set(claims.flatMap { ($0.references ?? []).map(\.sourceID) } + claims.flatMap(\.sourceIDs))
            let sourceIDs = refs.filter { transcripts[$0] != nil }.sorted()
            guard !sourceIDs.isEmpty else { continue }
            let viewpoints = claims.map { claim -> TopicSkeletonViewpoint in
                let sourceID = claim.sourceIDs.first ?? sourceIDs[0]
                return .init(id: claim.id,
                             statement: TopicOrganizationSlicePolicy.shortened(claim.statement, scalars: TopicOrganizationSlicePolicy.statementScalarLimit),
                             sourceID: sourceID,
                             occurredAt: input.sourceDates[sourceID] ?? "")
            }
            var quotes: [TopicBodyQuote] = [], seen = Set<String>()
            for claim in claims {
                for reference in claim.references ?? [] {
                    guard let transcript = transcripts[reference.sourceID],
                          let span = transcript.spans.first(where: { $0.id == reference.spanID }) else { continue }
                    let text = TopicOrganizationSlicePolicy.scalarSlice(transcript.text, start: span.textStart, end: span.textEnd)
                    let quote = TopicOrganizationSlicePolicy.shortened(text, scalars: TopicOrganizationSlicePolicy.quoteScalarLimit)
                    guard !quote.isEmpty, seen.insert(reference.sourceID + "\u{0}" + quote).inserted else { continue }
                    quotes.append(.init(sourceID: reference.sourceID, quote: quote))
                }
            }
            for sourceID in sourceIDs where !quotes.contains(where: { $0.sourceID == sourceID }) {
                guard let text = transcripts[sourceID]?.text else { continue }
                let quote = TopicOrganizationSlicePolicy.shortened(text, scalars: TopicOrganizationSlicePolicy.quoteScalarLimit)
                if !quote.isEmpty { quotes.append(.init(sourceID: sourceID, quote: quote)) }
            }
            let tasks = input.tasks.filter { summary.taskStates?[$0.id] != nil }
            topics.append(.init(topicID: id, title: title, summary: summary.summary, sourceIDs: sourceIDs,
                                viewpoints: viewpoints, quotes: quotes, tasks: tasks))
        }
        return try TopicOrganizationSlicingValidation.bodyPlans(topics: topics)
    }

    private func applyTopicBody(_ result: TopicBodyResult, plan: TopicBodyPlan, input: TopicOrganizationInput) throws {
        let knowledge = Dictionary(uniqueKeysWithValues: input.knowledge.map { ($0.id, $0) })
        let planned = Dictionary(uniqueKeysWithValues: plan.input.topics.map { ($0.topicID, $0) })
        for proposed in result.topics {
            guard let topic = planned[proposed.topicID],
                  let row = try db.query("SELECT title,organization_json FROM reflection_questions WHERE id=?", [proposed.topicID]).first,
                  let json = row["organization_json"],
                  var summary = try? JSONDecoder().decode(TopicOrganizationSummary.self, from: Data(json.utf8)) else { continue }
            summary.sections = proposed.sections
            summary.bodyPending = nil
            summary.claimVersions = Dictionary(uniqueKeysWithValues: topic.viewpoints.compactMap { viewpoint in
                knowledge[viewpoint.id].map { (viewpoint.id, $0.reviewVersion) }
            })
            summary.taskStates = Dictionary(uniqueKeysWithValues: topic.tasks.map { ($0.id, "\($0.version):\($0.state)") })
            let encoded = try Self.relevanceJSON(summary)
            guard encoded != json else { continue }
            try db.execute("UPDATE reflection_questions SET organization_json=?,updated_at=? WHERE id=?", [encoded, Self.now(), proposed.topicID])
        }
    }

    public static func validateTopicSkeleton(_ result: TopicSkeletonResult, input: TopicSkeletonInput, allowedSources: Set<String>) throws {
        try TopicOrganizationSlicingValidation.skeleton(result, input: input, allowedSources: allowedSources)
    }

    public static func validateTopicSkeletonMerge(_ result: TopicSkeletonMergeResult, input: TopicSkeletonMergeInput) throws {
        try TopicOrganizationSlicingValidation.skeletonMerge(result, input: input)
    }

    public static func validateTopicBodyStructure(_ result: TopicBodyResult, input: TopicBodyInput) throws {
        try TopicOrganizationSlicingValidation.body(result, input: input)
    }

    /// Body evidence must be a verbatim slice of the current full transcript,
    /// which only the store can see. A model that reflows whitespace still
    /// passes; the returned result carries the transcript slice as its quote.
    static func validateTopicBody(_ result: TopicBodyResult, input: TopicBodyInput, sources: [ContextTranscript]) throws -> TopicBodyResult {
        try TopicOrganizationSlicingValidation.body(result, input: input)
        let byID = Dictionary(uniqueKeysWithValues: sources.map { ($0.sourceID, $0) })
        var topics: [TopicBodyTopicResult] = []
        for topic in result.topics {
            var sections: [TopicReadingSection] = []
            for section in topic.sections {
                var evidence: [TopicReadingEvidence] = []
                for item in section.evidence {
                    guard let source = byID[item.sourceID],
                          let quote = Self.anchoredQuote(item.quote, in: source.text) else {
                        throw VoiceOSError("主题正文的引用无法定位到当前完整原文（来源 \(item.sourceID)，引文开头「\(String(item.quote.prefix(12)))」）")
                    }
                    evidence.append(TopicReadingEvidence(sourceID: item.sourceID, quote: quote))
                }
                sections.append(TopicReadingSection(id: section.id, title: section.title, summary: section.summary,
                                                    claimIDs: section.claimIDs, actionIDs: section.actionIDs, evidence: evidence))
            }
            topics.append(TopicBodyTopicResult(topicID: topic.topicID, questions: topic.questions, sections: sections))
        }
        return TopicBodyResult(topics: topics, responseID: result.responseID)
    }

    /// The exact quote wins first. Otherwise strip all whitespace from both
    /// sides, find the hit in the normalized transcript, and slice the original
    /// text between the mapped character boundaries.
    private static func anchoredQuote(_ quote: String, in text: String) -> String? {
        if text.contains(quote) { return quote }
        var normalized = String(), starts: [String.Index] = [], ends: [String.Index] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            if !text[index].isWhitespace {
                normalized.append(text[index]); starts.append(index); ends.append(next)
            }
            index = next
        }
        let wanted = String(quote.filter { !$0.isWhitespace })
        guard !wanted.isEmpty, let range = normalized.range(of: wanted) else { return nil }
        let lower = normalized.distance(from: normalized.startIndex, to: range.lowerBound)
        let upper = normalized.distance(from: normalized.startIndex, to: range.upperBound)
        return String(text[starts[lower]..<ends[upper - 1]])
    }
}
