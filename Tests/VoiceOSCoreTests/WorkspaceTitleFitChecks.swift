import XCTest
@testable import VoiceOSCore

final class WorkspaceTitleFitChecks: XCTestCase {
    func testRepositoryLinkSplitsIntoNameAndOwner() {
        let fit = WorkspaceTitleFit.present("https://github.com/Adkid-Zephyr/anti-defensive-writing-Skill")
        XCTAssertEqual(fit.title, "anti-defensive-writing-Skill")
        XCTAssertEqual(fit.source, "github.com/Adkid-Zephyr")
    }

    func testPercentEncodedPathDecodes() {
        let fit = WorkspaceTitleFit.present("https://zh.wikipedia.org/wiki/%E5%AD%A6%E4%B9%A0")
        XCTAssertEqual(fit.title, "学习")
        XCTAssertEqual(fit.source, "zh.wikipedia.org/wiki")
    }

    func testBareHostStaysOneLine() {
        let fit = WorkspaceTitleFit.present("https://www.example.com")
        XCTAssertEqual(fit.title, "example.com")
        XCTAssertNil(fit.source)
    }

    func testPlainTitleAndMarkdownHeadingPassThrough() {
        XCTAssertEqual(WorkspaceTitleFit.present("## 晚间安排"), .init(title: "晚间安排"))
        XCTAssertEqual(WorkspaceTitleFit.present("了解 a16z 及其可能的播客订阅方式"),
                       .init(title: "了解 a16z 及其可能的播客订阅方式"))
    }
}