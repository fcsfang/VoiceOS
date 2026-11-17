import XCTest
@testable import VoiceOSCore
import VoiceOSPlatform

private struct SingleGroupExpressionPort: RecordingExpressionPort {
    func group(_ input: RecordingExpressionInput) async throws -> ([RecordingExpressionProposal], [String]) {
        let incoming = Set(input.newSourceIDs)
        let members = input.context.sources.filter { incoming.contains($0.sourceID) }
        guard !members.isEmpty else { return ([], ["receipt-a", "receipt-b"]) }
        let proposal = RecordingExpressionProposal(existingID: "", sourceIDs: members.map(\.sourceID),
            title: "自动分组标题", summary: "整体摘要", reason: "话题连续",
            evidence: members.map { TopicReadingEvidence(sourceID: $0.sourceID, quote: $0.text) })
        return ([proposal], ["receipt-a", "receipt-b"])
    }
}

final class RecordingExpressionDetailsChecks: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-expression-details-" + UUID().uuidString)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func openStore() async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }
    private func automaticSources(_ store: VoiceOSStore, _ texts: [String]) async throws -> [String] {
        var ids: [String] = []
        for (index, text) in texts.enumerated() {
            let id = try await store.recordUserExpression(text)
            _ = try await store.setSourceLocalOnly(sourceID: id, expectedVersion: 1, localOnly: false)
            try await store.registerAutomaticRecording(sourceID: id, inbox: "fixture", recordedAt: "2026-11-17T02:0\(index):00Z")
            ids.append(id)
        }
        return ids
    }
    private func source(_ id: String, transcript: String? = "原话内容", localOnly: Bool = false,
                        presentation: RecordingPresentation? = nil) -> SourceRecord {
        SourceRecord(id: id, assetID: "asset-" + id, name: id, state: "saved", kind: "user_text",
                     createdAt: "2026-11-17T00:00:00Z", bytes: 1, duration: nil, jobState: "completed",
                     transcript: transcript, error: nil, relativePath: "assets/" + id,
                     transcriptVersionID: "t-" + id, transcriptionBackend: nil, spans: [],
                     localOnly: localOnly, policyVersion: 1, origin: "user", speaker: "user",
                     feedbackActionID: nil, feedbackActionVersion: nil, feedbackKind: nil, feedbackRelation: nil,
                     timeZone: "Asia/Shanghai", presentation: presentation ?? RecordingPresentation())
    }

    func testGroupTitleIsSharedByEveryMemberAndSurvivesReload() async throws {
        let ids: [String] = try await {
            let store = try await openStore()
            let ids = try await automaticSources(store, ["第一段原话", "第二段原话"])
            let groups = try await store.connectRecordingExpressions(using: SingleGroupExpressionPort())
            XCTAssertEqual(groups.count, 1)
            try await store.renameRecording(sourceID: ids[0], title: "我的分组标题")
            let sources = try await store.sources()
            let catalog = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
            for id in ids {
                let member = try XCTUnwrap(catalog[id])
                XCTAssertEqual(member.presentation?.expression?.manualTitle, "我的分组标题")
                XCTAssertNil(member.presentation?.manualTitle)
                XCTAssertEqual(member.recordingExpression(in: catalog)?.displayTitle(in: catalog), "我的分组标题")
            }
            return ids
        }()
        let reopened = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await reopened.recover()
        let reopenedSources = try await reopened.sources()
        let reopenedCatalog = Dictionary(uniqueKeysWithValues: reopenedSources.map { ($0.id, $0) })
        XCTAssertEqual(reopenedCatalog[ids[1]]?.presentation?.expression?.manualTitle, "我的分组标题")
        try await reopened.renameRecording(sourceID: ids[1], title: nil)
        let clearedSources = try await reopened.sources()
        let cleared = Dictionary(uniqueKeysWithValues: clearedSources.map { ($0.id, $0) })
        XCTAssertNil(cleared[ids[0]]?.presentation?.expression?.manualTitle)
        XCTAssertEqual(cleared[ids[0]]?.recordingExpression(in: cleared)?.displayTitle(in: cleared), "自动分组标题")
    }

    func testSingleRecordingTitleStaysOnPresentation() async throws {
        let store = try await openStore()
        let id = try await store.recordUserExpression("单独的一段话")
        try await store.renameRecording(sourceID: id, title: "单段标题")
        let catalog = try await store.sources()
        let member = try XCTUnwrap(catalog.first)
        XCTAssertNil(member.presentation?.expression)
        XCTAssertEqual(member.presentation?.manualTitle, "单段标题")
        XCTAssertEqual(member.displayTitle, "单段标题")
    }

    func testSplitReturnsSegmentsToIndependentTitles() async throws {
        let store = try await openStore()
        let ids = try await automaticSources(store, ["第一段原话", "第二段原话"])
        _ = try await store.connectRecordingExpressions(using: SingleGroupExpressionPort())
        try await store.renameRecording(sourceID: ids[0], title: "分组标题")
        let changed = try await store.detachRecordingsFromExpressions(sourceIDs: [ids[0]])
        XCTAssertEqual(changed, 2)
        let sources = try await store.sources()
        for id in ids {
            let member = try XCTUnwrap(sources.first { $0.id == id })
            XCTAssertNil(member.presentation?.expression)
            XCTAssertEqual(member.displayTitle, id == ids[0] ? "第一段原话" : "第二段原话")
        }
        let remaining = try await store.recordingExpressions()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testSplitFromOneSegmentDetachesWholeGroup() async throws {
        let store = try await openStore()
        let ids = try await automaticSources(store, ["第一段原话", "第二段原话", "第三段原话"])
        _ = try await store.connectRecordingExpressions(using: SingleGroupExpressionPort())
        let changed = try await store.detachRecordingsFromExpressions(sourceIDs: [ids[1]])
        XCTAssertEqual(changed, 3)
        let sources = try await store.sources()
        let catalog = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        for id in ids { XCTAssertNil(catalog[id]?.presentation?.expression) }
        let remaining = try await store.recordingExpressions()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testChangedMemberExplainsUnavailableExpression() throws {
        let shared = RecordingExpression(id: "e1", sourceIDs: ["s1", "s2"], title: "自动分组标题",
            summary: "整体摘要", reason: "话题连续", responseIDs: [],
            versions: ["s1": "t-s1", "s2": "t-s2"], policies: ["s1": 1, "s2": 1],
            state: "completed", previousActionIDs: [])
        var firstPresentation = RecordingPresentation(expression: shared)
        firstPresentation.transcriptVersionID = "t-s1"
        let first = source("s1", presentation: firstPresentation)
        var secondPresentation = RecordingPresentation()
        secondPresentation.transcriptVersionID = "t-s2"
        let second = source("s2", presentation: secondPresentation)
        let catalog = ["s1": first, "s2": second]
        XCTAssertNil(first.recordingExpression(in: catalog))
        XCTAssertEqual(first.recordingExpressionIssue(in: catalog), "分组里有一段的原文或文字授权已变化")
    }

    func testDisplayTitleFallsBackToMemberTitles() {
        let shared = RecordingExpression(id: "e1", sourceIDs: ["s1", "s2"], title: "",
            summary: "整体摘要", reason: "话题连续", responseIDs: [], versions: [:], policies: [:],
            state: "completed", previousActionIDs: [])
        let catalog = ["s1": source("s1", transcript: "成员原话")]
        XCTAssertEqual(shared.displayTitle(in: catalog), "成员原话")
    }

    func testTopicAssignmentReasonNamesTheBlockingField() {
        let local = source("s1", localOnly: true)
        XCTAssertEqual(local.topicAssignmentReason(in: ["s1": local]), "部分文字仅本机保存，未交给 AI")
        let empty = source("s2", transcript: "")
        XCTAssertEqual(empty.topicAssignmentReason(in: ["s2": empty]), "还没有可读原文，暂未归组")
        let ready = source("s3")
        XCTAssertEqual(ready.topicAssignmentReason(in: ["s3": ready]), "AI 尚未连接到主题")
    }
}
