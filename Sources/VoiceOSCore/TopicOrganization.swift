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
}
public struct TopicOrganizationSummary: Codable, Sendable {
    public let summary: String
    public let questions: [String]
    public let sourceVersions: [String: String]
    public let policyVersions: [String: Int]
    public let responseID: String
    public var taskStates: [String:String]? = nil
    public var discussionContextIDs: [String]? = nil
    public var sections: [TopicReadingSection]? = nil
    public var claimVersions: [String:Int]? = nil
}
public struct TopicCatalogItem: Codable, Sendable {
    public let id: String
    public let title: String
    public let sourceIDs: [String]
}
public struct TopicTask: Codable, Sendable {
    public let id: String
    public let title: String
    public let state: String
    public let version: Int
    public let sourceIDs: [String]
    public let outcomeSourceIDs: [String]
    public var kind: String = "task"
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
public protocol TopicOrganizationPort: Sendable {
    func organize(_ input: TopicOrganizationInput) async throws -> TopicOrganizationResult
}

extension VoiceOSStore {
    public func prepareTopicOrganization() throws -> TopicOrganizationInput? {
        guard ready else { throw VoiceOSError("资料库尚未打开") }
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
            TopicCatalogItem(id: question.id, title: question.title, sourceIDs: (links[question.id] ?? []).filter { allowed.contains($0) }.sorted())
        }
        let claims = Dictionary(uniqueKeysWithValues: try candidateClaims().map { ($0.id,$0) })
        let knowledge=claims.values.compactMap { claim -> TopicKnowledgeItem? in
            let refs=Set(claim.references.map(\.sourceID))
            guard !refs.isEmpty,refs.isSubset(of:allowed) else { return nil }
            return .init(id:claim.id,statement:claim.statement,ownership:claim.ownership,reviewVersion:claim.reviewVersion,sourceIDs:refs.sorted())
        }.sorted { $0.id < $1.id }
        let tasks = try actions(includeHistory:true).compactMap { action -> TopicTask? in
            let refs = Set(claims[action.claimID]?.references.map(\.sourceID) ?? [])
            guard action.validity == "current",action.state != "dismissed", !refs.isEmpty, refs.isSubset(of: allowed) else { return nil }
            let outcomes=try actionFeedback(actionID:action.id).filter { $0.actionVersion == action.version && $0.sourceState != "frozen" && allowed.contains($0.sourceID) }.map(\.sourceID)
            return .init(id: action.id, title: action.title, state: action.state, version:action.version, sourceIDs: refs.sorted(),outcomeSourceIDs:outcomes,kind:action.kind)
        }.sorted { $0.id < $1.id }
        var replies:[TopicDiscussionReply]=[]
        for row in try db.query("SELECT a.*,t.source_id AS user_source_id FROM discussion_attempts a JOIN conversation_user_turns t ON t.id=a.reply_to_turn_id WHERE a.state='completed' AND a.validity='current' ORDER BY a.id") {
            guard let contextID=row["context_id"],let context=try? localContext(id:contextID),context.sources.allSatisfy({ allowed.contains($0.sourceID) }) else { continue }
            replies.append(.init(id:row["id"]!,contextID:contextID,replyToSourceID:row["user_source_id"]!,sourceIDs:context.sources.map(\.sourceID),parts:try Self.discussionParts(row)))
        }
        // AI labels and their own link updates must not wake another identical request.
        let manual = topics.filter { item in questions.contains { $0.id == item.id && $0.isAIOrganized != true } }
        let digest = Self.relevanceHash(Data(try Self.relevanceJSON(["topic-reading-v2",context.contentDigest,Self.relevanceJSON(policies),Self.relevanceJSON(knowledge),Self.relevanceJSON(tasks),Self.relevanceJSON(replies),Self.relevanceJSON(manual)]).utf8))
        return .init(context: context, policyVersions: policies, sourceDates:Dictionary(uniqueKeysWithValues:catalog.map { ($0.id,$0.expressedDate?.ISO8601Format() ?? $0.createdAt) }), topics: topics, tasks: tasks, discussionReplies:replies, digest: digest,knowledge:knowledge)
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

