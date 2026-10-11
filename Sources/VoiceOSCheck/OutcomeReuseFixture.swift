import Foundation
import VoiceOSCore

func runOutcomeReuseFixture(_ store:VoiceOSStore) async throws {
    let history=try await store.recordUserExpression("合成历史：迁移猜想尚未验证。",commandID:"reuse-history")
    let first=try await store.recordUserExpression("合成个人：我会整理开发验证素材。",commandID:"reuse-personal-first")
    let second=try await store.recordUserExpression("合成个人：我会校验迁移资料。",commandID:"reuse-personal-second")
    let id=try await store.beginConversation(sourceIDs:[history],commandID:"reuse-entry")
    _=try await store.appendConversationUserSource(conversationID:id,sourceID:first,expectedVersion:1,commandID:"reuse-turn-first")
    if try await store.discussionAttempts(conversationID:id).isEmpty {
        let input=try await store.prepareConversationInput(id:id,expectedVersion:2,destination:.local)
        _=try await store.performConversationReply(input,using:ReusableFixtureDiscussion())
    }
    if try await store.modelAttempts(sourceID:first).allSatisfy({ $0.provider != "reuse_fixture_personal" }) {
        _=try await store.understandSource(sourceID:first,using:ReusableFixturePersonal())
    }
    let actions=try await store.actions(includeHistory:true)
    guard let action=actions.first(where: { $0.title == "整理开发验证素材" }) else { throw VoiceOSError("missing synthetic prior task") }
    _=try await store.setActionState(actionID:action.id,expectedVersion:1,state:.completed,commandID:"reuse-prior-completed")
    guard let reply=try await store.discussionAttempts(conversationID:id).first else { throw VoiceOSError("missing synthetic reply") }
    let ai=try await store.retainDiscussionAICandidate(attemptID:reply.id,partIndex:0,commandID:"reuse-prior-ai")
    _=try await store.reviewClaim(claimID:ai,expectedVersion:0,action:.reject,commandID:"reuse-prior-rejected")
    _=try await store.appendConversationUserSource(conversationID:id,sourceID:second,expectedVersion:2,commandID:"reuse-turn-second")
    try await store.endConversation(id:id,expectedVersion:3,commandID:"reuse-end")
    if try await store.conversationOutcomes(conversationID:id).isEmpty {
        let input=try await store.prepareReusableConversationOutcome(id:id,expectedVersion:4,destination:.local,commandID:"reuse-outcome")
        _=try await store.performConversationOutcome(input,using:ReusableFixtureOutcome())
    }
}
private struct ReusableFixtureDiscussion:DiscussionModelPort {
    let configuration=ModelConfiguration(provider:"fixture",model:"discussion",promptVersion:"v1",schemaVersion:"v1",destination:.local)
    func reply(_ request:DiscussionModelRequest) async throws -> DiscussionModelResponse {
        .init(status:.completed,parts:[.init(kind:.aiSuggestion,text:"合成AI：比较迁移反例，尚未验证。")])
    }
}
private struct ReusableFixturePersonal:ModelPort {
    let configuration=ModelConfiguration(provider:"reuse_fixture_personal",model:"personal",promptVersion:"v1",schemaVersion:"v1",destination:.local)
    func generate(_ request:ModelRequest) async throws -> ModelResponse {
        let s=request.context.sources[0],ref=ClaimReference(sourceID:s.sourceID,transcriptVersionID:s.transcriptVersionID,spanID:s.spans[0].id)
        return .init(status:.completed,claims:[.init(statement:s.text,ownership:.userTentative,references:[ref],action:.init(title:"整理开发验证素材",kind:.task,quote:s.text,autoSend:true))])
    }
}
private struct ReusableFixtureOutcome:ConversationOutcomePort {
    let configuration=ModelConfiguration(provider:"reuse_fixture_outcome",model:"outcome",promptVersion:"v1",schemaVersion:"v1",destination:.local)
    func extract(_ request:ConversationOutcomeRequest) async throws -> ConversationOutcomeResponse {
        guard let plan=request.snapshot.reusePlan,let turn=plan.personalTargets.first,let source=request.snapshot.context.sources.first(where: { $0.sourceID == turn.sourceID }),let reply=request.snapshot.replies.first else { throw VoiceOSError("missing synthetic reusable scope") }
        let ref=ClaimReference(sourceID:source.sourceID,transcriptVersionID:source.transcriptVersionID,spanID:source.spans[0].id)
        return .init(status:.completed,proposals:[
            .init(statement:source.text,ownership:.userTentative,sourceEvidence:[.init(reference:ref,quote:source.text)],action:.init(title:"校验迁移资料",kind:.task,quote:source.text,autoSend:true)),
            .init(statement:"合成AI新成果：迁移仍需反例验证。",ownership:.aiCandidate,sourceEvidence:[],replyEvidence:[.init(attemptID:reply.attemptID,partIndex:0,quote:reply.parts[0].text)])],inputTokens:10,outputTokens:5)
    }
}
