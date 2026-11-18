import XCTest
import VoiceOSPlatform

final class AXDriverChecks: XCTestCase {
    func testParseCommandsAppliesRequiredOptionsAndDefaults() throws {
        XCTAssertEqual(try AXCommand.parse(["dump", "--pid", "42"]), .dump(pid: 42, identifierPrefix: nil, json: false))
        XCTAssertEqual(try AXCommand.parse(["dump", "--pid", "42", "--identifier", "nav.", "--json"]), .dump(pid: 42, identifierPrefix: "nav.", json: true))
        XCTAssertEqual(try AXCommand.parse(["click", "--pid", "42", "--identifier", "nav.monitor"]), .click(pid: 42, identifier: "nav.monitor"))
        XCTAssertEqual(try AXCommand.parse(["wait", "--pid", "42", "--identifier", "monitor.runCheck"]), .wait(pid: 42, identifier: "monitor.runCheck", timeout: 5))
        XCTAssertEqual(try AXCommand.parse(["scroll-to", "--pid", "42", "--identifier", "monitor.item", "--max-pages", "3"]), .scrollTo(pid: 42, identifier: "monitor.item", maxPages: 3))
        XCTAssertThrowsError(try AXCommand.parse(["dump", "--identifier", "nav."])) { error in
            XCTAssertTrue(error.localizedDescription.contains("--pid"))
        }
        XCTAssertThrowsError(try AXCommand.parse(["click", "--pid", "42"])) { error in
            XCTAssertTrue(error.localizedDescription.contains("--identifier"))
        }
        XCTAssertThrowsError(try AXCommand.parse(["dump", "--pid", "42", "--unknown", "x"])) { error in
            XCTAssertTrue(error.localizedDescription.contains("未知选项"))
        }
        XCTAssertThrowsError(try AXCommand.parse(["click", "--pid", "42", "--identifier", "x", "--json"])) { error in
            XCTAssertTrue(error.localizedDescription.contains("未知选项"))
        }
    }

    func testElementRecordEncodesAllFields() throws {
        let record = AXElementRecord(role: "AXButton", identifier: "nav.monitor", title: "消息监测", description: "侧栏入口", value: "当前", frame: AXFrame(x: 1, y: 2, w: 3, h: 4), actions: ["AXPress"])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try JSONEncoder().encode(record)) as? [String: Any])
        XCTAssertEqual(object["role"] as? String, "AXButton")
        XCTAssertEqual(object["identifier"] as? String, "nav.monitor")
        XCTAssertEqual(object["title"] as? String, "消息监测")
        XCTAssertEqual(object["description"] as? String, "侧栏入口")
        XCTAssertEqual(object["value"] as? String, "当前")
        XCTAssertEqual(object["actions"] as? [String], ["AXPress"])
        let frame = try XCTUnwrap(object["frame"] as? [String: Any])
        XCTAssertEqual(frame["x"] as? Double, 1)
        XCTAssertEqual(frame["y"] as? Double, 2)
        XCTAssertEqual(frame["w"] as? Double, 3)
        XCTAssertEqual(frame["h"] as? Double, 4)

        let snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: try JSONEncoder().encode(AXSnapshot(elements: [record], truncated: true))) as? [String: Any])
        XCTAssertEqual(snapshot["truncated"] as? Bool, true)
        XCTAssertEqual((snapshot["elements"] as? [Any])?.count, 1)
    }

    func testIdentifierPrefixFilter() {
        let records = [
            AXElementRecord(role: "AXGroup"),
            AXElementRecord(role: "AXButton", identifier: "nav.home"),
            AXElementRecord(role: "AXButton", identifier: "nav.monitor"),
            AXElementRecord(role: "AXButton", identifier: "monitor.runCheck"),
        ]
        XCTAssertEqual(AXRecords.filter(records, identifierPrefix: "nav.").map(\.identifier), ["nav.home", "nav.monitor"])
        XCTAssertEqual(AXRecords.filter(records, identifierPrefix: nil), records)
        XCTAssertEqual(AXRecords.filter(records, identifierPrefix: "monitor.").map(\.identifier), ["monitor.runCheck"])
    }
}
