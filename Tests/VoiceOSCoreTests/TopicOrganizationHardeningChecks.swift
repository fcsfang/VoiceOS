import XCTest
@testable import VoiceOSCore
import VoiceOSPlatform

private struct HangingTopicTransport: ModelHTTPTransport {
    func send(_ request: URLRequest) async throws -> ModelHTTPReply {
        try await Task.sleep(for: .seconds(3600))
        throw VoiceOSError("悬挂传输不应返回")
    }
}

private actor RecordingTopicPort: TopicOrganizationPort {
    private(set) var skeletonCalls = 0, bodyCalls = 0
    func organizeSkeleton(_ input: TopicSkeletonInput) async throws -> TopicSkeletonResult {
        skeletonCalls += 1
        return .init(briefing: "合成简报", highlightSourceIDs: input.viewpoints.map(\.sourceID),
                     topics: [.init(topicID: "", title: "合成主题", summary: "合成摘要",
                                    questions: ["接下来验证什么？"], viewpointIDs: input.viewpoints.map(\.id))],
                     responseID: "hardened-skeleton-\(skeletonCalls)")
    }
    func organizeBody(_ input: TopicBodyInput) async throws -> TopicBodyResult {
        bodyCalls += 1
        return .init(topics: input.topics.map { topic in
            .init(topicID: topic.topicID, questions: ["接下来验证什么？"],
                  sections: [.init(id: "synthetic", title: "合成小节", summary: "合成正文",
                                   claimIDs: topic.viewpoints.map(\.id), actionIDs: topic.tasks.map(\.id),
                                   evidence: topic.quotes.prefix(1).map { .init(sourceID: $0.sourceID, quote: $0.quote) })])
        }, responseID: "hardened-body-\(bodyCalls)")
    }
}

private actor RejectingTopicPort: TopicOrganizationPort {
    func organizeSkeleton(_ input: TopicSkeletonInput) async throws -> TopicSkeletonResult {
        throw ModelPortFailure.rejected("合成拒绝")
    }
    func organizeBody(_ input: TopicBodyInput) async throws -> TopicBodyResult {
        throw ModelPortFailure.rejected("合成拒绝")
    }
}

private actor FailingTopicPort: TopicOrganizationPort {
    func organizeSkeleton(_ input: TopicSkeletonInput) async throws -> TopicSkeletonResult {
        throw VoiceOSError("合成失败：模型不可用")
    }
    func organizeBody(_ input: TopicBodyInput) async throws -> TopicBodyResult {
        throw VoiceOSError("合成失败：模型不可用")
    }
}

