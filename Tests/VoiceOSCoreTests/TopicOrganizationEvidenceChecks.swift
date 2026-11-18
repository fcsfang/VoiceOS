import XCTest
@testable import VoiceOSCore
import VoiceOSPlatform

/// Reflows every comma inside the body quotes into a newline, the drift seen
/// on real material where the model rewrites whitespace it was told to copy.
private actor ReflowingQuotePort: TopicOrganizationPort {
    func organizeSkeleton(_ input: TopicSkeletonInput) async throws -> TopicSkeletonResult {
        .init(briefing: "骨架已建立。", highlightSourceIDs: input.viewpoints.first.map { [$0.sourceID] } ?? [],
              topics: [.init(topicID: "", title: "验证顺序", summary: "先确认范围，再验证结果。",
                             questions: [], viewpointIDs: input.viewpoints.map(\.id))],
              responseID: "reflow-skeleton")
    }
    func organizeSkeletonMerge(_ input: TopicSkeletonMergeInput) async throws -> TopicSkeletonMergeResult {
        mergedSkeletonMerge(input, responseID: "reflow-merge")
    }
    func organizeBody(_ input: TopicBodyInput) async throws -> TopicBodyResult {
        .init(topics: input.topics.map { topic in
            let reflowed = (topic.quotes.first?.quote ?? "").replacingOccurrences(of: "，", with: "，\n")
            return .init(topicID: topic.topicID, questions: [], sections: [
                .init(id: "s", title: topic.title, summary: "正文已补齐。",
                      claimIDs: topic.viewpoints.map(\.id), actionIDs: topic.tasks.map(\.id),
                      evidence: topic.quotes.prefix(1).map { .init(sourceID: $0.sourceID, quote: reflowed) })
            ])
        }, responseID: "reflow-body")
    }
}

final class TopicOrganizationEvidenceChecks: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-topic-evidence-" + UUID().uuidString)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let transcript = ContextTranscript(
        sourceID: "s1", sourceVersionID: "sv1", transcriptVersionID: "tv1", origin: "user",
        speaker: "我", localOnly: false, text: "今天先确认范围，\n再验证结果，最后复盘。", spans: [])

    private func input() -> TopicBodyInput {
        TopicBodyInput(digest: "d", topics: [
            .init(topicID: "t", title: "验证顺序", summary: "先确认范围，再验证结果。", sourceIDs: ["s1"],
                  viewpoints: [.init(id: "v1", statement: "先确认范围，再验证结果。", sourceID: "s1", occurredAt: "")],
                  quotes: [.init(sourceID: "s1", quote: "今天先确认范围，")], tasks: [])
        ])
    }

    private func result(quote: String) -> TopicBodyResult {
        TopicBodyResult(topics: [
            .init(topicID: "t", questions: [], sections: [
                .init(id: "s", title: "顺序", summary: "先确认范围，再验证结果。", claimIDs: ["v1"], actionIDs: [],
                      evidence: [.init(sourceID: "s1", quote: quote)])
            ])
        ], responseID: "r")
    }

    func testExactQuotePassesUnchanged() throws {
        let anchored = try VoiceOSStore.validateTopicBody(result(quote: "今天先确认范围，"), input: input(), sources: [transcript])
        XCTAssertEqual(anchored.topics[0].sections[0].evidence[0].quote, "今天先确认范围，")
        XCTAssertEqual(anchored.responseID, "r")
    }

    func testReflowedWhitespaceAnchorsToTranscriptSlice() throws {
        let anchored = try VoiceOSStore.validateTopicBody(result(quote: "今天先确认范围， 再验证结果"),
                                                         input: input(), sources: [transcript])
        XCTAssertEqual(anchored.topics[0].sections[0].evidence[0].quote, "今天先确认范围，\n再验证结果",
                       "返回的引文取原文切片，保留原文换行")
    }

    func testFabricatedQuoteStillFails() {
        XCTAssertThrowsError(try VoiceOSStore.validateTopicBody(result(quote: "录音里没有这句话"), input: input(), sources: [transcript])) { error in
            XCTAssertTrue(error.localizedDescription.contains("主题正文的引用无法定位到当前完整原文"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("s1"), "错误带上来源便于排查")
        }
    }

    func testRunPersistsTranscriptSliceWhenModelReflowsQuote() async throws {
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await store.recover()
        let sourceID = try await store.recordUserExpression("今天先确认范围，再验证结果，最后复盘。", commandID: "evidence-source")
        _ = try await store.setSourceLocalOnly(sourceID: sourceID, expectedVersion: 1, localOnly: false)
        let context = try await store.prepareLocalTranscriptContext(sourceIDs: [sourceID])
        let item = try XCTUnwrap(context.sources.first)
        _ = try await store.importOrganizedClaims(context: context, proposals: [
            .init(statement: "先确认范围，再验证结果。", ownership: .userTentative,
                  references: [.init(sourceID: sourceID, transcriptVersionID: item.transcriptVersionID, spanID: item.spans[0].id)])
        ], commandID: "evidence-claims")

        let organized = try await store.organizeTopics(using: ReflowingQuotePort())
        XCTAssertTrue(organized)
        let questions = try await store.reflectionQuestions()
        let quote = try XCTUnwrap(questions.first { $0.isAIOrganized == true }?.organization?.sections?.first?.evidence.first?.quote)
        let fresh = try await store.prepareLocalTranscriptContext(sourceIDs: [sourceID])
        let text = try XCTUnwrap(fresh.sources.first?.text)
        XCTAssertTrue(text.contains(quote), "落库引文来自原文")
        XCTAssertFalse(quote.contains("\n"), "模型插入的换行没有留在落库引文里")
        XCTAssertTrue(quote.contains("，再验证"), "原文切片跨过换行位置")
    }
}
