import XCTest
@testable import VoiceOSCore
import VoiceOSPlatform

private actor StubPushTransport: MonitorPushTransport {
    private var responses: [Result<MonitorPushResponse, Error>]
    private var requests: [URLRequest] = []
    init(_ responses: [Result<MonitorPushResponse, Error>]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> MonitorPushResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw VoiceOSError("fixture 没有剩余响应") }
        return try responses.removeFirst().get()
    }
    func sentRequests() -> [URLRequest] { requests }
}

final class MonitorPushChecks: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-monitor-push-" + UUID().uuidString)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }
    private func openStore(_ tag: String = "store") async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: root.appendingPathComponent(tag), inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }
    private func sampleContent() -> MonitorPushContent {
        MonitorPushContent(
            date: "2026-11-18",
            headline: "奖学金申请与课程通知",
            summary: "今天有两条需要关注。",
            items: [
                MonitorPushItem(title: "奖学金申请", deadline: "11月20日", whyRelevant: "学院通知申请即得",
                                sourceName: "南航16院2025级硕士生", category: .applicable),
                MonitorPushItem(title: "材料提交方式", deadline: nil, whyRelevant: "群里说法不一致",
                                sourceName: "计算机学院通知", category: .needsCheck)
            ])
    }
    private func wecomURL() -> URL { URL(string: "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=fixture")! }
    private func serverChanURL() -> URL { URL(string: "https://sctapi.ftqq.com/SCTfixture.send")! }

    func testComposerChannelsCarryFormattedBody() throws {
        let cases: [(name: String, channel: MonitorPushChannel, url: URL,
                     contentType: String, verify: (URLRequest) throws -> Void)] = [
            ("企业微信 markdown", .wecom, wecomURL(), "application/json", { urlRequest in
                XCTAssertEqual(urlRequest.httpMethod, "POST")
                let body = try XCTUnwrap(urlRequest.httpBody)
                let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
                XCTAssertEqual(json["msgtype"] as? String, "markdown")
                let markdown = try XCTUnwrap((json["markdown"] as? [String: Any])?["content"] as? String)
                XCTAssertTrue(markdown.contains("2026-11-18"))
                XCTAssertTrue(markdown.contains("奖学金申请"))
                XCTAssertTrue(markdown.contains("**适用**"))
                XCTAssertTrue(markdown.contains("**待核对**"))
                XCTAssertTrue(markdown.contains("截止 11月20日"))
                XCTAssertTrue(markdown.contains(MonitorPushComposer.footer(date: "2026-11-18")))
            }),
            ("Server酱表单", .serverChan, serverChanURL(), "application/x-www-form-urlencoded; charset=utf-8", { urlRequest in
                let body = String(decoding: try XCTUnwrap(urlRequest.httpBody), as: UTF8.self)
                var fields: [String: String] = [:]
                for pair in body.split(separator: "&") {
                    let parts = pair.split(separator: "=", maxSplits: 1)
                    let value = parts.count > 1 ? String(parts[1]) : ""
                    fields[String(parts[0])] = value.removingPercentEncoding ?? value
                }
                XCTAssertTrue(fields["title"]?.contains("每日消息监测") == true)
                XCTAssertTrue(fields["desp"]?.contains("奖学金申请") == true, "表单正文应包含事项内容")
            }),
        ]
        for c in cases {
            let request = try MonitorPushComposer.request(sampleContent(), channel: c.channel, webhookURL: c.url)
            XCTAssertEqual(request.urlRequest.value(forHTTPHeaderField: "Content-Type"), c.contentType,
                           "\(c.name)：Content-Type")
            try c.verify(request.urlRequest)
        }
    }

    func testDeliveryOutcomesPersistStateAndStayRetryable() async throws {
        let cases: [(name: String, responses: [Result<MonitorPushResponse, Error>], now: Date?,
                     verify: (VoiceOSStore, StubPushTransport, String, MonitorPushService) async throws -> Void)] = [
            ("成功投递",
             [.success(.init(statusCode: 200, body: Data("{\"errcode\":0,\"errmsg\":\"ok\"}".utf8)))],
             Date(timeIntervalSince1970: 1_763_424_000),
             { store, transport, reportID, service in
                 let outcome = await service.deliver(reportID: reportID, date: "2026-11-18", content: self.sampleContent(),
                                                     channel: .wecom, webhookURL: self.wecomURL())
                 XCTAssertTrue(outcome.success)
                 let stored = try await store.monitorReport(id: reportID)
                 XCTAssertEqual(stored?.deliveryState, "delivered")
                 XCTAssertNotNil(stored?.deliveredAt)
                 XCTAssertNil(stored?.deliveryError)
                 let payload = try XCTUnwrap(stored?.payloadJSON)
                 XCTAssertTrue(payload.contains("\"channel\":\"wecom\""), "发送前应保存报文体：\(payload)")
                 XCTAssertTrue(payload.contains("奖学金申请"))
                 let requestCount = await transport.sentRequests().count
                 XCTAssertEqual(requestCount, 1)
             }),
            ("失败后重试",
             [.success(.init(statusCode: 500, body: Data())),
              .success(.init(statusCode: 200, body: Data("{\"errcode\":0,\"errmsg\":\"ok\"}".utf8)))],
             nil,
             { store, transport, reportID, service in
                 let first = await service.deliver(reportID: reportID, date: "2026-11-18", content: self.sampleContent(),
                                                   channel: .wecom, webhookURL: self.wecomURL())
                 XCTAssertFalse(first.success)
                 var stored = try await store.monitorReport(id: reportID)
                 XCTAssertEqual(stored?.deliveryState, "failed")
                 XCTAssertTrue(stored?.deliveryError?.contains("HTTP 500") == true)
                 XCTAssertNotNil(stored?.payloadJSON, "失败后保留待重试的报文体")
                 let second = await service.deliver(reportID: reportID, date: "2026-11-18", content: self.sampleContent(),
                                                    channel: .wecom, webhookURL: self.wecomURL())
                 XCTAssertTrue(second.success)
                 stored = try await store.monitorReport(id: reportID)
                 XCTAssertEqual(stored?.deliveryState, "delivered")
                 XCTAssertNil(stored?.deliveryError)
                 let requestCount = await transport.sentRequests().count
                 XCTAssertEqual(requestCount, 2)
             }),
            ("企业微信 errcode 失败",
             [.success(.init(statusCode: 200, body: Data("{\"errcode\":93000,\"errmsg\":\"invalid webhook url\"}".utf8)))],
             nil,
             { store, _, reportID, service in
                 let outcome = await service.deliver(reportID: reportID, date: "2026-11-18", content: self.sampleContent(),
                                                     channel: .wecom, webhookURL: self.wecomURL())
                 XCTAssertFalse(outcome.success)
                 XCTAssertTrue(outcome.error?.contains("errcode=93000") == true)
                 let stored = try await store.monitorReport(id: reportID)
                 XCTAssertEqual(stored?.deliveryState, "failed")
             }),
        ]
        for (index, c) in cases.enumerated() {
            let store = try await openStore("delivery-\(index)")
            let reportID = try await store.upsertMonitorReport(date: "2026-11-18", state: .complete,
                                                               headline: "今日", summary: "摘要", sourceStatus: [])
            let transport = StubPushTransport(c.responses)
            let service: MonitorPushService
            if let now = c.now {
                service = MonitorPushService(store: store, transport: transport, now: { now })
            } else {
                service = MonitorPushService(store: store, transport: transport)
            }
            do {
                try await c.verify(store, transport, reportID, service)
            } catch {
                XCTFail("\(c.name)：\(error)")
            }
        }
    }

    private func makeItem(_ id: String, title: String, status: MonitorItemStatus) -> MonitorItem {
        MonitorItem(id: id, reportID: "report-1", title: title, whyRelevant: "原因",
                    suggestedAction: "行动", deadlineText: nil, deadlineDate: nil, conditions: nil,
                    evidenceQuote: "原文", sourceRefsJSON: "[]", uncertainty: nil,
                    category: .applicable, status: status, relatedItemID: nil,
                    firstSeenDate: "2026-11-18", lastUpdatedDate: "2026-11-18",
                    createdAt: "2026-11-18T00:00:00Z", updatedAt: "2026-11-18T00:00:00Z")
    }

    func testPushBodyKeepsOnlyOpenItemsAndCountsAll() {
        let content = MonitorPushContent(
            date: "2026-11-18", headline: "今日", summary: "",
            items: [
                MonitorPushItem(title: "已完成事项", deadline: nil, whyRelevant: "已完成",
                                sourceName: "来源", category: .applicable, status: .done),
                MonitorPushItem(title: "不适用事项", deadline: nil, whyRelevant: "不适用",
                                sourceName: "来源", category: .needsCheck, status: .dismissed),
                MonitorPushItem(title: "未处理事项", deadline: nil, whyRelevant: "待办",
                                sourceName: "来源", category: .applicable, status: .open)
            ])
        let markdown = MonitorPushComposer.wecomMarkdown(content)
        XCTAssertTrue(markdown.contains("共 3 条，未处理 1 条"), "正文顶部应统计全部条数与未处理条数")
        XCTAssertTrue(markdown.contains("未处理事项"), "未处理事项应进入推送正文")
        XCTAssertFalse(markdown.contains("已完成事项"), "已完成事项不应进入推送正文")
        XCTAssertFalse(markdown.contains("不适用事项"), "不适用事项不应进入推送正文")
    }

    func testTruncatedPushKeepsOmissionNoteAndFooter() {
        let items = (1...120).map { index in
            MonitorPushItem(title: "事项 \(index)", deadline: nil,
                            whyRelevant: String(repeating: "原因", count: 200),
                            sourceName: "来源", category: .applicable, status: .open)
        }
        let content = MonitorPushContent(date: "2026-11-18", headline: "长报告", summary: "", items: items)
        let markdown = MonitorPushComposer.wecomMarkdown(content)
        XCTAssertLessThanOrEqual(markdown.utf8.count, MonitorPushComposer.wecomLimit, "推送正文不能超过通道上限")
        XCTAssertTrue(markdown.contains("已省略部分事项，完整内容在应用内查看"), "截断后应提示进入应用查看")
        XCTAssertTrue(markdown.hasSuffix(MonitorPushComposer.footer(date: "2026-11-18")), "截断后页脚仍应保留回看路径")
    }

    func testItemTallyUsesLiveStatuses() {
        let tally = MonitorItemTally(items: [
            makeItem("a", title: "未处理", status: .open),
            makeItem("b", title: "已完成", status: .done),
            makeItem("c", title: "不适用", status: .dismissed)
        ])
        XCTAssertEqual(tally.total, 3, "总数应包含全部事项")
        XCTAssertEqual(tally.open, 1, "未处理数应按 open 状态统计")
        XCTAssertEqual(tally.handled, 2, "已处理数应统计完成与不适用")
    }
}