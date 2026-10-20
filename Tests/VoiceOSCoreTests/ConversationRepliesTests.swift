import XCTest
import Foundation
@testable import VoiceOSCore

private struct DiscussionInspector: MediaInspector {
    func inspect(_ url:URL) async throws -> MediaInfo { throw VoiceOSError("text fixture only") }
}
private actor DiscussionFixture: DiscussionModelPort {
    enum Mode { case valid, falseQuote, unknown, refused, invalidUsage, rejected, invalidRejectedUsage, foreignCitation, duplicateCitation }
    let configuration:ModelConfiguration
    let mode:Mode
    let callback:(@Sendable (DiscussionModelRequest) async throws -> Void)?
    var requests:[DiscussionModelRequest] = []
    init(_ mode:Mode = .valid,destination:ModelDestination = .local,callback:(@Sendable (DiscussionModelRequest) async throws -> Void)? = nil) {
        self.mode=mode;self.callback=callback
        configuration=ModelConfiguration(provider:"fixture",model:"discussion",promptVersion:"v1",schemaVersion:"v1",destination:destination)
    }
    func reply(_ request:DiscussionModelRequest) async throws -> DiscussionModelResponse {
        requests.append(request)
        if let callback { try await callback(request) }
        if mode == .unknown { throw VoiceOSError("synthetic transport timeout") }
        if mode == .invalidRejectedUsage { throw ModelPortFailure.rejected("invalid usage",inputTokens:-1,outputTokens:2) }
        if mode == .rejected { throw ModelPortFailure.rejected("synthetic rejection",inputTokens:7,outputTokens:2) }
        let source=request.snapshot.context.sources[0],ref=ClaimReference(sourceID:mode == .foreignCitation ? "foreign" : source.sourceID,transcriptVersionID:source.transcriptVersionID,spanID:source.spans[0].id)
        return DiscussionModelResponse(status:mode == .refused ? .refused : .completed,
            parts:[DiscussionPart(kind:.quotation,text:mode == .falseQuote ? "捏造的原话" : source.text,references:mode == .duplicateCitation ? [ref,ref] : [ref]),
                   DiscussionPart(kind:.aiSuggestion,text:"合成AI分析：可以检验反例；这不代表用户已承诺阅读或认可结论。",references:[ref])],inputTokens:11,outputTokens:mode == .invalidUsage ? -1 : 5)
    }
}
final class ConversationRepliesTests:XCTestCase {
    var base:URL!
    override func setUpWithError() throws { base=FileManager.default.temporaryDirectory.appendingPathComponent("discussion-reply-"+UUID().uuidString) }
    override func tearDownWithError() throws { if FileManager.default.fileExists(atPath:base.path) { try FileManager.default.removeItem(at:base) } }
    func store(_ name:String = "root",checkpoint:@escaping @Sendable (SaveCheckpoint) throws -> Void = {_ in}) async throws -> VoiceOSStore {
        let s=try VoiceOSStore(root:base.appendingPathComponent(name),inspector:DiscussionInspector(),checkpoint:checkpoint);try await s.recover();return s
    }
    func input(_ s:VoiceOSStore) async throws -> PreparedConversationInput {
        let history=try await s.recordUserExpression("合成旧观点：条件保留可能比容量更重要，尚未验证。",commandID:"history")
        let id=try await s.beginConversation(sourceIDs:[history],commandID:"entry")
        let source=try await s.recordUserExpression("合成追问：哪些反例能限制这个猜想？",commandID:"turn-source")
        _=try await s.appendConversationUserSource(conversationID:id,sourceID:source,expectedVersion:1,commandID:"turn")
        return try await s.prepareConversationInput(id:id,expectedVersion:2,destination:.local)
    }
    func testCompletedReplyHasExactQuoteAIIdentityKnownUsageAndNoSideEffects() async throws {
        let s=try await store(),input=try await input(s),port=DiscussionFixture()
        let id=try await s.performConversationReply(input,using:port),attempts=try await s.discussionAttempts(conversationID:input.conversationID)
        XCTAssertEqual(attempts.count,1);XCTAssertEqual(attempts[0].id,id);XCTAssertEqual(attempts[0].state,"completed")
        XCTAssertEqual(attempts[0].parts[0].kind,.quotation);XCTAssertEqual(attempts[0].parts[1].kind,.aiSuggestion)
        XCTAssertEqual(attempts[0].usage,["input_tokens":11,"output_tokens":5]);XCTAssertEqual(attempts[0].billingState,"unknown")
        let claims=try await s.candidateClaims(),actions=try await s.actions();XCTAssertTrue(claims.isEmpty);XCTAssertTrue(actions.isEmpty)
        try await s.endConversation(id:input.conversationID,expectedVersion:2)
        let after=try await s.discussionAttempts(conversationID:input.conversationID);XCTAssertEqual(after[0].parts.count,2)
    }
    func testSecondRoundIncludesPriorAIResultAndAllUserHistory() async throws {
        let s=try await store(),first=try await input(s),port=DiscussionFixture()
        let previous=try await s.performConversationReply(first,using:port)
        let source=try await s.recordUserExpression("合成第二轮：请比较旧观点和这个反例。")
        _=try await s.appendConversationUserSource(conversationID:first.conversationID,sourceID:source,expectedVersion:2)
        let second=try await s.prepareConversationInput(id:first.conversationID,expectedVersion:3,destination:.local)
        _=try await s.performConversationReply(second,using:port)
        let requests=await port.requests;XCTAssertEqual(requests.count,2)
        XCTAssertEqual(requests[1].snapshot.priorReplies.map(\.attemptID),[previous]);XCTAssertEqual(requests[1].snapshot.input.userTurns.count,2)
        XCTAssertEqual(requests[1].snapshot.context.sources.count,3)
    }
    func testReprepareCannotResendSameTurnOrChangeModelToEvadeUnknown() async throws {
        let s=try await store(),first=try await input(s),port=DiscussionFixture(.unknown)
        do { _=try await s.performConversationReply(first,using:port);XCTFail() } catch {}
        let prepared=try await s.prepareConversationInput(id:first.conversationID,expectedVersion:2,destination:.local)
        let fresh=DiscussionFixture()
        do { _=try await s.performConversationReply(prepared,using:fresh);XCTFail() } catch {}
        let requests=await fresh.requests;XCTAssertTrue(requests.isEmpty)
        let attempts=try await s.discussionAttempts(conversationID:first.conversationID);XCTAssertEqual(attempts[0].state,"unknown")
    }
    func testFalseQuoteRefusalAndNegativeUsageRejectWithoutCommit() async throws {
        for (index,mode) in [DiscussionFixture.Mode.falseQuote,.refused,.invalidUsage].enumerated() {
            let s=try await store("case\(index)"),input=try await input(s)
            do { _=try await s.performConversationReply(input,using:DiscussionFixture(mode));XCTFail() } catch {}
            let rows=try await s.discussionAttempts(conversationID:input.conversationID)
            XCTAssertEqual(rows[0].state,"rejected");XCTAssertTrue(rows[0].parts.isEmpty)
        }
    }
    func testExplicitModelRejectionPreservesKnownUsage() async throws {
        let s=try await store(),input=try await input(s)
        do { _=try await s.performConversationReply(input,using:DiscussionFixture(.rejected));XCTFail() } catch {}
        let rows=try await s.discussionAttempts(conversationID:input.conversationID)
        XCTAssertEqual(rows[0].state,"rejected");XCTAssertEqual(rows[0].usage,["input_tokens":7,"output_tokens":2])
    }
    func testEndWhileWaitingRejectsLateResultAndDoesNotReopen() async throws {
        let s=try await store(),input=try await input(s)
        let port=DiscussionFixture(callback: { _ in try await s.endConversation(id:input.conversationID,expectedVersion:2) })
        do { _=try await s.performConversationReply(input,using:port);XCTFail() } catch {}
        let session=try await s.conversation(id:input.conversationID),rows=try await s.discussionAttempts(conversationID:input.conversationID)
        XCTAssertEqual(session.state,"ended");XCTAssertEqual(rows[0].state,"rejected");XCTAssertEqual(rows[0].usage?["input_tokens"],11)
    }
    func testCorrectionWhileWaitingRejectsLateResultAndFreezesWholeDiscussion() async throws {
        let s=try await store(),input=try await input(s)
        let port=DiscussionFixture(callback: { request in
            let source=request.snapshot.context.sources[0]
            _=try await s.correctTranscript(sourceID:source.sourceID,expectedVersionID:source.transcriptVersionID,text:"合成纠错后的历史")
        })
        do { _=try await s.performConversationReply(input,using:port);XCTFail() } catch {}
        let session=try await s.conversation(id:input.conversationID),rows=try await s.discussionAttempts(conversationID:input.conversationID)
        XCTAssertEqual(session.validity,"frozen");XCTAssertEqual(rows[0].state,"rejected");XCTAssertEqual(rows[0].validity,"frozen")
        let original=try await s.conversationHistorySources(conversationID:input.conversationID),sessions=try await s.conversations()
        XCTAssertTrue(original[0].text.contains("合成旧观点"));XCTAssertEqual(sessions.first?.validity,"frozen")
    }
    func testSourceRestrictionAndDestinationMismatchDoNotCallPort() async throws {
        let s=try await store(),input=try await input(s),port=DiscussionFixture(destination:.cloud)
        do { _=try await s.performConversationReply(input,using:port);XCTFail() } catch {}
        let calls=await port.requests;XCTAssertTrue(calls.isEmpty)
        let rows=try await s.discussionAttempts(conversationID:input.conversationID);XCTAssertTrue(rows.isEmpty)
    }
    func testRestartAfterReservationMarksUnknownAndNeverSendsAutomatically() async throws {
        var conversationID:String!
        do {
            let s=try await store(checkpoint: { if $0 == .discussionReserved { throw VoiceOSError("injected exit") } }),input=try await input(s)
            conversationID=input.conversationID
            do { _=try await s.performConversationReply(input,using:DiscussionFixture());XCTFail() } catch {}
        }
        let s=try await store(),rows=try await s.discussionAttempts(conversationID:conversationID)
        XCTAssertEqual(rows.count,1);XCTAssertEqual(rows[0].state,"unknown")
        let input=try await s.prepareConversationInput(id:conversationID,expectedVersion:2,destination:.local),port=DiscussionFixture()
        do { _=try await s.performConversationReply(input,using:port);XCTFail() } catch {}
        let requests=await port.requests;XCTAssertTrue(requests.isEmpty)
    }
    func testReplyPortableRoundTripRetainsIdentityAndFreezesExecution() async throws {
        let s=try await store(),input=try await input(s),id=try await s.performConversationReply(input,using:DiscussionFixture())
        let package=base.appendingPathComponent("package"),target=base.appendingPathComponent("restored")
        try await s.exportPackage(to:package)
        XCTAssertEqual(try VoiceOSStore.packageSummary(at:package).version,19)
        try await VoiceOSStore.restorePackage(from:package,to:target,inspector:DiscussionInspector())
        let r=try await store("restored"),rows=try await r.discussionAttempts(conversationID:input.conversationID)
        XCTAssertEqual(rows[0].id,id);XCTAssertEqual(rows[0].state,"completed");XCTAssertEqual(rows[0].validity,"frozen");XCTAssertEqual(rows[0].parts.count,2)
        let integrity=try await r.integrityCheck();XCTAssertTrue(integrity)
    }
    func testForeignAndDuplicateCitationsAndInvalidRejectedUsageStayRejected() async throws {
        for (index,mode) in [DiscussionFixture.Mode.foreignCitation,.duplicateCitation,.invalidRejectedUsage].enumerated() {
            let s=try await store("invalid\(index)"),input=try await input(s)
            do { _=try await s.performConversationReply(input,using:DiscussionFixture(mode));XCTFail() } catch {}
            let rows=try await s.discussionAttempts(conversationID:input.conversationID)
            XCTAssertEqual(rows[0].state,"rejected");XCTAssertTrue(rows[0].parts.isEmpty)
        }
    }
    func testPriorReplyBudgetOverflowPreventsCallWithoutDroppingHistory() async throws {
        let s=try await store(),first=try await input(s)
        _=try await s.performConversationReply(first,using:DiscussionFixture())
        let source=try await s.recordUserExpression("合成第二轮")
        _=try await s.appendConversationUserSource(conversationID:first.conversationID,sourceID:source,expectedVersion:2)
        let context=try await s.prepareLocalTranscriptContext(sourceIDs:first.historySourceIDs + first.userTurns.map(\.sourceID) + [source])
        let exactTextBudget=context.sources.reduce(0) { $0+$1.text.unicodeScalars.count }
        let second=try await s.prepareConversationInput(id:first.conversationID,expectedVersion:3,destination:.local,scalarBudget:exactTextBudget)
        let port=DiscussionFixture()
        do { _=try await s.performConversationReply(second,using:port);XCTFail() } catch {}
        let calls=await port.requests,rows=try await s.discussionAttempts(conversationID:first.conversationID)
        XCTAssertTrue(calls.isEmpty);XCTAssertEqual(rows.count,1)
    }
    func testCloudPermissionRevocationWhileWaitingRejectsReply() async throws {
        let s=try await store()
        let h=try await s.recordUserExpression("合成授权历史"),u=try await s.recordUserExpression("合成个人追问")
        for source in [h,u] { _=try await s.setSourceLocalOnly(sourceID:source,expectedVersion:1,localOnly:false) }
        let id=try await s.beginConversation(sourceIDs:[h])
        _=try await s.appendConversationUserSource(conversationID:id,sourceID:u,expectedVersion:1)
        let input=try await s.prepareConversationInput(id:id,expectedVersion:2,destination:.cloud)
        let port=DiscussionFixture(destination:.cloud,callback:{ _ in _=try await s.setSourceLocalOnly(sourceID:h,expectedVersion:2,localOnly:true) })
        do { _=try await s.performConversationReply(input,using:port);XCTFail() } catch {}
        let rows=try await s.discussionAttempts(conversationID:id)
        XCTAssertEqual(rows[0].state,"rejected");XCTAssertEqual(rows[0].validity,"frozen");XCTAssertTrue(rows[0].parts.isEmpty)
    }
    func testMigrationRejectsOmittedPriorReplyEvenWithRecomputedHashes() async throws {
        let s=try await store(),first=try await input(s)
        _=try await s.performConversationReply(first,using:DiscussionFixture())
        let source=try await s.recordUserExpression("合成第二轮")
        _=try await s.appendConversationUserSource(conversationID:first.conversationID,sourceID:source,expectedVersion:2)
        let second=try await s.prepareConversationInput(id:first.conversationID,expectedVersion:3,destination:.local)
        let secondID=try await s.performConversationReply(second,using:DiscussionFixture())
        let package=base.appendingPathComponent("tampered"),target=base.appendingPathComponent("invalid-restored")
        try await s.exportPackage(to:package)
        let file=package.appendingPathComponent("discussion_attempts.jsonl")
        let lines=try String(contentsOf:file,encoding:.utf8).split(separator:"\n")
        var content=Data()
        for line in lines {
            var row=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(line.utf8)) as? [String:Any])
            if row["id"] as? String == secondID {
                var snapshot=try XCTUnwrap(JSONSerialization.jsonObject(with:Data((row["snapshot_json"] as! String).utf8)) as? [String:Any])
                snapshot["priorReplies"]=[]
                let json=try JSONSerialization.data(withJSONObject:snapshot,options:[.sortedKeys])
                row["snapshot_json"]=String(decoding:json,as:UTF8.self);row["snapshot_digest"]=VoiceOSStore.relevanceHash(json)
            }
            content.append(try JSONSerialization.data(withJSONObject:row));content.append(10)
        }
        try content.write(to:file)
        let manifest=package.appendingPathComponent("manifest.json")
        var m=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:manifest)) as? [String:Any])
        var files=m["files"] as! [[String:Any]]
        let index=files.firstIndex { $0["path"] as? String == "discussion_attempts.jsonl" }!,hash=try DurableFiles.hash(file)
        files[index]["bytes"]=hash.0;files[index]["sha256"]=hash.1;m["files"]=files
        try JSONSerialization.data(withJSONObject:m).write(to:manifest)
        do { try await VoiceOSStore.restorePackage(from:package,to:target,inspector:DiscussionInspector());XCTFail() } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath:target.path))
    }

}
