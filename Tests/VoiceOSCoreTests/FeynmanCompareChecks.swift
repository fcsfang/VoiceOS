import XCTest
@testable import VoiceOSCore

final class FeynmanCompareChecks: XCTestCase {
    func testChineseCoverageAndMissedPoints() {
        let feedback = FeynmanCompare.compare(claim: "复盘不是记流水账，而是找出关键判断。", response: "复盘要找出关键判断")
        XCTAssertEqual(feedback.covered, ["复盘", "找出", "出关", "关键", "键判", "判断"])
        XCTAssertEqual(feedback.missed, ["盘不", "不是", "是记", "记流", "流水", "水账"])
        XCTAssertNil(feedback.vague)
    }

    func testEnglishIsCaseInsensitive() {
        let feedback = FeynmanCompare.compare(claim: "Attention Is All You Need", response: "attention is all you need")
        XCTAssertEqual(feedback.covered, ["attention", "is", "all", "you", "need"])
        XCTAssertTrue(feedback.missed.isEmpty)
        XCTAssertNil(feedback.vague)
    }

    func testEmptyResponseReportsMissedPointsAndVague() {
        let feedback = FeynmanCompare.compare(claim: "专注才能深入，复盘才能改进。", response: "  ")
        XCTAssertTrue(feedback.covered.isEmpty)
        XCTAssertEqual(feedback.missed, ["专注", "注才", "才能", "能深", "深入", "入复"])
        XCTAssertNotNil(feedback.vague)
    }

    func testShortResponseTriggersVague() {
        let feedback = FeynmanCompare.compare(claim: "复盘不是记流水账，而是找出关键判断。", response: "复盘")
        XCTAssertEqual(feedback.covered, ["复盘"])
        XCTAssertFalse(feedback.missed.isEmpty)
        XCTAssertNotNil(feedback.vague)
    }

    func testPunctuationDoesNotAffectSegmentation() {
        let punctuated = FeynmanCompare.compare(claim: "读书,很重要。", response: "读书很重要")
        let plain = FeynmanCompare.compare(claim: "读书很重要", response: "读书很重要")
        XCTAssertEqual(punctuated.covered, plain.covered)
        XCTAssertTrue(punctuated.missed.isEmpty)
        XCTAssertTrue(plain.missed.isEmpty)
        let english = FeynmanCompare.compare(claim: "Focus then act", response: "focus, then act!")
        XCTAssertTrue(english.missed.isEmpty)
    }

    func testCoveredPointsCapAtSixInClaimOrder() {
        let text = "持续记录并且定期复盘"
        let feedback = FeynmanCompare.compare(claim: text, response: text)
        XCTAssertEqual(feedback.covered, ["持续", "续记", "记录", "录并", "并且", "且定"])
        XCTAssertTrue(feedback.missed.isEmpty)
        XCTAssertNil(feedback.vague)
    }
}
