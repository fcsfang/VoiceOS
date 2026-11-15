import XCTest
@testable import VoiceOSCore

final class MarkdownTextChecks: XCTestCase {
    func testPlainTitleDropsHeadingMarkers() {
        XCTAssertEqual(MarkdownDocument.plainTitle("# 标题"), "标题")
        XCTAssertEqual(MarkdownDocument.plainTitle("## 双层"), "双层")
        XCTAssertEqual(MarkdownDocument.plainTitle("# # 重复"), "重复")
        XCTAssertEqual(MarkdownDocument.plainTitle("#无空格"), "无空格")
        XCTAssertEqual(MarkdownDocument.plainTitle("C# 不是标题"), "C# 不是标题")
    }

    func testHeadingsCarryTheirLevelAndLoseTheMarker() {
        let blocks = MarkdownDocument.blocks(from: "# 一级\n## 二级\n### 三级")
        XCTAssertEqual(blocks, [
            .heading(level: 1, text: "一级"),
            .heading(level: 2, text: "二级"),
            .heading(level: 3, text: "三级")
        ])
    }

    func testHashtagWithoutSpaceStaysBody() {
        XCTAssertEqual(MarkdownDocument.blocks(from: "#话题# 不是标题"), [.paragraph(text: "#话题# 不是标题")])
    }

    func testConsecutiveLinesFormOneParagraph() {
        XCTAssertEqual(MarkdownDocument.blocks(from: "第一段\n继续\n\n第二段"), [
            .paragraph(text: "第一段\n继续"),
            .paragraph(text: "第二段")
        ])
    }

    func testUnorderedListKeepsDepthAndDropsMarkers() {
        let blocks = MarkdownDocument.blocks(from: "- 一\n  - 二\n* 三")
        XCTAssertEqual(blocks, [.list(ordered: false, items: [
            MarkdownListItem(depth: 0, text: "一"),
            MarkdownListItem(depth: 1, text: "二"),
            MarkdownListItem(depth: 0, text: "三")
        ])])
    }

    func testOrderedListNumbersAreDroppedAndTheListStaysOrdered() {
        XCTAssertEqual(MarkdownDocument.blocks(from: "1. 一\n2. 二"), [.list(ordered: true, items: [
            MarkdownListItem(depth: 0, text: "一"),
            MarkdownListItem(depth: 0, text: "二")
        ])])
    }

    func testIndentedLineContinuesTheCurrentListItem() {
        XCTAssertEqual(MarkdownDocument.blocks(from: "- 一\n  续"), [.list(ordered: false, items: [
            MarkdownListItem(depth: 0, text: "一 续")
        ])])
    }

    func testQuoteLinesMergeAndDropTheMarker() {
        XCTAssertEqual(MarkdownDocument.blocks(from: "> 引\n> 言"), [.quote(text: "引\n言")])
    }

    func testRuleSeparatesBlocks() {
        XCTAssertEqual(MarkdownDocument.blocks(from: "文字\n---\n下一段"), [
            .paragraph(text: "文字"),
            .rule,
            .paragraph(text: "下一段")
        ])
    }

    func testFenceMarkersDisappearAndContentStaysBody() {
        XCTAssertEqual(MarkdownDocument.blocks(from: "```\n# 不是标题\n```"), [.paragraph(text: "# 不是标题")])
    }

    func testBlankLinesEndListsAndQuotes() {
        XCTAssertEqual(MarkdownDocument.blocks(from: "- 一\n\n> 引\n\n正文"), [
            .list(ordered: false, items: [MarkdownListItem(depth: 0, text: "一")]),
            .quote(text: "引"),
            .paragraph(text: "正文")
        ])
    }

    func testEmptyTextProducesNoBlocks() {
        XCTAssertEqual(MarkdownDocument.blocks(from: ""), [])
        XCTAssertEqual(MarkdownDocument.blocks(from: "\n\n"), [])
    }
}
