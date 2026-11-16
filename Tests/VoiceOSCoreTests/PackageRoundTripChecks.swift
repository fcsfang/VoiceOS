import XCTest
import Foundation
@testable import VoiceOSCore
import VoiceOSPlatform

final class PackageRoundTripChecks: XCTestCase {
    private static let newTables = ["action_clarifications", "action_focus", "source_reading_states", "claim_notes", "topic_claim_confirmations", "source_capture_metadata", "source_attachments", "action_subtasks", "action_estimates", "source_chapters", "capture_templates"]
    private static let optionalTables = ["action_recurrence", "source_entities"]
    private static let addedIn50Tables = ["task_initiations"]
    private static let addedIn51Tables = ["panorama_attempts", "panorama_steps", "panorama_theme_replies", "panorama_themes", "panorama_theme_batches", "panorama_theme_appearances"]
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
        let sourceID = try await store.recordUserExpression(text)
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

    private func insertTaskInitiation(_ store: VoiceOSStore, sourceID: String) async throws -> String {
        let sources = try await store.sources()
        let source = try XCTUnwrap(sources.first { $0.id == sourceID })
        let versionID = try XCTUnwrap(source.transcriptVersionID)
        let text = try XCTUnwrap(source.transcript)
        let db = await store.db
        let input = TaskInitiationInput(sourceID: sourceID, transcriptVersionID: versionID, text: text,
                                        answer: "", mode: .direct, preferredRoute: nil,
                                        recordedAt: "2026-11-15T00:00:00Z", timeZone: "Asia/Shanghai")
        let proposal = TaskInitiationProposal(isTaskInitiation: true, route: .guidedStart, title: "迁移往返启动包",
                                              objective: "验证任务启动记录随迁移包往返", firstAction: "打开终端",
                                              verification: "恢复后记录仍在")
        let id = UUID().uuidString
        try db.execute("""
        INSERT INTO task_initiations(id,command_id,source_id,transcript_version_id,state,route,input_json,proposal_json,created_at,updated_at)
        VALUES(?,?,?,?,?,?,?,?,?,?)
        """, [id, "package-round-trip-initiation", sourceID, versionID, "draft", "guided_start",
              String(decoding: try JSONEncoder().encode(input), as: UTF8.self),
              String(decoding: try JSONEncoder().encode(proposal), as: UTF8.self),
              "2026-11-15T00:00:00Z", "2026-11-15T00:00:00Z"])
        return id
    }

    private func insertPanorama(_ store: VoiceOSStore) async throws -> (attemptID: String, themeID: String) {
        let db = await store.db
        let attemptID = UUID().uuidString, themeID = "theme-" + String(repeating: "b", count: 32), now = "2026-11-15T00:00:00Z", digest = String(repeating: "a", count: 64)
        try db.execute("INSERT INTO panorama_attempts(id,digest,state,input_json,created_at) VALUES(?,?,'completed','{}',?)", [attemptID, digest, now])
        try db.execute("INSERT INTO panorama_themes(id,title,created_at,last_seen_at) VALUES(?,'主题甲',?,?)", [themeID, now, now])
        try db.execute("INSERT INTO panorama_theme_batches(attempt_id,phase,theme_count,created_at) VALUES(?,'completed',1,?)", [attemptID, now])
        try db.execute("""
        INSERT INTO panorama_theme_appearances(attempt_id,phase,theme_id,raw_region_id,region_title,question_titles_json,claim_ids_json,source_ids_json,quote_keys_json,match_kind,match_score,created_at)
        VALUES(?,'completed',?,'region-1','主题甲','[]','[]','[]','[]','new',0.5,?)
        """, [attemptID, themeID, now])
        try db.execute("INSERT INTO panorama_theme_replies(region_id,digest,reply,model,prompt_version,state,created_at) VALUES('region-1',?,'回收主题','fixture','v1','completed',?)", [digest, now])
        return (attemptID, themeID)
    }

