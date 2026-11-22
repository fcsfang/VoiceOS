import XCTest
@testable import VoiceOSCore
import VoiceOSPlatform

final class PromoteActionChecks: XCTestCase {
    private var base: URL!
    private var root: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-promote-action-" + UUID().uuidString)
        root = base.appendingPathComponent("library")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: base) }

    private func openStore(_ directory: URL? = nil) async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: directory ?? root, inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }

    private func addAction(_ store: VoiceOSStore, title: String, kind: ActionKind,
                           sourceID: String? = nil) async throws -> (action: ActionRecord, claimID: String) {
        let source: String
        if let sourceID { source = sourceID } else { source = try await store.recordUserExpression("需要核对的内容。") }
        let context = try await store.prepareLocalTranscriptContext(sourceIDs: [source])
        let references = context.sources.map {
            ClaimReference(sourceID: $0.sourceID, transcriptVersionID: $0.transcriptVersionID, spanID: $0.spans[0].id)
        }
        let quote = try XCTUnwrap(context.sources.first?.text)
        let claimIDs = try await store.importOrganizedClaims(context: context, proposals: [
            .init(statement: title, ownership: .userTentative, references: references,
                  action: .init(title: title, kind: kind, quote: quote))
        ], commandID: "promote-claims-" + UUID().uuidString)
        let claimID = try XCTUnwrap(claimIDs.first)
        let candidates = try await store.actions()
        let action = try XCTUnwrap(candidates.first { $0.claimID == claimID })
        return (action, claimID)
    }

    private func action(_ store: VoiceOSStore, _ id: String) async throws -> ActionRecord {
        let actions = try await store.actions(includeHistory: true)
        return try XCTUnwrap(actions.first { $0.id == id })
    }

    func testPromotionMakesTaskAndKeepsValidChain() async throws {
        let store = try await openStore()
        let seeded = try await addAction(store, title: "要不要做这件事", kind: .opportunity)
        XCTAssertEqual(seeded.action.kind, "opportunity")

        let version = try await store.promoteAction(actionID: seeded.action.id,
                                                    expectedVersion: seeded.action.version,
                                                    commandID: "promote-once")
        XCTAssertEqual(version, seeded.action.version + 1)

        let promoted = try await action(store, seeded.action.id)
        XCTAssertEqual(promoted.kind, "task")
        XCTAssertEqual(promoted.intentActor, "user")
        XCTAssertEqual(promoted.state, "open")
        XCTAssertEqual(promoted.validity, "current")
        XCTAssertEqual(promoted.version, seeded.action.version + 1)

        let history = try await store.actionHistory(actionID: seeded.action.id)
        XCTAssertEqual(history.map(\.version), [1, 2])
        XCTAssertEqual(history.last?.state, "open")
        XCTAssertEqual(history.last?.note, "转为待办")
        XCTAssertEqual(history.last?.actor, "user")

        let database = await store.db
        try VoiceOSStore.validateStoredActions(database)
    }

    func testPromotionIsIdempotentPerCommand() async throws {
        let store = try await openStore()
        let seeded = try await addAction(store, title: "需要提醒自己的问题", kind: .opportunity)

        let first = try await store.promoteAction(actionID: seeded.action.id,
                                                  expectedVersion: seeded.action.version,
                                                  commandID: "promote-repeat")
        let second = try await store.promoteAction(actionID: seeded.action.id,
                                                   expectedVersion: seeded.action.version,
                                                   commandID: "promote-repeat")
        XCTAssertEqual(first, seeded.action.version + 1)
        XCTAssertEqual(second, first)

        let database = await store.db
        XCTAssertEqual(try database.query("SELECT count(*) AS n FROM action_revisions WHERE command_id=?",
                                          ["promote:promote-repeat"]).first?["n"], "1")
        XCTAssertEqual(try database.query("SELECT version FROM actions WHERE id=?",
                                          [seeded.action.id]).first?["version"], String(first))
        let history = try await store.actionHistory(actionID: seeded.action.id)
        XCTAssertEqual(history.count, 2)

        do {
            _ = try await store.promoteAction(actionID: seeded.action.id, expectedVersion: first,
                                              commandID: "promote-repeat")
            XCTFail("同一提升命令更换内容必须被拒绝")
        } catch {
            XCTAssertEqual((error as? VoiceOSError)?.message, "同一提升命令不能更换行动或内容")
        }
    }

    func testPromotionRejectionMatrix() async throws {
        struct Seeded {
            let actionID: String
            let version: Int
        }
        struct Rejection {
            let name: String
            let seed: (VoiceOSStore) async throws -> Seeded
            let message: String
        }
        let cases: [Rejection] = [
            Rejection(name: "task", seed: { store in
                let seeded = try await self.addAction(store, title: "已经是待办", kind: .task)
                return Seeded(actionID: seeded.action.id, version: seeded.action.version)
            }, message: "只有问题与目标可以转为待办"),
            Rejection(name: "dismissed opportunity", seed: { store in
                let seeded = try await self.addAction(store, title: "已经放弃的问题", kind: .opportunity)
                _ = try await store.setActionState(actionID: seeded.action.id, expectedVersion: seeded.action.version,
                                                   state: .dismissed)
                return Seeded(actionID: seeded.action.id, version: seeded.action.version + 1)
            }, message: "只有未完成的问题与目标可以转为待办"),
            Rejection(name: "stale version", seed: { store in
                let seeded = try await self.addAction(store, title: "版本已经不匹配", kind: .opportunity)
                return Seeded(actionID: seeded.action.id, version: seeded.action.version + 1)
            }, message: "行动版本已变化，请重新核对"),
            Rejection(name: "missing action", seed: { _ in
                Seeded(actionID: UUID().uuidString, version: 1)
            }, message: "行动不存在"),
        ]
        for c in cases {
            let store = try await openStore()
            let seeded = try await c.seed(store)
            do {
                _ = try await store.promoteAction(actionID: seeded.actionID, expectedVersion: seeded.version)
                XCTFail("提升必须被拒绝：" + c.name)
            } catch {
                XCTAssertEqual((error as? VoiceOSError)?.message, c.message, c.name)
            }
        }
    }

    func testPromotedActionBecomesSchedulable() async throws {
        let store = try await openStore()
        let seeded = try await addAction(store, title: "需要被提醒的问题", kind: .opportunity)
        let proposal = try ReminderScheduleProposal(due: .dateOnly(localDate: "2026-11-20", timeZone: "Asia/Shanghai"),
                                                    authority: .userCommitment, rawExpression: "下周五",
                                                    anchorEventTime: Date(timeIntervalSince1970: 1_763_000_000))
        do {
            _ = try await store.recordActionSchedule(actionID: seeded.action.id,
                                                     expectedActionVersion: seeded.action.version,
                                                     expectedScheduleVersion: 0, proposal: proposal,
                                                     actor: .user, anchorTimeZone: "Asia/Shanghai")
            XCTFail("问题与目标不能直接排期")
        } catch {
            XCTAssertEqual((error as? VoiceOSError)?.message, "只有当前有效且未完成任务可以记录排期提案")
        }

        let promotedVersion = try await store.promoteAction(actionID: seeded.action.id,
                                                            expectedVersion: seeded.action.version)
        let intentID = try await store.recordActionSchedule(actionID: seeded.action.id,
                                                            expectedActionVersion: promotedVersion,
                                                            expectedScheduleVersion: 0, proposal: proposal,
                                                            actor: .user, anchorTimeZone: "Asia/Shanghai")
        let intents = try await store.actionScheduleIntents()
        let intent = try XCTUnwrap(intents.first { $0.id == intentID })
        XCTAssertEqual(intent.eligibleForPlanning, true)
        XCTAssertEqual(intent.due, proposal.due)

        let database = await store.db
        try VoiceOSStore.validateStoredActions(database)
    }

    func testPromotedActionSurvivesPackageRoundTrip() async throws {
        let store = try await openStore()
        let seeded = try await addAction(store, title: "需要提醒的问题", kind: .opportunity)
        let promotedVersion = try await store.promoteAction(actionID: seeded.action.id,
                                                            expectedVersion: seeded.action.version,
                                                            commandID: "promote-round-trip")
        let package = base.appendingPathComponent("package")
        try await store.exportPackage(to: package, includeMedia: true)
        let restoredRoot = base.appendingPathComponent("restored")
        try await VoiceOSStore.restorePackage(from: package, to: restoredRoot, inspector: NativeMediaInspector())

        let restored = try await openStore(restoredRoot)
        let restoredAction = try await action(restored, seeded.action.id)
        XCTAssertEqual(restoredAction.kind, "task")
        XCTAssertEqual(restoredAction.intentActor, "user")
        XCTAssertEqual(restoredAction.version, promotedVersion)
        let history = try await restored.actionHistory(actionID: seeded.action.id)
        XCTAssertEqual(history.last?.note, "转为待办")
    }

    func testPromotedExpressionAdoptedOpportunityStaysValid() async throws {
        let store = try await openStore()
        let sourceID = try await store.recordUserExpression("这件事需要回看。")
        let old = try await addAction(store, title: "要不要继续这件事", kind: .opportunity, sourceID: sourceID)
        let new = try await addAction(store, title: "要不要继续这件事", kind: .opportunity, sourceID: sourceID)
        let database = await store.db
        let oldRow = try XCTUnwrap(try database.query("SELECT * FROM actions WHERE id=?", [old.action.id]).first)
        let newRow = try XCTUnwrap(try database.query("SELECT * FROM actions WHERE id=?", [new.action.id]).first)
        let metadata = ActionIntentMetadata(
            intentType: "idea", followupState: "pending", uncertain: false,
            expressionHistory: [.init(fromClaimID: old.claimID, fromReviewVersion: Int(oldRow["claim_review_version"]!)!,
                                      fromTitle: oldRow["title"]!, fromNote: oldRow["note"]!, fromKind: oldRow["kind"]!,
                                      fromAutoSend: false, toClaimID: new.claimID, replacedActionID: new.action.id,
                                      responseIDs: ["review-1", "review-2"])])
        // Mirrors the stored shape of a completed expression adoption before the promotion.
        try database.execute("UPDATE actions SET claim_id=?,claim_review_version=?,title=?,note=?,intent_json=? WHERE id=?",
                             [new.claimID, newRow["claim_review_version"]!, newRow["title"]!, newRow["note"]!,
                              String(decoding: try JSONEncoder().encode(metadata), as: UTF8.self), old.action.id])
        try database.execute("UPDATE actions SET validity='frozen' WHERE id=?", [new.action.id])
        try VoiceOSStore.validateStoredActions(database)
        try VoiceOSStore.validateStoredCognition(database)

        let promotedVersion = try await store.promoteAction(actionID: old.action.id,
                                                            expectedVersion: Int(oldRow["version"]!)!)
        XCTAssertEqual(promotedVersion, Int(oldRow["version"]!)! + 1)
        let promoted = try await action(store, old.action.id)
        XCTAssertEqual(promoted.kind, "task")
        try VoiceOSStore.validateStoredActions(database)
        try VoiceOSStore.validateStoredCognition(database)
    }
}
