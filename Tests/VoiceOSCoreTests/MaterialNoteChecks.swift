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
                ]),
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
}