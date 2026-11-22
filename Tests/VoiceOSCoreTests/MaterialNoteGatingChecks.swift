import XCTest
@testable import VoiceOSCore

final class MaterialNoteGatingChecks: XCTestCase {
    private func source(_ id: String, state: String = "saved", transcript: String? = "原话",
                        versionID: String? = "t-1", localOnly: Bool = false,
                        policyVersion: Int = 1, kind: String = "user_text",
                        backend: String? = nil, spans: [TranscriptSpan] = [],
                        presentation: RecordingPresentation? = nil) -> SourceRecord {
        SourceRecord(id: id, assetID: "asset-" + id, name: id, state: state, kind: kind,
                     createdAt: "2026-04-01T00:00:00Z", bytes: 1, duration: nil, jobState: "completed",
                     transcript: transcript, error: nil, relativePath: "assets/" + id,
                     transcriptVersionID: versionID, transcriptionBackend: backend, spans: spans,
                     localOnly: localOnly, policyVersion: policyVersion, origin: "user", speaker: "user",
                     feedbackActionID: nil, feedbackActionVersion: nil, feedbackKind: nil,
                     feedbackRelation: nil, timeZone: "Asia/Shanghai", presentation: presentation)
    }

    private func timedSpans() -> [TranscriptSpan] {
        [TranscriptSpan(id: "s1", textStart: 0, textEnd: 2, startMS: 0, endMS: 100)]
    }

    private func reviewedPresentation(_ versionID: String) -> RecordingPresentation {
        var presentation = RecordingPresentation()
        presentation.transcriptionReview = TranscriptionReview(
            completed: true, changed: false, response_id: "review", response_ids: ["review"],
            context_review_version: 3, corrections: [], unresolved_issues: [],
            transcriptVersionID: versionID, scope: "complete_expression_knowledge_and_intent",
            full_text_independent_passes: 1, review_method: "direct_ai")
        presentation.transcriptVersionID = versionID
        return presentation
    }

