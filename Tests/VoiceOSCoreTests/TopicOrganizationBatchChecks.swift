import XCTest
@testable import VoiceOSCore
import VoiceOSPlatform

private final class BatchTopicRecorder: @unchecked Sendable {
    struct Call {
        let kind: String
        let bytes: Int
        let timeout: TimeInterval
        let maxOutputTokens: Int
        let content: String
        let viewpointCount: Int
    }
    private let lock = NSLock()
    private var calls: [Call] = []
    func record(_ call: Call) {
        lock.lock(); calls.append(call); lock.unlock()
    }
    func snapshot() -> [Call] {
        lock.lock(); defer { lock.unlock() }
        return calls
    }
}

/// Answers the real Responses topic port from the request it receives: one
/// topic per skeleton batch, one merged topic per identical candidate title,
/// and one section per body topic. It records the exact payload shape so tests
/// measure the requests the port would really send.
private struct BatchTopicTransport: ModelHTTPTransport {
    let recorder: BatchTopicRecorder
    let batchTitle: String
    let truncateSkeleton: Bool
    init(recorder: BatchTopicRecorder, batchTitle: String = "批主题", truncateSkeleton: Bool = false) {
        self.recorder = recorder; self.batchTitle = batchTitle; self.truncateSkeleton = truncateSkeleton
    }
    func send(_ request: URLRequest) async throws -> ModelHTTPReply {
        guard let payload = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any],
              let content = (payload["input"] as? [[String: Any]])?.first?["content"] as? String,
              let object = try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any] else {
            return ModelHTTPReply(status: 400, body: Data())
        }
        let maxTokens = payload["max_output_tokens"] as? Int ?? 0
        if let batches = object["batches"] as? [[String: Any]] {
            let viewpointCount = batches.reduce(0) { $0 + (($1["viewpointIDs"] as? [String])?.count ?? 0) }
            recorder.record(.init(kind: "merge", bytes: request.httpBody?.count ?? 0, timeout: request.timeoutInterval,
                                  maxOutputTokens: maxTokens, content: content, viewpointCount: viewpointCount))
            var topics: [[String: Any]] = []
            var index: [String: Int] = [:]
            for batch in batches {
                for candidate in batch["topics"] as? [[String: Any]] ?? [] {
                    let title = candidate["title"] as? String ?? "主题"
                    let summary = candidate["summary"] as? String ?? "摘要"
                    let key = title + "\u{0}" + summary
                    let ids = candidate["viewpointIDs"] as? [String] ?? []
                    if let existing = index[key] {
                        var union = topics[existing]["viewpointIDs"] as? [String] ?? []
                        union += ids
                        topics[existing]["viewpointIDs"] = union
                    } else {
                        index[key] = topics.count
                        topics.append(["topicID": candidate["topicID"] as? String ?? "", "title": title,
                                       "summary": summary, "questions": [String](), "viewpointIDs": ids])
                    }
                }
            }
            let result: [String: Any] = ["briefing": "已合并 \(batches.count) 批骨架候选，正文随后补齐。", "topics": topics]
            let text = String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)
            return Self.reply(text: text, id: "merge-\(topics.count)")
        }
        if let viewpoints = object["viewpoints"] as? [[String: Any]] {
            let ids = viewpoints.compactMap { $0["id"] as? String }
            recorder.record(.init(kind: "skeleton", bytes: request.httpBody?.count ?? 0, timeout: request.timeoutInterval,
                                  maxOutputTokens: maxTokens, content: content, viewpointCount: ids.count))
            if truncateSkeleton {
                let envelope: [String: Any] = ["status": "incomplete", "id": "truncated",
                    "incomplete_details": ["reason": "max_output_tokens"],
                    "usage": ["output_tokens": maxTokens]]
                return ModelHTTPReply(status: 200, body: try JSONSerialization.data(withJSONObject: envelope))
            }
            let sourceID = viewpoints.first?["sourceID"] as? String ?? ""
            let result: [String: Any] = ["briefing": "本批骨架已建立。",
                "highlightSourceIDs": sourceID.isEmpty ? [String]() : [sourceID],
                "topics": [["topicID": "", "title": batchTitle, "summary": "本批观点归入同一个主题。",
                            "questions": [String](), "viewpointIDs": ids]]]
            let text = String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)
            return Self.reply(text: text, id: "skeleton-\(recorder.snapshot().count)")
        }
        if let topics = object["topics"] as? [[String: Any]] {
            recorder.record(.init(kind: "body", bytes: request.httpBody?.count ?? 0, timeout: request.timeoutInterval,
                                  maxOutputTokens: maxTokens, content: content, viewpointCount: 0))
            let answered: [[String: Any]] = topics.map { topic in
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
            let text = String(decoding: try JSONSerialization.data(withJSONObject: ["topics": answered]), as: UTF8.self)
            return Self.reply(text: text, id: "body-\(recorder.snapshot().count)")
        }
        return ModelHTTPReply(status: 400, body: Data())
    }
    private static func reply(text: String, id: String) -> ModelHTTPReply {
        let envelope: [String: Any] = ["status": "completed", "id": id,
            "output": [["type": "message", "role": "assistant", "status": "completed",
                        "content": [["type": "output_text", "text": text]]]]]
        return ModelHTTPReply(status: 200, body: (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data())
    }
}

