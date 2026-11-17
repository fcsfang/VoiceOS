import XCTest
@testable import VoiceOSCore
import VoiceOSPlatform

final class ConversationBatchReadChecks: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-conversation-batch-" + UUID().uuidString)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }
    private func openStore() async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }

    func testBatchConversationReadsMatchPerConversationReads() async throws {
        let store = try await openStore()
        let first = try await store.recordUserExpression("第一份讨论材料。")
        let second = try await store.recordUserExpression("第二份讨论材料。")
        let turnSource = try await store.recordUserExpression("讨论中的个人发言。")
        let firstConversation = try await store.beginConversation(sourceIDs: [first])
        _ = try await store.appendConversationUserSource(conversationID: firstConversation, sourceID: turnSource, expectedVersion: 1)
        let secondConversation = try await store.beginConversation(sourceIDs: [second])

        let listed = try await store.conversations()
        XCTAssertEqual(Set(listed.map(\.id)), Set([firstConversation, secondConversation]))
        for record in listed {
            let single = try await store.conversation(id: record.id)
            XCTAssertEqual(record.version, single.version)
            XCTAssertEqual(record.state, single.state)
            XCTAssertEqual(record.validity, single.validity)
            XCTAssertEqual(record.entryContextID, single.entryContextID)
        }

        for sourceID in [first, turnSource] {
            let bySource = try await store.conversationsForSource(sourceID: sourceID)
            XCTAssertEqual(bySource.map(\.id), [firstConversation])
            let single = try await store.conversation(id: firstConversation)
            XCTAssertEqual(bySource.first?.version, single.version)
            XCTAssertEqual(bySource.first?.validity, single.validity)
            XCTAssertEqual(bySource.first?.entryContextID, single.entryContextID)
        }
        let missing = try await store.conversationsForSource(sourceID: "missing-source")
        XCTAssertTrue(missing.isEmpty)

        // A frozen conversation keeps its stored validity through both reads.
        _ = try await store.setSourceLocalOnly(sourceID: second, expectedVersion: 1, localOnly: false)
        _ = try await store.setSourceLocalOnly(sourceID: second, expectedVersion: 2, localOnly: true)
        let afterRevoke = try await store.conversations()
        let frozen = try XCTUnwrap(afterRevoke.first { $0.id == secondConversation })
        let singleFrozen = try await store.conversation(id: secondConversation)
        XCTAssertEqual(frozen.validity, "frozen")
        XCTAssertEqual(frozen.validity, singleFrozen.validity)
        XCTAssertEqual(frozen.version, singleFrozen.version)
        let bySecond = try await store.conversationsForSource(sourceID: second)
        XCTAssertEqual(bySecond.map(\.id), [secondConversation])
        XCTAssertEqual(bySecond.first?.validity, "frozen")
    }
}
