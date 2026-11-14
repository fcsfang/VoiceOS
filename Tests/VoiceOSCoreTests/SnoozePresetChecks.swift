import XCTest
@testable import VoiceOSCore

final class SnoozePresetChecks: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    func testPresetTitles() {
        XCTAssertEqual(SnoozePreset.allCases.map(\.title), ["今晚", "明天", "下周"])
    }

    func testTonightBeforeEightUsesSameDayEight() {
        let now = date(2026, 11, 14, 12, 30)
        XCTAssertEqual(SnoozePreset.tonight.dueDate(now: now, calendar: calendar), date(2026, 11, 14, 20, 0))
    }

    func testTonightAtEightMovesOneHourLater() {
        let now = date(2026, 11, 14, 20, 0)
        XCTAssertEqual(SnoozePreset.tonight.dueDate(now: now, calendar: calendar), date(2026, 11, 14, 21, 0))
    }

    func testTonightAfterEightCrossesMidnight() {
        let now = date(2026, 11, 14, 23, 30)
        XCTAssertEqual(SnoozePreset.tonight.dueDate(now: now, calendar: calendar), date(2026, 11, 15, 0, 30))
    }

    func testTomorrowUsesNextDayNineAcrossMidnight() {
        let now = date(2026, 11, 14, 23, 50)
        XCTAssertEqual(SnoozePreset.tomorrow.dueDate(now: now, calendar: calendar), date(2026, 11, 15, 9, 0))
    }

    func testTomorrowUsesNextDayNineAfterMidnight() {
        let now = date(2026, 11, 14, 0, 10)
        XCTAssertEqual(SnoozePreset.tomorrow.dueDate(now: now, calendar: calendar), date(2026, 11, 15, 9, 0))
    }

    func testNextWeekOnMondayAddsSevenDays() {
        let now = date(2026, 11, 16, 10, 0)
        XCTAssertEqual(SnoozePreset.nextWeek.dueDate(now: now, calendar: calendar), date(2026, 11, 23, 9, 0))
    }

    func testNextWeekOnSaturdayUsesUpcomingMonday() {
        let now = date(2026, 11, 14, 10, 0)
        XCTAssertEqual(SnoozePreset.nextWeek.dueDate(now: now, calendar: calendar), date(2026, 11, 16, 9, 0))
    }

    func testNextWeekOnSundayUsesTomorrowMonday() {
        let now = date(2026, 11, 15, 22, 0)
        XCTAssertEqual(SnoozePreset.nextWeek.dueDate(now: now, calendar: calendar), date(2026, 11, 16, 9, 0))
    }
}