final class TopicOrganizationHardeningChecks: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-topic-hardening-" + UUID().uuidString)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func openStore() async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }

    private func cloudSource(_ store: VoiceOSStore, _ text: String) async throws -> String {
        let sourceID = try await store.recordUserExpression(text)
        _ = try await store.setSourceLocalOnly(sourceID: sourceID, expectedVersion: 1, localOnly: false)
        let context = try await store.prepareLocalTranscriptContext(sourceIDs: [sourceID])
        let item = try XCTUnwrap(context.sources.first)
        _ = try await store.importOrganizedClaims(context: context, proposals: [
            .init(statement: text, ownership: .userTentative,
                  references: [.init(sourceID: sourceID, transcriptVersionID: item.transcriptVersionID, spanID: item.spans[0].id)])
        ], commandID: "hardening-claims-" + sourceID)
        return sourceID
    }

    private func latestTopicAttempt(_ store: VoiceOSStore) async throws -> [String: String] {
        let db = await store.db
        return try XCTUnwrap(db.query("SELECT state,error FROM model_attempts WHERE provider LIKE 'topic%' ORDER BY CAST(producer_sequence AS INTEGER) DESC LIMIT 1").first)
    }

    private func withTestDeadline<T: Sendable>(_ seconds: TimeInterval, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask { try await Task.sleep(for: .seconds(seconds)); throw VoiceOSError("测试超时：调用未在限期内返回") }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    func testHangingStreamThrowsAtHardDeadline() async throws {
        let store = try await openStore()
        _ = try await cloudSource(store, "主题整理必须在总时长截止后停止等待悬挂的流。")
        let prepared = try await store.prepareTopicSkeleton()
        let input = try XCTUnwrap(prepared)
        let port = try ResponsesTopicOrganizationPort(baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: "fixture",
                                                      model: "fixture-model", transport: HangingTopicTransport(), deadline: 0.2)
        let started = Date()
        do {
            _ = try await withTestDeadline(5) { try await port.organizeSkeleton(input) }
            XCTFail("悬挂的流式传输必须在截止后抛错")
        } catch let error as ModelDeadlineExceeded {
            XCTAssertTrue(error.errorDescription?.contains("超过") == true, error.localizedDescription)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testSuccessfulRunRecordsCompletedAttempt() async throws {
        let store = try await openStore()
        _ = try await cloudSource(store, "主题整理成功后应留下可观察的完成记录。")
        let organized = try await store.organizeTopics(using: RecordingTopicPort())
        XCTAssertTrue(organized)
        let attempt = try await latestTopicAttempt(store)
        XCTAssertEqual(attempt["state"], "completed")
        XCTAssertNil(attempt["error"])
    }

    func testRejectedRunRecordsRejectedAttempt() async throws {
        let store = try await openStore()
        _ = try await cloudSource(store, "主题整理被拒绝时应留下可见原因。")
        do {
            _ = try await store.organizeTopics(using: RejectingTopicPort())
            XCTFail("被拒绝的结果不能当作成功")
        } catch let error as ModelPortFailure {
            guard case .rejected(let reason, _, _) = error else { XCTFail("应保留拒绝原因"); return }
            XCTAssertEqual(reason, "合成拒绝")
        }
        let attempt = try await latestTopicAttempt(store)
        XCTAssertEqual(attempt["state"], "rejected")
        XCTAssertEqual(attempt["error"], "合成拒绝")
    }

    func testUnknownFailureRecordsUnknownAttemptAndNextRunSucceeds() async throws {
        let store = try await openStore()
        _ = try await cloudSource(store, "主题整理失败后必须能立即重新整理。")
        do {
            _ = try await store.organizeTopics(using: FailingTopicPort())
            XCTFail("失败端口不能返回成功")
        } catch let error as VoiceOSError {
            XCTAssertEqual(error.message, "合成失败：模型不可用")
        }
        let failed = try await latestTopicAttempt(store)
        XCTAssertEqual(failed["state"], "unknown")
        XCTAssertTrue((failed["error"] ?? "").contains("不自动重发"))
        let reorganized = try await store.organizeTopics(using: RecordingTopicPort())
        XCTAssertTrue(reorganized)
        let succeeded = try await latestTopicAttempt(store)
        XCTAssertEqual(succeeded["state"], "completed")
    }

    func testFailureCooldownBlocksAutomaticRetryForSixHours() throws {
        let suite = "voiceos-topic-cooldown-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cooldown = TopicOrganizationCooldown(defaults: defaults)
        let failedAt = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertNil(cooldown.waitingMessage(now: failedAt))
        cooldown.recordFailure(reason: "主题正文整理超过 600 秒仍未完成", at: failedAt)
        XCTAssertEqual(cooldown.waitingMessage(now: failedAt.addingTimeInterval(6 * 3600 - 60)),
                       "主题整理上次失败（主题正文整理超过 600 秒仍未完成），6 小时后自动重试；已完成的主题会保留，可手动补齐")
        XCTAssertNil(cooldown.waitingMessage(now: failedAt.addingTimeInterval(6 * 3600)))
        XCTAssertTrue(cooldown.blocksAutomaticRetry(now: failedAt.addingTimeInterval(60)))
        XCTAssertFalse(cooldown.blocksAutomaticRetry(force: true, now: failedAt.addingTimeInterval(60)), "显式重试不受冷却限制")
    }

    func testSuccessClearsFailureCooldown() throws {
        let suite = "voiceos-topic-cooldown-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cooldown = TopicOrganizationCooldown(defaults: defaults)
        cooldown.recordFailure(reason: "合成失败")
        XCTAssertNotNil(cooldown.waitingMessage())
        cooldown.recordSuccess()
        XCTAssertNil(cooldown.waitingMessage())
        XCTAssertNil(cooldown.lastFailure())
    }
}
