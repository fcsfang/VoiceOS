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

    func testOpeningFillersAndDuplicatedPronounAreStripped() {
        let title = MaterialTitleText.derived(fromTranscript: "所以我我要考虑找一个方法，在使用AI的过程中要减少这种情况。")
        XCTAssertNotNil(title)
        XCTAssertTrue(title?.hasPrefix("我要考虑") == true)
        XCTAssertLessThanOrEqual(title?.count ?? 0, 20)
    }

    func testFirstClauseIsKeptBeforeComma() {
        XCTAssertEqual(MaterialTitleText.derived(fromTranscript: "我想做一个标题工具，后面还有很多内容"), "我想做一个标题工具")
    }

    func testLongUnpunctuatedTextGetsEllipsisWithinTwentyCharacters() {
        XCTAssertEqual(MaterialTitleText.derived(fromTranscript: String(repeating: "长", count: 25)),
                       String(repeating: "长", count: 20) + "…")
    }

    func testExactlyTwentyCharactersStaysIntact() {
        XCTAssertEqual(MaterialTitleText.derived(fromTranscript: String(repeating: "字", count: 20)),
                       String(repeating: "字", count: 20))
    }

    func testOverStrippingFallsBackToOriginalWording() {
        XCTAssertEqual(MaterialTitleText.derived(fromTranscript: "那个方案很好"), "那个方案很好")
    }

    func testGeneratedTitleLosesMarkdownAndTrailingPunctuation() {
        XCTAssertEqual(MaterialTitleText.normalizedGenerated("**周会结论**。"), "周会结论")
        XCTAssertEqual(MaterialTitleText.normalizedGenerated("## 预算安排\n第二行"), "预算安排 第二行")
    }

    func testGeneratedTitleIsCappedAtTwentyFourCharacters() {
        XCTAssertEqual(MaterialTitleText.normalizedGenerated(String(repeating: "题", count: 30)),
                       String(repeating: "题", count: 24) + "…")
    }

    func testEmptyAndPunctuationOnlyTitlesAreNil() {
        XCTAssertNil(MaterialTitleText.normalizedGenerated(""))
        XCTAssertNil(MaterialTitleText.normalizedGenerated("  \n "))
        XCTAssertNil(MaterialTitleText.normalizedGenerated("。。。"))
        XCTAssertNil(MaterialTitleText.derived(fromTranscript: "，，，"))
    }

    func testManualTitleIsTrimmedButNotRewritten() {
        let presentation = RecordingPresentation(
            manualTitle: "  我的标题。 ",
            automatic: RecordingTitleProposal(sourceID: "s1", title: "**自动标题**。", summary: "s", quotes: []),
            transcriptVersionID: "t-s1")
        let record = source(id: "s1", transcript: "所以我我要考虑找一个方法，在使用AI的过程中要减少这种情况。", presentation: presentation)
        XCTAssertEqual(record.displayTitle, "我的标题。")
    }

    func testAutomaticTitleReachesDisplayTitleNormalized() {
        let presentation = RecordingPresentation(
            automatic: RecordingTitleProposal(sourceID: "s2", title: "**周会结论**。", summary: "s", quotes: []),
            transcriptVersionID: "t-s2")
        XCTAssertEqual(source(id: "s2", transcript: "原文", presentation: presentation).displayTitle, "周会结论")
    }

    func testTranscriptFallbackReachesDisplayTitleDerived() {
        let record = source(id: "s3", transcript: "所以我我要考虑找一个方法，在使用AI的过程中要减少这种情况。", presentation: nil)
        XCTAssertEqual(record.displayTitle, "我要考虑找一个方法")
    }

    func testGraphemeClustersAreNotTorn() {
        let family = "👨‍👩‍👧‍👦"
        XCTAssertEqual(MaterialTitleText.derived(fromTranscript: String(repeating: family, count: 22)),
                       String(repeating: family, count: 20) + "…")
        XCTAssertEqual(MaterialTitleText.normalizedGenerated(String(repeating: family, count: 30)),
                       String(repeating: family, count: 24) + "…")
    }
}