import XCTest
@testable import VoiceOSCore
import VoiceOSPlatform

private struct StubQQCollector: QQMonitorCollecting {
    let messages: [QQMonitorReadMessage]
    let failure: String?
    func collect(conversationID: String, start: Date, end: Date, settings: QQMonitorSettings) async throws -> QQMonitorReadResult {
        if let failure { throw VoiceOSError(failure) }
        return QQMonitorReadResult(conversationID: conversationID, conversationName: "示例班级群",
                                   messages: messages, truncated: false)
    }
}

private struct StubWebsiteCollector: WebsiteMonitorCollecting {
    let entries: [WebsiteMonitorEntry]
    let failure: String?
    func collect(columnURL: URL) async throws -> [WebsiteMonitorEntry] {
        if let failure { throw VoiceOSError(failure) }
        return entries
    }
}

private func echoResult(_ input: NotificationAnalysisInput) -> NotificationAnalysisResult {
    let items = input.messages.map { message in
        NotificationAnalysisItem(title: "关注：" + String(message.text.prefix(12)),
                                 whyRelevant: "来源通知", suggestedAction: "查看原文并跟进",
                                 deadlineText: nil, deadlineDate: nil, conditions: nil,
                                 evidenceQuote: message.text,
                                 sourceRefs: [.init(sourceID: message.sourceID, externalID: message.externalID)],
                                 uncertainty: nil, category: .applicable, relatedExistingItemID: nil)
    }
    return NotificationAnalysisResult(headline: "今日检查", summary: "共 \(items.count) 条待关注事项。",
                                      items: items, responseID: "echo")
}

private struct EchoAnalysis: NotificationAnalysisPort {
    let failure: String?
    let identity = NotificationAnalysisIdentity(provider: "fixture", model: "fixture",
                                                promptVersion: "message-monitor-daily-v1", schemaVersion: "v1")
    func analyze(_ input: NotificationAnalysisInput) async throws -> NotificationAnalysisResult {
        if let failure { throw VoiceOSError(failure) }
        return echoResult(input)
    }
}

private actor FlakyAnalysis: NotificationAnalysisPort {
    var failuresLeft: Int
    let identity = NotificationAnalysisIdentity(provider: "fixture", model: "fixture",
                                                promptVersion: "message-monitor-daily-v1", schemaVersion: "v1")
    init(failuresLeft: Int) { self.failuresLeft = failuresLeft }
    func analyze(_ input: NotificationAnalysisInput) async throws -> NotificationAnalysisResult {
        if failuresLeft > 0 {
            failuresLeft -= 1
            throw VoiceOSError("fixture 模型暂时失败")
        }
        return echoResult(input)
    }
}

