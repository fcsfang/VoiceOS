import XCTest
@testable import VoiceOSCore

final class MaterialNamingChecks: XCTestCase {
    private let shanghai = TimeZone(identifier: "Asia/Shanghai")!

    func testBothPrefixesRenderInShanghaiTime() {
        XCTAssertEqual(MaterialNaming.displayName("行动反馈 · 2026-10-14T12:28:35Z", timeZone: shanghai), "行动反馈 · 10月14日 20:28")
        XCTAssertEqual(MaterialNaming.displayName("我的表达 · 2026-10-14T12:28:35Z", timeZone: shanghai), "我的表达 · 10月14日 20:28")
    }

    func testMillisecondsAndExplicitOffsetParse() {
        XCTAssertEqual(MaterialNaming.displayName("行动反馈 · 2026-10-14T12:28:35.123Z", timeZone: shanghai), "行动反馈 · 10月14日 20:28")
        XCTAssertEqual(MaterialNaming.displayName("我的表达 · 2026-10-14T20:28:35+08:00", timeZone: shanghai), "我的表达 · 10月14日 20:28")
    }

    func testExplicitTimeZoneConversion() {
        let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
        XCTAssertEqual(MaterialNaming.displayName("行动反馈 · 2026-10-14T12:28:35Z", timeZone: losAngeles), "行动反馈 · 10月14日 05:28")
    }

    func testLocalDateCanDifferFromUTCDate() {
        XCTAssertEqual(MaterialNaming.displayName("我的表达 · 2026-10-14T23:30:00Z", timeZone: shanghai), "我的表达 · 10月15日 07:30")
    }

    func testUnparseableSuffixStaysUnchanged() {
        XCTAssertEqual(MaterialNaming.displayName("行动反馈 · 明天再试", timeZone: shanghai), "行动反馈 · 明天再试")
    }

    func testOrdinaryNameStaysUnchanged() {
        XCTAssertEqual(MaterialNaming.displayName("购买服务器机架", timeZone: shanghai), "购买服务器机架")
    }

    func testBarePrefixWithoutTimestampStaysUnchanged() {
        XCTAssertEqual(MaterialNaming.displayName("行动反馈", timeZone: shanghai), "行动反馈")
    }

    func testTimestampFollowedByMoreTextStaysUnchanged() {
        XCTAssertEqual(MaterialNaming.displayName("行动反馈 · 2026-10-14T12:28:35Z 已归档", timeZone: shanghai), "行动反馈 · 2026-10-14T12:28:35Z 已归档")
    }
}