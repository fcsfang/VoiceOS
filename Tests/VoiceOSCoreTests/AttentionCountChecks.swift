import XCTest
@testable import VoiceOSCore
import VoiceOSPlatform

final class AttentionCountChecks: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-attention-" + UUID().uuidString)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }
    private func openStore() async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }
    private func report(_ state: MonitorReportState, delivery: String, date: String = "2026-11-18") -> MonitorReport {
        MonitorReport(id: date + "-" + state.rawValue, reportDate: date, state: state, headline: "检查结果",
                      summary: "fixture", sourceStatus: [], itemCount: 0, createdAt: date,
                      deliveredAt: delivery == "delivered" ? date : nil, deliveryState: delivery,
                      deliveryError: delivery == "failed" ? "fixture" : nil, payloadJSON: nil)
    }

    func test重复span的转写疑点只计一次且列表保留首条() async throws {
        let store = try await openStore()
        let sourceID = try await store.recordUserExpression("同一条转写疑点会重复出现在核对结果里。")
        let review = try JSONDecoder().decode(TranscriptionReview.self, from: Data("""
            {"completed":true,"changed":false,"response_id":"synthetic-review","response_ids":["synthetic-review"],"context_review_version":3,"corrections":[],"unresolved_issues":[{"span_id":"span-b","reason":"首次出现"},{"span_id":"span-a","reason":"甲"},{"span_id":"span-b","reason":"重复乙"},{"span_id":"span-b","reason":"重复丙"},{"span_id":"span-a","reason":"甲的重复"}],"scope":"complete_expression_knowledge_and_intent","full_text_independent_passes":1,"review_method":"direct_ai"}
            """.utf8))
        try await store.saveTranscriptionReview(review, sourceID: sourceID)
        let sources = try await store.sources()
        let saved = try XCTUnwrap(sources.first { $0.id == sourceID })
        XCTAssertEqual(saved.unresolvedTranscriptionIssueCount, 2, "同一 span 的重复疑点只应计一次")
        XCTAssertEqual(saved.unresolvedTranscriptionIssues.map(\.span_id), ["span-b", "span-a"],
                       "疑点列表只保留每个 span 的首次出现")
        XCTAssertEqual(saved.unresolvedTranscriptionIssues.first?.reason, "首次出现",
                       "保留首次出现的原因")
    }

    func test未解决的报告打开消息监测页后仍需注意() {
        let unresolved = [report(.failed, delivery: "pending"),
                          report(.incomplete, delivery: "delivered"),
                          report(.complete, delivery: "failed")]
        for report in unresolved {
            XCTAssertTrue(MonitorAttention.needsAttention(report), "\(report.state.rawValue)/\(report.deliveryState) 的报告仍需注意")
            XCTAssertNil(MonitorAttention.seenSignatureWhenOpened(for: report),
                         "未解决的报告不应在打开页面时写入已看签名")
        }
    }

    func test报告解决后打开消息监测页才清除注意力() {
        let failed = report(.failed, delivery: "pending")
        XCTAssertTrue(MonitorAttention.needsAttention(failed), "检查失败的报告需要查看")
        XCTAssertNil(MonitorAttention.seenSignatureWhenOpened(for: failed),
                     "检查失败时打开页面不写已看签名，注意力保持")
        let resolved = report(.complete, delivery: "delivered")
        XCTAssertFalse(MonitorAttention.needsAttention(resolved), "报告解决且投递正常后不再需要查看")
        XCTAssertEqual(MonitorAttention.seenSignatureWhenOpened(for: resolved),
                       MonitorAttention.signature(for: resolved),
                       "报告解决后下一次打开页面写入已看签名")
        XCTAssertFalse(MonitorAttention.needsAttention(resolved), "已看签名写入后注意力保持为假")
    }
}
