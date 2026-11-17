import XCTest
@testable import VoiceOSCore
import VoiceOSPlatform

private actor SlicingTopicPort: TopicOrganizationPort {
    private let failMarker: String?
    private var failOnce: Bool
    private(set) var skeletonCalls = 0
    private(set) var bodyBatches: [[String]] = []
    private(set) var skeletonInputs: [TopicSkeletonInput] = []
    init(failMarker: String? = nil) { self.failMarker = failMarker; self.failOnce = failMarker != nil }
    func organizeSkeleton(_ input: TopicSkeletonInput) async throws -> TopicSkeletonResult {
        skeletonCalls += 1
        skeletonInputs.append(input)
        let topics = input.viewpoints.enumerated().map { index, viewpoint in
            TopicSkeletonTopic(topicID: "", title: "主题 \(index)", summary: "这份材料提出了一个待接续的观点。",
                               questions: [], viewpointIDs: [viewpoint.id])
        }
        return .init(briefing: "已按观点建立主题骨架，正文随后分批补齐。",
                     highlightSourceIDs: input.viewpoints.first.map { [$0.sourceID] } ?? [],
                     topics: topics, responseID: "slicing-skeleton-\(skeletonCalls)")
    }
    func organizeBody(_ input: TopicBodyInput) async throws -> TopicBodyResult {
        bodyBatches.append(input.topics.map(\.topicID))
        if let marker = failMarker, failOnce, input.topics.contains(where: { $0.title == marker }) {
            failOnce = false
            throw VoiceOSError("合成正文失败：这一批超时")
        }
        return .init(topics: input.topics.map { topic in
            .init(topicID: topic.topicID, questions: [],
                  sections: [.init(id: "section", title: topic.title, summary: "正文已补齐。",
                                   claimIDs: topic.viewpoints.map(\.id), actionIDs: topic.tasks.map(\.id),
                                   evidence: topic.quotes.prefix(1).map { .init(sourceID: $0.sourceID, quote: $0.quote) })])
        }, responseID: "slicing-body-\(bodyBatches.count)")
    }
}

private final class TopicRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var skeleton: [Int] = [], body: [Int] = [], count = 0
    func recordSkeleton(_ bytes: Int) -> String {
        lock.lock(); defer { lock.unlock() }
        skeleton.append(bytes); count += 1; return "recording-skeleton-\(count)"
    }
    func recordBody(_ bytes: Int) -> String {
        lock.lock(); defer { lock.unlock() }
        body.append(bytes); count += 1; return "recording-body-\(count)"
    }
    func sizes() -> (skeleton: [Int], body: [Int]) {
        lock.lock(); defer { lock.unlock() }
        return (skeleton, body)
    }
}

