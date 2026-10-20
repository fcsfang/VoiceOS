import XCTest
import Foundation
@testable import VoiceOSCore

private struct OutcomeInputInspector:MediaInspector {
    func inspect(_ url:URL) async throws -> MediaInfo { throw VoiceOSError("text fixture") }
}
private actor OutcomeInputDiscussion:DiscussionModelPort {
    let configuration=ModelConfiguration(provider:"synthetic",model:"discussion",promptVersion:"v1",schemaVersion:"v1",destination:.local)
    let unknown:Bool
    let callback:(@Sendable () async throws -> Void)?
    var calls=0
    init(unknown:Bool=false,callback:(@Sendable () async throws -> Void)?=nil) { self.unknown=unknown;self.callback=callback }
    func reply(_ request:DiscussionModelRequest) async throws -> DiscussionModelResponse {
        calls += 1
        if let callback { try await callback() }
        if unknown { throw VoiceOSError("synthetic timeout") }
        let s=request.snapshot.context.sources[0],ref=ClaimReference(sourceID:s.sourceID,transcriptVersionID:s.transcriptVersionID,spanID:s.spans[0].id)
        return DiscussionModelResponse(status:.completed,parts:[DiscussionPart(kind:.quotation,text:s.text,references:[ref]),DiscussionPart(kind:.aiSuggestion,text:"合成AI建议：可以阅读论文，这是建议而非个人承诺。")])
    }
}
final class ConversationOutcomeInputTests:XCTestCase {
    var base:URL!
    override func setUpWithError() throws { base=FileManager.default.temporaryDirectory.appendingPathComponent("conversation-outcome-input-"+UUID().uuidString) }
    override func tearDownWithError() throws { if FileManager.default.fileExists(atPath:base.path) { try FileManager.default.removeItem(at:base) } }
    func store(_ name:String="root") async throws -> VoiceOSStore { let s=try VoiceOSStore(root:base.appendingPathComponent(name),inspector:OutcomeInputInspector());try await s.recover();return s }
    private func setup(_ s:VoiceOSStore,granted:Bool=false,unknown:Bool=false) async throws -> (String,String,OutcomeInputDiscussion) {
        let old=try await s.recordUserExpression("合成历史：条件尚未验证。"),personal=try await s.recordUserExpression("合成个人：我会整理开发验证素材，但现在不打算阅读论文。")
        if granted { for id in [old,personal] { _=try await s.setSourceLocalOnly(sourceID:id,expectedVersion:1,localOnly:false) } }
        let id=try await s.beginConversation(sourceIDs:[old]);_=try await s.appendConversationUserSource(conversationID:id,sourceID:personal,expectedVersion:1)
        let input=try await s.prepareConversationInput(id:id,expectedVersion:2,destination:.local),port=OutcomeInputDiscussion(unknown:unknown)
        do { _=try await s.performConversationReply(input,using:port) } catch { if !unknown { throw error } }
        return (id,personal,port)
    }
    func testEndedPreparationIncludesLastAIReplyAndFullRoleCatalogWithoutWork() async throws {
        let s=try await store(),(id,personal,port)=try await setup(s)
        try await s.endConversation(id:id,expectedVersion:2)
        let input=try await s.prepareConversationOutcome(id:id,expectedVersion:3,destination:.local)
        try await s.validateConversationOutcome(input)
        XCTAssertEqual(input.sessionState,"ended");XCTAssertEqual(input.context.sources.count,2);XCTAssertEqual(input.input.userTurns[0].sourceID,personal)
        XCTAssertEqual(input.replies.count,1);XCTAssertEqual(input.replies[0].parts.count,2);XCTAssertEqual(input.replies[0].state,"completed")
        let calls=await port.calls,models=try await s.modelAttempts(),claims=try await s.candidateClaims(),actions=try await s.actions()
        XCTAssertEqual(calls,1);XCTAssertTrue(models.isEmpty);XCTAssertTrue(claims.isEmpty);XCTAssertTrue(actions.isEmpty)
    }
    func testUnknownReplyIsExplicitMetadataNotInventedTextOrRetry() async throws {
        let s=try await store(),(id,_,port)=try await setup(s,unknown:true)
        let input=try await s.prepareConversationOutcome(id:id,expectedVersion:2,destination:.local)
        XCTAssertEqual(input.replies[0].state,"unknown");XCTAssertNil(input.replies[0].digest);XCTAssertTrue(input.replies[0].parts.isEmpty)
        let calls=await port.calls;XCTAssertEqual(calls,1)
    }
    func testFullHistoryBudgetCountsLatestAIAndNeverSilentlyTrims() async throws {
        let s=try await store(),(id,_,_)=try await setup(s)
        let baseInput=try await s.prepareConversationOutcome(id:id,expectedVersion:2,destination:.local)
        let sourceCount=baseInput.context.sources.reduce(0) { $0+$1.text.unicodeScalars.count }
        do { _=try await s.prepareConversationOutcome(id:id,expectedVersion:2,destination:.local,scalarBudget:sourceCount);XCTFail() } catch {}
        do { _=try await s.prepareConversationOutcome(id:id,expectedVersion:2,destination:.local,scalarBudget:13000);XCTFail() } catch {}
    }
    func testCloudChecksAllInputsAndDerivedAIAndRevocationRejectsPreparedSnapshot() async throws {
        let local=try await store("local"),(localID,_,_)=try await setup(local)
        do { _=try await local.prepareConversationOutcome(id:localID,expectedVersion:2,destination:.cloud);XCTFail() } catch {}
        let s=try await store("granted"),(id,personal,_)=try await setup(s,granted:true)
        let input=try await s.prepareConversationOutcome(id:id,expectedVersion:2,destination:.cloud)
        _=try await s.setSourceLocalOnly(sourceID:personal,expectedVersion:2,localOnly:true)
        do { try await s.validateConversationOutcome(input);XCTFail() } catch {}
    }
    func testEndNewTurnOrCorrectionInvalidatePreparedInput() async throws {
        for mode in ["end","turn","correction"] {
            let s=try await store(mode),(id,personal,_)=try await setup(s)
            let input=try await s.prepareConversationOutcome(id:id,expectedVersion:2,destination:.local)
            if mode == "end" { try await s.endConversation(id:id,expectedVersion:2) }
            else if mode == "turn" { let p=try await s.recordUserExpression("合成第二轮：我暂不同意");_=try await s.appendConversationUserSource(conversationID:id,sourceID:p,expectedVersion:2) }
            else { let source=try XCTUnwrap(input.context.sources.first { $0.sourceID == personal });_=try await s.correctTranscript(sourceID:personal,expectedVersionID:source.transcriptVersionID,text:"合成更正：没有行动承诺") }
            do { try await s.validateConversationOutcome(input);XCTFail(mode) } catch {}
        }
    }
    func testProposalsSeparateSourceAndAIQuotesAndCannotPromoteCrossTurnApprovalToTask() async throws {
        let s=try await store(),(id,personal,_)=try await setup(s)
        let input=try await s.prepareConversationOutcome(id:id,expectedVersion:2,destination:.local),source=try XCTUnwrap(input.context.sources.first { $0.sourceID == personal })
        let ref=ClaimReference(sourceID:source.sourceID,transcriptVersionID:source.transcriptVersionID,spanID:source.spans[0].id)
        let evidence=OutcomeSourceEvidence(reference:ref,quote:"我会整理开发验证素材"),reply=OutcomeReplyEvidence(attemptID:input.replies[0].attemptID,partIndex:1,quote:"可以阅读论文")
        let fullTask=ConversationOutcomeProposal(statement:evidence.quote,ownership:.userTentative,sourceEvidence:[evidence],action:ExtractedAction(title:"整理开发验证素材",kind:.task,quote:evidence.quote,autoSend:true))
        let ai=ConversationOutcomeProposal(statement:"合成阅读建议",ownership:.aiCandidate,sourceEvidence:[],replyEvidence:[reply],action:ExtractedAction(title:"阅读论文",kind:.aiSuggestion,quote:reply.quote))
        try VoiceOSStore.validateConversationOutcomeProposals([fullTask,ai],snapshot:input)
        let invalid:[ConversationOutcomeProposal]=[
            .init(statement:"伪造个人承诺",ownership:.userTentative,sourceEvidence:[],replyEvidence:[reply]),
            .init(statement:"省略AI引用仍不能自动执行",ownership:.userTentative,sourceEvidence:[evidence],action:ExtractedAction(title:"阅读论文",kind:.task,quote:evidence.quote,autoSend:true)),
            .init(statement:"跨轮任务",ownership:.userTentative,sourceEvidence:[evidence],replyEvidence:[reply],action:ExtractedAction(title:"阅读论文",kind:.task,quote:evidence.quote,autoSend:true)),
            .init(statement:"伪造引文",ownership:.userTentative,sourceEvidence:[.init(reference:ref,quote:"我决定阅读论文")]),
            .init(statement:"AI冒充外部",ownership:.external,sourceEvidence:[],replyEvidence:[reply]),
            .init(statement:"引用冒充AI",ownership:.aiCandidate,sourceEvidence:[],replyEvidence:[.init(attemptID:input.replies[0].attemptID,partIndex:0,quote:input.replies[0].parts[0].text)]),
            .init(statement:"重复出处",ownership:.aiCandidate,sourceEvidence:[],replyEvidence:[reply,reply])]
        for proposal in invalid { XCTAssertThrowsError(try VoiceOSStore.validateConversationOutcomeProposals([proposal],snapshot:input)) }
        let unresolved=ConversationOutcomeProposal(statement:"跨轮意图待核对",ownership:.userTentative,sourceEvidence:[evidence],replyEvidence:[reply],action:ExtractedAction(title:"阅读论文",kind:.opportunity,quote:evidence.quote))
        try VoiceOSStore.validateConversationOutcomeProposals([unresolved],snapshot:input)
    }
    func testEntryHistoryCannotBecomeNewPersonalStatementAndRestoreCannotResumePreparation() async throws {
        let s=try await store(),(id,_,_)=try await setup(s),input=try await s.prepareConversationOutcome(id:id,expectedVersion:2,destination:.local)
        let entry=input.context.sources[0],ref=ClaimReference(sourceID:entry.sourceID,transcriptVersionID:entry.transcriptVersionID,spanID:entry.spans[0].id)
        XCTAssertThrowsError(try VoiceOSStore.validateConversationOutcomeProposals([.init(statement:entry.text,ownership:.userTentative,sourceEvidence:[.init(reference:ref,quote:entry.text)])],snapshot:input))
        let package=base.appendingPathComponent("package");try await s.exportPackage(to:package)
        try await VoiceOSStore.restorePackage(from:package,to:base.appendingPathComponent("restored"),inspector:OutcomeInputInspector())
        let r=try await store("restored")
        do { _=try await r.prepareConversationOutcome(id:id,expectedVersion:2,destination:.local);XCTFail() } catch {}
    }
    func testReservedReplyBlocksPreparationUntilActualReceiptSettles() async throws {
        let s=try await store(),(id,_,_)=try await setup(s),probe=OutcomePreparationProbe()
        let source=try await s.recordUserExpression("合成第二轮：继续检验条件")
        _=try await s.appendConversationUserSource(conversationID:id,sourceID:source,expectedVersion:2)
        let input=try await s.prepareConversationInput(id:id,expectedVersion:3,destination:.local)
        let port=OutcomeInputDiscussion(callback:{
            do { _=try await s.prepareConversationOutcome(id:id,expectedVersion:3,destination:.local) }
            catch { await probe.markBlocked() }
        })
        _=try await s.performConversationReply(input,using:port)
        let blocked=await probe.blocked;XCTAssertTrue(blocked)
        let outcome=try await s.prepareConversationOutcome(id:id,expectedVersion:3,destination:.local)
        XCTAssertEqual(outcome.replies.count,2);XCTAssertEqual(outcome.input.userTurns.count,2);XCTAssertEqual(outcome.context.sources.count,3)
    }

}

private actor OutcomePreparationProbe { var blocked=false;func markBlocked() { blocked=true } }
