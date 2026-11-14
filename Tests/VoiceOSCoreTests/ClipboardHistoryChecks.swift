import XCTest
@testable import VoiceOSCore
import VoiceOSPlatform

final class ClipboardHistoryChecks: XCTestCase {
    func testConsecutiveDuplicateIsIgnored() {
        var history = ClipboardHistory()
        XCTAssertTrue(history.record("同一段文字"))
        XCTAssertFalse(history.record("同一段文字"))
        XCTAssertEqual(history.entries.map(\.text), ["同一段文字"])
        XCTAssertTrue(history.record("另一段文字"))
        XCTAssertTrue(history.record("同一段文字"))
        XCTAssertEqual(history.entries.map(\.text), ["同一段文字", "另一段文字", "同一段文字"])
    }

    func testLimitKeepsMostRecentTwenty() {
        var history = ClipboardHistory()
        for index in 0..<25 { history.record("第\(index)条") }
        XCTAssertEqual(history.entries.count, ClipboardHistory.limit)
        XCTAssertEqual(history.entries.first?.text, "第24条")
        XCTAssertEqual(history.entries.last?.text, "第5条")
    }

    func testBlankAndOverlongAreIgnored() {
        var history = ClipboardHistory()
        XCTAssertFalse(history.record(""))
        XCTAssertFalse(history.record("   \n\t"))
        XCTAssertFalse(history.record(String(repeating: "字", count: ClipboardHistory.maximumTextLength + 1)))
        XCTAssertTrue(history.entries.isEmpty)
        XCTAssertTrue(history.record(String(repeating: "字", count: ClipboardHistory.maximumTextLength)))
        XCTAssertEqual(history.entries.count, 1)
    }

    func testURLAndTextShareTheSameHistory() {
        var history = ClipboardHistory()
        XCTAssertTrue(history.record("https://example.com/文章", isURL: true))
        XCTAssertTrue(history.record("普通文字"))
        XCTAssertEqual(history.entries.map(\.isURL), [false, true])
    }

    func testSameContentInSameBucketHasSameCommandID() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let bucketStart = base.timeIntervalSince1970 - base.timeIntervalSince1970.truncatingRemainder(dividingBy: CaptureDedupe.bucketLength)
        let first = Date(timeIntervalSince1970: bucketStart)
        let last = Date(timeIntervalSince1970: bucketStart + CaptureDedupe.bucketLength - 0.001)
        XCTAssertEqual(CaptureDedupe.commandID(text: "同一内容", now: first),
                       CaptureDedupe.commandID(text: "同一内容", now: last))
    }

    func testDifferentBucketsProduceDifferentCommandIDs() {
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        let nextBucket = first.addingTimeInterval(CaptureDedupe.bucketLength)
        let id = CaptureDedupe.commandID(text: "同一内容", now: first)
        XCTAssertNotEqual(id, CaptureDedupe.commandID(text: "同一内容", now: nextBucket))
        XCTAssertNotEqual(id, CaptureDedupe.commandID(text: "另一内容", now: first))
        let parts = id.split(separator: ":")
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts[0], "capture")
        XCTAssertEqual(parts[1].count, 16)
    }
}
