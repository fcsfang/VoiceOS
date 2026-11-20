import XCTest
@testable import VoiceOSCore

final class TopicLevelChecks: XCTestCase {
    func testTwoMaterialsAcrossFiveDaysStaysClue() {
        XCTAssertEqual(TopicLevel.classify(materialCount: 2, distinctDays: 5, manual: false), .clue)
    }

    func testThreeMaterialsAcrossThreeDaysIsTheme() {
        XCTAssertEqual(TopicLevel.classify(materialCount: 3, distinctDays: 3, manual: false), .theme)
    }

    func testThreeMaterialsInTwoDaysStaysClue() {
        XCTAssertEqual(TopicLevel.classify(materialCount: 3, distinctDays: 2, manual: false), .clue)
    }

    func testManualTopicIsThemeRegardlessOfMaterials() {
        XCTAssertEqual(TopicLevel.classify(materialCount: 1, distinctDays: 1, manual: true), .theme)
    }
}