import XCTest
@testable import VoiceOSCore

final class MultiSegmentMergeChecks: XCTestCase {
    private func source(_ id: String, createdAt: String, transcript: String = "原话内容",
                        state: String = "saved", localOnly: Bool = false, duration: Double? = nil,
                        expression: RecordingExpression? = nil) -> SourceRecord {
        SourceRecord(id: id, assetID: "asset-" + id, name: id, state: state, kind: "user_text", createdAt: createdAt,
                     bytes: 1, duration: duration, jobState: "completed", transcript: transcript, error: nil,
                     relativePath: "assets/" + id, transcriptVersionID: "t-" + id, transcriptionBackend: nil,
                     spans: [], localOnly: localOnly, policyVersion: 1, origin: "user", speaker: "user",
                     feedbackActionID: nil, feedbackActionVersion: nil, feedbackKind: nil, feedbackRelation: nil,
                     timeZone: "Asia/Shanghai", presentation: expression.map { RecordingPresentation(expression: $0) })
    }

    private func expression(_ id: String, sourceIDs: [String]) -> RecordingExpression {
        RecordingExpression(id: id, sourceIDs: sourceIDs, title: "连续对话", summary: "整段摘要", reason: "同一次对话",
                            responseIDs: [],
                            versions: Dictionary(sourceIDs.map { ($0, "t-" + $0) }, uniquingKeysWith: { first, _ in first }),
                            policies: Dictionary(sourceIDs.map { ($0, 1) }, uniquingKeysWith: { first, _ in first }),
                            state: "completed", previousActionIDs: [])
    }

    private func claim(_ id: String, sourceID: String, statement: String) -> CandidateClaim {
        CandidateClaim(contentKind: nil, id: id, statement: statement, ownership: "user_tentative",
                       evidenceState: "unverified", validity: "current",
                       references: [ClaimReference(sourceID: sourceID, transcriptVersionID: "t-" + sourceID, spanID: "span-" + sourceID)],
                       reviewVersion: 1, reviewState: "pending")
    }

    func testSegmentsOfOneExpressionMergeIntoOneItem() {
        let shared = expression("e1", sourceIDs: ["s1", "s2"])
        let sources = [
            source("s1", createdAt: "2024-05-01T10:00:00Z", duration: 60, expression: shared),
            source("s2", createdAt: "2024-05-01T10:05:00Z", duration: 90, expression: shared),
        ]
        let claims = [
            claim("c1", sourceID: "s1", statement: "【观点】第一段的收获"),
            claim("c2", sourceID: "s2", statement: "【观点】第一段的收获"),
            claim("c3", sourceID: "s2", statement: "【长期目标】持续练习"),
        ]
        let calendar = Calendar(identifier: .gregorian)
        let days = RecentContentIndex.build(sources: sources, claims: claims, calendar: calendar)
        let materials = days.flatMap(\.items).filter { $0.kind == .material }
        guard let item = materials.first else { return XCTFail("merged material missing") }
        XCTAssertEqual(materials.count, 1)
        XCTAssertEqual(item.id, "e1")
        XCTAssertEqual(item.sourceIDs, ["s1", "s2"])
        XCTAssertEqual(item.title, "连续对话")
        XCTAssertEqual(item.summary, "整段摘要")
        XCTAssertEqual(item.date, RecentContentIndex.date(of: sources[1]))
        XCTAssertEqual(item.duration, 150)
        XCTAssertEqual(item.thoughts.map(\.statement), ["第一段的收获", "持续练习"])
        XCTAssertEqual(item.thoughts.map(\.kind), [.insight, .goal])
    }

    func testChangedMemberKeepsSegmentsSeparate() {
        let shared = expression("e1", sourceIDs: ["s1", "s2"])
        let sources = [
            source("s1", createdAt: "2024-05-01T10:00:00Z", expression: shared),
            source("s2", createdAt: "2024-05-01T10:05:00Z"),
        ]
        let days = RecentContentIndex.build(sources: sources, claims: [], calendar: Calendar(identifier: .gregorian))
        let ids = days.flatMap(\.items).filter { $0.kind == .material }.map(\.id)
        XCTAssertEqual(Set(ids), ["s1", "s2"])
    }

    func testMissingMemberKeepsSegmentsSeparate() {
        let shared = expression("e1", sourceIDs: ["s1", "s2"])
        let sources = [
            source("s1", createdAt: "2024-05-01T10:00:00Z", expression: shared),
            source("s2", createdAt: "2024-05-01T10:05:00Z", state: "trashed", expression: shared),
        ]
        let days = RecentContentIndex.build(sources: sources, claims: [], calendar: Calendar(identifier: .gregorian))
        let ids = days.flatMap(\.items).filter { $0.kind == .material }.map(\.id)
        XCTAssertEqual(ids, ["s1"])
    }

    func testSingleSourceExpressionStaysItsOwnItem() {
        let shared = expression("e1", sourceIDs: ["s1"])
        let sources = [source("s1", createdAt: "2024-05-01T10:00:00Z", expression: shared)]
        let days = RecentContentIndex.build(sources: sources, claims: [], calendar: Calendar(identifier: .gregorian))
        let items = days.flatMap(\.items).filter { $0.kind == .material }
        XCTAssertEqual(items.map(\.id), ["s1"])
    }

    func testDuplicateMembershipIsDeduped() {
        let shared = expression("e1", sourceIDs: ["s1", "s1", "s2"])
        let sources = [
            source("s1", createdAt: "2024-05-01T10:00:00Z", expression: shared),
            source("s2", createdAt: "2024-05-01T10:05:00Z", expression: shared),
        ]
        let days = RecentContentIndex.build(sources: sources, claims: [], calendar: Calendar(identifier: .gregorian))
        let items = days.flatMap(\.items).filter { $0.kind == .material }
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.sourceIDs, ["s1", "s2"])
    }
}
