import XCTest
@testable import VoiceOSCore

final class MonitorEvidenceChecks: XCTestCase {
    private func message(_ id: String, kind: MonitorMessageKind, content: String,
                         metaJSON: String? = nil) -> MonitorMessage {
        MonitorMessage(id: "id-" + id, sourceID: "s1", externalID: id, kind: kind, senderName: "同学",
                       sentAt: "2026-11-17T01:00:00Z", collectedAt: "2026-11-17T01:00:00Z",
                       content: content, metaJSON: metaJSON)
    }

    func testAnalysisInputCarriesReplyContextAndTypeMarker() {
        let reply = String(repeating: "奖", count: 90)
        let meta = "{\"chatlab_type\":26,\"replyToMessageId\":\"m0\",\"replyContext\":{\"accountName\":\"班长\",\"content\":\"\(reply)\"}}"
        let input = MessageMonitorRunner.notificationInput(
            for: message("m1", kind: .forward, content: "[合并转发]", metaJSON: meta))
        XCTAssertTrue(input.text.contains("（类型：合并转发）"), "合并转发应附类型占位：\(input.text)")
        XCTAssertTrue(input.text.contains("（回复：" + String(repeating: "奖", count: 80) + "…）"),
                      "引用摘要应截断到 80 字：\(input.text)")
        XCTAssertFalse(input.text.contains(String(repeating: "奖", count: 81)),
                       "引用摘要不应超过 80 字：\(input.text)")
        XCTAssertTrue(input.needsReview, "合并转发仍需用户打开查看")
    }

    func testEvidenceExcerptIsTruncatedAndReplyIsShown() {
        let body = String(repeating: "通", count: 150)
        let meta = "{\"replyContext\":{\"accountName\":\"班长\",\"content\":\"前文通知内容\"}}"
        let records = MonitorEvidenceBuilder.build(
            refs: [.init(sourceID: "s1", externalID: "m1")],
            messagesBySource: ["s1": [message("m1", kind: .text, content: body, metaJSON: meta)]],
            sourceNames: ["s1": "示例班级群"], sourceKinds: ["s1": .qqGroup])
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].kind, .text)
        XCTAssertEqual(records[0].excerpt, String(repeating: "通", count: 120) + "…",
                       "证据正文片段应截断到 120 字")
        XCTAssertEqual(records[0].replyQuote, "引用：班长：前文通知内容", "有引用上下文时应显示引用行")
        XCTAssertEqual(records[0].sourceName, "示例班级群")
        XCTAssertFalse(records[0].missing)
    }

    func testMissingMessageFallsBackToSourceName() {
        let records = MonitorEvidenceBuilder.build(
            refs: [.init(sourceID: "s1", externalID: "deleted-1")],
            messagesBySource: ["s1": []],
            sourceNames: ["s1": "示例班级群"], sourceKinds: ["s1": .qqGroup])
        XCTAssertEqual(records.count, 1)
        XCTAssertTrue(records[0].missing, "消息已删除时证据应标记原文未找到")
        XCTAssertEqual(records[0].sourceName, "示例班级群", "降级后仍应显示来源名")
        XCTAssertNil(records[0].kind)
        XCTAssertEqual(records[0].excerpt, "")
    }
}
