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

    func testEvidenceBuilderTruncatesExcerptAndFallsBackForMissingMessage() {
        let body = String(repeating: "通", count: 150)
        let meta = "{\"replyContext\":{\"accountName\":\"班长\",\"content\":\"前文通知内容\"}}"
        let cases: [(name: String, records: () -> [MonitorEvidenceRecord],
                     kind: MonitorMessageKind?, excerpt: String,
                     replyQuote: String?, missing: Bool)] = [
            ("消息存在", {
                MonitorEvidenceBuilder.build(
                    refs: [.init(sourceID: "s1", externalID: "m1")],
                    messagesBySource: ["s1": [self.message("m1", kind: .text, content: body, metaJSON: meta)]],
                    sourceNames: ["s1": "示例班级群"], sourceKinds: ["s1": .qqGroup])
            }, .text, String(repeating: "通", count: 120) + "…", "引用：班长：前文通知内容", false),
            ("消息已删除", {
                MonitorEvidenceBuilder.build(
                    refs: [.init(sourceID: "s1", externalID: "deleted-1")],
                    messagesBySource: ["s1": []],
                    sourceNames: ["s1": "示例班级群"], sourceKinds: ["s1": .qqGroup])
            }, nil, "", nil, true),
        ]
        for c in cases {
            let records = c.records()
            XCTAssertEqual(records.count, 1, "\(c.name)：应生成一条证据")
            XCTAssertEqual(records[0].kind, c.kind, "\(c.name)：消息类型")
            XCTAssertEqual(records[0].excerpt, c.excerpt, "\(c.name)：证据正文片段")
            if let replyQuote = c.replyQuote {
                XCTAssertEqual(records[0].replyQuote, replyQuote, "\(c.name)：引用行")
            }
            XCTAssertEqual(records[0].sourceName, "示例班级群", "\(c.name)：来源名")
            XCTAssertEqual(records[0].missing, c.missing, "\(c.name)：原文缺失标记")
        }
    }
}