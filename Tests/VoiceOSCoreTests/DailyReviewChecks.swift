import XCTest
@testable import VoiceOSCore

final class DailyReviewChecks: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-11-14T12:00:00Z")!

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private func action(_ id: String, state: String = "open", kind: String = "task",
                        validity: String = "current") -> ActionRecord {
        ActionRecord(id: id, claimID: "claim-" + id, claimReviewVersion: 1, title: "任务 " + id,
                     kind: kind, intentActor: "user", note: "", state: state, validity: validity,
                     version: 1, autoSend: true, intent: nil, commandID: "test:" + id,
                     createdAt: "2026-11-01T00:00:00Z")
    }

    private func schedule(_ actionID: String, _ due: ReminderDueDate) -> ActionScheduleIntent {
        ActionScheduleIntent(id: "schedule-" + actionID, actionID: actionID, actionVersion: 1, version: 1,
                             due: due, authority: .userCommitment, actor: .user,
                             rawExpression: "测试期限", anchorEventTime: now, anchorTimeZone: "UTC",
                             baseObservationID: nil, baseAuthority: .unknown, baseOperationID: nil,
                             validity: "current", eligibleForPlanning: true)
    }

    private func link(_ actionID: String, _ due: ReminderDueDate) -> ReminderLink {
        ReminderLink(id: "link-" + actionID, actionID: actionID, calendarID: "calendar", state: "linked",
                     externalID: "reminder-" + actionID, remoteTitle: "任务 " + actionID,
                     remoteCompleted: false, lastObservedAt: nil, lastCheckedAt: nil,
                     lastObservationID: "observation-" + actionID, remoteMarkerValid: true,
                     remoteDueDate: due)
    }

    private func day(_ text: String) -> ReminderDueDate {
        .dateOnly(localDate: text, timeZone: nil)
    }

    func testSeparatesTodayOverdueAndRemainingOpen() {
        let actions = [action("overdue"), action("today"), action("readback"), action("later"), action("undated")]
        let schedules = [schedule("overdue", day("2026-11-12")),
                         schedule("today", day("2026-11-14")),
                         schedule("later", day("2026-11-18"))]
        let links = [link("readback", day("2026-11-14"))]
        let review = DailyReview.build(actions: actions, schedules: schedules, links: links,
                                       now: now, calendar: calendar)
        XCTAssertEqual(review.overdue.map(\.action.id), ["overdue"])
        XCTAssertEqual(review.today.map(\.action.id), ["today", "readback"])
        XCTAssertEqual(review.remaining.map(\.action.id), ["later", "undated"])
        XCTAssertEqual(review.remainingCount, 3)
        XCTAssertEqual(review.completedCount, 0)
        XCTAssertEqual(review.dismissedCount, 0)
        XCTAssertFalse(review.isClear)
    }

    func testSortsEachGroupByDueDayThenInputOrder() {
        let actions = [action("today-first"), action("overdue-oldest"), action("today-second"),
                       action("overdue-newer"), action("next-week"), action("in-two-days")]
        let schedules = [schedule("today-first", day("2026-11-14")),
                         schedule("overdue-oldest", day("2026-11-09")),
                         schedule("today-second", day("2026-11-14")),
                         schedule("overdue-newer", day("2026-11-13")),
                         schedule("next-week", day("2026-11-21")),
                         schedule("in-two-days", day("2026-11-16"))]
        let review = DailyReview.build(actions: actions, schedules: schedules, links: [],
                                       now: now, calendar: calendar)
        XCTAssertEqual(review.overdue.map(\.action.id), ["overdue-oldest", "overdue-newer"])
        XCTAssertEqual(review.today.map(\.action.id), ["today-first", "today-second"])
        XCTAssertEqual(review.remaining.map(\.action.id), ["in-two-days", "next-week"])
    }

    func testEmptyListIsClear() {
        let review = DailyReview.build(actions: [], schedules: [], links: [],
                                       now: now, calendar: calendar)
        XCTAssertTrue(review.today.isEmpty)
        XCTAssertTrue(review.overdue.isEmpty)
        XCTAssertTrue(review.remaining.isEmpty)
        XCTAssertEqual(review.remainingCount, 0)
        XCTAssertEqual(review.completedCount, 0)
        XCTAssertEqual(review.dismissedCount, 0)
        XCTAssertTrue(review.isClear)
    }

    func testCompletedAndDismissedStayOutOfOpenGroupsAndCount() {
        let actions = [action("open-today"), action("done-today", state: "completed"),
                       action("dropped-overdue", state: "dismissed"),
                       action("done-later", state: "completed")]
        let schedules = [schedule("open-today", day("2026-11-14")),
                         schedule("done-today", day("2026-11-14")),
                         schedule("dropped-overdue", day("2026-11-13")),
                         schedule("done-later", day("2026-11-20"))]
        let review = DailyReview.build(actions: actions, schedules: schedules, links: [],
                                       now: now, calendar: calendar)
        XCTAssertEqual(review.today.map(\.action.id), ["open-today"])
        XCTAssertTrue(review.overdue.isEmpty)
        XCTAssertTrue(review.remaining.isEmpty)
        XCTAssertEqual(review.completedCount, 1)
        XCTAssertEqual(review.dismissedCount, 1)
        XCTAssertEqual(review.remainingCount, 1)
    }

    func testLocalScheduleWinsOverReminderReadback() {
        let actions = [action("task")]
        let schedules = [schedule("task", day("2026-11-18"))]
        let links = [link("task", day("2026-11-14"))]
        let review = DailyReview.build(actions: actions, schedules: schedules, links: links,
                                       now: now, calendar: calendar)
        XCTAssertTrue(review.today.isEmpty)
        XCTAssertTrue(review.overdue.isEmpty)
        XCTAssertEqual(review.remaining.map(\.action.id), ["task"])
    }

    func testOnlyCurrentTasksEnterTheReview() {
        let actions = [action("opportunity", kind: "opportunity"),
                       action("frozen", validity: "frozen"),
                       action("task")]
        let schedules = [schedule("opportunity", day("2026-11-14")),
                         schedule("frozen", day("2026-11-14")),
                         schedule("task", day("2026-11-14"))]
        let review = DailyReview.build(actions: actions, schedules: schedules, links: [],
                                       now: now, calendar: calendar)
        XCTAssertEqual(review.today.map(\.action.id), ["task"])
        XCTAssertEqual(review.remainingCount, 1)
    }
}
