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
}
