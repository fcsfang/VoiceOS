import XCTest
@testable import VoiceOSCore

final class WorkspaceRemainingReadChecks: XCTestCase {
    private struct Fixture {
        let records: [SourceRecord]
        let claims: [CandidateClaim]
        let actions: [ActionRecord]
        let current: [String: [CandidateClaim]]
        let ledgers: [String: ActionReviewLedger]
        let index: SourcePageIndex
    }

    private func source(_ id: String, createdAt: String = "2026-04-01T00:00:00Z",
                        presentation: RecordingPresentation? = nil) -> SourceRecord {
        SourceRecord(id: id, assetID: "asset-" + id, name: id, state: "saved", kind: "user_text",
                     createdAt: createdAt, bytes: 1, duration: nil, jobState: "completed",
                     transcript: "原话 " + id, error: nil, relativePath: "assets/" + id,
                     transcriptVersionID: "t-" + id, transcriptionBackend: nil, spans: [],
                     localOnly: false, policyVersion: 1, origin: "user", speaker: "user",
                     feedbackActionID: nil, feedbackActionVersion: nil, feedbackKind: nil,
                     feedbackRelation: nil, timeZone: "Asia/Shanghai", presentation: presentation)
    }

    private func claim(_ id: String, sourceIDs: [String], validity: String = "current") -> CandidateClaim {
        CandidateClaim(contentKind: nil, id: id, statement: "理解 " + id, ownership: "user_tentative",
                       evidenceState: "unverified", validity: validity,
                       references: sourceIDs.map { ClaimReference(sourceID: $0, transcriptVersionID: "t-" + $0, spanID: "span-" + $0) },
                       reviewVersion: 1, reviewState: "pending")
    }

    private func action(_ id: String, claimID: String, validity: String = "current",
                        state: String = "open", claimReviewVersion: Int = 1) -> ActionRecord {
        ActionRecord(id: id, claimID: claimID, claimReviewVersion: claimReviewVersion,
                     title: "待办 " + id, kind: "task", intentActor: "user", note: "",
                     state: state, validity: validity, version: 1, autoSend: true,
                     intent: ActionIntentMetadata(intentType: "task", followupState: "pending", uncertain: false),
                     commandID: "test:" + id, createdAt: "2026-01-01T00:00:00Z", parentID: nil)
    }

    private func expression(_ id: String, sourceIDs: [String], brokenMember: Bool = false) -> RecordingPresentation {
        var presentation = RecordingPresentation()
        presentation.expression = RecordingExpression(
            id: id, sourceIDs: sourceIDs, title: "分组 " + id, summary: "摘要", reason: "依据",
            responseIDs: ["response"],
            versions: Dictionary(uniqueKeysWithValues: sourceIDs.enumerated().map { ($0.element, brokenMember && $0.offset == sourceIDs.count - 1 ? "stale-" + $0.element : "t-" + $0.element) }),
            policies: Dictionary(uniqueKeysWithValues: sourceIDs.map { ($0, 1) }),
            state: "completed", previousActionIDs: [])
        return presentation
    }

    private func fixture(count: Int) -> Fixture {
        var grouped: [String: RecordingPresentation] = [:]
        for start in stride(from: 0, to: count - 1, by: 25) {
            let presentation = expression("expression-\(start)", sourceIDs: ["src-\(start)", "src-\(start + 1)"])
            grouped["src-\(start)"] = presentation
            grouped["src-\(start + 1)"] = presentation
        }
        let broken = expression("expression-broken", sourceIDs: ["src-3", "src-4"], brokenMember: true)
        grouped["src-3"] = broken
        grouped["src-4"] = broken
        let records = (0..<count).map { offset in
            source("src-\(offset)", presentation: grouped["src-\(offset)"])
        }
        var claims = (0..<count).map { claim("claim-\($0)", sourceIDs: ["src-\($0)"]) }
        claims.append(claim("claim-shared", sourceIDs: ["src-0", "src-1"]))
        var actions = (0..<60).map { offset in
            action("action-\(offset)", claimID: "claim-\(offset)",
                   validity: offset % 4 == 0 ? "frozen" : "current",
                   state: offset % 13 == 0 ? "dismissed" : "open",
                   claimReviewVersion: offset % 7 == 0 ? 0 : 1)
        }
        actions.append(action("action-shared", claimID: "claim-shared", validity: "frozen"))
        var current: [String: [CandidateClaim]] = [:]
        for claim in claims {
            for reference in claim.references { current[reference.sourceID, default: []].append(claim) }
        }
        let ledgers = ActionReviewLedger.buildMap(expressions: records.compactMap { $0.presentation?.expression },
                                                  actions: actions, resolutions: [], acknowledgements: [],
                                                  linkedActionIDs: [])
        let index = SourcePageIndex(records: records, claims: claims, actions: actions,
                                    currentClaimsBySource: current, ledgers: ledgers)
        return Fixture(records: records, claims: claims, actions: actions, current: current, ledgers: ledgers, index: index)
    }

