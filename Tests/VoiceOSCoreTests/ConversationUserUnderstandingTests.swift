import XCTest
import Foundation
@testable import VoiceOSCore

private struct OutcomeInspector:MediaInspector {
    func inspect(_ url:URL) async throws -> MediaInfo { throw VoiceOSError("text only") }
}
private struct OutcomeDiscussion:DiscussionModelPort {
    let configuration=ModelConfiguration(provider:"synthetic",model:"discussion",promptVersion:"v1",schemaVersion:"v1",destination:.local)
    func reply(_ request:DiscussionModelRequest) async throws -> DiscussionModelResponse {
        DiscussionModelResponse(status:.completed,parts:[DiscussionPart(kind:.aiSuggestion,text:"合成AI建议：也可以学习摄影，这不是用户承诺。")])
    }
}
private actor OutcomeUnderstanding:ModelPort {
    let configuration=ModelConfiguration(provider:"synthetic",model:"understanding",promptVersion:"v1",schemaVersion:"v1",destination:.local)
    var requests:[ModelRequest]=[]
    let callback:(@Sendable (ModelRequest) async throws -> Void)?
    init(callback:(@Sendable (ModelRequest) async throws -> Void)? = nil) { self.callback=callback }
    func generate(_ request:ModelRequest) async throws -> ModelResponse {
        requests.append(request)
        if let callback { try await callback(request) }
        let source=request.context.sources[0],refs=[ClaimReference(sourceID:source.sourceID,transcriptVersionID:source.transcriptVersionID,spanID:source.spans[0].id)]
        return ModelResponse(status:.completed,claims:[ClaimProposal(statement:"我会整理开发验证素材",ownership:.userTentative,references:refs,action:ExtractedAction(title:"整理开发验证素材",kind:.task,quote:"我会整理开发验证素材",autoSend:true)),ClaimProposal(statement:"我现在不打算学习摄影",ownership:.userTentative,references:refs)])
    }
}
final class ConversationUserUnderstandingTests:XCTestCase {
    var base:URL!
    override func setUpWithError() throws { base=FileManager.default.temporaryDirectory.appendingPathComponent("conversation-outcome-"+UUID().uuidString) }
    override func tearDownWithError() throws { if FileManager.default.fileExists(atPath:base.path) { try FileManager.default.removeItem(at:base) } }
    func store(_ name:String="root") async throws -> VoiceOSStore {
        let s=try VoiceOSStore(root:base.appendingPathComponent(name),inspector:OutcomeInspector());try await s.recover();return s
    }
    func setup(_ s:VoiceOSStore) async throws -> (String,String,String) {
        let history=try await s.recordUserExpression("合成旧猜想：条件还没验证。")
        let source=try await s.recordUserExpression("合成用户决定：我会整理开发验证素材。我现在不打算学习摄影。")
        _=try await s.setSourceLocalOnly(sourceID:source,expectedVersion:1,localOnly:false)
        let id=try await s.beginConversation(sourceIDs:[history])
        let turn=try await s.appendConversationUserSource(conversationID:id,sourceID:source,expectedVersion:1)
        let input=try await s.prepareConversationInput(id:id,expectedVersion:2,destination:.local)
        _=try await s.performConversationReply(input,using:OutcomeDiscussion())
        return (id,turn,source)
    }
    func testEndedDiscussionPersonalDecisionUsesExistingPipelineAndExcludesAIHistory() async throws {
        let s=try await store(),(id,turn,source)=try await setup(s),port=OutcomeUnderstanding()
        try await s.endConversation(id:id,expectedVersion:2)
        let ids=try await s.understandConversationUserTurn(conversationID:id,turnID:turn,using:port)
        let requests=await port.requests,claims=try await s.candidateClaims(),actions=try await s.actions(),session=try await s.conversation(id:id)
        XCTAssertEqual(ids.count,2);XCTAssertEqual(requests.count,1);XCTAssertEqual(requests[0].context.sources.map(\.sourceID),[source])
        XCTAssertFalse(requests[0].context.sources[0].text.contains("合成AI建议"))
        XCTAssertEqual(actions.count,1);XCTAssertEqual(actions[0].title,"整理开发验证素材");XCTAssertEqual(actions[0].intentActor,"user");XCTAssertTrue(actions[0].autoSend)
        XCTAssertTrue(claims.allSatisfy { $0.ownership == "user_tentative" && $0.reviewState == "pending" && $0.evidenceState == "unverified" && $0.references.allSatisfy { $0.sourceID == source } })
        XCTAssertEqual(session.state,"ended")
        let linked=try await s.conversationsForSource(sourceID:source)
        XCTAssertEqual(linked.map(\.id),[id])
        do { _=try await s.understandConversationUserTurn(conversationID:id,turnID:turn,using:port);XCTFail() } catch {}
        let after=await port.requests;XCTAssertEqual(after.count,1)
        let reminders=try await s.reminderLinks();XCTAssertTrue(reminders.isEmpty)
    }
    func testAIReplyIdentityAndAnotherConversationTurnCannotBecomePersonalInput() async throws {
        let s=try await store(),(id,_,source)=try await setup(s),port=OutcomeUnderstanding()
        let reply=try await s.discussionAttempts(conversationID:id)[0]
        let other=try await s.beginConversation(sourceIDs:[source])
        let personal=try await s.recordUserExpression("合成其他会话发言")
        let foreignTurn=try await s.appendConversationUserSource(conversationID:other,sourceID:personal,expectedVersion:1)
        for target in [reply.id,foreignTurn] {
            do { _=try await s.understandConversationUserTurn(conversationID:id,turnID:target,using:port);XCTFail() } catch {}
        }
        let requests=await port.requests;XCTAssertTrue(requests.isEmpty)
    }
    func testCorrectedDiscussionCannotExtractOldTurn() async throws {
        let s=try await store(),(id,turn,source)=try await setup(s),port=OutcomeUnderstanding()
        let text=try await s.prepareLocalTranscriptContext(sourceIDs:[source])
        _=try await s.correctTranscript(sourceID:source,expectedVersionID:text.sources[0].transcriptVersionID,text:"合成纠错：没有决定行动")
        do { _=try await s.understandConversationUserTurn(conversationID:id,turnID:turn,using:port);XCTFail() } catch {}
        let requests=await port.requests,claims=try await s.candidateClaims();XCTAssertTrue(requests.isEmpty);XCTAssertTrue(claims.isEmpty)
    }
    func testCorrectionDuringUnderstandingRejectsCandidatesAndActions() async throws {
        let s=try await store(),(id,turn,_)=try await setup(s)
        let port=OutcomeUnderstanding(callback:{ request in
            let source=request.context.sources[0]
            _=try await s.correctTranscript(sourceID:source.sourceID,expectedVersionID:source.transcriptVersionID,text:"合成纠错：没有决定行动")
        })
        do { _=try await s.understandConversationUserTurn(conversationID:id,turnID:turn,using:port);XCTFail() } catch {}
        let claims=try await s.candidateClaims(),actions=try await s.actions();XCTAssertTrue(claims.isEmpty);XCTAssertTrue(actions.isEmpty)
    }
    func testPersonalOutcomeAndConversationProvenanceSurviveMigrationWithoutResuming() async throws {
        let s=try await store(),(id,turn,source)=try await setup(s)
        _=try await s.understandConversationUserTurn(conversationID:id,turnID:turn,using:OutcomeUnderstanding())
        try await s.endConversation(id:id,expectedVersion:2)
        let claims=try await s.candidateClaims(),actions=try await s.actions()
        let package=base.appendingPathComponent("package"),target=base.appendingPathComponent("restored")
        try await s.exportPackage(to:package,includeMedia:true)
        try await VoiceOSStore.restorePackage(from:package,to:target,inspector:OutcomeInspector())
        let r=try await store("restored"),turns=try await r.conversationUserTurns(conversationID:id),restored=try await r.candidateClaims(includeFrozen:true),ra=try await r.actions(includeHistory:true)
        XCTAssertEqual(turns[0].id,turn);XCTAssertEqual(turns[0].sourceID,source)
        let linked=try await r.conversationsForSource(sourceID:source)
        XCTAssertEqual(linked.map(\.id),[id]);XCTAssertEqual(linked[0].validity,"frozen")
        XCTAssertEqual(Set(restored.map(\.id)),Set(claims.map(\.id)));XCTAssertEqual(Set(ra.map(\.id)),Set(actions.map(\.id)))
        let session=try await r.conversation(id:id);XCTAssertEqual(session.validity,"frozen")
        let port=OutcomeUnderstanding()
        do { _=try await r.understandConversationUserTurn(conversationID:id,turnID:turn,using:port);XCTFail() } catch {}
        let requests=await port.requests;XCTAssertTrue(requests.isEmpty)
    }
}
