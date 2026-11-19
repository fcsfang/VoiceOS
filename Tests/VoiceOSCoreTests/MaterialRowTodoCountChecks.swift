import XCTest
@testable import VoiceOSCore

final class MaterialRowTodoCountChecks: XCTestCase {
    private func source(_ id: String, presentation: RecordingPresentation? = nil) -> SourceRecord {
        SourceRecord(id: id, assetID: "asset-" + id, name: id, state: "saved", kind: "user_text",
                     createdAt: "2026-04-01T00:00:00Z", bytes: 1, duration: nil, jobState: "completed",
                     transcript: "原话 " + id, error: nil, relativePath: "assets/" + id,
                     transcriptVersionID: "t-" + id, transcriptionBackend: nil, spans: [],
                     localOnly: false, policyVersion: 1, origin: "user", speaker: "user",
                     feedbackActionID: nil, feedbackActionVersion: nil, feedbackKind: nil,
                     feedbackRelation: nil, timeZone: "Asia/Shanghai", presentation: presentation)
    }

    private func claim(_ id: String, _ sourceIDs: [String]) -> CandidateClaim {
        CandidateClaim(contentKind: nil, id: id, statement: "理解 " + id, ownership: "user_tentative",
                       evidenceState: "unverified", validity: "current",
                       references: sourceIDs.map { ClaimReference(sourceID: $0, transcriptVersionID: "t-" + $0, spanID: "span-" + $0) },
                       reviewVersion: 1, reviewState: "pending")
    }

    private func action(_ id: String, claimID: String, kind: String = "task", state: String = "open",
                        validity: String = "current") -> ActionRecord {
        ActionRecord(id: id, claimID: claimID, claimReviewVersion: 1,
                     title: "待办 " + id, kind: kind, intentActor: "user", note: "",
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

    private func index(records: [SourceRecord], claims: [CandidateClaim], actions: [ActionRecord]) -> SourcePageIndex {
        var current: [String: [CandidateClaim]] = [:]
        for claim in claims {
            for reference in claim.references { current[reference.sourceID, default: []].append(claim) }
        }
        return SourcePageIndex(records: records, claims: claims, actions: actions, currentClaimsBySource: current)
    }

    func test材料行只计当前开放且未被暂停的任务() {
        let records = [source("a"), source("b"), source("p", presentation: expression("expression-p", sourceIDs: ["p"]))]
        let claims = [claim("ca", ["a"]), claim("cb", ["b"]), claim("cab", ["a", "b"]), claim("cp", ["p"])]
        let actions = [
            action("open-a", claimID: "ca"),
            action("open-shared", claimID: "cab"),
            action("completed", claimID: "ca", state: "completed"),
            action("dismissed", claimID: "ca", state: "dismissed"),
            action("frozen", claimID: "ca", validity: "frozen"),
            action("goal", claimID: "ca", kind: "opportunity"),
            action("paused", claimID: "cp")
        ]
        let index = index(records: records, claims: claims, actions: actions)
        XCTAssertEqual(index.openActionCount(for: Set(["a"])), 2, "材料行只计当前开放的任务，已完成、已停止、历史记录与问题不计")
        XCTAssertEqual(index.openActionCount(for: Set(["b"])), 1, "引用多份材料的任务在每个材料行各计一次")
        XCTAssertEqual(index.openActionCount(for: Set(["p"])), 0, "需要核对的任务不计入材料行待办数")
    }

    func test组合材料合并待办时按行动去重() {
        let records = [source("x"), source("y")]
        let claims = [claim("cxy", ["x", "y"])]
        let actions = [action("shared", claimID: "cxy")]
        let index = index(records: records, claims: claims, actions: actions)
        XCTAssertEqual(index.openActionCount(for: Set(["x", "y"])), 1, "组合材料行合并成员材料时同一行动只计一次")
    }
}
