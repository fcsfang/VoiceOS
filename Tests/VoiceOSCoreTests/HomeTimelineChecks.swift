import XCTest
@testable import VoiceOSCore

final class HomeTimelineChecks: XCTestCase {
    func testParseDelegatesTagSemanticsToStatementTagParser() {
        XCTAssertEqual(RecentContentIndex.parse("【观点】完成比完美更重要")?.kind, .insight)
        XCTAssertEqual(RecentContentIndex.parse("【长期目标】每周复盘")?.kind, .goal)
        XCTAssertEqual(RecentContentIndex.parse("【问题】意识与身体有什么联系")?.kind, .note)
        XCTAssertEqual(RecentContentIndex.parse("【想法】周末去看看")?.kind, .note)
        XCTAssertEqual(RecentContentIndex.parse("【问题】意识与身体有什么联系")?.statement, "意识与身体有什么联系")
        XCTAssertNil(RecentContentIndex.parse("【待核对】核对这条理解"))
        XCTAssertNil(RecentContentIndex.parse("核对这条理解（待核对）"))
        XCTAssertNil(RecentContentIndex.parse("【问题】这条成立吗(待核对)"))
        XCTAssertNil(RecentContentIndex.parse("【录音中活动】继续讲解"))
    }

    func testParseKeepsAnnotationAndTrailingPunctuationRules() {
        XCTAssertEqual(RecentContentIndex.parse("晚饭后散步；说明：这是补充")?.statement, "晚饭后散步")
        XCTAssertEqual(RecentContentIndex.parse("随手记下的想法；")?.statement, "随手记下的想法")
        XCTAssertEqual(RecentContentIndex.parse("随手记下的想法；")?.kind, .note)
        XCTAssertNil(RecentContentIndex.parse("【观点】说明：补充"))
        XCTAssertNil(RecentContentIndex.parse("  ； "))
    }

    func testUnknownBracketTextSurvives() {
        XCTAssertEqual(RecentContentIndex.parse("【未知】保留原样")?.statement, "【未知】保留原样")
        XCTAssertEqual(RecentContentIndex.parse("【未知】保留原样")?.kind, .note)
    }
}
