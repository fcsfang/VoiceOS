import XCTest
@testable import VoiceOSCore

private struct SegmentationInspector: MediaInspector {
    func inspect(_ url: URL) async throws -> MediaInfo { .init(duration:2,kind:"audio") }
}
private struct SegmentationSpeech: SpeechPort {
    let text: String
    func transcribe(_ url: URL, locale: String) async throws -> SpeechText {
        .init(text:text,spans:[TranscriptSpan(textStart:0,textEnd:text.unicodeScalars.count,startMS:0,endMS:2000)])
    }
}
final class TranscriptSegmentationTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent("segmentation-"+UUID().uuidString) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at:root) }
    func source(_ text: String, timed: Bool = true) -> ContextTranscript {
        let spans = text.isEmpty ? [] : [TranscriptSpan(textStart:0,textEnd:text.unicodeScalars.count,startMS:timed ? 0 : nil,endMS:timed ? 2000 : nil)]
        return .init(sourceID:UUID().uuidString,sourceVersionID:UUID().uuidString,transcriptVersionID:UUID().uuidString,origin:"external",speaker:"unknown",localOnly:true,text:text,spans:spans)
    }
    func plan(_ source: ContextTranscript, budget: Int = 4000) throws -> TranscriptSegmentationPlan {
        try VoiceOSStore.segmentTranscript(source,policyVersion:1,scalarBudget:budget)
    }
    func assertLossless(_ plan: TranscriptSegmentationPlan, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(plan.segments.map(\.text).joined(),plan.source.text,file:file,line:line)
        var end = 0
        for segment in plan.segments {
            XCTAssertEqual(segment.textStart,end,file:file,line:line)
            XCTAssertEqual(segment.textEnd-segment.textStart,segment.text.unicodeScalars.count,file:file,line:line)
            XCTAssertLessThanOrEqual(segment.text.unicodeScalars.count,plan.scalarBudget,file:file,line:line)
            XCTAssertEqual(segment.references.first?.textStart,segment.textStart,file:file,line:line)
            XCTAssertEqual(segment.references.last?.textEnd,segment.textEnd,file:file,line:line)
            end = segment.textEnd
        }
        XCTAssertEqual(end,plan.source.text.unicodeScalars.count,file:file,line:line)
    }
    func testLargeTranscriptHasCompleteStableCoverageAndNoInterpolatedTimes() throws {
        let input = source(String(repeating:"原话。",count:4000)), p = try plan(input)
        assertLossless(p); XCTAssertGreaterThan(p.segments.count,1)
        let again = try plan(input); XCTAssertEqual(p.segments.map(\.id),again.segments.map(\.id))
        for segment in p.segments {
            XCTAssertEqual(segment.references[0].spanID,input.spans[0].id)
            XCTAssertEqual(segment.references[0].containingSpanStartMS,0)
            XCTAssertEqual(segment.references[0].containingSpanEndMS,2000)
        }
    }
    func testBoundariesPreserveEmojiCombiningMarksAndWhitespaceExactly() throws {
        let text = String(repeating:"甲👨‍👩‍👧‍👦e\u{301}\r\n乙 ",count:300)
        let p = try plan(source(text),budget:30); assertLossless(p)
        let characters = Array(text), rebuilt = p.segments.flatMap { Array($0.text) }
        XCTAssertEqual(characters,rebuilt)
    }
    func testUnsplitCharacterThatExceedsBudgetIsRejected() throws {
        XCTAssertThrowsError(try plan(source("👨‍👩‍👧‍👦"),budget:2))
        XCTAssertThrowsError(try plan(source("a"),budget:0))
        XCTAssertThrowsError(try plan(source("a"),budget:4001))
    }
    func testPartialAndCrossSpanReferencesUseOriginalOffsets() throws {
        let text = "abcdefghij"
        let spans = [TranscriptSpan(textStart:0,textEnd:3,startMS:0,endMS:300),TranscriptSpan(textStart:3,textEnd:10,startMS:300,endMS:2000)]
        let s = ContextTranscript(sourceID:UUID().uuidString,sourceVersionID:UUID().uuidString,transcriptVersionID:UUID().uuidString,origin:"user",speaker:"user",localOnly:true,text:text,spans:spans)
        let p = try plan(s,budget:6); assertLossless(p)
        XCTAssertEqual(p.segments[0].textEnd,3) // Original span boundary preferred.
        XCTAssertEqual(p.segments[1].references[0].textStart,3)
        XCTAssertEqual(p.segments[1].references[0].textEnd,9)
        XCTAssertEqual(p.segments[2].references[0].textStart,9)
        XCTAssertEqual(p.segments[2].references[0].containingSpanStartMS,300)
    }
    func testEmptyAndUntimedCorrectedTextInventNoMediaPositions() throws {
        XCTAssertTrue(try plan(source("")).segments.isEmpty)
        let p = try plan(source("更正后的文字",timed:false),budget:3); assertLossless(p)
        XCTAssertTrue(p.segments.flatMap(\.references).allSatisfy { $0.containingSpanStartMS == nil && $0.containingSpanEndMS == nil })
    }
    func testStorePlanIsLocalAndRejectsCorrectionPolicyChangeAndTampering() async throws {
        let s = try VoiceOSStore(root:root,inspector:SegmentationInspector()); try await s.recover()
        let file = root.appendingPathComponent("fixture.wav"); try Data("synthetic inspector fixture".utf8).write(to:file)
        let id = try await s.importPersonalAudio(file); try await s.processTranscriptions(using:SegmentationSpeech(text:String(repeating:"原话。",count:2000)))
        let p = try await s.prepareTranscriptSegmentation(sourceID:id)
        try await s.validateTranscriptSegmentation(p); assertLossless(p)
        let attempts = try await s.modelAttempts(), intents = try await s.processingIntents(), policy = try await s.sourcePolicy(sourceID:id)
        XCTAssertTrue(attempts.isEmpty); XCTAssertTrue(intents.isEmpty); XCTAssertTrue(policy.localOnly)
        let tampered = TranscriptSegmentationPlan(algorithm:p.algorithm,source:p.source,policyVersion:p.policyVersion,scalarBudget:p.scalarBudget,segments:Array(p.segments.dropLast()),contentDigest:p.contentDigest)
        do { try await s.validateTranscriptSegmentation(tampered); XCTFail() } catch {}
        _ = try await s.setSourceLocalOnly(sourceID:id,expectedVersion:1,localOnly:false)
        do { try await s.validateTranscriptSegmentation(p); XCTFail() } catch {}
        let changed = try await s.prepareTranscriptSegmentation(sourceID:id)
        _ = try await s.correctTranscript(sourceID:id,expectedVersionID:changed.source.transcriptVersionID,text:"更正后的文字")
        do { try await s.validateTranscriptSegmentation(changed); XCTFail() } catch {}
        let corrected = try await s.prepareTranscriptSegmentation(sourceID:id)
        XCTAssertTrue(corrected.segments.flatMap(\.references).allSatisfy { $0.containingSpanStartMS == nil })
    }
    func testDamagedOriginalCannotRemainAValidPlan() async throws {
        let s = try VoiceOSStore(root:root,inspector:SegmentationInspector()); try await s.recover()
        let file = root.appendingPathComponent("fixture.wav"); try Data("synthetic inspector fixture".utf8).write(to:file)
        let id = try await s.importFile(file); try await s.processTranscriptions(using:SegmentationSpeech(text:"外部原话"))
        let p = try await s.prepareTranscriptSegmentation(sourceID:id)
        let original = try await s.playableURL(sourceID:id); try Data("damaged".utf8).write(to:original)
        do { try await s.validateTranscriptSegmentation(p); XCTFail() } catch {}
    }
}
