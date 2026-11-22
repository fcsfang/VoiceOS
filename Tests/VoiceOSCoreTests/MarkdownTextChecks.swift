import XCTest
@testable import VoiceOSCore

final class MarkdownTextChecks: XCTestCase {
    func testPlainTitleCases() {
        let cases: [(raw: String, expected: String)] = [
            ("# 标题", "标题"),
            ("## 双层", "双层"),
            ("# # 重复", "重复"),
            ("#无空格", "无空格"),
            ("C# 不是标题", "C# 不是标题")
        ]
        for c in cases {
            XCTAssertEqual(MarkdownDocument.plainTitle(c.raw), c.expected, c.raw)
        }
    }

    func testBlocksCases() {
        let cases: [(input: String, expected: [MarkdownBlock])] = [
            ("# 一级\n## 二级\n### 三级", [
                .heading(level: 1, text: "一级"),
                .heading(level: 2, text: "二级"),
                .heading(level: 3, text: "三级")
            ]),
            ("#话题# 不是标题", [.paragraph(text: "#话题# 不是标题")]),
            ("第一段\n继续\n\n第二段", [
                .paragraph(text: "第一段\n继续"),
                .paragraph(text: "第二段")
            ]),
            ("- 一\n  - 二\n* 三", [.list(ordered: false, items: [
                MarkdownListItem(depth: 0, text: "一"),
                MarkdownListItem(depth: 1, text: "二"),
                MarkdownListItem(depth: 0, text: "三")
            ])]),
            ("1. 一\n2. 二", [.list(ordered: true, items: [
                MarkdownListItem(depth: 0, text: "一"),
                MarkdownListItem(depth: 0, text: "二")
            ])]),
            ("- 一\n  续", [.list(ordered: false, items: [
                MarkdownListItem(depth: 0, text: "一 续")
            ])]),
            ("> 引\n> 言", [.quote(text: "引\n言")]),
            ("文字\n---\n下一段", [
                .paragraph(text: "文字"),
                .rule,
                .paragraph(text: "下一段")
            ]),
            ("```\n# 不是标题\n```", [.paragraph(text: "# 不是标题")]),
            ("- 一\n\n> 引\n\n正文", [
                .list(ordered: false, items: [MarkdownListItem(depth: 0, text: "一")]),
                .quote(text: "引"),
                .paragraph(text: "正文")
            ]),
            ("", []),
            ("\n\n", [])
        ]
        for c in cases {
            XCTAssertEqual(MarkdownDocument.blocks(from: c.input), c.expected, c.input)
        }
    }
}