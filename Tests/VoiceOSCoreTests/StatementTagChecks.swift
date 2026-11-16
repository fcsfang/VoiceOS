import XCTest
@testable import VoiceOSCore

final class StatementTagChecks: XCTestCase {
    func testSplitsKnownPrefixTags() {
        XCTAssertEqual(StatementTagParser.split("【问题】意识与身体有什么联系"), StatementTagged(tag: .question, text: "意识与身体有什么联系"))
        XCTAssertEqual(StatementTagParser.split("【长期目标】每天阅读"), StatementTagged(tag: .goal, text: "每天阅读"))
        XCTAssertEqual(StatementTagParser.split("【录音中活动】继续讲解"), StatementTagged(tag: .recordingActivity, text: "继续讲解"))
    }

    func testMovesReviewSuffixIntoTag() {
        XCTAssertEqual(StatementTagParser.split("核对这条理解（待核对）"), StatementTagged(tag: .review, text: "核对这条理解"))
        XCTAssertEqual(StatementTagParser.split("【问题】这条成立吗(待核对)"), StatementTagged(tag: .question, text: "这条成立吗"))
    }

    func testLeavesPlainTextAlone() {
        XCTAssertEqual(StatementTagParser.split("普通陈述"), StatementTagged(tag: nil, text: "普通陈述"))
    }
}
