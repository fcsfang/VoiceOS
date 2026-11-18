import XCTest
@testable import VoiceOSCore

final class WorkspaceClickReadChecks: XCTestCase {
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

    private func expression(_ id: String, sourceIDs: [String]) -> RecordingPresentation {
        var presentation = RecordingPresentation()
        presentation.expression = RecordingExpression(id: id, sourceIDs: sourceIDs, title: "分组 " + id,
                                                      summary: "摘要", reason: "依据", responseIDs: ["response"],
                                                      versions: Dictionary(uniqueKeysWithValues: sourceIDs.map { ($0, "t-" + $0) }),
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

    func testSourcePageIndexClickReadsMatchDirectReads() {
        let fixture = fixture(count: 200)
        for record in fixture.records {
            XCTAssertEqual(fixture.index.recordsByID[record.id]?.id,
                           fixture.records.first(where: { $0.id == record.id })?.id,
                           "记录按 id 读取必须与逐行扫描一致")
        }
        for claim in fixture.claims {
            XCTAssertEqual(fixture.index.claim(for: claim.id)?.id,
                           fixture.claims.first(where: { $0.id == claim.id })?.id,
                           "观点按 id 读取必须与逐行扫描一致")
        }
        for action in fixture.actions {
            let directReview = WorkspaceActionPause.reason(for: action, sources: fixture.records, claims: fixture.claims,
                                                           currentClaimsBySource: fixture.current,
                                                           actions: fixture.actions, ledgers: fixture.ledgers) != nil
            XCTAssertEqual(fixture.index.requiresReview(action.id), directReview,
                           "待核对判定必须与直算一致：" + action.id)
            let directActive = fixture.actions.first(where: { $0.id == action.id && $0.state != "dismissed" })?.id
            XCTAssertEqual(fixture.index.activeAction(for: action.id)?.id, directActive,
                           "行动按 id 读取必须与逐行扫描一致：" + action.id)
        }
    }

    func testHomeAndMaterialRowReadsDoNotRescanTheLibrary() {
        let fixture = fixture(count: 500)
        let clock = ContinuousClock()
        let itemIDs = fixture.records.map(\.id)
        let progressRecordIDs = Array(itemIDs.prefix(12))
        let progressActionIDs = ["action-1", "action-2", "action-3"]

        func directHomePass() -> Int {
            var work = 0
            for id in itemIDs {
                if fixture.records.first(where: { $0.id == id }) != nil { work += 1 }
                if fixture.records.first(where: { $0.id == id }) != nil { work += 1 }
            }
            for id in progressRecordIDs where fixture.records.contains(where: { $0.id == id }) { work += 1 }
            for id in progressActionIDs {
                if let action = fixture.actions.first(where: { $0.id == id }),
                   WorkspaceActionPause.reason(for: action, sources: fixture.records, claims: fixture.claims,
                                               currentClaimsBySource: fixture.current,
                                               actions: fixture.actions, ledgers: fixture.ledgers) != nil {
                    work += 1
                }
            }
            return work
        }
        func indexHomePass() -> Int {
            var work = 0
            for id in itemIDs {
                if fixture.index.recordsByID[id] != nil { work += 1 }
                if fixture.index.recordsByID[id] != nil { work += 1 }
            }
            for id in progressRecordIDs where fixture.index.recordsByID[id] != nil { work += 1 }
            for id in progressActionIDs {
                if let action = fixture.index.activeAction(for: id), fixture.index.requiresReview(action.id) { work += 1 }
            }
            return work
        }
        func directMaterialPass() -> Int {
            var work = 0
            for _ in 0..<8 {
                let catalog = Dictionary(fixture.records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                for record in fixture.records where record.recordingExpression(in: catalog) != nil { work += 1 }
            }
            return work
        }
        func indexMaterialPass() -> Int {
            var work = 0
            let built = SourcePageIndex(records: fixture.records, claims: fixture.claims, actions: fixture.actions,
                                        currentClaimsBySource: fixture.current, ledgers: fixture.ledgers)
            for _ in 0..<8 {
                for record in fixture.records where built.expression(for: record.id) != nil { work += 1 }
            }
            return work
        }

        var directHome: [Double] = [], indexedHome: [Double] = []
        var directMaterial: [Double] = [], indexedMaterial: [Double] = []
        for _ in 0..<5 {
            var directWork = 0, indexedWork = 0
            directHome.append(seconds(clock.measure { directWork = directHomePass() }))
            indexedHome.append(seconds(clock.measure { indexedWork = indexHomePass() }))
            XCTAssertEqual(directWork, indexedWork, "首页行读取的工作量必须相等")
        }
        for _ in 0..<5 {
            var directWork = 0, indexedWork = 0
            directMaterial.append(seconds(clock.measure { directWork = directMaterialPass() }))
            indexedMaterial.append(seconds(clock.measure { indexedWork = indexMaterialPass() }))
            XCTAssertEqual(directWork, indexedWork, "材料页行读取的工作量必须相等")
        }
        let directHomeMedian = median(directHome), indexedHomeMedian = median(indexedHome)
        let directMaterialMedian = median(directMaterial), indexedMaterialMedian = median(indexedMaterial)
        print("home rows: direct=\(directHomeMedian)s indexed=\(indexedHomeMedian)s (5 alternating rounds)")
        print("material page: direct=\(directMaterialMedian)s indexed=\(indexedMaterialMedian)s (5 alternating rounds)")
        XCTAssertLessThan(indexedHomeMedian, directHomeMedian, "首页行读取改索引后必须快于逐行扫描")
        XCTAssertLessThan(indexedMaterialMedian, directMaterialMedian, "材料页改索引后必须快于逐行重建目录")
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