/// Interrupts the third skeleton batch by throwing from inside the request,
/// which is how a cancelled run stops mid-skeleton while earlier batches stay.
private actor ResumeBatchPort: TopicOrganizationPort {
    private let interruptCall: Int?
    private(set) var skeletonInputs: [TopicSkeletonInput] = []
    private(set) var mergeCalls = 0
    private(set) var bodyCalls = 0
    init(interruptCall: Int? = nil) { self.interruptCall = interruptCall }
    func organizeSkeleton(_ input: TopicSkeletonInput) async throws -> TopicSkeletonResult {
        skeletonInputs.append(input)
        if let interruptCall, skeletonInputs.count == interruptCall { throw CancellationError() }
        return .init(briefing: "批骨架。", highlightSourceIDs: input.viewpoints.first.map { [$0.sourceID] } ?? [],
                     topics: [.init(topicID: "", title: "批主题", summary: "本批观点归入同一个主题。",
                                    questions: [], viewpointIDs: input.viewpoints.map(\.id))],
                     responseID: "resume-skeleton-\(skeletonInputs.count)")
    }
    func organizeSkeletonMerge(_ input: TopicSkeletonMergeInput) async throws -> TopicSkeletonMergeResult {
        mergeCalls += 1
        return mergedSkeletonMerge(input, responseID: "resume-merge-\(mergeCalls)")
    }
    func organizeBody(_ input: TopicBodyInput) async throws -> TopicBodyResult {
        bodyCalls += 1
        return .init(topics: input.topics.map { topic in
            .init(topicID: topic.topicID, questions: [],
                  sections: [.init(id: "section", title: topic.title, summary: "正文已补齐。",
                                   claimIDs: topic.viewpoints.map(\.id), actionIDs: topic.tasks.map(\.id),
                                   evidence: topic.quotes.prefix(1).map { .init(sourceID: $0.sourceID, quote: $0.quote) })])
        }, responseID: "resume-body-\(bodyCalls)")
    }
}

