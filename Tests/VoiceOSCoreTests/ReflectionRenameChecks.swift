import XCTest
@testable import VoiceOSCore
import VoiceOSPlatform

private actor RenameTopicPort: TopicOrganizationPort {
    func organizeSkeleton(_ input: TopicSkeletonInput) async throws -> TopicSkeletonResult {
        .init(briefing: "合成简报", highlightSourceIDs: input.viewpoints.map(\.sourceID),
              topics: [.init(topicID: "", title: "合成主题", summary: "合成摘要",
                             questions: ["合成问题"], viewpointIDs: input.viewpoints.map(\.id))],
              responseID: "rename-skeleton")
    }
    func organizeBody(_ input: TopicBodyInput) async throws -> TopicBodyResult {
        .init(topics: input.topics.map { topic in
            .init(topicID: topic.topicID, questions: ["合成问题"],
                  sections: [.init(id: "synthetic", title: "合成小节", summary: "合成正文",
                                   claimIDs: topic.viewpoints.map(\.id), actionIDs: topic.tasks.map(\.id),
                                   evidence: topic.quotes.prefix(1).map { .init(sourceID: $0.sourceID, quote: $0.quote) })])
        }, responseID: "rename-body")
    }
}

final class ReflectionRenameChecks: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-reflection-rename-" + UUID().uuidString)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func openStore() async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }

    func testRenamingTopicKeepsOrganizationAndUpdatesTitle() async throws {
        let store = try await openStore()
        let sourceID = try await store.recordUserExpression("重命名主题时，AI 整理出的摘要与阅读卡片应当保留。")
        _ = try await store.setSourceLocalOnly(sourceID: sourceID, expectedVersion: 1, localOnly: false)
        let context = try await store.prepareLocalTranscriptContext(sourceIDs: [sourceID])
        let item = try XCTUnwrap(context.sources.first)
        _ = try await store.importOrganizedClaims(context: context, proposals: [
            .init(statement: item.text, ownership: .userTentative,
                  references: [.init(sourceID: sourceID, transcriptVersionID: item.transcriptVersionID, spanID: item.spans[0].id)])
        ], commandID: "rename-claims-" + sourceID)
        let organized = try await store.organizeTopics(using: RenameTopicPort())
        XCTAssertTrue(organized)
        let questions = try await store.reflectionQuestions()
        let topic = try XCTUnwrap(questions.first { $0.isAIOrganized == true })
        let organization = try XCTUnwrap(topic.organization)

        try await store.renameReflectionQuestion(id: topic.id, title: "改名后的主题")

        let renamedQuestions = try await store.reflectionQuestions()
        let renamed = try XCTUnwrap(renamedQuestions.first { $0.id == topic.id })
        XCTAssertEqual(renamed.title, "改名后的主题")
        XCTAssertNotEqual(renamed.sourceID, topic.sourceID)
        XCTAssertEqual(renamed.isAIOrganized, false)
        XCTAssertEqual(renamed.organization?.summary, organization.summary)
        XCTAssertEqual(renamed.organization?.questions, organization.questions)
        XCTAssertEqual(renamed.organization?.sourceVersions, organization.sourceVersions)
        XCTAssertEqual(renamed.organization?.policyVersions, organization.policyVersions)
        XCTAssertEqual(renamed.organization?.responseID, organization.responseID)
    }
}