    private func directPauseReason(_ fixture: Fixture, _ action: ActionRecord) -> WorkspaceActionPauseReason? {
        WorkspaceActionPause.reason(for: action, sources: fixture.records, claims: fixture.claims,
                                     currentClaimsBySource: fixture.current, actions: fixture.actions,
                                     ledgers: fixture.ledgers)
    }

    func testRemainingIndexReadsMatchDirectReads() {
        let fixture = fixture(count: 120)
        let directPaused = fixture.actions.filter { $0.kind == "task" && directPauseReason(fixture, $0) != nil }
        XCTAssertEqual(fixture.index.pausedTasks.map(\.id), directPaused.map(\.id),
                       "暂停任务索引读必须与整库直算一致且保持工作台顺序")
        XCTAssertFalse(fixture.index.pausedTasks.isEmpty, "fixture 必须包含暂停任务")
        let catalog = Dictionary(fixture.records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for record in fixture.records {
            XCTAssertEqual(fixture.index.expressionIssue(for: record.id), record.recordingExpressionIssue(in: catalog),
                           "表达问题索引读必须与直算一致：" + record.id)
        }
        XCTAssertNotNil(fixture.index.expressionIssue(for: "src-4"), "损坏的分组必须给出表达问题")
        for action in fixture.actions {
            XCTAssertEqual(fixture.index.allAction(for: action.id)?.id,
                           fixture.actions.first(where: { $0.id == action.id })?.id,
                           "全量行动读取必须与逐行扫描一致：" + action.id)
        }
        let dismissed = fixture.actions.filter { $0.state == "dismissed" }
        XCTAssertFalse(dismissed.isEmpty, "fixture 必须包含 dismissed 行动")
        for action in dismissed {
            XCTAssertNil(fixture.index.activeAction(for: action.id), "未 dismiss 访问器不得返回 dismissed 行动：" + action.id)
            XCTAssertEqual(fixture.index.allAction(for: action.id)?.state, "dismissed", "全量访问器必须返回 dismissed 行动：" + action.id)
        }
        XCTAssertFalse(fixture.index.pausedTasks.contains { $0.state == "dismissed" }, "暂停任务不得包含 dismissed 行动")
    }

    func testPausedTasksAndExpressionIssuesDoNotRescanTheLibrary() {
        let fixture = fixture(count: 400)
        let catalog = Dictionary(fixture.records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let clock = ContinuousClock()
        let passes = 20

        // One pass mirrors the old processing-page body: a full-library pause
        // filter plus a per-material expression-issue check.
        func directPass() -> Int {
            var work = fixture.actions.filter { $0.kind == "task" && directPauseReason(fixture, $0) != nil }.count
            for record in fixture.records where (record.presentation?.expression?.sourceIDs.count ?? 0) > 1 {
                if record.recordingExpressionIssue(in: catalog) != nil { work += 1 }
            }
            return work
        }
        func indexPass() -> Int {
            var work = fixture.index.pausedTasks.count
            for record in fixture.records where (record.presentation?.expression?.sourceIDs.count ?? 0) > 1 {
                if fixture.index.expressionIssue(for: record.id) != nil { work += 1 }
            }
            return work
        }

        var direct: [Double] = []
        var indexed: [Double] = []
        var directWork = 0, indexWork = 0
        for _ in 0..<5 {
            direct.append(seconds(clock.measure {
                for _ in 0..<passes { directWork += directPass() }
            }))
            let build = clock.measure { _ = SourcePageIndex(records: fixture.records, claims: fixture.claims,
                                                            actions: fixture.actions,
                                                            currentClaimsBySource: fixture.current,
                                                            ledgers: fixture.ledgers) }
            let reads = clock.measure {
                for _ in 0..<passes { indexWork += indexPass() }
            }
            indexed.append(seconds(build) + seconds(reads))
        }
        XCTAssertEqual(directWork, indexWork, "行动页剩余读取的工作量必须相等")
        let directMedian = median(direct), indexedMedian = median(indexed)
        print("paused tasks + expression issues: direct=\(directMedian)s indexed=\(indexedMedian)s (5 alternating rounds)")
        XCTAssertLessThan(indexedMedian, directMedian, "暂停任务与表达问题改索引后必须快于逐页整库直算")
    }

    private func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