    func testPackageVersion49RoundTripPreservesNewTablesAndAttachments() async throws {
        let store = try await openStore()
        let fixture = try await makeFixture(store)
        let package = base.appendingPathComponent("package")
        try await store.exportPackage(to: package, includeMedia: true)
        try rewriteAsVersion49(package)
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

    func testPackageVersion51RoundTripPreservesTaskInitiationsAndPanorama() async throws {
        let store = try await openStore()
        let fixture = try await makeFixture(store)
        let initiationID = try await insertTaskInitiation(store, sourceID: fixture.sourceID)
        let panorama = try await insertPanorama(store)
        let package = base.appendingPathComponent("package51")
        try await store.exportPackage(to: package, includeMedia: true)
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: package.appendingPathComponent("manifest.json"))) as? [String: Any]
        XCTAssertEqual(manifest?["version"] as? Int, 51)
        XCTAssertEqual(manifest?["databaseSchema"] as? Int, 51)
        let counts = try XCTUnwrap(manifest?["counts"] as? [String: Any])
        XCTAssertEqual(counts["task_initiations"] as? Int, 1)
        for table in Self.addedIn51Tables { XCTAssertEqual(counts[table] as? Int, table == "panorama_steps" ? 0 : 1, table) }

        let restoredRoot = base.appendingPathComponent("restored51")
        try await VoiceOSStore.restorePackage(from: package, to: restoredRoot, inspector: NativeMediaInspector())
        let restored = try await openStore(restoredRoot)
        let records = try await restored.taskInitiations()
        XCTAssertEqual(records.map(\.id), [initiationID])
        XCTAssertEqual(records.first?.state, "draft")
        XCTAssertEqual(records.first?.route, TaskInitiationRoute.guidedStart)
        XCTAssertEqual(records.first?.sourceID, fixture.sourceID)
        XCTAssertEqual(records.first?.proposal.title, "迁移往返启动包")
        XCTAssertEqual(records.first?.basisChanged, false)
        let restoredDB = await restored.db
        XCTAssertEqual(try restoredDB.query("SELECT state FROM panorama_attempts WHERE id=?", [panorama.attemptID]).first?["state"], "completed")
        XCTAssertEqual(try restoredDB.query("SELECT title FROM panorama_themes WHERE id=?", [panorama.themeID]).first?["title"], "主题甲")
        XCTAssertEqual(try restoredDB.query("SELECT theme_count FROM panorama_theme_batches").first?["theme_count"], "1")
        XCTAssertEqual(try restoredDB.query("SELECT match_kind,match_score FROM panorama_theme_appearances").first?["match_kind"], "new")
        XCTAssertEqual(try restoredDB.query("SELECT match_kind,match_score FROM panorama_theme_appearances").first?["match_score"], "0.5")
        XCTAssertEqual(try restoredDB.query("SELECT reply FROM panorama_theme_replies").first?["reply"], "回收主题")
        let themeMap = try await restored.latestPanoramaThemeMap()
        XCTAssertEqual(themeMap?.references.map(\.id), [panorama.themeID])
        let history = try await restored.panoramaThemeHistory()
        XCTAssertEqual(history[panorama.themeID]?.appearanceCount, 1)

        try rewriteAsVersion50(package)
        let olderRoot = base.appendingPathComponent("restored50")
        try await VoiceOSStore.restorePackage(from: package, to: olderRoot, inspector: NativeMediaInspector())
        let older = try await openStore(olderRoot)
        let olderDB = await older.db
        for table in Self.addedIn51Tables { XCTAssertEqual(try olderDB.query("SELECT count(*) AS n FROM \(table)").first?["n"], "0", table) }
        let olderRecords = try await older.taskInitiations()
        XCTAssertEqual(olderRecords.map(\.id), [initiationID])