    public func workspaceBriefing() throws -> WorkspaceBriefing? {
        guard let row=try db.query("SELECT * FROM workspace_briefing WHERE id='00000000-0000-4000-8000-000000000001'").first,
              let json=row["result_json"], let contextID=row["context_id"] else { return nil }
        guard (try? localContext(id: contextID)) != nil else { return nil }
        let saved = try JSONDecoder().decode(WorkspaceBriefing.self,from:Data(json.utf8))
        guard try prepareTopicOrganization()?.digest == saved.digest else { return nil }
        return saved
    }

    @discardableResult public func organizeTopics(using model: any TopicOrganizationPort, force: Bool = false) async throws -> Bool {
        guard let input=try prepareTopicOrganization() else { return false }
        if !force, try workspaceBriefing()?.digest == input.digest { return false }
        let contextID=try persistLocalContext(input.context, destination: .cloud)
        let result=try await model.organize(input)
        guard try prepareTopicOrganization()?.digest == input.digest else { throw VoiceOSError("资料或任务已变化，将基于当前内容重新归组") }
        try validateLocalTranscriptContext(input.context)
        try Self.validateTopicOrganization(result,input:input)
        let byID=Dictionary(uniqueKeysWithValues: input.context.sources.map { ($0.sourceID,$0) })
        try db.transaction {
            for proposal in result.topics {
                let id=proposal.topicID.isEmpty ? UUID().uuidString : proposal.topicID
                var summary=TopicOrganizationSummary(summary:proposal.summary,questions:proposal.questions,
                    sourceVersions:Dictionary(uniqueKeysWithValues:proposal.sourceIDs.map { ($0,byID[$0]!.transcriptVersionID) }),
                    policyVersions:Dictionary(uniqueKeysWithValues:proposal.sourceIDs.map { ($0,input.policyVersions[$0]!) }),responseID:result.responseID)
                let members=Set(proposal.sourceIDs)
                summary.sections=proposal.sections
                let assignedTasks=proposal.sections.map { Set($0.flatMap(\.actionIDs)) }
                summary.taskStates=Dictionary(uniqueKeysWithValues:input.tasks.filter { assignedTasks?.contains($0.id) ?? !members.isDisjoint(with:$0.sourceIDs) }.map { ($0.id,String($0.version)+":"+$0.state) })
                if let sections=proposal.sections {
                    let ids=Set(sections.flatMap(\.claimIDs))
                    summary.claimVersions=Dictionary(uniqueKeysWithValues:input.knowledge.filter { ids.contains($0.id) }.map { ($0.id,$0.reviewVersion) })
                }
                summary.discussionContextIDs=input.discussionReplies.filter { !members.isDisjoint(with:$0.sourceIDs) }.map(\.contextID)
                let json=try Self.relevanceJSON(summary)
                if proposal.topicID.isEmpty {
                    // The title is AI metadata anchored to real material, never a fabricated user expression.
                    try db.execute("INSERT INTO reflection_questions(id,title,title_source_id,organization_json,ai_named,created_at,updated_at) VALUES(?,?,?,?,1,?,?)",[id,proposal.title,proposal.sourceIDs[0],json,Self.now(),Self.now()])
                } else {
                    // Metadata refresh does not change the user's title or note
                    // versions, and must not invalidate an in-flight discussion.
                    try db.execute("UPDATE reflection_questions SET organization_json=?,updated_at=? WHERE id=?",[json,Self.now(),id])
                }
                for sourceID in proposal.sourceIDs {
                    try db.execute("INSERT OR IGNORE INTO reflection_question_sources(id,question_id,source_id) VALUES(?,?,?)",[UUID().uuidString,id,sourceID])
                    try db.execute("UPDATE assistant_executions SET question_id=? WHERE result_source_id=? AND question_id IS NULL AND validity='current'",[id,sourceID])
                }
            }
        }
        // Include links just created by this result so they do not trigger
        // a second request; later manual changes still invalidate it. Read
        // after the write transaction because source validation may freeze history.
        let savedDigest=try prepareTopicOrganization()?.digest ?? input.digest
        let briefing=WorkspaceBriefing(digest:savedDigest,result:result,createdAt:Self.now())
        try db.execute("INSERT OR REPLACE INTO workspace_briefing(id,context_id,result_json) VALUES('00000000-0000-4000-8000-000000000001',?,?)",[contextID,try Self.relevanceJSON(briefing)])
        return true
    }