/// Answers the real Responses port from the request it receives, so body size
/// assertions measure the exact payload the port would send.
private struct RecordingTopicTransport: ModelHTTPTransport {
    let recorder: TopicRequestRecorder
    func send(_ request: URLRequest) async throws -> ModelHTTPReply {
        guard let payload = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any],
              let content = (payload["input"] as? [[String: Any]])?.first?["content"] as? String,
              let contentData = content.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: contentData) as? [String: Any] else {
            return ModelHTTPReply(status: 400, body: Data())
        }
        let text: String, id: String
        if let viewpoints = object["viewpoints"] as? [[String: Any]] {
            id = recorder.recordSkeleton(request.httpBody?.count ?? 0)
            let topics: [[String: Any]] = viewpoints.enumerated().map { index, viewpoint in
                ["topicID": "", "title": "主题 \(index)", "summary": "这份材料提出了一个待接续的观点。",
                 "questions": [String](), "viewpointIDs": [viewpoint["id"] as? String ?? ""]]
            }
            let result: [String: Any] = ["briefing": "已按观点建立主题骨架，正文随后分批补齐。",
                                         "highlightSourceIDs": [String](), "topics": topics]
            text = String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)
        } else if let topics = object["topics"] as? [[String: Any]] {
            id = recorder.recordBody(request.httpBody?.count ?? 0)
            let answered: [[String: Any]] = topics.map { topic -> [String: Any] in
                let viewpoints = topic["viewpoints"] as? [[String: Any]] ?? []
                let tasks = topic["tasks"] as? [[String: Any]] ?? []
                let quotes = topic["quotes"] as? [[String: Any]] ?? []
                let evidence: [[String: Any]] = quotes.map { ["sourceID": $0["sourceID"] as? String ?? "", "quote": $0["quote"] as? String ?? ""] }
                let section: [String: Any] = ["id": "section", "title": topic["title"] as? String ?? "主题",
                                              "summary": "正文已补齐。",
                                              "claimIDs": viewpoints.compactMap { $0["id"] as? String },
                                              "actionIDs": tasks.compactMap { $0["id"] as? String },
                                              "evidence": evidence]
                return ["topicID": topic["topicID"] as? String ?? "", "questions": [String](), "sections": [section]]
            }
            text = String(decoding: try JSONSerialization.data(withJSONObject: ["topics": answered]), as: UTF8.self)
        } else {
            return ModelHTTPReply(status: 400, body: Data())
        }
        let envelope: [String: Any] = ["status": "completed", "id": id,
            "output": [["type": "message", "role": "assistant", "status": "completed",
                        "content": [["type": "output_text", "text": text]]]]]
        return ModelHTTPReply(status: 200, body: try JSONSerialization.data(withJSONObject: envelope))
    }
}

