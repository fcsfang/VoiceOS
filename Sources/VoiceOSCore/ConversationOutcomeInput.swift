import Foundation

/// A separate extraction input: includes the last accepted reply and can be prepared after end.
/// Reply failures remain explicit metadata; missing output is never reconstructed.
public struct ConversationOutcomeReply:Codable,Sendable {
    public let attemptID:String
    public let replyToTurnID:String
    public let state:String
    public let validity:String
    public let digest:String?
    public let parts:[DiscussionPart]
}
public struct ConversationOutcomeSnapshot:Codable,Sendable {
    public let input:PreparedConversationInput
    public let sessionState:String
    public let context:LocalTranscriptContext
    public let replies:[ConversationOutcomeReply]
    public let reusePlan:ConversationOutcomeReusePlan?
    init(input:PreparedConversationInput,sessionState:String,context:LocalTranscriptContext,replies:[ConversationOutcomeReply],reusePlan:ConversationOutcomeReusePlan?=nil) {
        self.input=input;self.sessionState=sessionState;self.context=context;self.replies=replies;self.reusePlan=reusePlan
    }
}
public struct OutcomeSourceEvidence:Codable,Sendable {
    public let reference:ClaimReference
    public let quote:String
    public init(reference:ClaimReference,quote:String) { self.reference=reference;self.quote=quote }
}
public struct OutcomeReplyEvidence:Codable,Sendable {
    public let attemptID:String
    public let partIndex:Int
    public let quote:String
    public init(attemptID:String,partIndex:Int,quote:String) { self.attemptID=attemptID;self.partIndex=partIndex;self.quote=quote }
}
/// A proposal, not a committed candidate or a grant. Both kinds of evidence keep their identity.
public struct ConversationOutcomeProposal:Codable,Sendable {
    public let statement:String
    public let contentKind:CognitiveContentKind?
    public let ownership:CandidateOwnership
    public let sourceEvidence:[OutcomeSourceEvidence]
    public let replyEvidence:[OutcomeReplyEvidence]
    public let action:ExtractedAction?
    public init(statement:String,ownership:CandidateOwnership,sourceEvidence:[OutcomeSourceEvidence],replyEvidence:[OutcomeReplyEvidence]=[],action:ExtractedAction?=nil,contentKind:CognitiveContentKind?=nil) {
        self.statement=statement;self.ownership=ownership;self.sourceEvidence=sourceEvidence;self.replyEvidence=replyEvidence;self.action=action;self.contentKind=contentKind
    }
}
extension VoiceOSStore {
    /// Local preparation only. No model, endorsement, candidate or action side effects.
    public func prepareConversationOutcome(id:String,expectedVersion:Int,destination:ModelDestination,scalarBudget:Int=8000,commandID:String=UUID().uuidString) throws -> ConversationOutcomeSnapshot {
        guard ready,!commandID.isEmpty,(1...12000).contains(scalarBudget) else { throw VoiceOSError("讨论成果准备命令无效") }
        let session=try conversation(id:id)
        guard session.validity == "current",session.version == expectedVersion else { throw VoiceOSError("讨论成果版本或来源已变化") }
        let history=try conversationHistorySources(conversationID:id).map(\.sourceID),turns=try conversationUserTurns(conversationID:id)
        guard !turns.isEmpty else { throw VoiceOSError("讨论没有个人发言，不提取成果") }
        var ids=history
        for turn in turns where !ids.contains(turn.sourceID) { ids.append(turn.sourceID) }
        let entry = try conversationHistoryContext(id)
        guard try recordingContextSourceIDs(sourceIDs:history) == history else { throw VoiceOSError("讨论成果依据已增加节目上下文，请从当前材料继续") }
        try validateLocalTranscriptContext(entry)
        let replies=try outcomeReplies(id,destination:destination)
        if let focus = entry.conversationFocus { try validateConversationThoughtFocus(focus) }
        if let focus = entry.reflectionFocus { try validateReflectionFocus(focus) }
        let replyCharacters = replies.reduce(0) { $0 + $1.parts.reduce(0) { $0 + $1.text.unicodeScalars.count } }
        var context = try prepareFullDiscussionContext(sourceIDs:ids,minimumBudget:scalarBudget,replyCharacters:replyCharacters)
        context.conversationFocus = entry.conversationFocus
        context.reflectionFocus = entry.reflectionFocus
        try Self.validateOutcomeBudget(context,replies)
        let contextID=try persistLocalContext(context,commandID:"discussion-outcome:"+commandID,destination:destination)
        let input=PreparedConversationInput(conversationID:id,conversationVersion:session.version,contextID:contextID,historySourceIDs:history,userTurns:turns.map { ConversationTurnReference(turnID:$0.id,sourceID:$0.sourceID,transcriptVersionID:$0.transcriptVersionID) },destination:destination)
        let snapshot=ConversationOutcomeSnapshot(input:input,sessionState:session.state,context:context,replies:replies)
        try validateConversationOutcome(snapshot)
        return snapshot
    }
    /// Recheck before a future request and again before accepting it; ended-before-prepare is valid,
    /// but end/new turn/reply transition during extraction invalidates the exact input.
    public func validateConversationOutcome(_ snapshot:ConversationOutcomeSnapshot) throws {
        let input=snapshot.input,session=try conversation(id:input.conversationID)
        guard ready,session.validity == "current",session.state == snapshot.sessionState,session.version == input.conversationVersion,
              try db.query("SELECT destination FROM contexts WHERE id=?",[input.contextID]).first?["destination"] == input.destination.rawValue else { throw VoiceOSError("讨论成果输入状态或目的地已变化") }
        let current=try localContext(id:input.contextID),history=try conversationHistorySources(conversationID:input.conversationID).map(\.sourceID),turns=try conversationUserTurns(conversationID:input.conversationID)
        if let focus = current.conversationFocus { try validateConversationThoughtFocus(focus) }
        if let focus = current.reflectionFocus { try validateReflectionFocus(focus) }
        let entry = try conversationHistoryContext(input.conversationID)
        guard try recordingContextSourceIDs(sourceIDs:history) == history else { throw VoiceOSError("讨论成果缺少当前配对的节目来源") }
        try validateLocalTranscriptContext(entry)
        guard try Self.relevanceJSON(current.conversationFocus) == Self.relevanceJSON(entry.conversationFocus) else { throw VoiceOSError("讨论成果焦点与入口不一致") }
        guard try Self.relevanceJSON(current.reflectionFocus) == Self.relevanceJSON(entry.reflectionFocus) else { throw VoiceOSError("讨论成果范围与入口不一致") }
        let refs=turns.map { ConversationTurnReference(turnID:$0.id,sourceID:$0.sourceID,transcriptVersionID:$0.transcriptVersionID) }
        var ids=history
        for turn in turns where !ids.contains(turn.sourceID) { ids.append(turn.sourceID) }
        guard history == input.historySourceIDs,refs == input.userTurns,current.sources.map(\.sourceID) == ids,
              try Self.relevanceJSON(current) == Self.relevanceJSON(snapshot.context),
              try Self.relevanceJSON(outcomeReplies(input.conversationID,destination:input.destination)) == Self.relevanceJSON(snapshot.replies),
              input.destination != .cloud || current.sources.allSatisfy({ !$0.localOnly }) else { throw VoiceOSError("讨论成果实际输入、角色或许可不符") }
        try Self.validateOutcomeBudget(current,snapshot.replies)
    }
    private func outcomeReplies(_ conversationID:String,destination:ModelDestination) throws -> [ConversationOutcomeReply] {
        try db.query("SELECT a.* FROM discussion_attempts a JOIN conversation_user_turns t ON t.id=a.reply_to_turn_id WHERE a.conversation_id=? ORDER BY t.ordinal",[conversationID]).map { row in
            guard row["state"] != "reserved" else { throw VoiceOSError("仍有讨论回复在途，请等待结果后整理成果") }
            if row["state"] == "completed" {
                guard row["validity"] == "current" else { throw VoiceOSError("讨论AI依据已冻结") }
                let context=try localContext(id:row["context_id"]!)
                guard destination != .cloud || context.sources.allSatisfy({ !$0.localOnly }) else { throw VoiceOSError("仅本地衍生AI回复不能进入云端成果提取") }
            }
            return ConversationOutcomeReply(attemptID:row["id"]!,replyToTurnID:row["reply_to_turn_id"]!,state:row["state"]!,validity:row["validity"]!,digest:row["result_digest"],parts:try Self.discussionParts(row))
        }
    }
    static func validateOutcomeBudget(_ context:LocalTranscriptContext,_ replies:[ConversationOutcomeReply]) throws {
        let size=context.sources.reduce(0) { $0+$1.text.unicodeScalars.count }+replies.reduce(0) { $0+$1.parts.reduce(0) { $0+$1.text.unicodeScalars.count } }
        guard context.scalarBudget > 0,size <= context.scalarBudget else { throw VoiceOSError("完整讨论成果输入超过预算，不静默删减历史") }
    }
    public static func validateConversationOutcomeProposals(_ proposals:[ConversationOutcomeProposal],snapshot:ConversationOutcomeSnapshot) throws {
        for proposal in proposals {
            guard proposal.contentKind != .question || proposal.action == nil else { throw VoiceOSError("讨论问题不能同时作为行动承诺") }
            guard !proposal.statement.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,proposal.statement.unicodeScalars.count <= 2000,
                  proposal.sourceEvidence.count+proposal.replyEvidence.count > 0 else { throw VoiceOSError("讨论成果缺少内容或出处") }
            var seen:Set<String>=[],personalQuotes:[String]=[]
            for evidence in proposal.sourceEvidence {
                let ref=evidence.reference
                guard seen.insert("source:"+ref.sourceID+":"+ref.transcriptVersionID+":"+ref.spanID).inserted,
                      let source=snapshot.context.sources.first(where: { $0.sourceID == ref.sourceID && $0.transcriptVersionID == ref.transcriptVersionID }),
                      let span=source.spans.first(where: { $0.id == ref.spanID }) else { throw VoiceOSError("成果原文引用不在实际输入") }
                let text=Array(source.text.unicodeScalars)
                guard span.textStart >= 0,span.textEnd <= text.count,span.textStart < span.textEnd,!evidence.quote.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,evidence.quote.unicodeScalars.count <= 2000,
                      String(String.UnicodeScalarView(text[span.textStart..<span.textEnd])).contains(evidence.quote) else { throw VoiceOSError("成果引文不是原文连续片段") }
                let personal=source.origin == "user" && source.speaker == "user" && snapshot.input.userTurns.contains(where: { $0.sourceID == source.sourceID && $0.transcriptVersionID == source.transcriptVersionID })
                if personal { personalQuotes.append(evidence.quote) }
                guard proposal.ownership != .userTentative || personal,proposal.ownership != .external || source.origin == "external" else { throw VoiceOSError("历史或外部引文不能冒充本轮个人成果") }
            }
            for evidence in proposal.replyEvidence {
                guard seen.insert("reply:"+evidence.attemptID+":"+String(evidence.partIndex)).inserted,
                      let reply=snapshot.replies.first(where: { $0.attemptID == evidence.attemptID && $0.state == "completed" && $0.validity == "current" }),reply.parts.indices.contains(evidence.partIndex),
                      reply.parts[evidence.partIndex].kind == .aiSuggestion,!evidence.quote.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,evidence.quote.unicodeScalars.count <= 2000,reply.parts[evidence.partIndex].text.contains(evidence.quote),proposal.ownership != .external else { throw VoiceOSError("AI成果引用没有对应接纳的AI段落；原话引用应返回实际来源") }
            }
            if proposal.ownership == .userTentative,personalQuotes.isEmpty { throw VoiceOSError("AI段落不能单独证明用户认可") }
            if let action=proposal.action {
                guard !action.title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,action.title.unicodeScalars.count <= 2000,!action.quote.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,action.quote.unicodeScalars.count <= 2000,
                      !action.autoSend || (action.kind == .task && action.quote.contains(action.title)) else { throw VoiceOSError("自动讨论任务需完整个人原话包含动作标题，不能省略AI引用绕过指代屏障") }
                if proposal.ownership == .aiCandidate {
                    guard action.kind == .aiSuggestion,!action.autoSend,proposal.replyEvidence.contains(where: { $0.quote.contains(action.quote) }) else { throw VoiceOSError("AI建议不能变成个人任务") }
                } else {
                    guard proposal.ownership == .userTentative,personalQuotes.contains(where: { $0.contains(action.quote) }),
                          action.kind != .aiSuggestion,proposal.replyEvidence.isEmpty || (action.kind == .opportunity && !action.autoSend) else { throw VoiceOSError("跨轮指代仅留待核对意图；自动任务需个人完整原话") }
                }
            }
        }
    }
}
