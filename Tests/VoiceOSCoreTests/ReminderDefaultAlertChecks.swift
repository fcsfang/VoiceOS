import XCTest
@testable import VoiceOSCore

final class ReminderDefaultAlertChecks: XCTestCase {
    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func date(_ calendar: Calendar, _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    func testBeforeNineUsesSameDay() {
        let zone = calendar("Asia/Shanghai")
        let due = ReminderDueDate.dateOnly(localDate: "2026-11-15", timeZone: nil)
        XCTAssertEqual(ReminderFields.nextDefaultAlert(due: due, now: date(zone, 2026, 11, 15, 8, 30), calendar: zone), date(zone, 2026, 11, 15, 9, 0))
    }

    func testAfterNineUsesNextDay() {
        let zone = calendar("Asia/Shanghai")
        let due = ReminderDueDate.dateOnly(localDate: "2026-11-15", timeZone: nil)
        XCTAssertEqual(ReminderFields.nextDefaultAlert(due: due, now: date(zone, 2026, 11, 15, 9, 30), calendar: zone), date(zone, 2026, 11, 16, 9, 0))
    }

    func testExactlyNineUsesNextDay() {
        let zone = calendar("Asia/Shanghai")
        let due = ReminderDueDate.dateOnly(localDate: "2026-11-15", timeZone: nil)
        XCTAssertEqual(ReminderFields.nextDefaultAlert(due: due, now: date(zone, 2026, 11, 15, 9, 0), calendar: zone), date(zone, 2026, 11, 16, 9, 0))
    }

    func testCalendarZoneChangesTheInstant() {
        let due = ReminderDueDate.dateOnly(localDate: "2026-11-15", timeZone: nil)
        let now = ISO8601DateFormatter().date(from: "2026-11-15T00:00:00Z")!
        let shanghai = ReminderFields.nextDefaultAlert(due: due, now: now, calendar: calendar("Asia/Shanghai"))!
        let losAngeles = ReminderFields.nextDefaultAlert(due: due, now: now, calendar: calendar("America/Los_Angeles"))!
        XCTAssertEqual(ISO8601DateFormatter().string(from: shanghai), "2026-11-15T01:00:00Z")
        XCTAssertEqual(ISO8601DateFormatter().string(from: losAngeles), "2026-11-15T17:00:00Z")
        XCTAssertNotEqual(shanghai, losAngeles)
    }

    func testDateOnlyWithoutAlertsAddsNine() {
        let zone = calendar("Asia/Shanghai")
        let fields = ReminderFields(due: .dateOnly(localDate: "2026-11-15", timeZone: nil))
        let result = fields.withDefaultAlert(now: date(zone, 2026, 11, 15, 8, 0), calendar: zone)
        XCTAssertEqual(result.alerts, [ReminderFields.timestamp(date(zone, 2026, 11, 15, 9, 0))])
        XCTAssertNoThrow(try result.validate())
    }

    func testExistingAlertsAreKept() {
        let zone = calendar("Asia/Shanghai")
        let fields = ReminderFields(due: .dateOnly(localDate: "2026-11-15", timeZone: nil), alerts: ["2026-11-14T01:00:00.000Z"])
        XCTAssertEqual(fields.withDefaultAlert(now: date(zone, 2026, 11, 15, 8, 0), calendar: zone), fields)
    }

    func testTimedAndEmptyDueGetNoDefault() {
        let zone = calendar("Asia/Shanghai")
        let now = date(zone, 2026, 11, 15, 8, 0)
        XCTAssertNil(ReminderFields.nextDefaultAlert(due: .instant(utc: ReminderFields.timestamp(date(zone, 2026, 11, 15, 14, 0)), timeZone: "Asia/Shanghai"), now: now, calendar: zone))
        XCTAssertNil(ReminderFields.nextDefaultAlert(due: .none, now: now, calendar: zone))
    }
}
