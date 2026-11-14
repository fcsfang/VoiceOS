import XCTest
import Foundation
@testable import VoiceOSCore
import VoiceOSPlatform

final class CrossCuttingChecks: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-cross-cutting-" + UUID().uuidString) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func source(id: String, title: String, transcript: String?) -> SourceRecord {
        SourceRecord(id: id, assetID: "asset-" + id, name: title, state: "saved", kind: "user_text",
                     createdAt: "2026-11-14T00:00:00Z", bytes: 1, duration: nil, jobState: "completed",
                     transcript: transcript, error: nil, relativePath: "assets/" + id, transcriptVersionID: "t-" + id,
                     transcriptionBackend: "fixture", spans: [], localOnly: false, policyVersion: 1,
                     origin: "user", speaker: "user", feedbackActionID: nil, feedbackActionVersion: nil,
                     feedbackKind: nil, feedbackRelation: nil, timeZone: "Asia/Shanghai", presentation: nil)
    }

    private func claim(id: String, statement: String, validity: String = "current") -> CandidateClaim {
        CandidateClaim(contentKind: nil, id: id, statement: statement, ownership: "user_tentative",
                       evidenceState: "unverified", validity: validity,
                       references: [ClaimReference(sourceID: "s1", transcriptVersionID: "t-s1", spanID: "span-1")],
                       reviewVersion: 1, reviewState: "pending")
    }

    private func action(id: String, claimID: String, title: String, state: String = "open", validity: String = "current", note: String = "") -> ActionRecord {
        ActionRecord(id: id, claimID: claimID, claimReviewVersion: 1, title: title, kind: "task",
                     intentActor: "user", note: note, state: state, validity: validity, version: 1, autoSend: false,
                     intent: nil, commandID: "test:" + id, createdAt: "2026-11-14T00:00:00Z")
    }

    func testMarkdownMirrorWritesFrontMatterAndEscapes() throws {
        let mirrorDirectory = root.appendingPathComponent("Mirror", isDirectory: true)
        var mirror = MarkdownMirror(directory: mirrorDirectory, minimumInterval: 60)
        let quotedTitle = "他说\"甲\"\n乙\\丙"
        let sources = [source(id: "s1", title: quotedTitle, transcript: "第一行\n第二行")]
        let claims = [claim(id: "c1", statement: "检索质量决定价值")]
        let actions = [action(id: "a1", claimID: "c1", title: "整理\n摘录", note: "备注 \"原文\"")]
        XCTAssertTrue(try mirror.write(sources: sources, claims: claims, actions: actions, now: Date(timeIntervalSince1970: 1_800_000_000)))

        let material = try String(contentsOf: mirrorDirectory.appendingPathComponent("materials").appendingPathComponent("s1.md"), encoding: .utf8)
        XCTAssertTrue(material.contains("type: material"))
        XCTAssertTrue(material.contains("title: \"他说\\\"甲\\\"\\n乙\\\\丙\""))
        XCTAssertTrue(material.contains("# 他说\"甲\" 乙\\丙"))
        XCTAssertTrue(material.contains("第一行\n第二行"))

        let claimText = try String(contentsOf: mirrorDirectory.appendingPathComponent("claims").appendingPathComponent("c1.md"), encoding: .utf8)
        XCTAssertTrue(claimText.contains("type: claim"))
        XCTAssertTrue(claimText.contains("# 检索质量决定价值"))
        XCTAssertTrue(claimText.contains("来源：s1"))

        let actionText = try String(contentsOf: mirrorDirectory.appendingPathComponent("actions").appendingPathComponent("a1.md"), encoding: .utf8)
        XCTAssertTrue(actionText.contains("type: action"))
        XCTAssertTrue(actionText.contains("title: \"整理\\n摘录\""))
        XCTAssertTrue(actionText.contains("# 整理 摘录"))
    }

    func testMarkdownMirrorThrottlesAndKeepsHistory() throws {
        let mirrorDirectory = root.appendingPathComponent("Mirror", isDirectory: true)
        var mirror = MarkdownMirror(directory: mirrorDirectory, minimumInterval: 60)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = [source(id: "s1", title: "第一条", transcript: "内容一"), source(id: "s2", title: "第二条", transcript: "内容二")]
        XCTAssertTrue(try mirror.write(sources: first, claims: [], actions: [], now: start))
        let secondFile = mirrorDirectory.appendingPathComponent("materials").appendingPathComponent("s2.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondFile.path))

        let changed = [source(id: "s1", title: "改写", transcript: "内容三")]
        XCTAssertFalse(try mirror.write(sources: changed, claims: [], actions: [], now: start.addingTimeInterval(30)))
        let unchanged = try String(contentsOf: mirrorDirectory.appendingPathComponent("materials").appendingPathComponent("s1.md"), encoding: .utf8)
        XCTAssertTrue(unchanged.contains("第一条"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondFile.path))

        XCTAssertTrue(try mirror.write(sources: changed, claims: [], actions: [], now: start.addingTimeInterval(61)))
        let rewritten = try String(contentsOf: mirrorDirectory.appendingPathComponent("materials").appendingPathComponent("s1.md"), encoding: .utf8)
        XCTAssertTrue(rewritten.contains("改写"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondFile.path))
    }

    func testDatabaseBackupCreatesVerifiedCopiesAndKeepsSeven() async throws {
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await store.recover()
        let database = root.appendingPathComponent("voiceos.sqlite")
        let before = try Data(contentsOf: database)
        let directory = root.appendingPathComponent("Backups", isDirectory: true)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var created: [URL] = []
        for index in 0..<9 {
            created.append(try DatabaseBackup.create(database: database, directory: directory, retain: 7, now: start.addingTimeInterval(Double(index) * 60)))
        }
        let retained = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "sqlite" }
        XCTAssertEqual(retained.count, 7)
        let names = Set(retained.map { $0.lastPathComponent })
        XCTAssertFalse(names.contains(created[0].lastPathComponent))
        XCTAssertFalse(names.contains(created[1].lastPathComponent))
        XCTAssertTrue(names.contains(created[8].lastPathComponent))
        XCTAssertTrue(DatabaseBackup.integrityCheck(at: try XCTUnwrap(created.last)))
        XCTAssertEqual(try Data(contentsOf: database), before)
    }
}
