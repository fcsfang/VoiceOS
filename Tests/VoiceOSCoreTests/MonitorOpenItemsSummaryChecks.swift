import XCTest
@testable import VoiceOSCore

final class MonitorOpenItemsSummaryChecks: XCTestCase {
    private func report(id: String, date: String) -> MonitorReport {
        MonitorReport(id: id, reportDate: date, state: .complete, headline: "报告", summary: "",
                      sourceStatus: [], itemCount: 0, createdAt: date + "T02:23:00Z",
                      deliveredAt: nil, deliveryState: "pending", deliveryError: nil, payloadJSON: nil)
    }

    private func item(id: String, reportID: String) -> MonitorItem {
        MonitorItem(id: id, reportID: reportID, title: "事项", whyRelevant: "原因",
                    suggestedAction: "行动", deadlineText: nil, deadlineDate: nil, conditions: nil,
                    evidenceQuote: "原文", sourceRefsJSON: "[]", uncertainty: nil,
                    category: .applicable, status: .open, relatedItemID: nil,
                    firstSeenDate: "2026-11-18", lastUpdatedDate: "2026-11-18",
                    createdAt: "2026-11-18", updatedAt: "2026-11-18")
    }

    func test今日报告为空时更早报告的未处理仍被汇总() {
        let reports = [report(id: "r19", date: "2026-11-19"),
                       report(id: "r18", date: "2026-11-18"),
                       report(id: "r17", date: "2026-11-17")]
        let summary = MonitorOpenItemsSummary(
            openItems: [item(id: "a", reportID: "r18"), item(id: "b", reportID: "r17")],
            reports: reports, todayKey: "2026-11-19")
        XCTAssertEqual(summary.totalCount, 2)
        XCTAssertEqual(summary.earlierCount, 2, "今天报告为空时，更早报告的未处理事项必须单独汇总")
        XCTAssertEqual(summary.earliestReportDate, "2026-11-17", "最早报告按日期取最小值")
        XCTAssertEqual(summary.earliestReportID, "r17")
    }

    func test今日未处理不计入更早计数但仍算总数() {
        let reports = [report(id: "r19", date: "2026-11-19"),
                       report(id: "r18", date: "2026-11-18")]
        let summary = MonitorOpenItemsSummary(
            openItems: [item(id: "a", reportID: "r19"), item(id: "b", reportID: "r18")],
            reports: reports, todayKey: "2026-11-19")
        XCTAssertEqual(summary.totalCount, 2, "跨报告总数包含今天")
        XCTAssertEqual(summary.earlierCount, 1, "今天已展示的未处理不计入更早提示")
        XCTAssertEqual(summary.earliestReportID, "r18")
    }

    func test不在报告列表中的旧报告仍计入更早未处理() {
        let reports = [report(id: "r19", date: "2026-11-19"),
                       report(id: "r18", date: "2026-11-18")]
        let summary = MonitorOpenItemsSummary(
            openItems: [item(id: "b", reportID: "r18"), item(id: "c", reportID: "old-report")],
            reports: reports, todayKey: "2026-11-19")
        XCTAssertEqual(summary.totalCount, 2)
        XCTAssertEqual(summary.earlierCount, 2, "不在前 30 条报告列表里的旧报告仍计入更早未处理")
        XCTAssertEqual(summary.earliestReportDate, "2026-11-18", "最早日期只取能拿到报告日期的项")
        XCTAssertEqual(summary.earliestReportID, "r18")
    }
}