    public static func validateTopicOrganization(_ result: TopicOrganizationResult, input: TopicOrganizationInput) throws {
        let allowed=Set(input.context.sources.map(\.sourceID)), existing=Set(input.topics.map(\.id))
        var covered=Set<String>(), usedIDs=Set<String>()
        let knowledge=Dictionary(uniqueKeysWithValues:input.knowledge.map { ($0.id,$0) })
        let tasks=Dictionary(uniqueKeysWithValues:input.tasks.map { ($0.id,$0) })
        let sources=Dictionary(uniqueKeysWithValues:input.context.sources.map { ($0.sourceID,$0) })
        var assignedClaims=Set<String>(),assignedActions=Set<String>()
        guard !result.responseID.isEmpty, !result.briefing.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              Set(result.highlightSourceIDs).isSubset(of:allowed) else { throw VoiceOSError("主题整理缺少有效内容或来源") }
        for topic in result.topics {
            guard !topic.title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, topic.title.count <= 200,
                  !topic.summary.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
                  !topic.sourceIDs.isEmpty, Set(topic.sourceIDs).count == topic.sourceIDs.count,
                  Set(topic.sourceIDs).isSubset(of:allowed), topic.topicID.isEmpty || (existing.contains(topic.topicID) && usedIDs.insert(topic.topicID).inserted) else { throw VoiceOSError("主题整理包含无效来源或重复主题") }
            covered.formUnion(topic.sourceIDs)
            if let sections=topic.sections {
                guard !sections.isEmpty,Set(sections.map(\.id)).count == sections.count else { throw VoiceOSError("主题小节缺失或重复") }
                let members=Set(topic.sourceIDs)
                for section in sections {
                    guard !section.id.isEmpty,!section.title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
                          !section.summary.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,!section.evidence.isEmpty,
                          Set(section.claimIDs).count == section.claimIDs.count,Set(section.actionIDs).count == section.actionIDs.count else { throw VoiceOSError("主题卡片缺少内容或原话依据") }
                    for evidence in section.evidence {
                        guard members.contains(evidence.sourceID),!evidence.quote.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
                              sources[evidence.sourceID]?.text.contains(evidence.quote) == true else { throw VoiceOSError("主题卡片的引用无法定位到当前完整原文") }
                    }
                    for id in section.claimIDs {
                        guard let item=knowledge[id],Set(item.sourceIDs).isSubset(of:members) else { throw VoiceOSError("主题卡片引用了无效观点或其他材料") }
                        assignedClaims.insert(id)
                    }
                    for id in section.actionIDs {
                        guard let task=tasks[id],Set(task.sourceIDs).isSubset(of:members) else { throw VoiceOSError("主题卡片引用了无效行动或其他材料") }
                        assignedActions.insert(id)
                    }
                }
            }
        }
        guard covered == allowed else { throw VoiceOSError("主题整理遗漏了材料，未保存不完整归组") }
        if result.topics.allSatisfy({ $0.sections != nil }) {
            guard assignedClaims == Set(knowledge.keys),assignedActions == Set(tasks.keys) else { throw VoiceOSError("主题卡片遗漏了已有观点或行动，未保存不完整归组") }
        }
    }
}
