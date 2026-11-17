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
    private(set) var calls = 0
    func organize(_ input: TopicOrganizationInput) async throws -> TopicOrganizationResult {
        calls += 1
        let sourceIDs = input.context.sources.map(\.sourceID)
        return .init(briefing: "合成简报", highlightSourceIDs: sourceIDs,
                     topics: [.init(topicID: input.topics.first?.id ?? "", title: "合成主题", summary: "合成摘要",
                                    questions: ["接下来验证什么？"], sourceIDs: sourceIDs)],
                     responseID: "hardened-topic-\(calls)")
    }
}

private actor RejectingTopicPort: TopicOrganizationPort {
    func organize(_ input: TopicOrganizationInput) async throws -> TopicOrganizationResult {
        throw ModelPortFailure.rejected("合成拒绝")
    }
}

private actor FailingTopicPort: TopicOrganizationPort {
    func organize(_ input: TopicOrganizationInput) async throws -> TopicOrganizationResult {
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
        let prepared = try await store.prepareTopicOrganization()
        let input = try XCTUnwrap(prepared)
        let port = try ResponsesTopicOrganizationPort(baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: "fixture",
                                                      model: "fixture-model", transport: HangingTopicTransport(), deadline: 0.2)
        let started = Date()
        do {
            _ = try await withTestDeadline(5) { try await port.organize(input) }
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

    func testFailureCooldownBlocksAutomaticRetryForThirtyMinutes() throws {
        let suite = "voiceos-topic-cooldown-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cooldown = TopicOrganizationCooldown(defaults: defaults)
        let failedAt = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertNil(cooldown.waitingMessage(now: failedAt))
        cooldown.recordFailure(reason: "主题整理超过 600 秒仍未完成", at: failedAt)
        XCTAssertEqual(cooldown.waitingMessage(now: failedAt.addingTimeInterval(29 * 60)),
                       "主题整理上次失败（主题整理超过 600 秒仍未完成），30 分钟后自动重试或可手动重试")
        XCTAssertNil(cooldown.waitingMessage(now: failedAt.addingTimeInterval(30 * 60)))
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