final class TopicOrganizationBatchChecks: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-topic-batch-" + UUID().uuidString)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func openStore() async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }

    /// One source carrying `count` distinct viewpoints keeps seeding cheap while
    /// feeding the planner through the real store pipeline.
    private func seedViewpoints(_ store: VoiceOSStore, count: Int, prefix: String) async throws {
        let sourceID = try await store.recordUserExpression(String(repeating: "批量归组材料。", count: 20), commandID: prefix)
        _ = try await store.setSourceLocalOnly(sourceID: sourceID, expectedVersion: 1, localOnly: false)
        let context = try await store.prepareLocalTranscriptContext(sourceIDs: [sourceID])
        let item = try XCTUnwrap(context.sources.first)
        let proposals = (0..<count).map { index in
            ClaimProposal(statement: "观点\(index)批次边界。", ownership: .userTentative,
                          references: [.init(sourceID: sourceID, transcriptVersionID: item.transcriptVersionID,
                                             spanID: item.spans[0].id)])
        }
        _ = try await store.importOrganizedClaims(context: context, proposals: proposals, commandID: prefix + "-claims")
    }

    private func port(_ recorder: BatchTopicRecorder, batchTitle: String = "批主题") throws -> ResponsesTopicOrganizationPort {
        try ResponsesTopicOrganizationPort(baseURL: URL(string: "https://api.openai.com/v1")!,
                                           apiKey: "fixture", model: "fixture-model",
                                           transport: BatchTopicTransport(recorder: recorder, batchTitle: batchTitle))
    }

    func testFourHundredEightyViewpointsSplitIntoFourBatchesUnderBudget() async throws {
        let store = try await openStore()
        try await seedViewpoints(store, count: 480, prefix: "batch-480")
        let recorder = BatchTopicRecorder()
        let organized = try await store.organizeTopics(using: try port(recorder))
        XCTAssertTrue(organized)
        let calls = recorder.snapshot()
        let skeleton = calls.filter { $0.kind == "skeleton" }
        XCTAssertEqual(skeleton.count, 4, "480 条观点按 150 条一批切成 4 批")
        XCTAssertEqual(skeleton.map(\.viewpointCount).sorted(), [30, 150, 150, 150])
        for call in skeleton {
            XCTAssertLessThanOrEqual(call.viewpointCount, TopicOrganizationSlicePolicy.skeletonBatchViewpointLimit)
            XCTAssertLessThan(call.bytes, 40 * 1024, "单批骨架请求体实测 \(call.bytes) 字节")
        }
        let merge = calls.filter { $0.kind == "merge" }
        XCTAssertEqual(merge.count, 1, "所有骨架批之后走一次合流")
        let mergeCall = try XCTUnwrap(merge.first)
        XCTAssertLessThan(mergeCall.bytes, 64 * 1024, "合流请求只含 id、标题与摘要，实测 \(mergeCall.bytes) 字节")
        XCTAssertFalse(mergeCall.content.contains("批次边界"), "合流输入不含观点全文")
        let db = await store.db
        let stages = try db.query("SELECT stage,scope FROM topic_organization_stages WHERE stage IN ('skeleton','skeleton-merge')")
        let scopes = stages.filter { $0["stage"] == "skeleton" }.compactMap { $0["scope"] }
        XCTAssertEqual(scopes.count, 4, "每批都落阶段表")
        XCTAssertEqual(scopes.map { $0.split(separator: ",").count }.sorted(), [30, 150, 150, 150])
        XCTAssertEqual(stages.filter { $0["stage"] == "skeleton-merge" }.count, 1)
        let questions = try await store.reflectionQuestions()
        XCTAssertTrue(questions.contains { $0.isAIOrganized == true && $0.organization?.bodyPending != true })
    }

    func testResumeAfterInterruptionOnlyReplaysUnfinishedBatchesAndMerge() async throws {
        let store = try await openStore()
        try await seedViewpoints(store, count: 460, prefix: "batch-resume")
        let interrupted = ResumeBatchPort(interruptCall: 3)
        do {
            _ = try await store.organizeTopics(using: interrupted)
            XCTFail("第三批中断后不能报告成功")
        } catch is CancellationError {
        }
        let firstInputs = await interrupted.skeletonInputs
        XCTAssertEqual(firstInputs.count, 3, "中断发生在第三批请求内")
        let firstMerges = await interrupted.mergeCalls
        XCTAssertEqual(firstMerges, 0)
        let db = await store.db
        let completed = try db.query("SELECT scope FROM topic_organization_stages WHERE stage='skeleton' AND state='completed'")
        XCTAssertEqual(completed.count, 2, "只有前两批完成并落阶段表")

        let resumed = ResumeBatchPort()
        let organized = try await store.organizeTopics(using: resumed)
        XCTAssertTrue(organized)
        let resumedInputs = await resumed.skeletonInputs
        XCTAssertEqual(resumedInputs.count, 2, "重跑只补第三、四批")
        XCTAssertEqual(resumedInputs.map { $0.viewpoints.count }.sorted(), [10, 150])
        let resumedMerges = await resumed.mergeCalls
        XCTAssertEqual(resumedMerges, 1, "所有批完成后只合流一次")
        let questions = try await store.reflectionQuestions()
        XCTAssertEqual(questions.filter { $0.isAIOrganized == true }.count, 1)
        XCTAssertTrue(questions.allSatisfy { $0.organization?.bodyPending != true })
    }

    func testMergeDedupesSameTitleAcrossBatches() async throws {
        let store = try await openStore()
        try await seedViewpoints(store, count: 200, prefix: "batch-dedupe")
        let recorder = BatchTopicRecorder()
        let organized = try await store.organizeTopics(using: try port(recorder, batchTitle: "同名主题"))
        XCTAssertTrue(organized)
        let calls = recorder.snapshot()
        let skeleton = calls.filter { $0.kind == "skeleton" }
        XCTAssertEqual(skeleton.count, 2, "200 条观点切成 150 与 50 两批")
        let merge = calls.filter { $0.kind == "merge" }
        XCTAssertEqual(merge.count, 1)
        let mergeCall = try XCTUnwrap(merge.first)
        XCTAssertTrue(mergeCall.content.contains("同名主题"))
        XCTAssertFalse(mergeCall.content.contains("批次边界"), "合流输入只有 id、标题与摘要，不含观点全文")
        let questions = try await store.reflectionQuestions()
        let topics = questions.filter { $0.isAIOrganized == true }
        XCTAssertEqual(topics.count, 1, "两批的同名主题合并为一个")
        XCTAssertEqual(topics.first?.organization?.claimVersions?.count, 200, "合并后的主题覆盖全部观点")
    }

    func testIncompleteSkeletonResponseIsTruncationNotTimeout() async throws {
        let recorder = BatchTopicRecorder()
        let truncating = try ResponsesTopicOrganizationPort(baseURL: URL(string: "https://api.openai.com/v1")!,
                                                            apiKey: "fixture", model: "fixture-model",
                                                            transport: BatchTopicTransport(recorder: recorder, truncateSkeleton: true))
        let viewpoints = (0..<3).map { TopicSkeletonViewpoint(id: "v\($0)", statement: "观点\($0)", sourceID: "s", occurredAt: "") }
        let input = TopicSkeletonInput(digest: "truncated", topics: [], viewpoints: viewpoints)
        do {
            _ = try await truncating.organizeSkeleton(input)
            XCTFail("截断的骨架输出必须抛出专属错误")
        } catch let error as TopicSkeletonTruncated {
            XCTAssertEqual(error.viewpointCount, 3)
            XCTAssertTrue(error.localizedDescription.contains("单批观点过多，需要更小批次"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("3"), error.localizedDescription)
            XCTAssertFalse(error.localizedDescription.contains("超时"), error.localizedDescription)
        }
    }

    func testRequestParametersSplitSkeletonMergeAndBody() async throws {
        let recorder = BatchTopicRecorder()
        let topicPort = try ResponsesTopicOrganizationPort(baseURL: URL(string: "https://api.openai.com/v1")!,
                                                           apiKey: "fixture", model: "fixture-model",
                                                           transport: BatchTopicTransport(recorder: recorder))
        let viewpoints = (0..<2).map { TopicSkeletonViewpoint(id: "v\($0)", statement: "观点\($0)", sourceID: "s", occurredAt: "") }
        _ = try await topicPort.organizeSkeleton(.init(digest: "skeleton", topics: [], viewpoints: viewpoints))
        _ = try await topicPort.organizeSkeletonMerge(.init(digest: "merge", batches: [
            .init(viewpointIDs: ["v0", "v1"],
                  topics: [.init(topicID: "", title: "主题", summary: "摘要", viewpointIDs: ["v0", "v1"])])
        ]))
        _ = try await topicPort.organizeBody(.init(digest: "body", topics: [
            .init(topicID: "t", title: "主题", summary: "摘要", sourceIDs: ["s"], viewpoints: [viewpoints[0]],
                  quotes: [.init(sourceID: "s", quote: "观点0")], tasks: [])
        ]))
        let calls = recorder.snapshot()
        let skeleton = try XCTUnwrap(calls.first { $0.kind == "skeleton" })
        let merge = try XCTUnwrap(calls.first { $0.kind == "merge" })
        let body = try XCTUnwrap(calls.first { $0.kind == "body" })
        XCTAssertEqual(skeleton.maxOutputTokens, 65536, "骨架批输出上限")
        XCTAssertEqual(merge.maxOutputTokens, 65536, "合流输出上限")
        XCTAssertEqual(body.maxOutputTokens, 16384, "正文批保持原上限")
        XCTAssertEqual(skeleton.timeout, 1800, "骨架批时限")
        XCTAssertEqual(merge.timeout, 1800, "合流时限")
        XCTAssertEqual(body.timeout, 600, "正文批保持原时限")
    }

    func testTransportDeadlineCapParameterKeepsDefaultAtSixHundred() async throws {
        let defaultTransport = DirectStreamingModelHTTPTransport()
        try await assertDeadline(defaultTransport, 601, expected: "模型请求时限无效")
        try await assertDeadline(defaultTransport, 600, expected: "流式模型请求格式无效")
        let topicTransport = DirectStreamingModelHTTPTransport(deadlineCap: 1800)
        try await assertDeadline(topicTransport, 1801, expected: "模型请求时限无效")
        try await assertDeadline(topicTransport, 1800, expected: "流式模型请求格式无效")
    }

    private func assertDeadline(_ transport: any ModelHTTPTransport, _ seconds: TimeInterval, expected: String) async throws {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.timeoutInterval = seconds
        do {
            _ = try await transport.send(request)
            XCTFail("时限 \(seconds) 的请求不应完成")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(expected), "\(seconds) 秒：\(error.localizedDescription)")
        }
    }

    func testStageTableMigrationFromSeventyPreservesRowsAndAcceptsMergeStage() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("voiceos.sqlite")
        do {
            let db = try Database(url)
            XCTAssertEqual(try db.query("PRAGMA user_version").first?["user_version"], TestSchema.currentVersion)
            try db.execute("DROP TABLE topic_organization_stages")
            try db.execute("""
            CREATE TABLE topic_organization_stages(
              digest TEXT NOT NULL,
              stage TEXT NOT NULL CHECK(stage IN ('skeleton','body')),
              scope TEXT NOT NULL,
              state TEXT NOT NULL CHECK(state IN ('running','completed','failed')),
              result_json TEXT,
              error TEXT,
              attempt_id TEXT,
              updated_at TEXT NOT NULL,
              PRIMARY KEY(digest,stage,scope))
            """)
            try db.execute("INSERT INTO topic_organization_stages(digest,stage,scope,state,result_json,error,attempt_id,updated_at) VALUES('kept','skeleton','all','completed','{}',NULL,NULL,'t')")
            try db.execute("PRAGMA user_version=70")
        }
        let migrated = try Database(url)
        XCTAssertEqual(try migrated.query("PRAGMA user_version").first?["user_version"], TestSchema.currentVersion)
        XCTAssertEqual(try migrated.query("SELECT count(*) AS n FROM topic_organization_stages").first?["n"], "1")
        XCTAssertEqual(try migrated.query("SELECT digest FROM topic_organization_stages").first?["digest"], "kept")
        try migrated.execute("INSERT INTO topic_organization_stages(digest,stage,scope,state,result_json,error,attempt_id,updated_at) VALUES('m','skeleton-merge','all','completed','{}',NULL,NULL,'t')")
        XCTAssertEqual(try migrated.query("SELECT count(*) AS n FROM topic_organization_stages WHERE stage='skeleton-merge'").first?["n"], "1")
    }
}
