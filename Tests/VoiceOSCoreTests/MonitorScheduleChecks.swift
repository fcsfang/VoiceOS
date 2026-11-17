import XCTest
@testable import VoiceOSCore

final class MonitorScheduleChecks: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }
    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    func testTimerBeforeConfiguredTimeSkips() {
        let decision = MonitorSchedule.decide(trigger: .timer, now: date(2026, 11, 18, 8, 30),
                                              settings: .init(hour: 9, minute: 0),
                                              latestReportDate: "2026-11-17", calendar: calendar)
        XCTAssertFalse(decision.shouldRun)
        XCTAssertTrue(decision.reason.contains("未到"))
    }

    func testTimerAfterConfiguredTimeRunsUntilReportExists() {
        let first = MonitorSchedule.decide(trigger: .timer, now: date(2026, 11, 18, 9, 5),
                                           settings: .init(hour: 9, minute: 0),
                                           latestReportDate: "2026-11-17", calendar: calendar)
        XCTAssertTrue(first.shouldRun, "到达配置时间且今天没有报告时应运行")
        let second = MonitorSchedule.decide(trigger: .activation, now: date(2026, 11, 18, 9, 30),
                                            settings: .init(hour: 9, minute: 0),
                                            latestReportDate: "2026-11-18", calendar: calendar)
        XCTAssertFalse(second.shouldRun, "今天已有报告后自动检查不再运行")
        XCTAssertTrue(second.reason.contains("每天最多一次"))
    }

    func testSameDayFailedReportAlsoBlocksAutomaticRerun() {
        let decision = MonitorSchedule.decide(trigger: .wake, now: date(2026, 11, 18, 15, 0),
                                              settings: .init(hour: 9, minute: 0),
                                              latestReportDate: "2026-11-18", calendar: calendar)
        XCTAssertFalse(decision.shouldRun, "任何状态的今日报告都阻止自动重跑")
    }

    func testLaunchCatchesUpMissedDayBeforeConfiguredTime() {
        let decision = MonitorSchedule.decide(trigger: .launch, now: date(2026, 11, 18, 7, 0),
                                              settings: .init(hour: 9, minute: 0),
                                              latestReportDate: "2026-11-17", calendar: calendar)
        XCTAssertTrue(decision.shouldRun, "上次报告早于今天时启动直接补跑")
        XCTAssertTrue(decision.reason.contains("启动补跑"))
    }

    func testLaunchFirstEverRunsAndSameDayLaunchSkips() {
        let first = MonitorSchedule.decide(trigger: .launch, now: date(2026, 11, 18, 7, 0),
                                           settings: .init(hour: 9, minute: 0),
                                           latestReportDate: nil, calendar: calendar)
        XCTAssertTrue(first.shouldRun)
        let again = MonitorSchedule.decide(trigger: .launch, now: date(2026, 11, 18, 7, 0),
                                           settings: .init(hour: 9, minute: 0),
                                           latestReportDate: "2026-11-18", calendar: calendar)
        XCTAssertFalse(again.shouldRun)
    }

    func testInvalidSettingsNeverRun() {
        let decision = MonitorSchedule.decide(trigger: .timer, now: date(2026, 11, 18, 12, 0),
                                              settings: .init(hour: 25, minute: 0),
                                              latestReportDate: nil, calendar: calendar)
        XCTAssertFalse(decision.shouldRun)
        XCTAssertTrue(decision.reason.contains("时间无效"))
    }
}
