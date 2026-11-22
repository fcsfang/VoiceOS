import XCTest
@testable import VoiceOSCore

final class BilingualChecks: XCTestCase {
    private func span(_ id: String, _ start: Int, _ end: Int) -> TranscriptSpan {
        TranscriptSpan(id: id, textStart: start, textEnd: end)
    }

    private func excerpt(_ texts: [String], truncated: Bool) -> BilingualExcerpt {
        BilingualExcerpt(paragraphs: texts.enumerated().map { BilingualParagraph(id: $0.offset, text: $0.element) },
                         truncated: truncated)
    }

    func testParagraphExcerpts() {
        let line = String(repeating: "字", count: 800)
        let sentence = String(repeating: "句", count: 99) + "。"
        let cases: [(text: String, spans: [TranscriptSpan], expected: BilingualExcerpt)] = [
            ("第一句。第二句。", [span("a", 0, 4), span("b", 4, 8)],
             excerpt(["第一句。第二句。"], truncated: false)),
            (String(repeating: "甲", count: 500) + String(repeating: "乙", count: 400),
             [span("a", 0, 500), span("b", 500, 900)],
             excerpt([String(repeating: "甲", count: 500), String(repeating: "乙", count: 400)], truncated: false)),
            (String(repeating: "文", count: 1700), [span("a", 0, 1700)],
             excerpt([String(repeating: "文", count: 800), String(repeating: "文", count: 800),
                      String(repeating: "文", count: 100)], truncated: false)),
            ((1...10).map { _ in sentence }.joined(), [],
             excerpt([(1...8).map { _ in sentence }.joined(), (1...2).map { _ in sentence }.joined()],
                     truncated: false)),
            ("第一段\n\n第二段", [], excerpt(["第一段", "第二段"], truncated: false)),
            ((1...50).map { "第\($0)段" }.joined(separator: "\n"), [],
             excerpt((1...40).map { "第\($0)段" }, truncated: true)),
            (Array(repeating: line, count: 10).joined(separator: "\n"), [],
             excerpt(Array(repeating: line, count: 7) + [String(repeating: "字", count: 400)], truncated: true)),
            ("", [], excerpt([], truncated: false))
        ]
        for c in cases {
            XCTAssertEqual(Bilingual.paragraphs(from: c.text, spans: c.spans), c.expected)
        }
    }

    func testNextBatchCases() {
        let line = String(repeating: "字", count: 800)
        let paragraphText = (1...50).map { "第\($0)段" }.joined(separator: "\n")
        let characterText = Array(repeating: line, count: 10).joined(separator: "\n")
        let cases: [(text: String, firstCount: Int?, consumed: Int?, expected: [String], truncated: Bool)] = [
            (paragraphText, 40, nil, (41...50).map { "第\($0)段" }, false),
            (characterText, nil, 6000,
             [String(repeating: "字", count: 400)] + Array(repeating: line, count: 2), false),
            ("第一段\n\n第二段", nil, nil, [], false)
        ]
        for c in cases {
            let first = Bilingual.paragraphs(from: c.text, spans: [])
            if let count = c.firstCount { XCTAssertEqual(first.paragraphs.count, count) }
            let consumed = first.paragraphs.reduce(0) { $0 + $1.text.unicodeScalars.count }
            if let expected = c.consumed { XCTAssertEqual(consumed, expected) }
            let next = Bilingual.nextBatch(from: c.text, spans: [], consumed: consumed)
            XCTAssertEqual(next.paragraphs.map(\.text), c.expected)
            XCTAssertEqual(next.truncated, c.truncated)
        }
    }

    func testCombineCases() {
        let cases: [(translated: String, count: Int, expected: [String?])] = [
            ("[1] 译文一\n[2] 译文二", 2, ["译文一", "译文二"]),
            ("[1] 一\n[3] 三", 3, [nil, nil, nil]),
            ("[0] 零\n[1] 一", 2, [nil, nil]),
            ("[1] 一\n没有编号的续行", 2, [nil, nil]),
            ("译文一\n译文二", 2, ["译文一", "译文二"]),
            ("译文一", 2, [nil, nil]),
            ("", 0, [])
        ]
        for c in cases {
            XCTAssertEqual(Bilingual.combine(c.translated, paragraphCount: c.count), c.expected)
        }
    }

    func testPromptCarriesTargetAndNumberedParagraphs() {
        let prompt = Bilingual.requestPrompt(paragraphs: [BilingualParagraph(id: 0, text: "Hello"), BilingualParagraph(id: 1, text: "World")])
        XCTAssertTrue(prompt.contains("中文"))
        XCTAssertTrue(prompt.contains("[1] Hello"))
        XCTAssertTrue(prompt.contains("[2] World"))
    }

    func testTranslationTextCases() {
        let completed = #"{"status":"completed","output":[{"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"[1] 译文"}]}]}"#
        let incomplete = #"{"status":"incomplete","output":[]}"#
        XCTAssertEqual(try? Bilingual.translationText(from: Data(completed.utf8)), "[1] 译文")
        XCTAssertNil(try? Bilingual.translationText(from: Data(incomplete.utf8)))
    }
}