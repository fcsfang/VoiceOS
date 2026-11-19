import XCTest
@testable import VoiceOSCore

final class RecordingInboxScanPacingChecks: XCTestCase {
    func testConfirmationBacksOffFromOneToThirtySeconds() {
        let unstable = RecordingInboxScanPacing.FollowUp(unstable: true)
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(RecordingInboxScanPacing.delay(for: unstable, after: 0, now: now), 1)
        XCTAssertEqual(RecordingInboxScanPacing.delay(for: unstable, after: 16, now: now), 30)
        XCTAssertEqual(RecordingInboxScanPacing.delay(for: unstable, after: 30, now: now), 30)
    }

    func testBlockedWorkKeepsTenSecondRetry() {
        let blocked = RecordingInboxScanPacing.FollowUp(blocked: true)
        XCTAssertEqual(RecordingInboxScanPacing.delay(for: blocked, after: 4, now: Date()), 10)
    }

    func testScheduledRetryWakesWhenDueAndSettledInboxHasNoDelay() {
        let now = Date(timeIntervalSince1970: 5_000)
        let retry = RecordingInboxScanPacing.FollowUp(nextAttempt: now.addingTimeInterval(60))
        XCTAssertEqual(RecordingInboxScanPacing.delay(for: retry, after: 0, now: now), 60)
        XCTAssertNil(RecordingInboxScanPacing.delay(for: .init(), after: 0, now: now))
        let overdue = RecordingInboxScanPacing.FollowUp(nextAttempt: now.addingTimeInterval(-1))
        XCTAssertNil(RecordingInboxScanPacing.delay(for: overdue, after: 0, now: now))
    }

    func testRetryWakeArmsOnlyWhenSoonerThanPendingScan() {
        let now = Date(timeIntervalSince1970: 8_000)
        let due = now.addingTimeInterval(60)
        XCTAssertEqual(RecordingInboxScanPacing.retryWakeDelay(nextAttempt: due, pendingScanDelay: nil, now: now), 60)
        XCTAssertEqual(RecordingInboxScanPacing.retryWakeDelay(nextAttempt: due, pendingScanDelay: 120, now: now), 60)
        XCTAssertNil(RecordingInboxScanPacing.retryWakeDelay(nextAttempt: due, pendingScanDelay: 10, now: now))
        XCTAssertNil(RecordingInboxScanPacing.retryWakeDelay(nextAttempt: nil, pendingScanDelay: nil, now: now))
        XCTAssertNil(RecordingInboxScanPacing.retryWakeDelay(nextAttempt: now.addingTimeInterval(-60), pendingScanDelay: nil, now: now))
    }
}
