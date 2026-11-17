import XCTest
import Foundation
@testable import VoiceOSCore
import VoiceOSPlatform

final class ConversationReplyFailureChecks: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-reply-failure-" + UUID().uuidString)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }
    private func openStore() async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }
    private func preparedInput(_ store: VoiceOSStore) async throws -> PreparedConversationInput {
        let material = try await store.recordUserExpression("讨论材料。")
        let conversation = try await store.beginConversation(sourceIDs: [material])
        let turn = try await store.recordUserExpression("我想重新提问。")
        _ = try await store.appendConversationUserSource(conversationID: conversation, sourceID: turn, expectedVersion: 1)
        return try await store.prepareConversationInput(id: conversation, expectedVersion: 2, destination: .local)
    }
    func testRejectedReplyPersistsReasonForThePanel() async throws {
        let store = try await openStore()
        let input = try await preparedInput(store)
        do { _ = try await store.performConversationReply(input, using: RejectingDiscussion()); XCTFail("拒绝的回复应抛出") } catch {}
        let attempts = try await store.discussionAttempts(conversationID: input.conversationID)
        let attempt = try XCTUnwrap(attempts.first)
        XCTAssertEqual(attempt.state, "rejected")
        XCTAssertEqual(attempt.error, "模型拒绝或格式不符；不自动重发")
        XCTAssertTrue(attempt.parts.isEmpty)
    }
    func testUnknownResultPersistsReason() async throws {
        let store = try await openStore()
        let input = try await preparedInput(store)
        do { _ = try await store.performConversationReply(input, using: TimeoutDiscussion()); XCTFail("未登记的回复应抛出") } catch {}
        let attempts = try await store.discussionAttempts(conversationID: input.conversationID)
        let attempt = try XCTUnwrap(attempts.first)
        XCTAssertEqual(attempt.state, "unknown")
        XCTAssertEqual(attempt.error, "结果未登记；费用未知，不自动重发")
    }
    func testCompletedReplyHasNoFailureReason() async throws {
        let store = try await openStore()
        let input = try await preparedInput(store)
        _ = try await store.performConversationReply(input, using: CompletingDiscussion())
        let attempts = try await store.discussionAttempts(conversationID: input.conversationID)
        let attempt = try XCTUnwrap(attempts.first)
        XCTAssertEqual(attempt.state, "completed")
        XCTAssertNil(attempt.error)
        XCTAssertEqual(attempt.parts.count, 1)
    }
}

private struct RejectingDiscussion: DiscussionModelPort {
    let configuration = ModelConfiguration(provider: "fixture", model: "discussion-rejected", promptVersion: "v1", schemaVersion: "v1", destination: .local)
    func reply(_ request: DiscussionModelRequest) async throws -> DiscussionModelResponse {
        throw ModelPortFailure.rejected("fixture拒绝", inputTokens: 2, outputTokens: 0)
    }
}
private struct TimeoutDiscussion: DiscussionModelPort {
    let configuration = ModelConfiguration(provider: "fixture", model: "discussion-timeout", promptVersion: "v1", schemaVersion: "v1", destination: .local)
    func reply(_ request: DiscussionModelRequest) async throws -> DiscussionModelResponse {
        throw URLError(.timedOut)
    }
}
private struct CompletingDiscussion: DiscussionModelPort {
    let configuration = ModelConfiguration(provider: "fixture", model: "discussion-complete", promptVersion: "v1", schemaVersion: "v1", destination: .local)
    func reply(_ request: DiscussionModelRequest) async throws -> DiscussionModelResponse {
        .init(status: .completed, parts: [.init(kind: .aiSuggestion, text: "合成待核对分析。")])
    }
}
