import XCTest
@testable import VoiceOSCore
import VoiceOSPlatform

final class ContextValidationMemoChecks: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-context-memo-" + UUID().uuidString)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func openStore() async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }

    private func allowCloud(_ store: VoiceOSStore, _ sourceID: String) async throws {
        _ = try await store.setSourceLocalOnly(sourceID: sourceID, expectedVersion: 1, localOnly: false)
    }

    @discardableResult
    private func seedTask(_ store: VoiceOSStore, text: String, title: String, sharedSourceID: String? = nil) async throws -> String {
        let sourceID = try await store.recordUserExpression(text)
        try await allowCloud(store, sourceID)
        let context = try await store.prepareLocalTranscriptContext(sourceIDs: [sourceID, sharedSourceID].compactMap { $0 })
        let item = try XCTUnwrap(context.sources.first { $0.sourceID == sourceID })
        _ = try await store.importOrganizedClaims(context: context, proposals: [
            .init(statement: text, ownership: .userTentative,
                  references: [.init(sourceID: sourceID, transcriptVersionID: item.transcriptVersionID, spanID: item.spans[0].id)],
                  action: .init(title: title, kind: .task, quote: text))
        ], commandID: "context-memo-" + sourceID)
        return sourceID
    }

    func testRepeatedSnapshotsValidateEachContextOnceUntilWrite() async throws {
        let store = try await openStore()
        let originalSourceID = try await seedTask(store, text: "第一份整理材料。", title: "整理一")
        try await seedTask(store, text: "第二份整理材料。", title: "整理二")
        try await seedTask(store, text: "引用第一份材料。", title: "再次整理", sharedSourceID: originalSourceID)

        let first = try await store.workspaceSnapshot(.full)
        let firstBytes = await store.contextSnapshotDecodeBytes
        let firstPasses = await store.contextValidationPasses
        XCTAssertGreaterThan(firstBytes, 0, "第一轮应解码上下文快照")
        XCTAssertGreaterThan(firstPasses, 0, "第一轮应执行上下文校验")

        let repeated = try await store.workspaceSnapshot(.full)
        let repeatBytes = await store.contextSnapshotDecodeBytes
        let repeatPasses = await store.contextValidationPasses
        XCTAssertEqual(repeatBytes - firstBytes, 0, "未变化时重复刷新不应再次解码上下文快照")
        XCTAssertEqual(repeatPasses - firstPasses, 0, "未变化时重复刷新不应再次校验上下文")
        XCTAssertEqual(Set(repeated.claims.map(\.id)), Set(first.claims.map(\.id)), "记忆化不应改变快照内容")

        await store.resetContextValidationMemo()
        _ = try await store.workspaceSnapshot(.full)
        let uncachedBytes = await store.contextSnapshotDecodeBytes
        XCTAssertGreaterThan(uncachedBytes - firstBytes, 0, "清空缓存后应按旧路径重新解码上下文快照")

        _ = try await store.recordUserExpression("第三份材料推动一次外部写入。")
        let beforeWritePasses = await store.contextValidationPasses
        _ = try await store.workspaceSnapshot(.full)
        let afterWritePasses = await store.contextValidationPasses
        XCTAssertGreaterThan(afterWritePasses - beforeWritePasses, 0, "写入后必须重新校验上下文")

        let task = try XCTUnwrap(first.actions.first { $0.title == "整理一" })
        let linked = try XCTUnwrap(first.actions.first { $0.title == "再次整理" })
        let unrelated = try XCTUnwrap(first.actions.first { $0.title == "整理二" })
        let original = try await store.playableURL(sourceID: originalSourceID)
        try Data("外部写入改变了文件".utf8).write(to: original)

        let historical = try await store.action(id: task.id, includeHistory: true)
        let afterChange = try await store.actions(includeHistory: true)
        let current = try await store.action(id: task.id)
        XCTAssertEqual(historical?.validity, "frozen")
        XCTAssertEqual(afterChange.first { $0.id == linked.id }?.validity, "frozen")
        XCTAssertEqual(afterChange.first { $0.id == unrelated.id }?.validity, "current")
        XCTAssertNil(current)

        let staleSource = try await seedTask(store, text: "应用外改动的另一份材料。", title: "另外整理")
        let staleOriginal = try await store.playableURL(sourceID: staleSource)
        try Data("审阅期间变更了另一份原件".utf8).write(to: staleOriginal)
        let frozenBeforeReview = await store.frozenContextCount
        let revision = try await store.reviewClaim(claimID: unrelated.claimID, expectedVersion: unrelated.claimReviewVersion, action: .endorse)
        let frozenAfterReview = await store.frozenContextCount
        XCTAssertGreaterThan(frozenAfterReview, frozenBeforeReview)
        XCTAssertEqual(revision, unrelated.claimReviewVersion + 1)
        let reviewed = try await store.refreshedCandidateClaim(id: unrelated.claimID)
        XCTAssertEqual(reviewed?.reviewState, "endorsed")
        XCTAssertEqual(reviewed?.reviewVersion, revision)
    }
}
