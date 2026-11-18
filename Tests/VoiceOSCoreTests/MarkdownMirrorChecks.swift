import XCTest
@testable import VoiceOSCore
import VoiceOSPlatform

final class MarkdownMirrorChecks: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-markdown-mirror-" + UUID().uuidString)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func modificationDate(_ url: URL) throws -> Date {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
    }

    func testMirrorRewritesOnlyChangedDocuments() async throws {
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await store.recover()
        let firstID = try await store.recordUserExpression("第一份材料原文。")
        let secondID = try await store.recordUserExpression("第二份材料原文。")
        let directory = root.appendingPathComponent("Mirror", isDirectory: true)
        var mirror = MarkdownMirror(directory: directory, minimumInterval: 0)
        let initial = try await store.sources()
        XCTAssertTrue(try mirror.write(sources: initial, claims: [], actions: []))
        let firstURL = directory.appendingPathComponent("materials").appendingPathComponent(firstID + ".md")
        let secondURL = directory.appendingPathComponent("materials").appendingPathComponent(secondID + ".md")
        let firstStamp = try modificationDate(firstURL)
        let secondStamp = try modificationDate(secondURL)

        XCTAssertTrue(try mirror.write(sources: initial, claims: [], actions: []))
        XCTAssertEqual(try modificationDate(firstURL), firstStamp, "内容未变的镜像文件不应重写")
        XCTAssertEqual(try modificationDate(secondURL), secondStamp, "内容未变的镜像文件不应重写")

        let db = await store.db
        try db.execute("UPDATE sources SET name=? WHERE id=?", ["改过的标题", firstID])
        let renamed = try await store.sources()
        XCTAssertTrue(try mirror.write(sources: renamed, claims: [], actions: []))
        XCTAssertNotEqual(try modificationDate(firstURL), firstStamp, "标题变化的镜像文件应重写")
        XCTAssertEqual(try modificationDate(secondURL), secondStamp, "未变化的镜像文件不应跟随重写")
    }
}
