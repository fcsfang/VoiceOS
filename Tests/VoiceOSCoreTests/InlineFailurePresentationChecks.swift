import XCTest
@testable import VoiceOSCore

final class InlineFailurePresentationChecks: XCTestCase {
    func testMessageNamesTheFailedOperationBeforeTheReason() {
        XCTAssertEqual(
            InlineFailurePresentation.message(operation: "归档", reason: "材料尚未保存完成，请完成导入后再管理"),
            "归档失败：材料尚未保存完成，请完成导入后再管理"
        )
    }

    func testMessageKeepsOneShortLineAndFallsBackWhenReasonIsEmpty() {
        let message = InlineFailurePresentation.message(operation: "移入回收站", reason: String(repeating: "原因", count: 40) + "\n第二行")
        XCTAssertTrue(message.hasPrefix("移入回收站失败："), message)
        XCTAssertFalse(message.contains("第二行"), message)
        XCTAssertLessThanOrEqual(message.count, "移入回收站失败：".count + 61, message)
        XCTAssertEqual(InlineFailurePresentation.message(operation: "标记完成", reason: "  \n"), "标记完成失败：请重试。")
        XCTAssertEqual(InlineFailurePresentation.message(operation: "标记完成", reason: nil), "标记完成失败：请重试。")
    }
}
