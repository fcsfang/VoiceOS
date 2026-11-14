import XCTest
@testable import VoiceOSCore

final class FolderWatchChecks: XCTestCase {
    private func entry(_ path: String, size: Int64 = 10, modified: TimeInterval = 1_700_000_000) -> FolderWatchEntry {
        FolderWatchEntry(path: path, size: size, modified: Date(timeIntervalSince1970: modified))
    }

    func testFirstScanRecordsExistingFilesWithoutImporting() {
        var ledger = FolderWatchLedger()
        let existing = [entry("/watch/已有.pdf"), entry("/watch/旧.txt")]
        ledger.adoptBaseline(existing)
        XCTAssertTrue(ledger.initialized)
        XCTAssertTrue(ledger.newEntries(in: existing).isEmpty)
        let later = entry("/watch/新.md")
        XCTAssertEqual(ledger.newEntries(in: [later]), [later])
    }

    func testNewFileIsReportedOnce() {
        var ledger = FolderWatchLedger()
        ledger.adoptBaseline([])
        let new = entry("/watch/新.png")
        XCTAssertEqual(ledger.newEntries(in: [new]), [new])
        ledger.record([new])
        XCTAssertTrue(ledger.newEntries(in: [new]).isEmpty)
    }

    func testDuplicateEntriesInOneScanAreReportedOnce() {
        var ledger = FolderWatchLedger()
        ledger.adoptBaseline([])
        let duplicate = entry("/watch/复制.txt")
        XCTAssertEqual(ledger.newEntries(in: [duplicate, duplicate]), [duplicate])
    }

    func testUnknownExtensionIsIgnored() {
        var ledger = FolderWatchLedger()
        ledger.adoptBaseline([])
        let archive = entry("/watch/包.zip")
        XCTAssertEqual(archive.kind, .unsupported)
        XCTAssertTrue(ledger.newEntries(in: [archive]).isEmpty)
    }

    func testSizeChangeIsReportedAsNewFile() {
        var ledger = FolderWatchLedger()
        ledger.adoptBaseline([])
        let before = entry("/watch/日志.txt", size: 10)
        let after = entry("/watch/日志.txt", size: 20)
        XCTAssertNotEqual(before.fingerprint, after.fingerprint)
        XCTAssertEqual(ledger.newEntries(in: [before]), [before])
        ledger.record([before])
        XCTAssertEqual(ledger.newEntries(in: [after]), [after])
    }

    func testExtensionKindsFollowCaptureRouting() {
        XCTAssertEqual(FolderWatchLedger.kind(forFileExtension: "pdf"), .pdf)
        XCTAssertEqual(FolderWatchLedger.kind(forFileExtension: "JPG"), .image)
        XCTAssertEqual(FolderWatchLedger.kind(forFileExtension: "md"), .text)
        XCTAssertEqual(FolderWatchLedger.kind(forFileExtension: "m4a"), .media)
        XCTAssertEqual(FolderWatchLedger.kind(forFileExtension: "zip"), .unsupported)
    }
}
