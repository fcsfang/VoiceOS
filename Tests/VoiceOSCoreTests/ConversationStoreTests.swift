import XCTest
import Foundation
@testable import VoiceOSCore

private struct ConversationInspector: MediaInspector {
    func inspect(_ url: URL) async throws -> MediaInfo { throw VoiceOSError("synthetic personal text only") }
}
private struct ConversationExternalInspector: MediaInspector {
    func inspect(_ url: URL) async throws -> MediaInfo { MediaInfo(duration:1,kind:"audio") }
}
private struct ConversationExternalSpeech: SpeechPort {
    func transcribe(_ url:URL,locale:String) async throws -> SpeechText { SpeechText(text:"合成节目观点，不属于用户表达。") }
}
final class ConversationStoreTests: XCTestCase {
    var base:URL!
    override func setUpWithError() throws { base = FileManager.default.temporaryDirectory.appendingPathComponent("discussion-"+UUID().uuidString) }
    override func tearDownWithError() throws { if FileManager.default.fileExists(atPath:base.path) { try FileManager.default.removeItem(at:base) } }
    func store(_ name:String = "root", checkpoint:@escaping @Sendable (SaveCheckpoint) throws -> Void = {_ in}) async throws -> VoiceOSStore {
        let s = try VoiceOSStore(root:base.appendingPathComponent(name),inspector:ConversationInspector(),checkpoint:checkpoint); try await s.recover(); return s
    }
    func entry(_ s:VoiceOSStore) async throws -> (String,String) {
        let source = try await s.recordUserExpression("合成旧观点：我猜测检索质量取决于对条件的保留，尚未验证。")
        return (try await s.beginConversation(sourceIDs:[source],commandID:"enter"),source)
    }
    func testEntryAndEndAreExplicitIdempotentAndCreateNoClaimsOrTasks() async throws {
        let s = try await store(), (id,source) = try await entry(s)
        let again = try await s.beginConversation(sourceIDs:[source],commandID:"enter"); XCTAssertEqual(id,again)
        let first = try await s.conversation(id:id); XCTAssertEqual(first.state,"active"); XCTAssertEqual(first.version,1)
        try await s.endConversation(id:id,expectedVersion:1,commandID:"end")
        try await s.endConversation(id:id,expectedVersion:1,commandID:"end")
        let ended = try await s.conversation(id:id); XCTAssertEqual(ended.state,"ended"); XCTAssertEqual(ended.version,2)
        let claims = try await s.candidateClaims(), actions = try await s.actions(); XCTAssertTrue(claims.isEmpty); XCTAssertTrue(actions.isEmpty)
        let checked1 = try await s.beginConversation(sourceIDs:[source],commandID:"enter")
        XCTAssertEqual(checked1,id)
    }
    func testTwoPersonalTurnsKeepExactSourceVersionsAndReplayIdentity() async throws {
        let s = try await store(), (id,_) = try await entry(s)
        let one = try await s.recordUserExpression("合成追问：如果容量很大仍丢失限定条件，会有什么反例？")
        let two = try await s.recordUserExpression("合成新表达：我还不能确认原因；先保留这个猜想。")
        let turn = try await s.appendConversationUserSource(conversationID:id,sourceID:one,expectedVersion:1,commandID:"one")
        let checked2 = try await s.appendConversationUserSource(conversationID:id,sourceID:one,expectedVersion:1,commandID:"one")
        XCTAssertEqual(checked2,turn)
        _ = try await s.appendConversationUserSource(conversationID:id,sourceID:two,expectedVersion:2,commandID:"two")
        let turns = try await s.conversationUserTurns(conversationID:id), sources = try await s.sources()
        XCTAssertEqual(turns.map(\.sourceID),[one,two]); XCTAssertEqual(turns.map(\.ordinal),[1,2])
        XCTAssertEqual(turns[0].transcriptVersionID,sources.first { $0.id == one }?.transcriptVersionID)
        XCTAssertTrue(turns[1].text.contains("不能确认"))
        let session = try await s.conversation(id:id); XCTAssertEqual(session.version,3)
    }
    func testStaleVersionDuplicateSourceAndEndedSessionRejectNewTurns() async throws {
        let s = try await store(), (id,_) = try await entry(s)
        let source = try await s.recordUserExpression("合成个人追问")
        do { _ = try await s.appendConversationUserSource(conversationID:id,sourceID:source,expectedVersion:2); XCTFail() } catch {}
        _ = try await s.appendConversationUserSource(conversationID:id,sourceID:source,expectedVersion:1)
        do { _ = try await s.appendConversationUserSource(conversationID:id,sourceID:source,expectedVersion:2); XCTFail() } catch {}
        try await s.endConversation(id:id,expectedVersion:2)
        let fresh = try await s.recordUserExpression("合成另一次追问")
        do { _ = try await s.appendConversationUserSource(conversationID:id,sourceID:fresh,expectedVersion:3); XCTFail() } catch {}
        let checked3 = try await s.conversationUserTurns(conversationID:id).count
        XCTAssertEqual(checked3,1)
    }
    func testEntryCommandCannotChangeSourcesAndTurnCommandCannotChangePayload() async throws {
        let s = try await store(), (id,_) = try await entry(s), other = try await s.recordUserExpression("合成其他原文")
        do { _ = try await s.beginConversation(sourceIDs:[other],commandID:"enter"); XCTFail() } catch {}
        _ = try await s.appendConversationUserSource(conversationID:id,sourceID:other,expectedVersion:1,commandID:"turn")
        let changed = try await s.recordUserExpression("合成新原文")
        do { _ = try await s.appendConversationUserSource(conversationID:id,sourceID:changed,expectedVersion:1,commandID:"turn"); XCTFail() } catch {}
        do { try await s.endConversation(id:id,expectedVersion:1); XCTFail() } catch {}
    }
    func testCorrectedHistoricalInputFreezesSessionButAllowsExplicitClose() async throws {
        let s = try await store(), (id,source) = try await entry(s)
        let original = try await s.sources().first { $0.id == source }!
        _ = try await s.correctTranscript(sourceID:source,expectedVersionID:original.transcriptVersionID!,text:"合成纠错：原先的关键词识别错误。")
        let frozen = try await s.conversation(id:id); XCTAssertEqual(frozen.validity,"frozen")
        let next = try await s.recordUserExpression("合成追问")
        do { _ = try await s.appendConversationUserSource(conversationID:id,sourceID:next,expectedVersion:1); XCTFail() } catch {}
        try await s.endConversation(id:id,expectedVersion:1)
        let newID = try await s.beginConversation(sourceIDs:[source]); XCTAssertNotEqual(newID,id)
        let checked4 = try await s.conversation(id:newID).validity
        XCTAssertEqual(checked4,"current")
    }
    func testTurnCorrectionPreservesHistoricalTextAndPolicyChangeFreezes() async throws {
        let s = try await store(), (id,_) = try await entry(s)
        let source = try await s.recordUserExpression("合成原发言：没有决定采取行动。")
        _ = try await s.appendConversationUserSource(conversationID:id,sourceID:source,expectedVersion:1)
        let version = try await s.conversationUserTurns(conversationID:id)[0].transcriptVersionID
        _ = try await s.correctTranscript(sourceID:source,expectedVersionID:version,text:"合成更正：没有决定读论文。")
        let turns = try await s.conversationUserTurns(conversationID:id); XCTAssertEqual(turns[0].text,"合成原发言：没有决定采取行动。")
        let checked5 = try await s.conversation(id:id).validity
        XCTAssertEqual(checked5,"frozen")
        let fresh = try await s.beginConversation(sourceIDs:[source])
        _ = try await s.setSourceLocalOnly(sourceID:source,expectedVersion:1,localOnly:false)
        let checked6 = try await s.conversation(id:fresh).validity
        XCTAssertEqual(checked6,"frozen")
    }
    func testRestartPreservesEndedSessionAndExactUserHistory() async throws {
        var id:String!
        do {
            let s = try await store(); (id,_) = try await entry(s)
            let source = try await s.recordUserExpression("合成持久发言")
            _ = try await s.appendConversationUserSource(conversationID:id,sourceID:source,expectedVersion:1)
            try await s.endConversation(id:id,expectedVersion:2)
        }
        let s = try await store(), session = try await s.conversation(id:id); XCTAssertEqual(session.state,"ended")
        let checked7 = try await s.conversationUserTurns(conversationID:id)[0].text
        XCTAssertEqual(checked7,"合成持久发言")
        let checked8 = try await s.integrityCheck()
        XCTAssertTrue(checked8)
    }
    func testPortableHistoryRestoresFrozenAndDoesNotReactivateOldEntryCommand() async throws {
        let s = try await store(), (id,entrySource) = try await entry(s)
        let source = try await s.recordUserExpression("合成迁移发言")
        _ = try await s.appendConversationUserSource(conversationID:id,sourceID:source,expectedVersion:1)
        let package = base.appendingPathComponent("package"), target = base.appendingPathComponent("restored")
        try await s.exportPackage(to:package)
        XCTAssertEqual(try VoiceOSStore.packageSummary(at:package).version,19)
        try await VoiceOSStore.restorePackage(from:package,to:target,inspector:ConversationInspector())
        let r = try await store("restored"), session = try await r.conversation(id:id)
        XCTAssertEqual(session.validity,"frozen"); XCTAssertEqual(session.version,2)
        let checked9 = try await r.conversationUserTurns(conversationID:id)[0].sourceID
        XCTAssertEqual(checked9,source)
        let checked10 = try await r.beginConversation(sourceIDs:[entrySource],commandID:"enter")
        XCTAssertEqual(checked10,id)
        do { _ = try await r.appendConversationUserSource(conversationID:id,sourceID:entrySource,expectedVersion:2); XCTFail() } catch {}
        let fresh = try await r.beginConversation(sourceIDs:[entrySource]); XCTAssertNotEqual(fresh,id)
    }
    func testExternalHistoryMayBeDiscussedButCannotBecomePersonalTurn() async throws {
        let s = try VoiceOSStore(root:base.appendingPathComponent("external"),inspector:ConversationExternalInspector())
        try await s.recover()
        let input = base.appendingPathComponent("synthetic.wav"); try Data("synthetic unit-test bytes".utf8).write(to:input)
        let source = try await s.importFile(input); try await s.processTranscriptions(using:ConversationExternalSpeech())
        let id = try await s.beginConversation(sourceIDs:[source])
        do { _ = try await s.appendConversationUserSource(conversationID:id,sourceID:source,expectedVersion:1); XCTFail() } catch {}
        let turns = try await s.conversationUserTurns(conversationID:id); XCTAssertTrue(turns.isEmpty)
        let session = try await s.conversation(id:id); XCTAssertEqual(session.version,1)
    }
    func testTransactionFailuresLeaveOnlyCommittedStateAndAllowCommandReplay() async throws {
        for point in [SaveCheckpoint.conversationUncommitted,.conversationCommitted,.conversationTurnUncommitted,.conversationTurnCommitted,.conversationEndUncommitted,.conversationEndCommitted] {
            let name = point.rawValue
            do {
                let s = try await store(name,checkpoint: { if $0 == point { throw VoiceOSError("injected local failure") } })
                let source = try await s.recordUserExpression("合成讨论历史",commandID:"history")
                do {
                    let id = try await s.beginConversation(sourceIDs:[source],commandID:"entry")
                    let turnSource = try await s.recordUserExpression("合成讨论发言",commandID:"turn-source")
                    _ = try await s.appendConversationUserSource(conversationID:id,sourceID:turnSource,expectedVersion:1,commandID:"turn")
                    try await s.endConversation(id:id,expectedVersion:2,commandID:"end")
                    XCTFail("checkpoint not reached")
                } catch {}
            }
            let r = try await store(name), source = try await r.recordUserExpression("合成讨论历史",commandID:"history")
            let id = try await r.beginConversation(sourceIDs:[source],commandID:"entry")
            let turnSource = try await r.recordUserExpression("合成讨论发言",commandID:"turn-source")
            _ = try await r.appendConversationUserSource(conversationID:id,sourceID:turnSource,expectedVersion:1,commandID:"turn")
            try await r.endConversation(id:id,expectedVersion:2,commandID:"end")
            let session = try await r.conversation(id:id), turns = try await r.conversationUserTurns(conversationID:id)
            XCTAssertEqual(session.state,"ended"); XCTAssertEqual(session.version,3); XCTAssertEqual(turns.count,1)
            let valid = try await r.integrityCheck(); XCTAssertTrue(valid)
        }
    }
    func testMigrationRejectsTurnForgeryAfterRecomputedPackageHash() async throws {
        let s = try await store(), (id,history) = try await entry(s)
        let source = try await s.recordUserExpression("合成待迁移发言")
        _ = try await s.appendConversationUserSource(conversationID:id,sourceID:source,expectedVersion:1)
        let package = base.appendingPathComponent("tampered"), target = base.appendingPathComponent("bad")
        try await s.exportPackage(to:package)
        let file = package.appendingPathComponent("conversation_user_turns.jsonl")
        var row = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:Any]); row["source_id"] = history
        var content = try JSONSerialization.data(withJSONObject:row); content.append(10); try content.write(to:file)
        let manifest = package.appendingPathComponent("manifest.json")
        var m = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:manifest)) as? [String:Any])
        var files = m["files"] as! [[String:Any]], entry = files.firstIndex { $0["path"] as? String == "conversation_user_turns.jsonl" }!
        let hash = try DurableFiles.hash(file); files[entry]["bytes"] = hash.0; files[entry]["sha256"] = hash.1; m["files"] = files
        try JSONSerialization.data(withJSONObject:m).write(to:manifest)
        do { try await VoiceOSStore.restorePackage(from:package,to:target,inspector:ConversationInspector()); XCTFail() } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath:target.path))
    }
    func testCloudInputRequiresEveryHistoricalAndPersonalSourceGrant() async throws {
        let s = try await store(), (id,history) = try await entry(s)
        let source = try await s.recordUserExpression("合成个人追问")
        _ = try await s.appendConversationUserSource(conversationID:id,sourceID:source,expectedVersion:1)
        do { _ = try await s.prepareConversationInput(id:id,expectedVersion:2,destination:.cloud); XCTFail() } catch {}
        _ = try await s.setSourceLocalOnly(sourceID:history,expectedVersion:1,localOnly:false)
        // Changing the entry policy froze the old session: granting access cannot revive it.
        let fresh = try await s.beginConversation(sourceIDs:[history])
        _ = try await s.appendConversationUserSource(conversationID:fresh,sourceID:source,expectedVersion:1)
        do { _ = try await s.prepareConversationInput(id:fresh,expectedVersion:2,destination:.cloud); XCTFail() } catch {}
        _ = try await s.setSourceLocalOnly(sourceID:source,expectedVersion:1,localOnly:false)
        let granted = try await s.beginConversation(sourceIDs:[history])
        _ = try await s.appendConversationUserSource(conversationID:granted,sourceID:source,expectedVersion:1)
        let input = try await s.prepareConversationInput(id:granted,expectedVersion:2,destination:.cloud)
        let snapshot = try await s.validateConversationInput(input)
        XCTAssertEqual(snapshot.sources.map(\.sourceID),[history,source]); XCTAssertFalse(snapshot.sources.contains(where:\.localOnly))
        let actions = try await s.actions(); XCTAssertTrue(actions.isEmpty)
    }
    func testConversationInputRejectsBudgetOverflowWithoutDroppingEarlyHistory() async throws {
        let s = try await store(), (id,_) = try await entry(s), source = try await s.recordUserExpression("合成讨论发言")
        _ = try await s.appendConversationUserSource(conversationID:id,sourceID:source,expectedVersion:1)
        do { _ = try await s.prepareConversationInput(id:id,expectedVersion:2,destination:.local,scalarBudget:4); XCTFail() } catch {}
        let input = try await s.prepareConversationInput(id:id,expectedVersion:2,destination:.local)
        let snapshot = try await s.validateConversationInput(input); XCTAssertEqual(snapshot.sources.count,2)
        XCTAssertEqual(input.historySourceIDs.count,1); XCTAssertEqual(input.userTurns.count,1)
    }
    func testNewTurnAndExplicitEndBlockPreparedInput() async throws {
        let s = try await store(), (id,_) = try await entry(s), first = try await s.recordUserExpression("合成第一轮")
        _ = try await s.appendConversationUserSource(conversationID:id,sourceID:first,expectedVersion:1)
        let old = try await s.prepareConversationInput(id:id,expectedVersion:2,destination:.local)
        let next = try await s.recordUserExpression("合成第二轮")
        _ = try await s.appendConversationUserSource(conversationID:id,sourceID:next,expectedVersion:2)
        do { _ = try await s.validateConversationInput(old); XCTFail() } catch {}
        let current = try await s.prepareConversationInput(id:id,expectedVersion:3,destination:.local)
        let snapshot = try await s.validateConversationInput(current); XCTAssertEqual(snapshot.sources.count,3)
        try await s.endConversation(id:id,expectedVersion:3)
        do { _ = try await s.validateConversationInput(current); XCTFail() } catch {}
    }
    func testAnyPreparedHistoryCorrectionInvalidatesEntireInput() async throws {
        let s = try await store(), (id,history) = try await entry(s), source = try await s.recordUserExpression("合成追问")
        _ = try await s.appendConversationUserSource(conversationID:id,sourceID:source,expectedVersion:1)
        let input = try await s.prepareConversationInput(id:id,expectedVersion:2,destination:.local)
        let snapshot = try await s.validateConversationInput(input), version = snapshot.sources.first { $0.sourceID == history }!.transcriptVersionID
        _ = try await s.correctTranscript(sourceID:history,expectedVersionID:version,text:"合成纠错后的历史")
        do { _ = try await s.validateConversationInput(input); XCTFail() } catch {}
    }
}
