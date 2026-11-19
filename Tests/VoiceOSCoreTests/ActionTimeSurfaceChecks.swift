import XCTest
@testable import VoiceOSCore

final class ActionTimeSurfaceChecks: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-11-19T12:00:00Z")!

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private func action(_ id: String) -> ActionRecord {
        ActionRecord(id: id, claimID: "claim-" + id, claimReviewVersion: 1, title: "任务 " + id,
                     kind: "task", intentActor: "user", note: "", state: "open", validity: "current",
                     version: 1, autoSend: true, intent: nil, commandID: "test:" + id,
                     createdAt: "2026-11-01T00:00:00Z", parentID: nil)
    }

    private func link(_ actionID: String, state: String, due: ReminderDueDate,
                      observedAt: String) -> ReminderLink {
        ReminderLink(id: "link-" + actionID + "-" + state, actionID: actionID, calendarID: "calendar",
                     state: state, externalID: "reminder-" + actionID, remoteTitle: "任务 " + actionID,
                     remoteCompleted: false, lastObservedAt: observedAt, lastCheckedAt: observedAt,
                     lastObservationID: "observation-" + actionID, remoteMarkerValid: true,
                     remoteDueDate: due)
    }

    private func day(_ text: String) -> ReminderDueDate { .dateOnly(localDate: text, timeZone: nil) }

    func testConflictDueSortsIntoOverdueGroup() {
        let links = [link("conflict", state: "conflict", due: day("2026-11-18"),
                          observedAt: "2026-11-18T09:00:00Z")]
        let surface = ActionTimeSurface.build(actions: [action("conflict")], schedules: [],
                                              links: links, now: now, calendar: calendar)
        XCTAssertEqual(surface.today.map(\.action.id), ["conflict"], "冲突链路的11月18日到期应进入逾期组")
        XCTAssertEqual(surface.today.first?.isOverdue, true, "11月18日早于今天，应标记为逾期")
        XCTAssertTrue(surface.anytime.isEmpty, "不应再留在随时尾部")
    }

    func testMissingDueJoinsItsGroup() {
        let links = [link("missing", state: "missing", due: day("2026-11-20"),
                          observedAt: "2026-11-18T09:00:00Z")]
        let surface = ActionTimeSurface.build(actions: [action("missing")], schedules: [],
                                              links: links, now: now, calendar: calendar)
        XCTAssertEqual(surface.soon.map(\.action.id), ["missing"], "缺失链路的11月20日到期应进入即将组")
        XCTAssertEqual(surface.soon.first?.isOverdue, false, "明天的到期不算逾期")
        XCTAssertTrue(surface.today.isEmpty, "明天的到期不进今天组")
        XCTAssertTrue(surface.anytime.isEmpty, "有日期的任务不进随时组")
    }

    func testNewestObservationWinsAndUnknownDoesNotCount() {
        let links = [
            link("task", state: "linked", due: day("2026-11-17"), observedAt: "2026-11-10T09:00:00Z"),
            link("task", state: "conflict", due: day("2026-11-20"), observedAt: "2026-11-18T09:00:00Z"),
            link("task", state: "unknown", due: day("2026-11-01"), observedAt: "2026-11-19T09:00:00Z"),
        ]
        let surface = ActionTimeSurface.build(actions: [action("task")], schedules: [],
                                              links: links, now: now, calendar: calendar)
        XCTAssertEqual(surface.soon.map(\.action.id), ["task"], "较新的冲突观察应取代较旧的已写入观察")
        XCTAssertTrue(surface.today.isEmpty, "unknown 链路不参与到期选择")
    }
}