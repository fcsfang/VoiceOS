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
        let base = try XCTUnwrap(afterSave)
        let edited = try await store.editMaterialNote(note("手改"), replacing: base)
        let late = try await store.saveMaterialNote(memberSourceIDs: ["a"], note: note("迟到的结果"),
                                                   transcriptVersions: base.transcriptVersions, modelIdentity: nil,
                                                   ifMembersStillMatch: [], replacing: base.id)
        XCTAssertNil(late)
        let latest = try await store.latestMaterialNote(memberSourceIDs: ["a"])
        XCTAssertEqual(latest, edited)
        XCTAssertEqual(latest?.note.manuallyEdited, true)
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

    func test旧笔记JSON无批注字段解码为空() throws {
        let json = #"{"title":"标题","lead":null,"sections":[{"heading":null,"paragraphs":[{"text":"一段","anchors":[]}]}]}"#
        let note = try JSONDecoder().decode(MaterialNote.self, from: Data(json.utf8))
        XCTAssertNil(note.closing)
        XCTAssertNil(note.sections[0].paragraphs[0].annotations)
    }

    func test批注字段解码保留类型身份与出处() throws {
        let json = #"{"title":"标题","lead":null,"sections":[{"heading":null,"paragraphs":[{"text":"一段","anchors":[],"annotations":[{"id":"a1","kind":"theory","text":"某理论认为…","quote":null,"title":null,"startsFrom":null,"voice":"导师","source":"家庭系统理论（Bowen）","confidence":"需核对"}]}]}],"closing":[{"id":"c1","kind":"extension","text":"从这段向外延伸…","quote":null,"title":"再看一眼","startsFrom":"一段","voice":null,"source":null,"confidence":null}]}"#
        let note = try JSONDecoder().decode(MaterialNote.self, from: Data(json.utf8))
        let annotation = try XCTUnwrap(note.sections[0].paragraphs[0].annotations?.first)
        XCTAssertEqual(annotation.kind, "theory")
        XCTAssertEqual(annotation.voice, "导师")
        XCTAssertEqual(annotation.source, "家庭系统理论（Bowen）")
        XCTAssertEqual(note.closing?.first?.kind, "extension")
    }

    func test锚定清掉无法定位的批注引文但保留批注本体() {
        let member = MaterialNoteMember(sourceID: "a", title: "材料", transcriptVersionID: nil,
                                        transcript: "原话在这里。", spans: [MaterialNoteSpan(id: "s1", text: "原话在这里。")])
        let note = MaterialNote(title: "标题", sections: [
            MaterialNote.Section(paragraphs: [
                MaterialNote.Paragraph(text: "一段", anchors: [], annotations: [
                    MaterialNote.Annotation(id: "a1", kind: "quote", text: "有依据的批注", quote: "原话在这里"),
                    MaterialNote.Annotation(id: "a2", kind: "extension", text: "发散批注", quote: "原文里没有这句")
                ])
            ])
        ], closing: [MaterialNote.Annotation(id: "c1", kind: "theory", text: "文末长文")])
        let anchored = MaterialNoteAnchoring.anchored(note, members: [member])
        let annotations = anchored.sections[0].paragraphs[0].annotations ?? []
        XCTAssertEqual(annotations.count, 2)
        XCTAssertEqual(annotations[0].quote, "原话在这里")
        XCTAssertNil(annotations[1].quote, "定位不到时只清掉引文")
        XCTAssertEqual(annotations[1].text, "发散批注")
        XCTAssertEqual(anchored.closing?.first?.text, "文末长文")
    }

    func test行内标记解码并在锚定时丢弃找不到的词句() throws {
        let json = #"{"title":"标题","lead":null,"sections":[{"heading":null,"paragraphs":[{"text":"我想弄明白充电匹配。","anchors":[],"marks":[{"id":"m1","text":"充电匹配","style":"underline","tone":"warm"},{"id":"m2","text":"原文里没有这句","style":null,"tone":null}]}]}]}"#
        let note = try JSONDecoder().decode(MaterialNote.self, from: Data(json.utf8))
        XCTAssertEqual(note.sections[0].paragraphs[0].marks?.count, 2)
        let member = MaterialNoteMember(sourceID: "a", title: "材料", transcriptVersionID: nil,
                                        transcript: "我想弄明白充电匹配。", spans: [])
        let anchored = MaterialNoteAnchoring.anchored(note, members: [member])
        let marks = anchored.sections[0].paragraphs[0].marks ?? []
        XCTAssertEqual(marks.count, 1, "改写过的标记直接忽略")
        XCTAssertEqual(marks.first?.text, "充电匹配")
        XCTAssertEqual(marks.first?.style, "underline")
    }

    func test旧笔记适配为文字块与批注块() {
        let note = MaterialNote(title: "标题", lead: "导语", sections: [
            MaterialNote.Section(heading: "一节", paragraphs: [MaterialNote.Paragraph(text: "一段")])
        ], closing: [MaterialNote.Annotation(id: "c1", kind: "theory", text: "长文")])
        let blocks = NoteBoardAdapting.blocks(for: note)
        XCTAssertEqual(blocks.map(\.kind), ["text", "insight"])
        XCTAssertEqual(blocks[0].paragraphs?.first?.text, "一段")
        XCTAssertEqual(blocks[1].annotation?.text, "长文")
    }

    func test引用失效的块降级为文字块而材料块被丢弃() {
        let blocks: [NoteBlock] = [
            NoteBlock(id: "b0", kind: "todo", actionID: "missing", titleOverride: "去买菜"),
            NoteBlock(id: "b1", kind: "claim", claimID: "c1"),
            NoteBlock(id: "b2", kind: "materials", sourceID: "s1"),
            NoteBlock(id: "b3", kind: "mystery", text: "自定义内容")
        ]
        let sanitized = NoteBoardSanitizing.sanitized(blocks, actionIDs: [], claimIDs: ["c1"], sourceIDs: ["s1"])
        XCTAssertEqual(sanitized.map(\.kind), ["text", "claim", "mystery"])
        XCTAssertEqual(sanitized.first?.paragraphs?.first?.text, "去买菜")
    }

    func test板引用解析汇总区分可解析与失效() {
        let note = MaterialNote(title: "板", sections: [], blocks: [
            NoteBlock(id: "b0", kind: "text", paragraphs: [MaterialNote.Paragraph(text: "正文")]),
            NoteBlock(id: "b1", kind: "todo", actionID: "a1"),
            NoteBlock(id: "b2", kind: "todo", actionID: "gone"),
            NoteBlock(id: "b3", kind: "claim", claimID: "c1"),
            NoteBlock(id: "b4", kind: "mystery", text: "自定义")
        ])
        let summary = NoteBoardResolving.summarize([note], actionIDs: ["a1"], claimIDs: ["c1"])
        XCTAssertEqual(summary.noteCount, 1)
        XCTAssertEqual(summary.todoBlocks, 2)
        XCTAssertEqual(summary.claimBlocks, 1)
        XCTAssertEqual(summary.unresolvedBlocks, 1, "失效的行动引用被计入")
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