final class MessageMonitorRunnerChecks: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-monitor-runner-" + UUID().uuidString)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func openStore() async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }

    private func settings() -> QQMonitorSettings {
        QQMonitorSettings(pythonPath: "/usr/bin/true", scriptPath: "/dev/null",
                          keyPath: "/dev/null", cacheDir: NSTemporaryDirectory(), account: nil)
    }

    private func runner(store: VoiceOSStore, qq: any QQMonitorCollecting, website: (any WebsiteMonitorCollecting)? = nil,
                        analysis: (any NotificationAnalysisPort)?, now: Date) -> MessageMonitorRunner {
        MessageMonitorRunner(store: store, analysis: analysis, qqCollector: qq, websiteCollector: website,
                             qqSettings: settings(), now: { now })
    }

    private func message(_ id: String, text: String) -> QQMonitorReadMessage {
        QQMonitorReadMessage(externalID: id, kind: .text, senderName: "同学", sentAt: Date(timeIntervalSince1970: 1_763_424_000),
                             content: text, metaJSON: nil)
    }

    func testNoNewMessagesSavesCompleteReportWithEmptySummary() async throws {
        let store = try await openStore()
        _ = try await store.addMonitorSource(kind: .qqGroup, displayName: "示例班级群",
                                             configJSON: "{\"conversation_id\":\"group:fixture\"}")
        let day = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 9))!
        let run = try await runner(store: store, qq: StubQQCollector(messages: [], failure: nil), analysis: nil, now: day)
            .runDailyCheck(date: day)
        XCTAssertEqual(run.state, .complete)
        XCTAssertTrue(run.summary.contains("无新增待办"), "无新消息时摘要应为检查完成、无新增待办")
        let stored = try await store.monitorReport(date: "2026-11-18")
        XCTAssertEqual(stored?.state, .complete)
        XCTAssertEqual(stored?.itemCount, 0)
    }

    func testSourceFailureMarksReportIncompleteWithDiagnosis() async throws {
        let store = try await openStore()
        _ = try await store.addMonitorSource(kind: .qqGroup, displayName: "示例班级群",
                                             configJSON: "{\"conversation_id\":\"group:fixture\"}")
        let day = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 9))!
        let run = try await runner(store: store, qq: StubQQCollector(messages: [], failure: "QQ 数据目录缺失"),
                                   analysis: nil, now: day).runDailyCheck(date: day)
        XCTAssertEqual(run.state, .incomplete, "任一来源失败应把报告标为不完整")
        XCTAssertEqual(run.sourceStatus.first?.ok, false)
        XCTAssertTrue(run.sourceStatus.first?.error?.contains("QQ 数据目录缺失") == true)
        XCTAssertTrue(run.summary.contains("未能检查"), "摘要应写明哪些来源失败")
        let stored = try await store.monitorReport(date: "2026-11-18")
        XCTAssertEqual(stored?.state, .incomplete)
        XCTAssertTrue(stored?.sourceStatus.first?.error?.contains("QQ 数据目录缺失") == true,
                      "失败原因应按来源落库")
    }

    func testSecondDayOverlapDoesNotDuplicateMessages() async throws {
        let store = try await openStore()
        _ = try await store.addMonitorSource(kind: .qqGroup, displayName: "示例班级群",
                                             configJSON: "{\"conversation_id\":\"group:fixture\"}")
        let day1 = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 9))!
        let day2 = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 9))!
        _ = try await runner(store: store, qq: StubQQCollector(messages: [message("m1", text: "第一天的通知")], failure: nil),
                             analysis: EchoAnalysis(failure: nil), now: day1).runDailyCheck(date: day1)
        let second = try await runner(store: store,
                                      qq: StubQQCollector(messages: [message("m1", text: "第一天的通知"),
                                                                     message("m2", text: "第二天的通知")], failure: nil),
                                      analysis: EchoAnalysis(failure: nil), now: day2).runDailyCheck(date: day2)
        XCTAssertEqual(second.state, .complete)
        XCTAssertEqual(second.newMessageCount, 1, "重叠窗口只把真正新增的消息计入")
        let db = await store.db
        XCTAssertEqual(try db.query("SELECT COUNT(*) AS n FROM monitor_messages").first?["n"], "2",
                       "重复读取的旧消息不产生重复行")
    }

    func testAnalysisFailureKeepsMessagesAndCursorThenRetrySucceeds() async throws {
        let store = try await openStore()
        let source = try await store.addMonitorSource(kind: .qqGroup, displayName: "示例班级群",
                                                      configJSON: "{\"conversation_id\":\"group:fixture\"}")
        let day = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 9))!
        let analysis = FlakyAnalysis(failuresLeft: 1)
        let failed = try await runner(store: store, qq: StubQQCollector(messages: [message("m1", text: "奖学金通知全文")], failure: nil),
                                      analysis: analysis, now: day).runDailyCheck(date: day)
        XCTAssertEqual(failed.state, .failed, "模型失败应把当天报告标为失败")
        let storedFailed = try await store.monitorReport(date: "2026-11-18")
        XCTAssertEqual(storedFailed?.state, .failed)
        let db = await store.db
        XCTAssertEqual(try db.query("SELECT COUNT(*) AS n FROM monitor_messages").first?["n"], "1",
                       "分析失败时已采集原文必须保留")
        let cursor = try await store.monitorCursor(sourceID: source.id)
        XCTAssertNotNil(cursor?.lastSuccessAt, "消息持久化成功后游标应已推进")

        let retried = try await runner(store: store, qq: StubQQCollector(messages: [], failure: nil),
                                       analysis: analysis, now: day).retryAnalysis(reportDate: day)
        XCTAssertEqual(retried.state, .complete, "重试分析成功后报告应为完整")
        XCTAssertEqual(retried.itemCount, 1)
        XCTAssertEqual(try db.query("SELECT COUNT(*) AS n FROM monitor_messages").first?["n"], "1",
                       "只重分析不应重新采集或重复保存消息")
    }

    func testQQFailureDoesNotDiscardWebsiteResults() async throws {
        let store = try await openStore()
        _ = try await store.addMonitorSource(kind: .qqGroup, displayName: "示例班级群",
                                             configJSON: "{\"conversation_id\":\"group:fixture\"}")
        _ = try await store.addMonitorSource(kind: .websiteColumn, displayName: "计算机学院通知",
                                             configJSON: "{\"column_url\":\"https://example.invalid/tzgg\"}")
        let day = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 9))!
        let entry = WebsiteMonitorEntry(url: "https://example.invalid/tzgg/2026/1118.html",
                                        title: "关于奖学金申请的通知",
                                        publishedAt: Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 18)),
                                        text: "学院奖学金申请截止 11 月 20 日。", note: nil)
        let run = try await runner(store: store, qq: StubQQCollector(messages: [], failure: "密钥无效"),
                                   website: StubWebsiteCollector(entries: [entry], failure: nil),
                                   analysis: EchoAnalysis(failure: nil), now: day).runDailyCheck(date: day)
        XCTAssertEqual(run.state, .incomplete, "QQ 失败时报告应标为不完整")
        XCTAssertEqual(run.itemCount, 1, "官网已抓取的消息仍应完成分析并保存事项")
        let db = await store.db
        XCTAssertEqual(try db.query("SELECT COUNT(*) AS n FROM monitor_messages").first?["n"], "1")
    }

    func testWebsiteStartDateSkipsOlderEntriesAndFlagsUndated() async throws {
        let store = try await openStore()
        let config = try MonitorSourceConfigParser.websiteJSON(columnURL: "https://cs.nuaa.edu.cn/10851/list.htm",
                                                               startAt: "2026-11-18")
        _ = try await store.addMonitorSource(kind: .websiteColumn, displayName: "计算机学院通知", configJSON: config)
        let day = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 9))!
        let keepURL = "https://cs.nuaa.edu.cn/2026/1118/c10851a1/page.htm"
        let oldURL = "https://cs.nuaa.edu.cn/2026/1101/c10851a2/page.htm"
        let undatedURL = "https://cs.nuaa.edu.cn/2026/1110/c10851a3/page.htm"
        let entries = [
            WebsiteMonitorEntry(url: keepURL, title: "启用当天发布的通知",
                                publishedAt: Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 18)),
                                text: "启用当天发布的通知正文。", note: nil),
            WebsiteMonitorEntry(url: oldURL, title: "起始日期之前的旧通知",
                                publishedAt: Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 1)),
                                text: "早于起始日期的通知正文。", note: nil),
            WebsiteMonitorEntry(url: undatedURL, title: "没有发布日期的通知",
                                publishedAt: nil, text: "列表页没有日期标记的通知正文。", note: nil),
        ]
        let run = try await runner(store: store, qq: StubQQCollector(messages: [], failure: nil),
                                   website: StubWebsiteCollector(entries: entries, failure: nil),
                                   analysis: EchoAnalysis(failure: nil), now: day).runDailyCheck(date: day)
        XCTAssertEqual(run.newMessageCount, 2, "早于起始日期的条目不应进入采集，其余条目照常采集")
        let db = await store.db
        let rows = try db.query("SELECT external_id, sent_at, meta_json FROM monitor_messages ORDER BY external_id")
        XCTAssertEqual(rows.count, 2, "无日期条目仍应采集，只有早于起始日期的条目被过滤")
        XCTAssertFalse(rows.contains { $0["external_id"] == oldURL }, "早于起始日期的条目不应落库")
        let undated = rows.first { $0["external_id"] == undatedURL }
        XCTAssertNotNil(undated, "无日期条目不应被静默丢弃")
        XCTAssertNil(undated?["sent_at"], "无日期条目的 sent_at 应为空")
        XCTAssertTrue(undated?["meta_json"]?.contains("\"date_missing\":true") == true,
                      "无日期条目应在 meta 标记 date_missing")
        let dated = rows.first { $0["external_id"] == keepURL }
        let datedComponents = dated?["sent_at"].flatMap { ISO8601DateFormatter().date(from: $0) }
            .map { Calendar.current.dateComponents([.year, .month, .day], from: $0) }
        XCTAssertEqual(datedComponents?.year, 2026, "可解析日期的条目应把发布日期写入 sent_at")
        XCTAssertEqual(datedComponents?.month, 11)
        XCTAssertEqual(datedComponents?.day, 18)
    }
}
