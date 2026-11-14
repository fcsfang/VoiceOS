import XCTest
import Foundation
@testable import VoiceOSCore
import VoiceOSPlatform

final class PackageRoundTripChecks: XCTestCase {
    private static let newTables = ["action_clarifications", "action_focus", "source_reading_states", "claim_notes", "topic_claim_confirmations", "source_capture_metadata", "source_attachments", "action_subtasks", "action_estimates", "source_chapters", "capture_templates"]
    private static let optionalTables = ["action_recurrence", "source_entities"]
    private var base: URL!
    private var root: URL!
    private var input: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-package-round-trip-" + UUID().uuidString)
        root = base.appendingPathComponent("library")
        input = base.appendingPathComponent("input")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: base) }

    private func openStore(_ directory: URL? = nil) async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: directory ?? root, inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }

    private func file(_ name: String, _ data: Data) throws -> URL {
        let url = input.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func makeFixture(_ store: VoiceOSStore) async throws -> (sourceID: String, claimID: String, actionID: String, attachment: SourceAttachment) {
        let text = "第一段观点。第二段说明。"
        let sourceID = try await store.recordCapturedText(text, title: "往返来源", ownership: .external)
        let context = try await store.prepareLocalTranscriptContext(sourceIDs: [sourceID])
        let source = try XCTUnwrap(context.sources.first)
        let span = try XCTUnwrap(source.spans.first)
        let reference = ClaimReference(sourceID: source.sourceID, transcriptVersionID: source.transcriptVersionID, spanID: span.id)
        let claimIDs = try await store.importOrganizedClaims(context: context, proposals: [
            .init(statement: text, ownership: .userTentative, references: [reference], action: .init(title: "核对往返", kind: .task, quote: text))
        ], commandID: "package-round-trip-claims")
        let claimID = try XCTUnwrap(claimIDs.first)
        let actions = try await store.actions()
        let actionID = try XCTUnwrap(actions.first { $0.claimID == claimID }?.id)
        _ = try await store.addSubtask(actionID: actionID, title: "拆第一步")
        let second = try await store.addSubtask(actionID: actionID, title: "拆第二步")
        _ = try await store.setSubtaskDone(id: second.id, done: true)
        try await store.setActionEstimate(actionID: actionID, minutes: 30)
        try await store.replaceChapters(sourceID: sourceID, entries: [(title: "开场", startMS: 0), (title: "正题", startMS: 12000)])
        _ = try await store.saveCaptureTemplate(name: "会议模板", body: "要点：\n行动：")
        _ = try await store.saveClaimNote(claimID: claimID, body: "这里是旁注")
        try await store.attachCaptureMetadata(sourceID: sourceID, url: "https://example.com/source", context: "剪贴板历史")
        try await store.setSourceReadingState(sourceID: sourceID, state: .reading)
        _ = try await store.toggleActionFocus(actionID: actionID)
        _ = try await store.confirmTopicClaim(topicID: "topic-fixture", claimID: claimID)
        let db = await store.db
        try db.execute("INSERT INTO action_clarifications(action_id,decision,command_id,created_at) VALUES(?,'commit',?,?)", [actionID, "clarify:" + UUID().uuidString, "2026-11-14T00:00:00Z"])
        let attachment = try await store.attachSourceFile(sourceID: sourceID, fileURL: file("附件.png", Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])))
        return (sourceID, claimID, actionID, attachment)
    }

    func testPackageVersion49RoundTripPreservesNewTablesAndAttachments() async throws {
        let store = try await openStore()
        let fixture = try await makeFixture(store)
        let package = base.appendingPathComponent("package")
        try await store.exportPackage(to: package, includeMedia: true)
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: package.appendingPathComponent("manifest.json"))) as? [String: Any]
        XCTAssertEqual(manifest?["version"] as? Int, 49)
        XCTAssertEqual(manifest?["databaseSchema"] as? Int, 49)
        let counts = try XCTUnwrap(manifest?["counts"] as? [String: Any])
        XCTAssertEqual(counts["sources"] as? Int, 1)
        for table in Self.newTables { XCTAssertNotNil(counts[table], table) }

        let restoredRoot = base.appendingPathComponent("restored")
        try await VoiceOSStore.restorePackage(from: package, to: restoredRoot, inspector: NativeMediaInspector())
        let restored = try await openStore(restoredRoot)
        let originalDB = await store.db
        let restoredDB = await restored.db
        for table in Self.newTables {
            XCTAssertEqual(try restoredDB.query("SELECT count(*) AS n FROM \(table)").first?["n"],
                           try originalDB.query("SELECT count(*) AS n FROM \(table)").first?["n"], table)
        }

        let subtasks = try await restored.subtasks(actionID: fixture.actionID)
        XCTAssertEqual(subtasks.map(\.title), ["拆第一步", "拆第二步"])
        XCTAssertEqual(subtasks.map(\.done), [false, true])
        let estimates = try await restored.actionEstimates()
        XCTAssertEqual(estimates[fixture.actionID], 30)
        let chapters = try await restored.chapters(sourceID: fixture.sourceID)
        XCTAssertEqual(chapters.map(\.title), ["开场", "正题"])
        XCTAssertEqual(chapters.map(\.startMS), [0, 12000])
        let templates = try await restored.captureTemplates()
        XCTAssertEqual(templates.first { $0.name == "会议模板" }?.body, "要点：\n行动：")
        let notes = try await restored.claimNotes()
        XCTAssertEqual(notes[fixture.claimID]?.body, "这里是旁注")
        let metadata = try await restored.captureMetadata()
        XCTAssertEqual(metadata[fixture.sourceID]?.url, "https://example.com/source")
        XCTAssertEqual(metadata[fixture.sourceID]?.context, "剪贴板历史")
        let states = try await restored.sourceReadingStates()
        XCTAssertEqual(states[fixture.sourceID], .reading)
        let focus = try await restored.focusedActionIDs()
        XCTAssertTrue(focus.contains(fixture.actionID))
        let clarifications = try await restored.actionClarifications()
        XCTAssertEqual(clarifications[fixture.actionID], "commit")
        let confirmations = try await restored.confirmedTopicClaimIDs(topicID: "topic-fixture")
        XCTAssertEqual(confirmations, [fixture.claimID])
        let attachment = try await restored.sourceAttachment(sourceID: fixture.sourceID)
        XCTAssertEqual(attachment?.relativePath, fixture.attachment.relativePath)
        XCTAssertEqual(attachment?.mime, "image/png")
        XCTAssertEqual(attachment?.bytes, fixture.attachment.bytes)
        let original = try Data(contentsOf: root.appendingPathComponent(fixture.attachment.relativePath))
        let copied = try Data(contentsOf: restoredRoot.appendingPathComponent(fixture.attachment.relativePath))
        XCTAssertEqual(copied, original)
    }

    func testVersion48PackageStillRestoresAndLeavesNewTablesEmpty() async throws {
        let store = try await openStore()
        let fixture = try await makeFixture(store)
        let package = base.appendingPathComponent("package48")
        try await store.exportPackage(to: package, includeMedia: true)
        try rewriteAsVersion48(package, attachment: fixture.attachment)

        let restoredRoot = base.appendingPathComponent("restored48")
        try await VoiceOSStore.restorePackage(from: package, to: restoredRoot, inspector: NativeMediaInspector())
        let restored = try await openStore(restoredRoot)
        let db = await restored.db
        for table in Self.newTables {
            XCTAssertEqual(try db.query("SELECT count(*) AS n FROM \(table)").first?["n"], "0", table)
        }
        let sources = try await restored.sources()
        XCTAssertEqual(sources.count, 1)
        let attachment = try await restored.sourceAttachment(sourceID: fixture.sourceID)
        XCTAssertNil(attachment)
    }

    func testReplacingAttachmentDeletesOldFile() async throws {
        let store = try await openStore()
        let sourceID = try await store.recordCapturedText("替换附件正文", title: "替换来源", ownership: .external)
        let first = try await store.attachSourceFile(sourceID: sourceID, fileURL: file("旧.png", Data(repeating: 1, count: 12)))
        let second = try await store.attachSourceFile(sourceID: sourceID, fileURL: file("新.jpg", Data(repeating: 2, count: 20)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(first.relativePath).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(second.relativePath).path))
        let stored = try await store.sourceAttachment(sourceID: sourceID)
        XCTAssertEqual(stored?.relativePath, second.relativePath)
        XCTAssertEqual(stored?.mime, "image/jpeg")
    }

    func testOversizedAttachmentIsRejectedOnWriteAndRead() async throws {
        let store = try await openStore()
        let sourceID = try await store.recordCapturedText("附件上限正文", title: "上限来源", ownership: .external)
        let big = input.appendingPathComponent("big.png")
        _ = FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(SourceAttachment.byteLimit + 1))
        try handle.close()
        do {
            _ = try await store.attachSourceFile(sourceID: sourceID, fileURL: big)
            XCTFail("超过 200MB 的附件必须被拒绝")
        } catch {
            XCTAssertEqual((error as? VoiceOSError)?.message, "附件过大")
        }
        let db = await store.db
        try db.execute("INSERT INTO source_attachments(source_id,relative_path,mime,bytes,created_at) VALUES(?,'assets/missing.png','image/png',?,?)", [sourceID, String(SourceAttachment.byteLimit + 1), "2026-11-14T00:00:00Z"])
        do {
            _ = try await store.sourceAttachment(sourceID: sourceID)
            XCTFail("超过 200MB 的附件记录不能读取")
        } catch {
            XCTAssertEqual((error as? VoiceOSError)?.message, "附件过大")
        }
    }

    private func rewriteAsVersion48(_ package: URL, attachment: SourceAttachment) throws {
        let manifestURL = package.appendingPathComponent("manifest.json")
        guard var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any],
              var counts = manifest["counts"] as? [String: Any],
              var files = manifest["files"] as? [[String: Any]] else { XCTFail("迁移清单格式错误"); return }
        let dropped = Self.newTables + Self.optionalTables
        for table in dropped {
            counts.removeValue(forKey: table)
            try? FileManager.default.removeItem(at: package.appendingPathComponent("\(table).jsonl"))
        }
        files.removeAll { entry in
            guard let path = entry["path"] as? String else { return false }
            return dropped.contains(String(path.dropLast(6))) || path == attachment.relativePath
        }
        try? FileManager.default.removeItem(at: package.appendingPathComponent(attachment.relativePath))
        manifest["version"] = 48
        manifest["databaseSchema"] = 48
        manifest["counts"] = counts
        manifest["files"] = files
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: manifestURL)
    }
}
