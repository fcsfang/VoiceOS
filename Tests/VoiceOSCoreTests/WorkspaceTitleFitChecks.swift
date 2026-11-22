import XCTest
@testable import VoiceOSCore

final class WorkspaceTitleFitChecks: XCTestCase {
    private struct LeadingLinkCase {
        let raw: String
        let link: String?
        let rest: String?
    }

    func testPresentCases() {
        let cases: [(raw: String, expected: WorkspaceTitleFit.Presentation)] = [
            ("https://github.com/Adkid-Zephyr/anti-defensive-writing-Skill",
             .init(title: "anti-defensive-writing-Skill", source: "github.com/Adkid-Zephyr")),
            ("https://zh.wikipedia.org/wiki/%E5%AD%A6%E4%B9%A0",
             .init(title: "学习", source: "zh.wikipedia.org/wiki")),
            ("https://www.example.com", .init(title: "example.com")),
            ("## 晚间安排", .init(title: "晚间安排")),
            ("了解 a16z 及其可能的播客订阅方式", .init(title: "了解 a16z 及其可能的播客订阅方式")),
            ("https://www.youtube.com/watch?v=dQw4w9WgXcQ", .init(title: "youtube.com")),
            ("https://mp.weixin.qq.com/s?__biz=MjM5NQ==", .init(title: "mp.weixin.qq.com")),
            ("https://www.example.com/", .init(title: "example.com"))
        ]
        for c in cases {
            XCTAssertEqual(WorkspaceTitleFit.present(c.raw), c.expected, c.raw)
        }
    }

    func testSplitLeadingLinkCases() {
        let cases: [LeadingLinkCase] = [
            .init(raw: "https://github.com/Adkid-Zephyr/anti-defensive-writing-Skill 学术写作 skill，值得读",
                  link: "https://github.com/Adkid-Zephyr/anti-defensive-writing-Skill",
                  rest: "学术写作 skill，值得读"),
            .init(raw: "只是普通的一句话", link: nil, rest: nil),
            .init(raw: "https://example.com", link: nil, rest: nil)
        ]
        for c in cases {
            let split = WorkspaceTitleFit.splitLeadingLink(c.raw)
            XCTAssertEqual(split?.link, c.link, c.raw)
            XCTAssertEqual(split?.rest, c.rest, c.raw)
        }
    }
}