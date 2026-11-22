import XCTest
@testable import VoiceOSCore

final class ReminderDefaultAlertChecks: XCTestCase {
    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func date(_ calendar: Calendar, _ components: DateComponents) -> Date {
        calendar.date(from: components)!
    }

    func testNextDefaultAlertCases() {
        let zone = calendar("Asia/Shanghai")
        let cases: [(due: ReminderDueDate, now: DateComponents, expected: DateComponents?)] = [
            (.dateOnly(localDate: "2026-11-15", timeZone: nil),
             .init(year: 2026, month: 11, day: 15, hour: 8, minute: 30),
             .init(year: 2026, month: 11, day: 15, hour: 9, minute: 0)),
            (.dateOnly(localDate: "2026-11-15", timeZone: nil),
             .init(year: 2026, month: 11, day: 15, hour: 9, minute: 30),
             .init(year: 2026, month: 11, day: 16, hour: 9, minute: 0)),
            (.dateOnly(localDate: "2026-11-15", timeZone: nil),
             .init(year: 2026, month: 11, day: 15, hour: 9, minute: 0),
             .init(year: 2026, month: 11, day: 16, hour: 9, minute: 0)),
            (.dateOnly(localDate: "2026-11-01", timeZone: nil),
             .init(year: 2026, month: 11, day: 15, hour: 10, minute: 30),
             .init(year: 2026, month: 11, day: 16, hour: 9, minute: 0)),
            (.dateOnly(localDate: "2026-11-01", timeZone: nil),
             .init(year: 2026, month: 11, day: 15, hour: 7, minute: 0),
             .init(year: 2026, month: 11, day: 15, hour: 9, minute: 0)),
            (.instant(utc: ReminderFields.timestamp(date(zone, .init(year: 2026, month: 11, day: 15, hour: 14, minute: 0))),
                      timeZone: "Asia/Shanghai"),
             .init(year: 2026, month: 11, day: 15, hour: 8, minute: 0),
             nil),
            (.none,
             .init(year: 2026, month: 11, day: 15, hour: 8, minute: 0),
             nil)
        ]
        for c in cases {
            let now = date(zone, c.now)
            let expected = c.expected.map { date(zone, $0) }
            XCTAssertEqual(ReminderFields.nextDefaultAlert(due: c.due, now: now, calendar: zone), expected)
        }
    }

    func testCalendarZoneChangesTheInstant() {
        let due = ReminderDueDate.dateOnly(localDate: "2026-11-15", timeZone: nil)
        let now = ISO8601DateFormatter().date(from: "2026-11-15T00:00:00Z")!
        let cases: [(zone: String, expected: String)] = [
            ("Asia/Shanghai", "2026-11-15T01:00:00Z"),
            ("America/Los_Angeles", "2026-11-15T17:00:00Z")
        ]
        var instants: [Date] = []
        for c in cases {
            let value = ReminderFields.nextDefaultAlert(due: due, now: now, calendar: calendar(c.zone))!
            XCTAssertEqual(ISO8601DateFormatter().string(from: value), c.expected, c.zone)
            instants.append(value)
        }
        XCTAssertNotEqual(instants[0], instants[1])
    }

    func testWithDefaultAlertCases() {
        let zone = calendar("Asia/Shanghai")
        let due = ReminderDueDate.dateOnly(localDate: "2026-11-15", timeZone: nil)
        let nine = ReminderFields.timestamp(date(zone, .init(year: 2026, month: 11, day: 15, hour: 9, minute: 0)))
        let existing = "2026-11-14T01:00:00.000Z"
        let cases: [(alerts: [String], expected: [String], validates: Bool)] = [
            ([], [nine], true),
            ([existing], [existing], false)
        ]
        let now = date(zone, .init(year: 2026, month: 11, day: 15, hour: 8, minute: 0))
        for c in cases {
            let result = ReminderFields(due: due, alerts: c.alerts).withDefaultAlert(now: now, calendar: zone)
            XCTAssertEqual(result.alerts, c.expected)
            if c.validates { XCTAssertNoThrow(try result.validate()) }
        }
    }

    func testAlertsWithoutDueAreRejected() {
        let fields = ReminderFields(alerts: ["2026-11-15T01:00:00.000Z"])
        XCTAssertThrowsError(try fields.validate()) { error in
            XCTAssertEqual(error.localizedDescription, "通知需要安排日期")
        }
    }
}