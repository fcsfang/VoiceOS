import XCTest
@testable import VoiceOSCore
import VoiceOSPlatform

final class MaterialNoteChecks: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-material-note-" + UUID().uuidString)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func openStore() async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }

    private func note(_ title: String) -> MaterialNote {
        MaterialNote(title: title, lead: "导语 " + title, sections: [
            MaterialNote.Section(heading: "缘起", paragraphs: [
                MaterialNote.Paragraph(text: "第一段 " + title, anchors: [
                    MaterialNote.Anchor(quote: "原话甲", sourceID: "a", transcriptVersionID: "ta-v1", spanID: "span-a"),
                    MaterialNote.Anchor(quote: "原话乙", sourceID: "b")
                ], inferred: true),
                MaterialNote.Paragraph(text: "第二段 " + title)
            ]),
            MaterialNote.Section(paragraphs: [
                MaterialNote.Paragraph(text: "无标题段 " + title, anchors: [])
            ])
        ])
    }

    func test保存后读回最新版本且字段逐项相等() async throws {
        let store = try await openStore()
        let saved = try await store.saveMaterialNote(memberSourceIDs: ["b", "a"], note: note("检索质量"),
                                                     transcriptVersions: ["a": "ta-v1", "b": "tb-v1"], modelIdentity: "fixture-model")
        XCTAssertEqual(saved.expressionKey, "a|b")
        let loaded = try await store.latestMaterialNote(memberSourceIDs: ["a", "b"])
        let latest = try XCTUnwrap(loaded)
        XCTAssertEqual(latest, saved)
        XCTAssertEqual(latest.note, note("检索质量"))
        XCTAssertEqual(latest.transcriptVersions, ["a": "ta-v1", "b": "tb-v1"])
        XCTAssertEqual(latest.modelIdentity, "fixture-model")
        XCTAssertEqual(latest.createdAt, saved.createdAt)
    }

    func test旧笔记JSON无inferred字段解码为nil() throws {
        let json = "{\"title\":\"标题\",\"lead\":null,\"sections\":[{\"heading\":null,\"paragraphs\":[{\"text\":\"一段\",\"anchors\":[]}]}]}"
        let note = try JSONDecoder().decode(MaterialNote.self, from: Data(json.utf8))
        XCTAssertNil(note.sections[0].paragraphs[0].inferred)
    }

    func test守卫保存仅在成员仍匹配时落库() async throws {
        let store = try await openStore()
        let record = SourceRecord(id: "a", assetID: "asset-a", name: "a", state: "saved", kind: "user_text",
                                  createdAt: "2026-04-01T00:00:00Z", bytes: 1, duration: nil, jobState: "completed",
                                  transcript: "原话", error: nil, relativePath: "assets/a",
                                  transcriptVersionID: "ta-v1", transcriptionBackend: nil, spans: [],
                                  localOnly: false, policyVersion: 1, origin: "user", speaker: "user",
                                  feedbackActionID: nil, feedbackActionVersion: nil, feedbackKind: nil,
                                  feedbackRelation: nil, timeZone: "Asia/Shanghai", presentation: nil)
        let blocked = try await store.saveMaterialNote(memberSourceIDs: ["a"], note: note("甲"),
                                                       transcriptVersions: ["a": "ta-v1"], modelIdentity: nil,
                                                       ifMembersStillMatch: [MaterialNoteMemberSnapshot(record)])
        XCTAssertNil(blocked, "成员已不在库中（或已变化）时不落库")
        let afterBlocked = try await store.latestMaterialNote(memberSourceIDs: ["a"])
        XCTAssertNil(afterBlocked)
        let saved = try await store.saveMaterialNote(memberSourceIDs: ["a"], note: note("乙"),
                                                     transcriptVersions: ["a": "ta-v1"], modelIdentity: nil,
                                                     ifMembersStillMatch: [])
        XCTAssertNotNil(saved, "空期望不做拦截")
        let afterSave = try await store.latestMaterialNote(memberSourceIDs: ["a"])
        XCTAssertEqual(afterSave?.note.title, "乙")
    }

    func test成员顺序不同命中同一expressionKey() async throws {
        let store = try await openStore()
        let first = try await store.saveMaterialNote(memberSourceIDs: ["b", "a"], note: note("甲"),
                                                     transcriptVersions: ["a": "ta-v1", "b": "tb-v1"], modelIdentity: nil)
        let second = try await store.saveMaterialNote(memberSourceIDs: ["a", "b"], note: note("乙"),
                                                      transcriptVersions: ["a": "ta-v1", "b": "tb-v1"], modelIdentity: nil)
        XCTAssertEqual(first.expressionKey, "a|b")
        XCTAssertEqual(second.expressionKey, first.expressionKey)
        let loaded = try await store.latestMaterialNote(memberSourceIDs: ["b", "a"])
        XCTAssertEqual(try XCTUnwrap(loaded), second)
        let db = await store.db
        XCTAssertEqual(try db.query("SELECT COUNT(DISTINCT expression_key) AS n FROM material_notes").first?["n"], "1")
        XCTAssertEqual(try db.query("SELECT COUNT(*) AS n FROM material_notes").first?["n"], "2")
    }

    func test再保存生成新版本且旧版本仍在库中() async throws {
        let store = try await openStore()
        let first = try await store.saveMaterialNote(memberSourceIDs: ["a"], note: note("旧"),
                                                     transcriptVersions: ["a": "ta-v1"], modelIdentity: nil)
        let second = try await store.saveMaterialNote(memberSourceIDs: ["a"], note: note("新"),
                                                      transcriptVersions: ["a": "ta-v1"], modelIdentity: "fixture-model")
        let loaded = try await store.latestMaterialNote(memberSourceIDs: ["a"])
        let latest = try XCTUnwrap(loaded)
        XCTAssertEqual(latest, second)
        XCTAssertNotEqual(latest.id, first.id)
        let db = await store.db
        XCTAssertEqual(try db.query("SELECT COUNT(*) AS n FROM material_notes").first?["n"], "2")
        XCTAssertEqual(try db.query("SELECT COUNT(*) AS n FROM material_notes WHERE id IN (?,?)", [first.id, second.id]).first?["n"], "2")
    }

    func test成员版本一致为current任一变化失效() async throws {
        let store = try await openStore()
        let stored = try await store.saveMaterialNote(memberSourceIDs: ["a", "b"], note: note("当前"),
                                                      transcriptVersions: ["a": "ta-v1", "b": "tb-v1"], modelIdentity: nil)
        let same = await store.materialNoteIsCurrent(stored, currentTranscriptVersions: ["b": "tb-v1", "a": "ta-v1"])
        XCTAssertTrue(same)
        let changed = await store.materialNoteIsCurrent(stored, currentTranscriptVersions: ["a": "ta-v1", "b": "tb-v2"])
        XCTAssertFalse(changed)
        let missing = await store.materialNoteIsCurrent(stored, currentTranscriptVersions: ["a": "ta-v1"])
        XCTAssertFalse(missing)
    }

    func test空成员latest返回nil() async throws {
        let store = try await openStore()
        let latest = try await store.latestMaterialNote(memberSourceIDs: [])
        XCTAssertNil(latest)
    }

    func test批量读每键只返回最新一版() async throws {
        let store = try await openStore()
        try await store.saveMaterialNote(memberSourceIDs: ["a"], note: note("第一版"),
                                         transcriptVersions: ["a": "ta-v1"], modelIdentity: nil)
        let newestA = try await store.saveMaterialNote(memberSourceIDs: ["a"], note: note("第二版"),
                                                       transcriptVersions: ["a": "ta-v2"], modelIdentity: nil)
        let newestBC = try await store.saveMaterialNote(memberSourceIDs: ["b", "c"], note: note("另一篇"),
                                                        transcriptVersions: ["b": "tb-v1", "c": "tc-v1"], modelIdentity: nil)
        let latest = try await store.latestMaterialNotes(expressionKeys: ["a", "b|c", "a"])
        XCTAssertEqual(latest.count, 2)
        XCTAssertEqual(latest["a"], newestA)
        XCTAssertEqual(latest["b|c"], newestBC)
    }

    func test最近笔记按整理时间倒序且每表达只一篇() async throws {
        let store = try await openStore()
        _ = try await store.saveMaterialNote(memberSourceIDs: ["a"], note: note("较早"),
                                             transcriptVersions: ["a": "ta-v1"], modelIdentity: nil)
        let second = try await store.saveMaterialNote(memberSourceIDs: ["b"], note: note("较晚"),
                                                      transcriptVersions: ["b": "tb-v1"], modelIdentity: nil)
        _ = try await store.saveMaterialNote(memberSourceIDs: ["a"], note: note("较早·第二版"),
                                             transcriptVersions: ["a": "ta-v2"], modelIdentity: nil)
        let recent = try await store.recentMaterialNotes(limit: 8)
        XCTAssertEqual(recent.count, 2)
        XCTAssertEqual(recent.first?.expressionKey, "a")
        XCTAssertEqual(recent.last, second)
    }

    func test批量读单行损坏不拖垮其余笔记() async throws {
        let store = try await openStore()
        let good = try await store.saveMaterialNote(memberSourceIDs: ["a"], note: note("完好"),
                                                    transcriptVersions: ["a": "ta-v1"], modelIdentity: nil)
        try await store.saveMaterialNote(memberSourceIDs: ["b"], note: note("将损坏"),
                                         transcriptVersions: ["b": "tb-v1"], modelIdentity: nil)
        let db = await store.db
        try db.execute("UPDATE material_notes SET note_json=? WHERE expression_key=?", ["{不是 JSON", "b"])
        let latest = try await store.latestMaterialNotes(expressionKeys: ["a", "b"])
        XCTAssertEqual(latest.count, 1)
        XCTAssertEqual(latest["a"], good)
        XCTAssertNil(latest["b"])
    }
}