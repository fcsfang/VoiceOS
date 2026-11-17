import XCTest
@testable import VoiceOSCore
import VoiceOSPlatform

private actor StalenessTopicPort: TopicOrganizationPort {
    private var calls = 0
    func count() -> Int { calls }
    func organize(_ input: TopicOrganizationInput) async throws -> TopicOrganizationResult {
        calls += 1
        let sourceIDs = input.context.sources.map(\.sourceID)
        let existingID = input.topics.first?.id ?? ""
        return .init(briefing: "合成简报", highlightSourceIDs: sourceIDs,
                     topics: [.init(topicID: existingID, title: "合成主题", summary: "合成摘要第 \(calls) 版",
                                    questions: ["这份材料接下来要验证什么？"], sourceIDs: sourceIDs)],
                     responseID: "stale-topic-\(calls)")
    }
}

final class TopicOrganizationStalenessChecks: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-topic-staleness-" + UUID().uuidString)
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

    func testStaleTopicKeepsOrganizationForReading() async throws {
        let store = try await openStore()
        let sourceID = try await store.recordUserExpression("主题整理后，原文更正不应清空已经生成的阅读卡片。")
        try await allowCloud(store, sourceID)
        let port = StalenessTopicPort()
        let organized = try await store.organizeTopics(using: port)
        XCTAssertTrue(organized)

        let initialQuestions = try await store.reflectionQuestions()
        let initial = try XCTUnwrap(initialQuestions.first { $0.organization != nil })
        let initialSummary = try XCTUnwrap(initial.organization)
        XCTAssertNotEqual(initial.organizationStale, true)
        let initialRefresh = try await store.needsTopicOrganizationRefresh()
        XCTAssertFalse(initialRefresh)

        let sources = try await store.sources()
        let source = try XCTUnwrap(sources.first { $0.id == sourceID })
        _ = try await store.correctTranscript(sourceID: sourceID, expectedVersionID: try XCTUnwrap(source.transcriptVersionID),
                                              text: "主题整理后，原文更正了措辞，旧卡片与旧摘要仍应保留供阅读。")

        let changedQuestions = try await store.reflectionQuestions()
        let changed = try XCTUnwrap(changedQuestions.first { $0.id == initial.id })
        XCTAssertEqual(changed.organizationStale, true)
        XCTAssertEqual(changed.organization?.summary, initialSummary.summary)
        XCTAssertEqual(changed.organization?.questions, initialSummary.questions)
        XCTAssertEqual(changed.organization?.sourceVersions, initialSummary.sourceVersions)
        let changedRefresh = try await store.needsTopicOrganizationRefresh()
        XCTAssertTrue(changedRefresh)
    }

    func testStaleTopicReorganizesWhenBriefingDigestStillMatches() async throws {
        let store = try await openStore()
        let firstID = try await store.recordUserExpression("第一份材料说明主题需要两份材料。")
        try await allowCloud(store, firstID)
        let secondID = try await store.recordUserExpression("第二份材料补充同一主题的细节。")
        try await allowCloud(store, secondID)
        let port = StalenessTopicPort()
        let organized = try await store.organizeTopics(using: port)
        XCTAssertTrue(organized)

        let initialQuestions = try await store.reflectionQuestions()
        let topic = try XCTUnwrap(initialQuestions.first { $0.organization != nil })
        let linkedIDs = try await store.reflectionQuestionSourceIDs(questionID: topic.id)
        let otherID = try XCTUnwrap(linkedIDs.first { $0 != topic.sourceID })
        try await store.unlinkReflectionQuestionSource(questionID: topic.id, sourceID: otherID)

        let staleQuestions = try await store.reflectionQuestions()
        let stale = try XCTUnwrap(staleQuestions.first { $0.id == topic.id })
        XCTAssertEqual(stale.organizationStale, true)
        XCTAssertNotNil(stale.organization)

        let prepared = try await store.prepareTopicOrganization()
        let input = try XCTUnwrap(prepared)
        let savedBriefing = try await store.workspaceBriefing()
        let briefing = try XCTUnwrap(savedBriefing)
        XCTAssertEqual(briefing.digest, input.digest)
        let staleRefresh = try await store.needsTopicOrganizationRefresh()
        XCTAssertTrue(staleRefresh)

        let reorganized = try await store.organizeTopics(using: port)
        XCTAssertTrue(reorganized, "摘要未变而过期主题必须放行重排")
        let calls = await port.count()
        XCTAssertEqual(calls, 2)

        let repairedQuestions = try await store.reflectionQuestions()
        let repaired = try XCTUnwrap(repairedQuestions.first { $0.id == topic.id })
        XCTAssertEqual(repaired.organizationStale, false)
        XCTAssertEqual(repaired.organization?.sourceVersions.count, 2)
        XCTAssertEqual(repaired.organization?.summary, "合成摘要第 2 版")
        let repairedRefresh = try await store.needsTopicOrganizationRefresh()
        XCTAssertFalse(repairedRefresh)
    }

    func testCurrentTopicKeepsOrganizationAndSkipsReorganization() async throws {
        let store = try await openStore()
        let sourceID = try await store.recordUserExpression("未过期的主题不应重新整理，也不应出现提示。")
        try await allowCloud(store, sourceID)
        let port = StalenessTopicPort()
        let organized = try await store.organizeTopics(using: port)
        XCTAssertTrue(organized)

        let initialQuestions = try await store.reflectionQuestions()
        let initial = try XCTUnwrap(initialQuestions.first { $0.organization != nil })
        let repeated = try await store.organizeTopics(using: port)
        XCTAssertFalse(repeated)
        let calls = await port.count()
        XCTAssertEqual(calls, 1)

        let repeatedQuestions = try await store.reflectionQuestions()
        let repeatedTopic = try XCTUnwrap(repeatedQuestions.first { $0.id == initial.id })
        XCTAssertEqual(repeatedTopic.organizationStale, false)
        XCTAssertEqual(repeatedTopic.organization?.summary, initial.organization?.summary)
        XCTAssertEqual(repeatedTopic.organization?.sourceVersions, initial.organization?.sourceVersions)
        let refresh = try await store.needsTopicOrganizationRefresh()
        XCTAssertFalse(refresh)
    }
}
