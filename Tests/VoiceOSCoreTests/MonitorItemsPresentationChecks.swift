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

    func test缓存缺失且未失败时显示加载态() {
        XCTAssertEqual(MonitorItemsPresentation.resolve(items: nil, loadFailed: false), .loading,
                       "事项缓存尚未补齐时应显示加载态，不能当作空列表")
    }

    func test读取成功后的空数组才显示空态() {
        XCTAssertEqual(MonitorItemsPresentation.resolve(items: [], loadFailed: false), .empty,
                       "只有读取成功且确实没有事项时才允许显示空态")
        XCTAssertEqual(MonitorItemsPresentation.resolve(items: [item()], loadFailed: false), .items,
                       "读取成功且有条目时显示事项列表")
    }

    func test读取失败显示错误且旧缓存优先() {
        XCTAssertEqual(MonitorItemsPresentation.resolve(items: nil, loadFailed: true), .failed,
                       "读取失败时应显示错误而不是空态")
        XCTAssertEqual(MonitorItemsPresentation.resolve(items: [item()], loadFailed: true), .items,
                       "失败时若已有旧缓存，仍显示缓存事项")
    }
}