final class TopicOrganizationSlicingChecks: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-topic-slicing-" + UUID().uuidString)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func openStore() async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }

    @discardableResult
    private func seed(_ store: VoiceOSStore, _ text: String, index: Int) async throws -> String {
        let sourceID = try await store.recordUserExpression(text, commandID: "slicing-source-\(index)")
        _ = try await store.setSourceLocalOnly(sourceID: sourceID, expectedVersion: 1, localOnly: false)
        let context = try await store.prepareLocalTranscriptContext(sourceIDs: [sourceID])
        let item = try XCTUnwrap(context.sources.first)
        _ = try await store.importOrganizedClaims(context: context, proposals: [
            .init(statement: text, ownership: .userTentative,
                  references: [.init(sourceID: sourceID, transcriptVersionID: item.transcriptVersionID, spanID: item.spans[0].id)])
        ], commandID: "slicing-claims-\(index)")
        return sourceID
    }

    private func seedFifteen(_ store: VoiceOSStore, length: Int = 6) async throws {
        for index in 0..<15 {
            let body = String(repeating: "材料\(index)表达了关于任务边界与验证的观点。", count: length)
            try await seed(store, body, index: index)
        }
    }

    func testSkeletonLandsFirstThenBodiesResumeWithoutRepeatingCompletedBatches() async throws {
        let store = try await openStore()
        try await seedFifteen(store)
        let failing = SlicingTopicPort(failMarker: "主题 3")
        do {
            _ = try await store.organizeTopics(using: failing)
            XCTFail("有批次失败时不能报告整次成功")
        } catch let incomplete as TopicOrganizationIncomplete {
            XCTAssertGreaterThanOrEqual(incomplete.topicCount, 1)
            XCTAssertLessThan(incomplete.topicCount, 15, "单批失败只影响该批主题")
            XCTAssertTrue(incomplete.localizedDescription.contains("个主题待补齐"), incomplete.localizedDescription)
        }
        let afterSkeleton = try await store.reflectionQuestions()
        XCTAssertEqual(afterSkeleton.count, 15, "骨架完成即写入全部主题")
        let pending = afterSkeleton.filter { $0.organization?.bodyPending == true }
        let completed = afterSkeleton.filter { $0.organization?.bodyPending != true }
        XCTAssertEqual(pending.count + completed.count, 15)
        XCTAssertGreaterThan(completed.count, 0, "其余批次继续完成")
        XCTAssertGreaterThan(pending.count, 0)
        let briefing = try await store.workspaceBriefing()
        XCTAssertNotNil(briefing, "骨架完成即留下简报")
        let firstSkeletonCalls = await failing.skeletonCalls
        XCTAssertEqual(firstSkeletonCalls, 1)
        let firstBatches = await failing.bodyBatches
        XCTAssertEqual(firstBatches.count, 3, "15 个主题按 5 个一批分成 3 批")
        let pendingIDs = Set(pending.map(\.id))

        let resumed = SlicingTopicPort()
        let organized = try await store.organizeTopics(using: resumed)
        XCTAssertTrue(organized)
        let resumedSkeletons = await resumed.skeletonCalls
        XCTAssertEqual(resumedSkeletons, 0, "同一摘要复用骨架，不重复调用")
        let resumedBatches = await resumed.bodyBatches
        XCTAssertEqual(resumedBatches.count, 1, "只补未完成批次")
        XCTAssertEqual(Set(resumedBatches[0]), pendingIDs)
        let repaired = try await store.reflectionQuestions()
        XCTAssertFalse(repaired.contains { $0.organization?.bodyPending == true })
        XCTAssertTrue(repaired.allSatisfy { $0.organization?.sections?.isEmpty == false })
        let refreshAfterRepair = try await store.needsTopicOrganizationRefresh()
        XCTAssertFalse(refreshAfterRepair)

        let repeated = try await store.organizeTopics(using: resumed)
        XCTAssertFalse(repeated, "同一摘要完成后再组织不发起调用")
        let finalCalls = await resumed.bodyBatches
        XCTAssertEqual(finalCalls.count, 1)
    }

    func testRequestBodiesStayWithinSlicedBudgets() async throws {
        let store = try await openStore()
        try await seedFifteen(store, length: 12)
        let recorder = TopicRequestRecorder()
        let port = try ResponsesTopicOrganizationPort(baseURL: URL(string: "https://api.openai.com/v1")!,
                                                      apiKey: "fixture", model: "fixture-model",
                                                      transport: RecordingTopicTransport(recorder: recorder))
        _ = try await store.organizeTopics(using: port)
        let sizes = recorder.sizes()
        print("topic-skeleton request bytes: \(sizes.skeleton)")
        print("topic-body request bytes: \(sizes.body)")
        XCTAssertEqual(sizes.skeleton.count, 1)
        XCTAssertEqual(sizes.body.count, 3, "15 个主题按 5 个一批分成 3 批")
        for skeleton in sizes.skeleton {
            XCTAssertLessThan(skeleton, TopicOrganizationSlicePolicy.skeletonByteLimit, "骨架请求体实测 \(skeleton) 字节")
        }
        for body in sizes.body {
            XCTAssertLessThan(body, TopicOrganizationSlicePolicy.bodyByteLimit, "正文请求体实测 \(body) 字节")
        }
        let questions = try await store.reflectionQuestions()
        XCTAssertTrue(questions.allSatisfy { $0.organization?.sections?.isEmpty == false })
    }

    func testStageTableMigrationFromSixtyEightIsIdempotent() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("voiceos.sqlite")
        do {
            let db = try Database(url)
            XCTAssertEqual(try db.query("PRAGMA user_version").first?["user_version"], TestSchema.currentVersion)
            XCTAssertEqual(try db.query("SELECT count(*) AS n FROM sqlite_master WHERE type='table' AND name='topic_organization_stages'").first?["n"], "1")
            try db.execute("DROP TABLE topic_organization_stages")
            try db.execute("PRAGMA user_version=68")
        }
        do {
            let migrated = try Database(url)
            XCTAssertEqual(try migrated.query("PRAGMA user_version").first?["user_version"], "69")
            XCTAssertEqual(try migrated.query("SELECT count(*) AS n FROM sqlite_master WHERE type='table' AND name='topic_organization_stages'").first?["n"], "1")
            try migrated.execute("PRAGMA user_version=68")
        }
        let retried = try Database(url)
        XCTAssertEqual(try retried.query("PRAGMA user_version").first?["user_version"], "69")
        XCTAssertEqual(try retried.query("SELECT count(*) AS n FROM sqlite_master WHERE type='table' AND name='topic_organization_stages'").first?["n"], "1")
    }
}
