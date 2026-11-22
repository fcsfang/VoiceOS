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

    func testOpenItemsSummarySeparatesEarlierUnreachableAndEarliestReport() {
        let cases: [(name: String, openItems: [MonitorItem], reports: [MonitorReport],
                     total: Int, earlier: Int, unreachable: Int,
                     earliestDate: String?, earliestID: String?)] = [
            ("今日报告为空时更早报告的未处理仍被汇总",
             [item(id: "a", reportID: "r18"), item(id: "b", reportID: "r17")],
             [report(id: "r19", date: "2026-11-19"),
              report(id: "r18", date: "2026-11-18"),
              report(id: "r17", date: "2026-11-17")],
             2, 2, 0, "2026-11-17", "r17"),
            ("今日未处理不计入更早计数但仍算总数",
             [item(id: "a", reportID: "r19"), item(id: "b", reportID: "r18")],
             [report(id: "r19", date: "2026-11-19"),
              report(id: "r18", date: "2026-11-18")],
             2, 1, 0, "2026-11-18", "r18"),
            ("未加载报告的未处理事项计入不可达而不是更早",
             [item(id: "b", reportID: "r18"), item(id: "c", reportID: "old-report")],
             [report(id: "r19", date: "2026-11-19"),
              report(id: "r18", date: "2026-11-18")],
             2, 1, 1, "2026-11-18", "r18"),
            ("只有未加载报告时更早为空且不可达计数完整",
             [item(id: "c", reportID: "old-report"), item(id: "d", reportID: "older-report")],
             [report(id: "r19", date: "2026-11-19")],
             2, 0, 2, nil, nil),
        ]
        for c in cases {
            let summary = MonitorOpenItemsSummary(openItems: c.openItems, reports: c.reports, todayKey: "2026-11-19")
            XCTAssertEqual(summary.totalCount, c.total, "\(c.name)：跨报告总数")
            XCTAssertEqual(summary.earlierCount, c.earlier, "\(c.name)：更早未处理数")
            XCTAssertEqual(summary.unreachableCount, c.unreachable, "\(c.name)：不可达数")
            XCTAssertEqual(summary.earliestReportDate, c.earliestDate, "\(c.name)：最早报告日期")
            XCTAssertEqual(summary.earliestReportID, c.earliestID, "\(c.name)：最早报告 ID")
        }
    }
}