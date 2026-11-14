import XCTest
import Foundation
@testable import VoiceOSCore
import VoiceOSPlatform

final class SourceAttachmentChecks: XCTestCase {
    private var root: URL!
    private var input: URL!
    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
        root = base.appendingPathComponent("voiceos-source-attachment-" + UUID().uuidString)
        input = base.appendingPathComponent("voiceos-source-attachment-input-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: input)
    }

    private func openStore() async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }

    private func insertSource(_ db: Database, id: String = UUID().uuidString) throws -> String {
        try db.execute("""
        INSERT INTO sources(id,command_id,input_fingerprint,asset_id,version_id,name,kind,speaker,origin,state,created_at,timezone,expected_bytes,expected_hash,relative_path)
        VALUES(?,?,?,?,?,?,?,'unknown','external','saved',?,?, '0','0',?)
        """, [id, "source:" + id, "fixture:" + id, "asset:" + id, "version:" + id, "合成资料", "external_text", "2026-11-14T00:00:00Z", TimeZone.current.identifier, "assets/" + id])
        return id
    }

    private func file(_ name: String, _ data: Data) throws -> URL {
        let url = input.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testMigrationAddsSourceAttachmentsTable() async throws {
        let store = try await openStore()
        let db = await store.db
        XCTAssertEqual(try db.query("PRAGMA user_version").first?["user_version"], "56")
        XCTAssertNotNil(try db.query("SELECT name FROM sqlite_master WHERE type='table' AND name='source_attachments'").first)
    }

    func testAttachPNGCopiesFileAndReadsBack() async throws {
        let store = try await openStore()
        let db = await store.db
        let sourceID = try insertSource(db)
        let png = try file("截图.png", Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        let attachment = try await store.attachSourceFile(sourceID: sourceID, fileURL: png)
        XCTAssertEqual(attachment.sourceID, sourceID)
        XCTAssertEqual(attachment.mime, "image/png")
        XCTAssertEqual(attachment.bytes, 8)
        XCTAssertTrue(attachment.relativePath.hasPrefix("assets/"))
        XCTAssertTrue(attachment.relativePath.hasSuffix(".png"))
        let saved = root.appendingPathComponent(attachment.relativePath)
        XCTAssertEqual(try Data(contentsOf: saved), try Data(contentsOf: png))
        let attributes = try FileManager.default.attributesOfItem(atPath: saved.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertNotNil(ISO8601DateFormatter().date(from: attachment.createdAt))
        let readBack = try await store.sourceAttachment(sourceID: sourceID)
        XCTAssertEqual(readBack?.sourceID, sourceID)
        XCTAssertEqual(readBack?.relativePath, attachment.relativePath)
        XCTAssertEqual(readBack?.mime, "image/png")
        XCTAssertEqual(readBack?.bytes, 8)
        XCTAssertEqual(readBack?.createdAt, attachment.createdAt)
    }

    func testAttachOverwritesExistingAttachment() async throws {
        let store = try await openStore()
        let db = await store.db
        let sourceID = try insertSource(db)
        let first = try await store.attachSourceFile(sourceID: sourceID, fileURL: try file("第一张.png", Data(repeating: 1, count: 12)))
        let second = try await store.attachSourceFile(sourceID: sourceID, fileURL: try file("第二张.jpg", Data(repeating: 2, count: 20)))
        XCTAssertNotEqual(first.relativePath, second.relativePath)
        XCTAssertEqual(try db.query("SELECT * FROM source_attachments WHERE source_id=?", [sourceID]).count, 1)
        let readBack = try await store.sourceAttachment(sourceID: sourceID)
        XCTAssertEqual(readBack?.relativePath, second.relativePath)
        XCTAssertEqual(readBack?.mime, "image/jpeg")
        XCTAssertEqual(readBack?.bytes, 20)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(second.relativePath)).count, 20)
    }

    func testRejectsUnsupportedExtensionsAndMissingSource() async throws {
        let store = try await openStore()
        let db = await store.db
        let sourceID = try insertSource(db)
        for name in ["扫描.pdf", "笔记.txt"] {
            do {
                _ = try await store.attachSourceFile(sourceID: sourceID, fileURL: try file(name, Data("fixture".utf8)))
                XCTFail("非图片文件必须被拒绝：\(name)")
            } catch {}
        }
        XCTAssertTrue(try db.query("SELECT * FROM source_attachments WHERE source_id=?", [sourceID]).isEmpty)
        do {
            _ = try await store.attachSourceFile(sourceID: UUID().uuidString, fileURL: try file("合法.png", Data([0x89])))
            XCTFail("来源不存在时必须拒绝")
        } catch {
            XCTAssertEqual((error as? VoiceOSError)?.message, "来源不存在")
        }
    }
}
