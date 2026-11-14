import XCTest
@testable import VoiceOSCore

final class BilingualChecks: XCTestCase {
    private func span(_ id: String, _ start: Int, _ end: Int) -> TranscriptSpan {
        TranscriptSpan(id: id, textStart: start, textEnd: end)
    }

    func testAdjacentSpansMergeIntoOneParagraph() {
        let excerpt = Bilingual.paragraphs(from: "第一句。第二句。", spans: [span("a",0,4), span("b",4,8)])
        XCTAssertEqual(excerpt.paragraphs.map(\.text), ["第一句。第二句。"])
        XCTAssertFalse(excerpt.truncated)
    }

    func testSpanBoundaryKeepsParagraphsWithinLimit() {
        let text = String(repeating: "甲", count: 500) + String(repeating: "乙", count: 400)
        let excerpt = Bilingual.paragraphs(from: text, spans: [span("a",0,500), span("b",500,900)])
        XCTAssertEqual(excerpt.paragraphs.map(\.text.count), [500, 400])
        XCTAssertFalse(excerpt.truncated)
    }

    func testOversizedSpanSplitsAt800Characters() {
        let excerpt = Bilingual.paragraphs(from: String(repeating: "文", count: 1700), spans: [span("a",0,1700)])
        XCTAssertEqual(excerpt.paragraphs.map(\.text.count), [800, 800, 100])
        XCTAssertFalse(excerpt.truncated)
    }

    func testSentencePackingWithinALine() {
        let text = (1...10).map { _ in String(repeating: "句", count: 99) + "。" }.joined()
        let excerpt = Bilingual.paragraphs(from: text, spans: [])
        XCTAssertEqual(excerpt.paragraphs.map(\.text.count), [800, 200])
    }

    func testBlankLinesProduceParagraphs() {
        let excerpt = Bilingual.paragraphs(from: "第一段\n\n第二段", spans: [])
        XCTAssertEqual(excerpt.paragraphs.map(\.text), ["第一段", "第二段"])
    }

    func testParagraphCapAt40() {
        let text = (1...50).map { "第\($0)段" }.joined(separator: "\n")
        let excerpt = Bilingual.paragraphs(from: text, spans: [])
        XCTAssertEqual(excerpt.paragraphs.count, 40)
        XCTAssertEqual(excerpt.paragraphs.last?.text, "第40段")
        XCTAssertTrue(excerpt.truncated)
    }

    func testCharacterCapAt6000() {
        let line = String(repeating: "字", count: 800)
        let excerpt = Bilingual.paragraphs(from: Array(repeating: line, count: 10).joined(separator: "\n"), spans: [])
        XCTAssertEqual(excerpt.paragraphs.reduce(0) { $0 + $1.text.unicodeScalars.count }, 6000)
        XCTAssertEqual(excerpt.paragraphs.count, 8)
        XCTAssertEqual(excerpt.paragraphs.last?.text.count, 400)
        XCTAssertTrue(excerpt.truncated)
    }

    func testEmptyMaterial() {
        let excerpt = Bilingual.paragraphs(from: "", spans: [])
        XCTAssertTrue(excerpt.isEmpty)
        XCTAssertFalse(excerpt.truncated)
        XCTAssertEqual(Bilingual.combine("", paragraphCount: 0), [])
    }

    func testPromptCarriesTargetAndNumberedParagraphs() {
        let prompt = Bilingual.requestPrompt(paragraphs: [BilingualParagraph(id: 0, text: "Hello"), BilingualParagraph(id: 1, text: "World")])
        XCTAssertTrue(prompt.contains("中文"))
        XCTAssertTrue(prompt.contains("[1] Hello"))
        XCTAssertTrue(prompt.contains("[2] World"))
    }

    func testCombineNumberedLines() {
        XCTAssertEqual(Bilingual.combine("[1] 译文一\n[2] 译文二", paragraphCount: 2), ["译文一", "译文二"])
    }

    func testCombineKeepsMissingParagraphsNil() {
        XCTAssertEqual(Bilingual.combine("[1] 一\n[3] 三", paragraphCount: 3), ["一", nil, "三"])
    }

    func testCombinePlainLinesOnlyWhenCountMatches() {
        XCTAssertEqual(Bilingual.combine("译文一\n译文二", paragraphCount: 2), ["译文一", "译文二"])
        XCTAssertEqual(Bilingual.combine("译文一", paragraphCount: 2), [nil, nil])
    }

    func testTranslationTextReadsCompletedEnvelope() throws {
        let json = #"{"status":"completed","output":[{"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"[1] 译文"}]}]}"#
        XCTAssertEqual(try Bilingual.translationText(from: Data(json.utf8)), "[1] 译文")
    }

    func testTranslationTextRejectsIncompleteEnvelope() {
        let json = #"{"status":"incomplete","output":[]}"#
        XCTAssertThrowsError(try Bilingual.translationText(from: Data(json.utf8)))
    }
}
