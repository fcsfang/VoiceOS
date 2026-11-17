import XCTest
@testable import VoiceOSCore

final class WeeklyReviewSummaryChecks: XCTestCase {
    func testZeroCountsArePlainText() {
        let links = WeeklyReviewSummaryLinks(weekCompleted: 0, pendingOutcomes: 0, stalledGoals: 0, unclarifiedTasks: 0)
        XCTAssertFalse(links.completed)
        XCTAssertFalse(links.pendingOutcome)
        XCTAssertFalse(links.stalled)
        XCTAssertFalse(links.unclarified)
    }

    func testNonEmptySectionsAreLinks() {
        let links = WeeklyReviewSummaryLinks(weekCompleted: 2, pendingOutcomes: 0, stalledGoals: 1, unclarifiedTasks: 3)
        XCTAssertTrue(links.completed)
        XCTAssertFalse(links.pendingOutcome)
        XCTAssertTrue(links.stalled)
        XCTAssertTrue(links.unclarified)
    }

    func testPendingOutcomeNeedsRenderedCompletedSection() {
        let noCompletions = WeeklyReviewSummaryLinks(weekCompleted: 0, pendingOutcomes: 3, stalledGoals: 0, unclarifiedTasks: 0)
        XCTAssertFalse(noCompletions.pendingOutcome)
        let withCompletions = WeeklyReviewSummaryLinks(weekCompleted: 1, pendingOutcomes: 3, stalledGoals: 0, unclarifiedTasks: 0)
        XCTAssertTrue(withCompletions.pendingOutcome)
    }
}