        try rewriteAsVersion49(package)
        let oldestRoot = base.appendingPathComponent("restored49")
        try await VoiceOSStore.restorePackage(from: package, to: oldestRoot, inspector: NativeMediaInspector())
        let oldest = try await openStore(oldestRoot)
        let oldestRecords = try await oldest.taskInitiations()
        XCTAssertTrue(oldestRecords.isEmpty)
        let oldestDB = await oldest.db
        XCTAssertEqual(try oldestDB.query("SELECT count(*) AS n FROM task_initiations").first?["n"], "0")
    }

    func testRestoreRejectsCorruptPanoramaLedgerJSONAndCleansUp() async throws {
        let store = try await openStore()
        _ = try await makeFixture(store)
        _ = try await insertPanorama(store)
        let db = await store.db
        try db.execute("UPDATE panorama_theme_appearances SET claim_ids_json='[broken'")
        let package = base.appendingPathComponent("package-bad-json")
        try await store.exportPackage(to: package, includeMedia: true)
        let restoredRoot = base.appendingPathComponent("restored-bad-json")
        do {
            try await VoiceOSStore.restorePackage(from: package, to: restoredRoot, inspector: NativeMediaInspector())
            XCTFail("全景账本 JSON 损坏时必须拒绝恢复")
        } catch {
            XCTAssertEqual((error as? VoiceOSError)?.message, "全景主题记录 JSON 无效")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: restoredRoot.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: base.path).filter { $0.hasPrefix(".voiceos-restore-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testRestoreTrimsDanglingPanoramaReferences() async throws {
        let store = try await openStore()
        let fixture = try await makeFixture(store)
        let panorama = try await insertPanorama(store)
        let db = await store.db
        try db.execute("UPDATE panorama_theme_appearances SET claim_ids_json=?,source_ids_json=?",
                       ["[\"\(fixture.claimID)\",\"\(UUID().uuidString)\"]", "[\"\(fixture.sourceID)\",\"\(UUID().uuidString)\"]"])
        let package = base.appendingPathComponent("package-dangling")
        try await store.exportPackage(to: package, includeMedia: true)
        let restoredRoot = base.appendingPathComponent("restored-dangling")
        try await VoiceOSStore.restorePackage(from: package, to: restoredRoot, inspector: NativeMediaInspector())
        let restored = try await openStore(restoredRoot)
        let restoredDB = await restored.db
        let row = try XCTUnwrap(restoredDB.query("SELECT claim_ids_json,source_ids_json,question_titles_json FROM panorama_theme_appearances").first)
        let claimsJSON = try XCTUnwrap(row["claim_ids_json"]), sourcesJSON = try XCTUnwrap(row["source_ids_json"]), titlesJSON = try XCTUnwrap(row["question_titles_json"])
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: Data(claimsJSON.utf8)), [fixture.claimID])
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: Data(sourcesJSON.utf8)), [fixture.sourceID])
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: Data(titlesJSON.utf8)), [])
        let themeMap = try await restored.latestPanoramaThemeMap()
        XCTAssertEqual(themeMap?.references.first?.claimIDs, Set([fixture.claimID]))
        XCTAssertEqual(themeMap?.references.first?.sourceIDs, Set([fixture.sourceID]))
        let history = try await restored.panoramaThemeHistory()
        XCTAssertEqual(history[panorama.themeID]?.appearanceCount, 1)
    }

    func testRestoreRejectsPanoramaThemeCountMismatch() async throws {
        let store = try await openStore()
        _ = try await makeFixture(store)
        _ = try await insertPanorama(store)
        let db = await store.db
        try db.execute("UPDATE panorama_theme_batches SET theme_count=2")
        let package = base.appendingPathComponent("package-count")
        try await store.exportPackage(to: package, includeMedia: true)
        let restoredRoot = base.appendingPathComponent("restored-count")
        do {
            try await VoiceOSStore.restorePackage(from: package, to: restoredRoot, inspector: NativeMediaInspector())
            XCTFail("主题计数与出现记录不一致时必须拒绝恢复")
        } catch {
            XCTAssertEqual((error as? VoiceOSError)?.message, "全景主题计数与出现记录不一致")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: restoredRoot.path))
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
        try rewriteManifest(package, version: 48, dropping: Self.newTables + Self.optionalTables + Self.addedIn50Tables + Self.addedIn51Tables, removing: [attachment.relativePath])
    }

    private func rewriteAsVersion49(_ package: URL) throws {
        try rewriteManifest(package, version: 49, dropping: Self.addedIn50Tables + Self.addedIn51Tables, removing: [])
    }

    private func rewriteAsVersion50(_ package: URL) throws {
        try rewriteManifest(package, version: 50, dropping: Self.addedIn51Tables, removing: [])
    }

    private func rewriteManifest(_ package: URL, version: Int, dropping tables: [String], removing paths: [String]) throws {
        let manifestURL = package.appendingPathComponent("manifest.json")
        guard var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any],
              var counts = manifest["counts"] as? [String: Any],
              var files = manifest["files"] as? [[String: Any]] else { XCTFail("迁移清单格式错误"); return }
        for table in tables {
            counts.removeValue(forKey: table)
            try? FileManager.default.removeItem(at: package.appendingPathComponent("\(table).jsonl"))
        }
        files.removeAll { entry in
            guard let path = entry["path"] as? String else { return false }
            return tables.contains(String(path.dropLast(6))) || paths.contains(path)
        }
        for path in paths { try? FileManager.default.removeItem(at: package.appendingPathComponent(path)) }
        manifest["version"] = version
        manifest["databaseSchema"] = version
        manifest["counts"] = counts
        manifest["files"] = files
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: manifestURL)
    }

    func testRestoreFreezesQueuedAssistantExecution() async throws {
        let store = try await openStore()
        let fixture = try await makeFixture(store)
        let actions = try await store.actions()
        let action = try XCTUnwrap(actions.first { $0.id == fixture.actionID })
        let execution = try await store.enqueueAssistantExecution(actionID: fixture.actionID, expectedVersion: action.version)
        XCTAssertEqual(execution.state, "queued")
        let package = base.appendingPathComponent("package-queued-execution")
        try await store.exportPackage(to: package, includeMedia: true)

        let restoredRoot = base.appendingPathComponent("restored-queued-execution")
        try await VoiceOSStore.restorePackage(from: package, to: restoredRoot, inspector: NativeMediaInspector())
        let restored = try await openStore(restoredRoot)
        let restoredDB = await restored.db
        let row = try XCTUnwrap(restoredDB.query("SELECT state,error FROM assistant_executions WHERE id=?", [execution.id]).first)
        XCTAssertEqual(row["state"], "failed")
        XCTAssertEqual(row["error"], "迁移前委托尚未完成，可手动重试")
        XCTAssertEqual(try restoredDB.query("SELECT count(*) AS n FROM assistant_executions WHERE state IN ('queued','running')").first?["n"], "0")
    }

    func testRestoreRejectsNewerPackageVersionWithDedicatedMessage() async throws {
        let store = try await openStore()
        _ = try await makeFixture(store)
        let package = base.appendingPathComponent("package-newer")
        try await store.exportPackage(to: package, includeMedia: true)
        try rewriteManifest(package, version: 52, dropping: [], removing: [])
        let message = "此迁移包由更新版本的 VoiceOS 创建（包版本 52），请升级后再恢复"

        do {
            _ = try VoiceOSStore.packageSummary(at: package)
            XCTFail("更新版本的迁移包必须在预览时被拒绝")
        } catch {
            XCTAssertEqual((error as? VoiceOSError)?.message, message)
        }
        let restoredRoot = base.appendingPathComponent("restored-newer")
        do {
            try await VoiceOSStore.restorePackage(from: package, to: restoredRoot, inspector: NativeMediaInspector())
            XCTFail("更新版本的迁移包必须拒绝恢复")
        } catch {
            XCTAssertEqual((error as? VoiceOSError)?.message, message)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: restoredRoot.path))
    }
}
