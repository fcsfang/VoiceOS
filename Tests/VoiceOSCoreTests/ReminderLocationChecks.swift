import XCTest
import EventKit
import VoiceOSPlatform

final class ReminderLocationChecks: XCTestCase {
    func testArrivalLabel() {
        XCTAssertEqual(ReminderLocationLabel.text(title: "公司", proximity: .enter), "到达 公司 时提醒")
    }
    func testLeaveLabel() {
        XCTAssertEqual(ReminderLocationLabel.text(title: "健身房", proximity: .leave), "离开 健身房 时提醒")
    }
    func testMissingLocationDoesNotProduceLabel() {
        XCTAssertNil(ReminderLocationLabel.text(title: "", proximity: .enter))
        XCTAssertNil(ReminderLocationLabel.text(title: "家", proximity: .none))
    }
    func testTitleIsTrimmed() {
        XCTAssertEqual(ReminderLocationLabel.text(title: " 公园 ", proximity: .enter), "到达 公园 时提醒")
    }
    func testLocationSpecTrimsTitle() {
        XCTAssertEqual(ReminderLocationSpec(title: " 公司 ", proximity: .enter)?.title, "公司")
        XCTAssertEqual(ReminderLocationSpec(title: " 公司 ", proximity: .enter)?.proximity, .enter)
    }
    func testLocationSpecRejectsBlankTitle() {
        XCTAssertNil(ReminderLocationSpec(title: "", proximity: .enter))
        XCTAssertNil(ReminderLocationSpec(title: "   ", proximity: .enter))
    }
    func testLocationSpecAccepts120Characters() {
        XCTAssertNotNil(ReminderLocationSpec(title: String(repeating: "地", count: 120), proximity: .enter))
    }
    func testLocationSpecRejectsLongerThan120Characters() {
        XCTAssertNil(ReminderLocationSpec(title: String(repeating: "地", count: 121), proximity: .enter))
    }
    func testLocationSpecRejectsNoProximity() {
        XCTAssertNil(ReminderLocationSpec(title: "家", proximity: .none))
    }
    func testStructuredLocationHasTitleAndNoGeolocation() {
        let location = ReminderLocationSpec(title: " 公司 ", proximity: .enter)?.structuredLocation
        XCTAssertEqual(location?.title, "公司")
        XCTAssertNil(location?.geoLocation)
    }
    func testAlarmCarriesStructuredLocationAndProximity() {
        let alarm = ReminderLocationSpec(title: "健身房", proximity: .leave)?.alarm
        XCTAssertEqual(alarm?.proximity, .leave)
        XCTAssertEqual(alarm?.structuredLocation?.title, "健身房")
        XCTAssertNil(alarm?.absoluteDate)
    }
}
