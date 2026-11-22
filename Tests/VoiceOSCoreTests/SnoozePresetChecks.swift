import XCTest
@testable import VoiceOSCore

final class SnoozePresetChecks: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func date(_ components: DateComponents) -> Date {
        calendar.date(from: components)!
    }

    func testPresetTitles() {
        XCTAssertEqual(SnoozePreset.allCases.map(\.title), ["今晚", "明天", "下周"])
    }

    func testDueDates() {
        let cases: [(preset: SnoozePreset, now: DateComponents, expected: DateComponents)] = [
            (.tonight,
             .init(year: 2026, month: 11, day: 14, hour: 12, minute: 30),
             .init(year: 2026, month: 11, day: 14, hour: 20, minute: 0)),
            (.tonight,
             .init(year: 2026, month: 11, day: 14, hour: 20, minute: 0),
             .init(year: 2026, month: 11, day: 14, hour: 21, minute: 0)),
            (.tonight,
             .init(year: 2026, month: 11, day: 14, hour: 23, minute: 30),
             .init(year: 2026, month: 11, day: 15, hour: 0, minute: 30)),
            (.tomorrow,
             .init(year: 2026, month: 11, day: 14, hour: 23, minute: 50),
             .init(year: 2026, month: 11, day: 15, hour: 9, minute: 0)),
            (.tomorrow,
             .init(year: 2026, month: 11, day: 14, hour: 0, minute: 10),
             .init(year: 2026, month: 11, day: 15, hour: 9, minute: 0)),
            (.nextWeek,
             .init(year: 2026, month: 11, day: 16, hour: 10, minute: 0),
             .init(year: 2026, month: 11, day: 23, hour: 9, minute: 0)),
            (.nextWeek,
             .init(year: 2026, month: 11, day: 14, hour: 10, minute: 0),
             .init(year: 2026, month: 11, day: 16, hour: 9, minute: 0)),
            (.nextWeek,
             .init(year: 2026, month: 11, day: 15, hour: 22, minute: 0),
             .init(year: 2026, month: 11, day: 16, hour: 9, minute: 0))
        ]
        for c in cases {
            XCTAssertEqual(c.preset.dueDate(now: date(c.now), calendar: calendar), date(c.expected))
        }
    }
}