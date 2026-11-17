import XCTest
@testable import VoiceOSCore
import VoiceOSPlatform

final class ConversationPreviewChecks: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-conversation-preview-" + UUID().uuidString)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }
    private func openStore() async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }

    func testPreviewCarriesFirstTurnAndTurnCount() async throws {
        let store = try await openStore()
        let emptySource = try await store.recordUserExpression("空会话的材料。")
        let talkSource = try await store.recordUserExpression("多轮会话的材料。")
        let firstTurn = try await store.recordUserExpression("第一轮：这件事我想先存下来。")
        let secondTurn = try await store.recordUserExpression("第二轮：再补一句。")
        let emptyID = try await store.beginConversation(sourceIDs: [emptySource])
        let talkID = try await store.beginConversation(sourceIDs: [talkSource])
        _ = try await store.appendConversationUserSource(conversationID: talkID, sourceID: firstTurn, expectedVersion: 1)
        _ = try await store.appendConversationUserSource(conversationID: talkID, sourceID: secondTurn, expectedVersion: 2)

        let previews = try await store.conversationPreviews()
        let empty = try XCTUnwrap(previews.first { $0.id == emptyID })
        XCTAssertEqual(empty.turnCount, 0)
        XCTAssertEqual(empty.firstTurnExcerpt, "尚未开始")
        XCTAssertEqual(empty.state, "active")
        XCTAssertEqual(empty.validity, "current")
        XCTAssertNotNil(ConversationReflectionFocus.date(empty.createdAt))
        XCTAssertNotNil(ConversationReflectionFocus.date(empty.updatedAt))
        let talk = try XCTUnwrap(previews.first { $0.id == talkID })
        XCTAssertEqual(talk.turnCount, 2)
        XCTAssertEqual(talk.firstTurnExcerpt, "第一轮：这件事我想先存下来。")
        XCTAssertNotNil(ConversationReflectionFocus.date(talk.createdAt))
        XCTAssertNotNil(ConversationReflectionFocus.date(talk.updatedAt))
    }

    func testPreviewExcerptCollapsesWhitespaceAndShortensLongFirstTurn() async throws {
        let store = try await openStore()
        let source = try await store.recordUserExpression("摘录测试材料。")
        let turn = try await store.recordUserExpression("开头\n换行后的内容 " + String(repeating: "一", count: 120))
        let id = try await store.beginConversation(sourceIDs: [source])
        _ = try await store.appendConversationUserSource(conversationID: id, sourceID: turn, expectedVersion: 1)

        let previews = try await store.conversationPreviews()
        let preview = try XCTUnwrap(previews.first { $0.id == id })
        XCTAssertFalse(preview.firstTurnExcerpt.contains("\n"))
        XCTAssertEqual(preview.firstTurnExcerpt.unicodeScalars.count, 81)
        XCTAssertTrue(preview.firstTurnExcerpt.hasSuffix("…"))
    }

    func testPreviewsSortByLatestActivityNotCreation() async throws {
        let store = try await openStore()
        let firstSource = try await store.recordUserExpression("先建立的讨论。")
        let secondSource = try await store.recordUserExpression("后建立的讨论。")
        let turn = try await store.recordUserExpression("稍后补上的第一轮发言。")
        let firstID = try await store.beginConversation(sourceIDs: [firstSource])
        let secondID = try await store.beginConversation(sourceIDs: [secondSource])
        try await Task.sleep(for: .milliseconds(1100))
        _ = try await store.appendConversationUserSource(conversationID: firstID, sourceID: turn, expectedVersion: 1)

        let previews = try await store.conversationPreviews()
        XCTAssertEqual(previews.map(\.id), [firstID, secondID])
        let firstUpdated = try XCTUnwrap(ConversationReflectionFocus.date(previews[0].updatedAt))
        let secondUpdated = try XCTUnwrap(ConversationReflectionFocus.date(previews[1].updatedAt))
        XCTAssertGreaterThan(firstUpdated, secondUpdated)
    }

    func testPreviewStatusFollowsFreezeAndEnd() async throws {
        let store = try await openStore()
        let frozenSource = try await store.recordUserExpression("会被冻结的讨论。")
        let endedSource = try await store.recordUserExpression("会被结束的讨论。")
        let frozenID = try await store.beginConversation(sourceIDs: [frozenSource])
        let endedID = try await store.beginConversation(sourceIDs: [endedSource])
        _ = try await store.setSourceLocalOnly(sourceID: frozenSource, expectedVersion: 1, localOnly: false)
        _ = try await store.setSourceLocalOnly(sourceID: frozenSource, expectedVersion: 2, localOnly: true)
        try await store.endConversation(id: endedID, expectedVersion: 1)

        let previews = try await store.conversationPreviews()
        let frozen = try XCTUnwrap(previews.first { $0.id == frozenID })
        XCTAssertEqual(frozen.state, "active")
        XCTAssertEqual(frozen.validity, "frozen")
        let ended = try XCTUnwrap(previews.first { $0.id == endedID })
        XCTAssertEqual(ended.state, "ended")
        XCTAssertEqual(ended.validity, "current")
        let endedUpdated = try XCTUnwrap(ConversationReflectionFocus.date(ended.updatedAt))
        let endedCreated = try XCTUnwrap(ConversationReflectionFocus.date(ended.createdAt))
        XCTAssertGreaterThanOrEqual(endedUpdated, endedCreated)
    }

    func testPreviewsAreEmptyWithoutConversations() async throws {
        let store = try await openStore()
        XCTAssertTrue(try await store.conversationPreviews().isEmpty)
    }
}
