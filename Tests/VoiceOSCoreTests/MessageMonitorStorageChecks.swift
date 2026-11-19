import XCTest
@testable import VoiceOSCore
import VoiceOSPlatform

final class MessageMonitorStorageChecks: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-monitor-store-" + UUID().uuidString)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func openStore() async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }

    func testMigrationAddsMonitorTablesAndSourceCRUD() async throws {
        let store = try await openStore()
        let db = await store.db
        XCTAssertEqual(try db.query("PRAGMA user_version").first?["user_version"], TestSchema.currentVersion,
                       "迁移后资料库版本应为 74")
        for table in ["monitor_sources", "monitor_messages", "monitor_cursors", "monitor_reports", "monitor_items"] {
            XCTAssertEqual(try db.query("SELECT name FROM sqlite_master WHERE type='table' AND name=?", [table]).count, 1,
                           "迁移 74 应创建表 \(table)")
        }
        let source = try await store.addMonitorSource(kind: .qqGroup, displayName: " 示例班级群 ",
                                                      configJSON: "{\"conversation_id\":\"group:fixture\"}")
        XCTAssertEqual(source.displayName, "示例班级群")
        let enabled = try await store.enabledMonitorSources()
        XCTAssertEqual(enabled.map(\.id), [source.id])
        _ = try await store.updateMonitorSource(id: source.id, displayName: "停用的群",
                                                configJSON: "{\"conversation_id\":\"group:fixture\"}", enabled: false)
        let remaining = try await store.enabledMonitorSources()
        XCTAssertEqual(remaining.count, 0, "停用的来源不再参与每日检查")
        try await store.removeMonitorSource(id: source.id)
        let sources = try await store.monitorSources()
        XCTAssertEqual(sources.count, 0, "删除来源后列表应为空")
    }

    func testOverlapRepeatedMessagesAreDeduplicated() async throws {
        let store = try await openStore()
        let source = try await store.addMonitorSource(kind: .qqGroup, displayName: "示例群",
                                                      configJSON: "{\"conversation_id\":\"group:fixture\"}")
        let drafts = [
            MonitorMessageDraft(sourceID: source.id, externalID: "m1", kind: .text, senderName: "甲",
                                sentAt: "2026-11-17T01:00:00Z", content: "奖学金申请通知", metaJSON: nil),
            MonitorMessageDraft(sourceID: source.id, externalID: "m2", kind: .image, senderName: "乙",
                                sentAt: "2026-11-17T01:05:00Z", content: "[图片：通知截图]",
                                metaJSON: "{\"chatlab_type\":1}"),
        ]
        let first = try await store.insertMonitorMessages(drafts)
        XCTAssertEqual(first.map(\.externalID), ["m1", "m2"], "首次采集应插入两条消息")
        let second = try await store.insertMonitorMessages(drafts)
        XCTAssertEqual(second.count, 0, "重叠窗口重复读取不能产生重复消息")
        let db = await store.db
        XCTAssertEqual(try db.query("SELECT COUNT(*) AS n FROM monitor_messages WHERE source_id=?", [source.id]).first?["n"], "2")
    }

    func testLaterStartAdvancesMonitorCursor() async throws {
        let store = try await openStore()
        let source = try await store.addMonitorSource(kind: .qqGroup, displayName: "示例群",
                                                      configJSON: "{\"conversation_id\":\"group:fixture\"}")
        let calendar = Calendar(identifier: .gregorian)
        let earlier = calendar.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 9))!
        let later = calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 9))!
        try await store.advanceMonitorCursor(sourceID: source.id, lastSuccessEnd: earlier, newMessageIDs: [])
        try await store.failMonitorCursor(sourceID: source.id, error: "旧错误")
        try await store.alignMonitorCursorToStart(sourceID: source.id, start: later)
        let cursor = try await store.monitorCursor(sourceID: source.id)
        XCTAssertEqual(cursor?.lastSuccessAt, ISO8601DateFormatter().string(from: later),
                       "把起始时间改晚后游标应同步推进，界面显示与实际读取一致")
        XCTAssertNil(cursor?.lastError, "重新选择起始时间应清除上次错误")
        try await store.alignMonitorCursorToStart(sourceID: source.id, start: earlier)
        let rewound = try await store.monitorCursor(sourceID: source.id)
        XCTAssertEqual(rewound?.lastSuccessAt, ISO8601DateFormatter().string(from: earlier),
                       "把起始时间改早后游标应回拨，去重吸收重叠")
    }

    func testCorruptSourceStatusIsMarkedUnreadable() async throws {
        let store = try await openStore()
        let reportID = try await store.upsertMonitorReport(
            date: "2026-11-19", state: .complete, headline: "示例", summary: "示例",
            sourceStatus: [MonitorSourceStatus(sourceID: "s1", displayName: "示例群", ok: true,
                                               newMessageCount: 0, error: nil)])
        let valid = try await store.monitorReport(id: reportID)
        XCTAssertEqual(valid?.sourceStatus.count, 1)
        XCTAssertEqual(valid?.sourceStatusUnreadable, false, "合法来源状态不应标记为无法读取")

        let db = await store.db
        try db.execute("UPDATE monitor_reports SET source_status_json='{broken' WHERE id=?", [reportID])
        let corrupt = try await store.monitorReport(id: reportID)
        XCTAssertEqual(corrupt?.sourceStatus.count, 0)
        XCTAssertEqual(corrupt?.sourceStatusUnreadable, true, "损坏的来源状态应显示为无法读取，而不是静默空数组")

        let emptyID = try await store.upsertMonitorReport(
            date: "2026-11-20", state: .complete, headline: "空状态", summary: "空状态", sourceStatus: [])
        let empty = try await store.monitorReport(id: emptyID)
        XCTAssertEqual(empty?.sourceStatusUnreadable, false, "合法空数组仍表示检查没有来源状态")
    }

    func testOpenItemMergeUpdatesInPlaceAndKeepsUserStatus() async throws {
        let store = try await openStore()
        let source = try await store.addMonitorSource(kind: .qqGroup, displayName: "示例群",
                                                      configJSON: "{\"conversation_id\":\"group:fixture\"}")
        _ = try await store.insertMonitorMessages([
            MonitorMessageDraft(sourceID: source.id, externalID: "m1", kind: .text, senderName: "甲",
                                sentAt: "2026-11-17T01:00:00Z", content: "学院通知：奖学金申请截止 11 月 20 日", metaJSON: nil)
        ])
        let firstReport = try await store.upsertMonitorReport(date: "2026-11-17", state: .complete,
                                                              headline: "今日有通知", summary: "奖学金通知。", sourceStatus: [])
        let firstItem = NotificationAnalysisItem(
            title: "申请奖学金", whyRelevant: "学院奖学金通知", suggestedAction: "按要求提交材料",
            deadlineText: "11月20日", deadlineDate: "2026-11-20", conditions: nil,
            evidenceQuote: "奖学金申请截止 11 月 20 日",
            sourceRefs: [.init(sourceID: source.id, externalID: "m1")],
            uncertainty: nil, category: .applicable, relatedExistingItemID: nil)
        let firstCount = try await store.applyMonitorAnalysis(reportID: firstReport, date: "2026-11-17", items: [firstItem])
        XCTAssertEqual(firstCount, 1)
        let created = try await store.monitorItems(reportID: firstReport)
        XCTAssertEqual(created.count, 1)
        try await store.setMonitorItemStatus(id: created[0].id, status: .done)

        let secondReport = try await store.upsertMonitorReport(date: "2026-11-18", state: .complete,
                                                               headline: "补充材料", summary: "同一事项后续。", sourceStatus: [])
        let update = NotificationAnalysisItem(
            title: "申请奖学金（补充材料）", whyRelevant: "学院补充通知", suggestedAction: "补齐成绩单",
            deadlineText: "11月22日", deadlineDate: "2026-11-22", conditions: "需成绩单",
            evidenceQuote: "奖学金申请截止 11 月 20 日",
            sourceRefs: [.init(sourceID: source.id, externalID: "m1")],
            uncertainty: nil, category: .applicable, relatedExistingItemID: created[0].id)
        let mergedCount = try await store.applyMonitorAnalysis(reportID: secondReport, date: "2026-11-18", items: [update])
        XCTAssertEqual(mergedCount, 1, "跨日关联应更新既有事项而不是新建重复行")
        let merged = try await store.monitorItems(reportID: secondReport)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].id, created[0].id, "关联更新应保留原事项标识")
        XCTAssertEqual(merged[0].status, .done, "更新字段时保留用户的已完成状态")
        XCTAssertEqual(merged[0].title, "申请奖学金（补充材料）")
        XCTAssertEqual(merged[0].firstSeenDate, "2026-11-17", "首次出现日期不随更新改变")
        XCTAssertEqual(merged[0].lastUpdatedDate, "2026-11-18")
        XCTAssertEqual(merged[0].reportID, secondReport)
    }

    func testDismissedRelatedItemIsUpdatedButStaysDismissed() async throws {
        let store = try await openStore()
        let source = try await store.addMonitorSource(kind: .websiteColumn, displayName: "学院通知",
                                                      configJSON: "{\"column_url\":\"https://example.invalid/tzgg\"}")
        let firstReport = try await store.upsertMonitorReport(date: "2026-11-17", state: .complete,
                                                              headline: "首条", summary: "摘要", sourceStatus: [])
        let item = NotificationAnalysisItem(
            title: "旧通知", whyRelevant: "学院通知", suggestedAction: "已处理",
            deadlineText: nil, deadlineDate: nil, conditions: nil,
            evidenceQuote: "关于某事项的通知", sourceRefs: [.init(sourceID: source.id, externalID: "u1")],
            uncertainty: nil, category: .applicable, relatedExistingItemID: nil)
        _ = try await store.applyMonitorAnalysis(reportID: firstReport, date: "2026-11-17", items: [item])
        let old = try await store.monitorItems(reportID: firstReport)[0]
        try await store.setMonitorItemStatus(id: old.id, status: .dismissed)
        let secondReport = try await store.upsertMonitorReport(date: "2026-11-19", state: .complete,
                                                               headline: "再次通知", summary: "摘要", sourceStatus: [])
        let followup = NotificationAnalysisItem(
            title: "同一通知再次发布", whyRelevant: "学院重新通知", suggestedAction: "按新通知处理",
            deadlineText: nil, deadlineDate: nil, conditions: nil,
            evidenceQuote: "关于某事项的通知", sourceRefs: [.init(sourceID: source.id, externalID: "u2")],
            uncertainty: nil, category: .applicable, relatedExistingItemID: old.id)
        let count = try await store.applyMonitorAnalysis(reportID: secondReport, date: "2026-11-19", items: [followup])
        XCTAssertEqual(count, 1, "命中关联事项时更新既有行，不新增重复行")
        let rows = try await store.monitorItems(reportID: secondReport)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, old.id, "关联更新保留原事项标识")
        XCTAssertEqual(rows[0].status, .dismissed, "更新字段时保留用户的已忽略状态")
        XCTAssertEqual(rows[0].title, "同一通知再次发布")
        XCTAssertEqual(rows[0].lastUpdatedDate, "2026-11-19")
        let open = try await store.openMonitorItems()
        XCTAssertEqual(open.count, 0, "已忽略事项不因更新回到未完成列表")
    }
}
