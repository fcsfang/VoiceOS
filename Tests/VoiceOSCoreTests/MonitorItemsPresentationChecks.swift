import XCTest
@testable import VoiceOSCore

final class MonitorItemsPresentationChecks: XCTestCase {
    private func item(status: MonitorItemStatus = .open) -> MonitorItem {
        MonitorItem(id: "item-1", reportID: "report-1", title: "事项", whyRelevant: "原因",
                    suggestedAction: "行动", deadlineText: nil, deadlineDate: nil, conditions: nil,
                    evidenceQuote: "原文", sourceRefsJSON: "[]", uncertainty: nil,
                    category: .applicable, status: status, relatedItemID: nil,
                    firstSeenDate: "2026-11-19", lastUpdatedDate: "2026-11-19",
                    createdAt: "2026-11-19", updatedAt: "2026-11-19")
    }

    func testResolveDistinguishesLoadingEmptyFailedAndCachedItems() {
        let cases: [(name: String, items: [MonitorItem]?, loadFailed: Bool, expected: MonitorItemsPresentation)] = [
            ("缓存缺失且未失败", nil, false, .loading),
            ("读取成功且为空", [], false, .empty),
            ("读取成功且有事项", [item()], false, .items),
            ("读取失败且无缓存", nil, true, .failed),
            ("读取失败但保留旧缓存", [item()], true, .items),
        ]
        for c in cases {
            XCTAssertEqual(MonitorItemsPresentation.resolve(items: c.items, loadFailed: c.loadFailed), c.expected,
                           "\(c.name) 时应显示 \(c.expected)")
        }
    }
}