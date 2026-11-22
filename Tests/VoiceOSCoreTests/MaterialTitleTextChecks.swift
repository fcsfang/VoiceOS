import XCTest
@testable import VoiceOSCore

final class MaterialTitleTextChecks: XCTestCase {
    private func source(id: String, transcript: String?, presentation: RecordingPresentation?) -> SourceRecord {
        SourceRecord(id: id, assetID: "asset-" + id, name: id, state: "saved", kind: "user_text",
                     createdAt: "2026-11-21T00:00:00Z", bytes: 1, duration: nil, jobState: "completed",
                     transcript: transcript, error: nil, relativePath: "assets/" + id,
                     transcriptVersionID: "t-" + id, transcriptionBackend: nil, spans: [],
                     localOnly: false, policyVersion: 1, origin: "user", speaker: "user",
                     feedbackActionID: nil, feedbackActionVersion: nil, feedbackKind: nil, feedbackRelation: nil,
                     timeZone: "Asia/Shanghai", presentation: presentation)
    }

    private struct PresentationSpec {
        let manual: String?
        let automatic: String?
        let version: String
    }

    private func makePresentation(_ spec: PresentationSpec) -> RecordingPresentation {
        RecordingPresentation(
            manualTitle: spec.manual,
            automatic: spec.automatic.map { RecordingTitleProposal(sourceID: "s", title: $0, summary: "s", quotes: []) },
            transcriptVersionID: spec.version)
    }

    private struct DisplayTitleCase {
        let id: String
        let presentation: PresentationSpec?
        let transcript: String
        let displayTitle: String
        let contentTitle: String?
    }

    private let filler = "所以我我要考虑找一个方法，在使用AI的过程中要减少这种情况。"

    func testDerivedTitleCases() {
        let family = "👨‍👩‍👧‍👦"
        let cases: [(transcript: String, expected: String?)] = [
            (filler, "我要考虑找一个方法"),
            ("我想做一个标题工具，后面还有很多内容", "我想做一个标题工具"),
            (String(repeating: "长", count: 25), String(repeating: "长", count: 20) + "…"),
            (String(repeating: "字", count: 20), String(repeating: "字", count: 20)),
            ("那个方案很好", "那个方案很好"),
            ("，，，", nil),
            (String(repeating: family, count: 22), String(repeating: family, count: 20) + "…")
        ]
        for c in cases {
            XCTAssertEqual(MaterialTitleText.derived(fromTranscript: c.transcript), c.expected, c.transcript)
        }
    }

    func testGeneratedTitleCases() {
        let family = "👨‍👩‍👧‍👦"
        let capped = String(repeating: "题", count: 24) + "…"
        let cases: [(input: String, expected: String?)] = [
            ("**周会结论**。", "周会结论"),
            ("## 预算安排\n第二行", "预算安排 第二行"),
            (String(repeating: "题", count: 30), capped),
            ("", nil),
            ("  \n ", nil),
            ("。。。", nil),
            ("标题…。", "标题…"),
            (capped, capped),
            ("用 C# 写 snake_case 工具", "用 C# 写 snake_case 工具"),
            ("- 用 C# 写 snake_case 工具", "用 C# 写 snake_case 工具"),
            (String(repeating: family, count: 30), String(repeating: family, count: 24) + "…")
        ]
        for c in cases {
            XCTAssertEqual(MaterialTitleText.normalizedGenerated(c.input), c.expected, c.input)
        }
        for input in ["**周会结论**。", String(repeating: "题", count: 30), "标题…。",
                      "## 预算安排\n第二行", "好的……"] {
            let once = MaterialTitleText.normalizedGenerated(input)
            XCTAssertEqual(once.flatMap(MaterialTitleText.normalizedGenerated), once, input)
        }
    }

    func testDisplayAndContentTitleCases() {
        let cases: [DisplayTitleCase] = [
            .init(id: "s1",
                  presentation: PresentationSpec(manual: "  我的标题。 ", automatic: "**自动标题**。", version: "t-s1"),
                  transcript: filler, displayTitle: "我的标题。", contentTitle: "我的标题。"),
            .init(id: "s2",
                  presentation: PresentationSpec(manual: nil, automatic: "**周会结论**。", version: "t-s2"),
                  transcript: "原文", displayTitle: "周会结论", contentTitle: "周会结论"),
            .init(id: "s3",
                  presentation: PresentationSpec(manual: nil, automatic: "过期标题", version: "t-old"),
                  transcript: "原文", displayTitle: "原文", contentTitle: nil)
        ]
        for c in cases {
            let record = source(id: c.id, transcript: c.transcript, presentation: c.presentation.map(makePresentation))
            XCTAssertEqual(record.displayTitle, c.displayTitle, c.id)
            XCTAssertEqual(record.contentTitle, c.contentTitle, c.id)
        }
    }

    func testExplicitTitleCases() {
        let automatic = PresentationSpec(manual: "  ", automatic: "**周会结论**。", version: "t-1")
        let cases: [(presentation: PresentationSpec?, transcriptVersionID: String?, expected: String?)] = [
            (automatic, "t-1", "周会结论"),
            (automatic, "t-2", nil),
            (PresentationSpec(manual: "  我的标题。 ", automatic: nil, version: "t-old"), "t-new", "我的标题。"),
            (nil, nil, nil)
        ]
        for c in cases {
            let value = c.presentation.map(makePresentation)
            XCTAssertEqual(MaterialDisplayTitle.explicitTitle(presentation: value, transcriptVersionID: c.transcriptVersionID), c.expected)
        }
    }
}