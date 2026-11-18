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
    private func openStore() async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
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

    func testWeComBodyContainsGroupedItemsAndFooter() throws {
        let request = try MonitorPushComposer.request(sampleContent(), channel: .wecom, webhookURL: wecomURL())
        XCTAssertEqual(request.urlRequest.httpMethod, "POST")
        XCTAssertEqual(request.urlRequest.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(request.urlRequest.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["msgtype"] as? String, "markdown")
        let markdown = try XCTUnwrap((json["markdown"] as? [String: Any])?["content"] as? String)
        XCTAssertTrue(markdown.contains("2026-11-18"))
        XCTAssertTrue(markdown.contains("奖学金申请"))
        XCTAssertTrue(markdown.contains("**适用**"))
        XCTAssertTrue(markdown.contains("**待核对**"))
        XCTAssertTrue(markdown.contains("截止 11月20日"))
        XCTAssertTrue(markdown.contains(MonitorPushComposer.footer))
    }

    func testServerChanFormCarriesTitleAndBody() throws {
        let request = try MonitorPushComposer.request(sampleContent(), channel: .serverChan, webhookURL: serverChanURL())
        XCTAssertEqual(request.urlRequest.value(forHTTPHeaderField: "Content-Type"),
                       "application/x-www-form-urlencoded; charset=utf-8")
        let body = String(decoding: try XCTUnwrap(request.urlRequest.httpBody), as: UTF8.self)
        var fields: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            let value = parts.count > 1 ? String(parts[1]) : ""
            fields[String(parts[0])] = value.removingPercentEncoding ?? value
        }
        XCTAssertTrue(fields["title"]?.contains("每日消息监测") == true)
        XCTAssertTrue(fields["desp"]?.contains("奖学金申请") == true, "表单正文应包含事项内容")
    }

    func testDeliveryPersistsPayloadThenRecordsSuccess() async throws {
        let store = try await openStore()
        let reportID = try await store.upsertMonitorReport(date: "2026-11-18", state: .complete,
                                                           headline: "今日", summary: "摘要", sourceStatus: [])
        let transport = StubPushTransport([.success(.init(statusCode: 200, body: Data("{\"errcode\":0,\"errmsg\":\"ok\"}".utf8)))])
        let service = MonitorPushService(store: store, transport: transport,
                                         now: { Date(timeIntervalSince1970: 1_763_424_000) })
        let outcome = await service.deliver(reportID: reportID, date: "2026-11-18", content: sampleContent(),
                                            channel: .wecom, webhookURL: wecomURL())
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
    }

    func testFailureStaysRetryableAndRetryMarksDelivered() async throws {
        let store = try await openStore()
        let reportID = try await store.upsertMonitorReport(date: "2026-11-18", state: .complete,
                                                           headline: "今日", summary: "摘要", sourceStatus: [])
        let transport = StubPushTransport([
            .success(.init(statusCode: 500, body: Data())),
            .success(.init(statusCode: 200, body: Data("{\"errcode\":0,\"errmsg\":\"ok\"}".utf8)))
        ])
        let service = MonitorPushService(store: store, transport: transport)
        let first = await service.deliver(reportID: reportID, date: "2026-11-18", content: sampleContent(),
                                          channel: .wecom, webhookURL: wecomURL())
        XCTAssertFalse(first.success)
        var stored = try await store.monitorReport(id: reportID)
        XCTAssertEqual(stored?.deliveryState, "failed")
        XCTAssertTrue(stored?.deliveryError?.contains("HTTP 500") == true)
        XCTAssertNotNil(stored?.payloadJSON, "失败后保留待重试的报文体")
        let second = await service.deliver(reportID: reportID, date: "2026-11-18", content: sampleContent(),
                                           channel: .wecom, webhookURL: wecomURL())
        XCTAssertTrue(second.success)
        stored = try await store.monitorReport(id: reportID)
        XCTAssertEqual(stored?.deliveryState, "delivered")
        XCTAssertNil(stored?.deliveryError)
        let requestCount = await transport.sentRequests().count
        XCTAssertEqual(requestCount, 2)
    }

    func testWeComNonZeroErrcodeFailsDelivery() async throws {
        let store = try await openStore()
        let reportID = try await store.upsertMonitorReport(date: "2026-11-18", state: .complete,
                                                           headline: "今日", summary: "摘要", sourceStatus: [])
        let transport = StubPushTransport([
            .success(.init(statusCode: 200, body: Data("{\"errcode\":93000,\"errmsg\":\"invalid webhook url\"}".utf8)))
        ])
        let outcome = await MonitorPushService(store: store, transport: transport)
            .deliver(reportID: reportID, date: "2026-11-18", content: sampleContent(),
                     channel: .wecom, webhookURL: wecomURL())
        XCTAssertFalse(outcome.success)
        XCTAssertTrue(outcome.error?.contains("errcode=93000") == true)
        let stored = try await store.monitorReport(id: reportID)
        XCTAssertEqual(stored?.deliveryState, "failed")
    }
}