    private func catalog(_ records: [SourceRecord]) -> [String: SourceRecord] {
        Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func test不可用门控矩阵按成员顺序返回首个原因() {
        struct Row {
            let name: String
            let present: [SourceRecord]
            let memberIDs: [String]
            let expected: String?
        }
        let rows: [Row] = [
            Row(name: "单成员就绪", present: [source("a")], memberIDs: ["a"], expected: nil),
            Row(name: "reference_only 可参与生成", present: [source("a", state: "reference_only")],
                memberIDs: ["a"], expected: nil),
            Row(name: "空成员视为就绪", present: [], memberIDs: [], expected: nil),
            Row(name: "材料缺失", present: [], memberIDs: ["a"], expected: "材料已变化或已移出资料库"),
            Row(name: "缺失先于后位成员的其他原因", present: [source("b", localOnly: true)],
                memberIDs: ["a", "b"], expected: "材料已变化或已移出资料库"),
            Row(name: "state 非 saved", present: [source("a", state: "processing")],
                memberIDs: ["a"], expected: "材料尚未保存完成"),
            Row(name: "state 非 reference_only", present: [source("a", state: "failed")],
                memberIDs: ["a"], expected: "材料尚未保存完成"),
            Row(name: "state 先于 localOnly", present: [source("a", state: "processing", localOnly: true)],
                memberIDs: ["a"], expected: "材料尚未保存完成"),
            Row(name: "仅本机保存", present: [source("a", localOnly: true)],
                memberIDs: ["a"], expected: "仅本机保存"),
            Row(name: "localOnly 先于无转写", present: [source("a", transcript: nil, localOnly: true)],
                memberIDs: ["a"], expected: "仅本机保存"),
            Row(name: "无转写", present: [source("a", transcript: nil)],
                memberIDs: ["a"], expected: "尚无转写"),
            Row(name: "空转写", present: [source("a", transcript: "")],
                memberIDs: ["a"], expected: "尚无转写"),
            Row(name: "纯空白转写", present: [source("a", transcript: " \n　")],
                memberIDs: ["a"], expected: "尚无转写"),
            Row(name: "无转写版本号", present: [source("a", versionID: nil)],
                memberIDs: ["a"], expected: "尚无转写"),
            Row(name: "Qwen 转写核对未完成", present: [source("a", kind: "audio", backend: "Qwen3-ASR-1.7B",
                                                              spans: timedSpans())],
                memberIDs: ["a"], expected: "转写核对未完成，暂不能交给云端整理"),
            Row(name: "仅本机先于转写核对", present: [source("a", kind: "audio", backend: "Qwen3-ASR-1.7B",
                                                            localOnly: true, spans: timedSpans())],
                memberIDs: ["a"], expected: "仅本机保存"),
            Row(name: "Qwen 转写核对完成后可生成",
                present: [source("a", kind: "audio", backend: "Qwen3-ASR-1.7B", spans: timedSpans(),
                                 presentation: reviewedPresentation("t-1"))],
                memberIDs: ["a"], expected: nil),
            Row(name: "后位成员的原因", present: [source("a"), source("b", localOnly: true)],
                memberIDs: ["a", "b"], expected: "仅本机保存")
        ]
        for row in rows {
            XCTAssertEqual(MaterialNoteGating.unavailableReason(memberIDs: row.memberIDs, catalog: catalog(row.present)),
                           row.expected, row.name)
        }
    }

    func test转写版本映射跳过缺失与无版本成员() {
        struct Row {
            let name: String
            let present: [SourceRecord]
            let memberIDs: [String]
            let expected: [String: String]
        }
        let rows: [Row] = [
            Row(name: "全部成员有版本",
                present: [source("a", versionID: "t-a"), source("b", versionID: "t-b")],
                memberIDs: ["a", "b"], expected: ["a": "t-a", "b": "t-b"]),
            Row(name: "成员顺序不影响映射",
                present: [source("a", versionID: "t-a"), source("b", versionID: "t-b")],
                memberIDs: ["b", "a"], expected: ["a": "t-a", "b": "t-b"]),
            Row(name: "跳过缺失成员", present: [source("a", versionID: "t-a")],
                memberIDs: ["a", "b"], expected: ["a": "t-a"]),
            Row(name: "跳过无版本成员",
                present: [source("a", versionID: nil), source("b", versionID: "t-b")],
                memberIDs: ["a", "b"], expected: ["b": "t-b"]),
            Row(name: "空成员映射为空", present: [source("a", versionID: "t-a")],
                memberIDs: [], expected: [:])
        ]
        for row in rows {
            XCTAssertEqual(MaterialNoteGating.transcriptVersions(memberIDs: row.memberIDs, catalog: catalog(row.present)),
                           row.expected, row.name)
        }
    }

    func test快照保存生成前的成员字段() {
        let snapshot = MaterialNoteMemberSnapshot(source("a", state: "reference_only", versionID: "t-9",
                                                        localOnly: true, policyVersion: 4))
        XCTAssertEqual(snapshot.sourceID, "a")
        XCTAssertEqual(snapshot.state, "reference_only")
        XCTAssertEqual(snapshot.transcriptVersionID, "t-9")
        XCTAssertTrue(snapshot.localOnly)
        XCTAssertEqual(snapshot.policyVersion, 4)
    }

    func test成员快照逐字段比对() {
        struct Row {
            let name: String
            let original: SourceRecord
            let current: SourceRecord?
            let expected: Bool
        }
        let rows: [Row] = [
            Row(name: "完全一致视为未变", original: source("a"), current: source("a"), expected: true),
            Row(name: "reference_only 一致视为未变",
                original: source("a", state: "reference_only"), current: source("a", state: "reference_only"),
                expected: true),
            Row(name: "state 变化视为已变", original: source("a"), current: source("a", state: "failed"),
                expected: false),
            Row(name: "state 在允许值之间变化视为已变",
                original: source("a", state: "reference_only"), current: source("a", state: "saved"),
                expected: false),
            Row(name: "版本号变化视为已变",
                original: source("a", versionID: "t-1"), current: source("a", versionID: "t-2"),
                expected: false),
            Row(name: "版本号消失视为已变",
                original: source("a", versionID: "t-1"), current: source("a", versionID: nil),
                expected: false),
            Row(name: "policyVersion 变化视为已变",
                original: source("a", policyVersion: 1), current: source("a", policyVersion: 2),
                expected: false),
            Row(name: "localOnly 变化视为已变",
                original: source("a", localOnly: false), current: source("a", localOnly: true),
                expected: false),
            Row(name: "材料离开资料库视为已变", original: source("a"), current: nil, expected: false),
            Row(name: "字段全等但状态不可参与视为已变",
                original: source("a", state: "processing"), current: source("a", state: "processing"),
                expected: false)
        ]
        for row in rows {
            XCTAssertEqual(MaterialNoteMemberSnapshot(row.original).matches(row.current), row.expected, row.name)
        }
    }
}