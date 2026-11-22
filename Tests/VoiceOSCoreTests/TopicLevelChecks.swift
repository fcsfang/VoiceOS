import XCTest
@testable import VoiceOSCore

final class TopicLevelChecks: XCTestCase {
    func testClassificationBoundaryTable() {
        let cases: [(materialCount: Int, distinctDays: Int, manual: Bool, expected: TopicLevel)] = [
            (2, 5, false, .clue),
            (3, 3, false, .theme),
            (3, 2, false, .clue),
            (1, 1, true, .theme),
        ]
        for testCase in cases {
            XCTAssertEqual(TopicLevel.classify(materialCount: testCase.materialCount,
                                               distinctDays: testCase.distinctDays,
                                               manual: testCase.manual),
                           testCase.expected,
                           "materials=\(testCase.materialCount) days=\(testCase.distinctDays) manual=\(testCase.manual)")
        }
    }
}