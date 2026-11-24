import XCTest
@testable import VoiceOSCore
import VoiceOSPlatform

private final class AnalysisReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let replies: [String]
    init(replies: [String]) { self.replies = replies }
    func next() -> (index: Int, text: String) {
        lock.lock(); defer { lock.unlock() }
        let index = min(calls, replies.count - 1)
        calls += 1
        return (index, replies[index])
    }
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls }
}

private struct FixedAnalysisTransport: ModelHTTPTransport {
    let box: AnalysisReplyBox
    func send(_ request: URLRequest) async throws -> ModelHTTPReply {
        let (index, text) = box.next()
        let envelope: [String: Any] = ["status": "completed", "id": "fixed-\(index)",
            "output": [["type": "message", "role": "assistant", "status": "completed",
                        "content": [["type": "output_text", "text": text]]]]]
        return ModelHTTPReply(status: 200, body: try JSONSerialization.data(withJSONObject: envelope))
    }
}

private func analysisPort(_ box: AnalysisReplyBox) throws -> ResponsesNotificationAnalysisPort {
    try ResponsesNotificationAnalysisPort(baseURL: URL(string: "https://api.openai.com/v1")!,
                                          apiKey: "fixture", model: "fixture-model",
                                          transport: FixedAnalysisTransport(box: box))
}

private func analysisInput(text: String, externalID: String = "m1",
                           existing: [NotificationExistingItem] = []) -> NotificationAnalysisInput {
    NotificationAnalysisInput(
        sources: [.init(sourceID: "s1", displayName: "示例群", kind: .qqGroup)],
        messages: [.init(sourceID: "s1", externalID: externalID, kind: .text, senderName: "同学",
                         sentAt: "2026-11-17T01:00:00Z", text: text, needsReview: false)],
        existingItems: existing, sourceStatus: [.init(sourceID: "s1", ok: true, error: nil)], digest: "d1")
}

private func replyJSON(_ entries: [(title: String, quote: String, externalID: String, related: String?)]) -> String {
    let items: [[String: Any]] = entries.map { entry in
        ["title": entry.title, "why_relevant": "学院通知", "suggested_action": "按要求提交材料",
         "deadline_text": "11月20日", "deadline_date": "2026-11-20", "conditions": NSNull(),
         "evidence_quote": entry.quote,
         "source_refs": [["sourceID": "s1", "externalID": entry.externalID] as [String: Any]],
         "uncertainty": NSNull(), "category": "applicable",
         "related_existing_item_id": entry.related ?? NSNull()]
    }
    let body: [String: Any] = ["headline": "今日有 \(items.count) 条通知", "summary": "学院发布奖学金相关通知。", "items": items]
    return String(decoding: try! JSONSerialization.data(withJSONObject: body), as: UTF8.self)
}

final class NotificationAnalysisChecks: XCTestCase {
    private let text = "学院通知：奖学金申请截止 11 月 20 日，请提交成绩单。"

    func testQuotedEvidenceIsAcceptedAndPromptVersionIsPinned() async throws {
        let box = AnalysisReplyBox(replies: [replyJSON([("申请奖学金", "奖学金申请截止 11 月 20 日", "m1", nil)])])
        let port = try analysisPort(box)
        XCTAssertEqual(port.identity.promptVersion, "message-monitor-daily-v3", "提示词版本应为 message-monitor-daily-v3")
        let result = try await port.analyze(analysisInput(text: text))
        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items[0].evidenceQuote, "奖学金申请截止 11 月 20 日")
        XCTAssertEqual(box.callCount, 1, "单批输入只应调用模型一次")
    }

    func testEvidenceOutsideInputIsRejectedInChinese() async throws {
        let box = AnalysisReplyBox(replies: [replyJSON([("不存在的通知", "这条原文并不在输入里", "m1", nil)])])
        let port = try analysisPort(box)
        do {
            _ = try await port.analyze(analysisInput(text: text))
            XCTFail("原文依据找不到时应拒绝保存")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("原文依据"), "错误应指明原文依据无法定位：\(error.localizedDescription)")
        }
    }

    func testSourceRefMustPointAtInputMessage() async throws {
        let box = AnalysisReplyBox(replies: [replyJSON([("申请奖学金", "奖学金申请截止 11 月 20 日", "m9", nil)])])
        let port = try analysisPort(box)
        do {
            _ = try await port.analyze(analysisInput(text: text))
            XCTFail("来源引用不在输入消息中时应拒绝")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("来源引用"), "错误应指明来源引用无效：\(error.localizedDescription)")
        }
    }

    func testRelatedExistingItemMustBeInOfferedList() async throws {
        let box = AnalysisReplyBox(replies: [replyJSON([("申请奖学金", "奖学金申请截止 11 月 20 日", "m1", "missing-item")])])
        let port = try analysisPort(box)
        do {
            _ = try await port.analyze(analysisInput(text: text))
            XCTFail("关联不存在的已有事项时应拒绝")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("已有事项"), "错误应指明关联事项无效：\(error.localizedDescription)")
        }
    }

    func testTwoBatchesMergeThroughOneExtraModelCall() async throws {
        let prefixA = String(repeating: "甲", count: 25_000)
        let prefixB = String(repeating: "乙", count: 25_000)
        let input = NotificationAnalysisInput(
            sources: [.init(sourceID: "s1", displayName: "示例群", kind: .qqGroup)],
            messages: [
                .init(sourceID: "s1", externalID: "m1", kind: .text, senderName: "甲",
                      sentAt: "2026-11-17T01:00:00Z", text: prefixA, needsReview: false),
                .init(sourceID: "s1", externalID: "m2", kind: .text, senderName: "乙",
                      sentAt: "2026-11-17T02:00:00Z", text: prefixB, needsReview: false),
            ],
            existingItems: [], sourceStatus: [.init(sourceID: "s1", ok: true, error: nil)], digest: "d2")
        let box = AnalysisReplyBox(replies: [
            replyJSON([("甲通知", prefixA, "m1", nil)]),
            replyJSON([("乙通知", prefixB, "m2", nil)]),
            replyJSON([("甲通知", prefixA, "m1", nil), ("乙通知", prefixB, "m2", nil)]),
        ])
        let port = try analysisPort(box)
        let result = try await port.analyze(input)
        XCTAssertEqual(box.callCount, 3, "两批分析后再合并一次，共三次调用")
        XCTAssertEqual(result.items.count, 2)
        XCTAssertEqual(Set(result.items.map(\.title)), ["甲通知", "乙通知"], "合并结果应覆盖两批候选")
    }
}
