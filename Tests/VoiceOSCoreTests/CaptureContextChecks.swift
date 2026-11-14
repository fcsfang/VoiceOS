import XCTest
import Foundation
@testable import VoiceOSCore
import VoiceOSPlatform

final class CaptureContextChecks: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-capture-context-" + UUID().uuidString) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func openStore() async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }

    private func insertSource(_ db: Database) throws -> String {
        let id = UUID().uuidString
        try db.execute("""
        INSERT INTO sources(id,command_id,input_fingerprint,asset_id,version_id,name,kind,speaker,origin,state,created_at,timezone,expected_bytes,expected_hash,relative_path)
        VALUES(?,?,?,?,?,?,?,'unknown','external','saved',?,?, '0','0',?)
        """, [id, "source:" + id, "fixture:" + id, "asset:" + id, "version:" + id, "合成资料", "external_text", "2026-11-14T00:00:00Z", TimeZone.current.identifier, "assets/" + id])
        return id
    }

    func testCaptureMetadataStoresContextWithURL() async throws {
        let store = try await openStore()
        let db = await store.db
        let sourceID = try insertSource(db)
        try await store.attachCaptureMetadata(sourceID: sourceID, url: "https://example.com/page", context: "Safari · 某页面")
        let metadata = try await store.captureMetadata()
        XCTAssertEqual(metadata[sourceID]?.url, "https://example.com/page")
        XCTAssertEqual(metadata[sourceID]?.context, "Safari · 某页面")
        XCTAssertNotNil(ISO8601DateFormatter().date(from: metadata[sourceID]?.capturedAt ?? ""))
        try await store.attachCaptureMetadata(sourceID: sourceID, url: nil, context: "Terminal · 文稿")
        let updated = try await store.captureMetadata()
        XCTAssertEqual(updated.count, 1)
        XCTAssertNil(updated[sourceID]?.url)
        XCTAssertEqual(updated[sourceID]?.context, "Terminal · 文稿")
    }

    func testCapturedTextWritesURLAndContext() async throws {
        let store = try await openStore()
        let sourceID = try await store.recordCapturedText("速记正文", title: "速记标题", ownership: .external, sourceURL: "https://example.com/note", captureContext: "Safari · 某页面")
        let metadata = try await store.captureMetadata()
        XCTAssertEqual(metadata[sourceID]?.url, "https://example.com/note")
        XCTAssertEqual(metadata[sourceID]?.context, "Safari · 某页面")
    }

    func testCaptureMetadataRejectsMissingSource() async throws {
        let store = try await openStore()
        do {
            try await store.attachCaptureMetadata(sourceID: UUID().uuidString, url: nil, context: "Safari · 某页面")
            XCTFail("来源不存在时不能写入抓取元数据")
        } catch {}
    }

    func testFrontContextDisplayJoinsAndTruncates() {
        XCTAssertEqual(FrontContext(app: " Safari ", window: " 某页面 ").display, "Safari · 某页面")
        XCTAssertEqual(FrontContext(app: "Terminal", window: "  ").display, "Terminal")
        XCTAssertEqual(FrontContext(app: "Finder", window: nil).display, "Finder")
        let long = String(repeating: "长", count: 130)
        XCTAssertEqual(FrontContext(app: "Safari", window: long).display, "Safari · " + String(repeating: "长", count: 120))
    }
}
