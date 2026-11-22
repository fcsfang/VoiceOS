import XCTest
@testable import VoiceOSCore

final class MaterialNamingChecks: XCTestCase {
    private let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!

    func testDisplayNameCases() {
        let cases: [(storedName: String, timeZone: TimeZone, expected: String)] = [
            ("行动反馈 · 2026-10-14T12:28:35Z", shanghai, "行动反馈 · 10月14日 20:28"),
            ("我的表达 · 2026-10-14T12:28:35Z", shanghai, "我的表达 · 10月14日 20:28"),
            ("行动反馈 · 2026-10-14T12:28:35.123Z", shanghai, "行动反馈 · 10月14日 20:28"),
            ("我的表达 · 2026-10-14T20:28:35+08:00", shanghai, "我的表达 · 10月14日 20:28"),
            ("行动反馈 · 2026-10-14T12:28:35Z", losAngeles, "行动反馈 · 10月14日 05:28"),
            ("我的表达 · 2026-10-14T23:30:00Z", shanghai, "我的表达 · 10月15日 07:30"),
            ("行动反馈 · 明天再试", shanghai, "行动反馈 · 明天再试"),
            ("购买服务器机架", shanghai, "购买服务器机架"),
            ("行动反馈", shanghai, "行动反馈"),
            ("行动反馈 · 2026-10-14T12:28:35Z 已归档", shanghai, "行动反馈 · 2026-10-14T12:28:35Z 已归档"),
            ("我的口述 · 2026-10-14T12:28:35Z", shanghai, "我的口述 · 10月14日 20:28")
        ]
        for c in cases {
            XCTAssertEqual(MaterialNaming.displayName(c.storedName, timeZone: c.timeZone), c.expected, c.storedName)
        }
    }
}