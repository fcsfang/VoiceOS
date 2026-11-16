import XCTest
@testable import VoiceOSCore
import VoiceOSPlatform

final class NextActionIdempotencyChecks: XCTestCase {
    private var base: URL!
    private var root: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-next-action-" + UUID().uuidString)
        root = base.appendingPathComponent("library")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: base) }

    private func openStore() async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }

    private func addOutcome(_ store: VoiceOSStore, title: String) async throws -> ActionRecord {
        let source = try await store.recordUserExpression("需要核对的内容。")
        let context = try await store.prepareLocalTranscriptContext(sourceIDs: [source])
        let references = context.sources.map {
            ClaimReference(sourceID: $0.sourceID, transcriptVersionID: $0.transcriptVersionID, spanID: $0.spans[0].id)
        }
        let quote = try XCTUnwrap(context.sources.first?.text)
        let claimIDs = try await store.importOrganizedClaims(context: context, proposals: [
            .init(statement: title, ownership: .userTentative, references: references,
                  action: .init(title: title, kind: .opportunity, quote: quote))
        ], commandID: "next-action-claims-" + UUID().uuidString)
        let claimID = try XCTUnwrap(claimIDs.first)
        let actions = try await store.actions()
        return try XCTUnwrap(actions.first { $0.claimID == claimID })
    }

    func testRepeatedCreateWithStableCommandKeepsOneNextAction() async throws {
        let store = try await openStore()
        let outcome = try await addOutcome(store, title: "发布新版本")
        let commandID = "workspace-next-action:" + outcome.id + ":form"
        let first = try await store.createAction(claimID: outcome.claimID, expectedClaimReviewVersion: outcome.claimReviewVersion,
                                                 title: "写好发布说明", kind: .task, commandID: commandID)
        let retry = try await store.createAction(claimID: outcome.claimID, expectedClaimReviewVersion: outcome.claimReviewVersion,
                                                 title: "写好发布说明", kind: .task, commandID: commandID)
        XCTAssertEqual(retry, first)
        let created = try await store.actions(includeHistory: true).filter { $0.commandID == commandID }
        XCTAssertEqual(created.count, 1)
    }

    func testRepeatedAttachWithStableCommandAttachesOnce() async throws {
        let store = try await openStore()
        let outcome = try await addOutcome(store, title: "发布新版本")
        let commandID = "workspace-next-action:" + outcome.id + ":form"
        let taskID = try await store.createAction(claimID: outcome.claimID, expectedClaimReviewVersion: outcome.claimReviewVersion,
                                                  title: "写好发布说明", kind: .task, commandID: commandID)
        let first = try await store.attachNextAction(outcomeID: outcome.id, actionID: taskID, commandID: commandID + ":attach")
        let retry = try await store.attachNextAction(outcomeID: outcome.id, actionID: taskID, commandID: commandID + ":attach")
        XCTAssertEqual(retry, first)
        let database = await store.db
        let revisions = try database.query("SELECT count(*) AS n FROM action_revisions WHERE action_id=? AND command_id LIKE 'attach:%'",
                                           [taskID])
        XCTAssertEqual(revisions.first?["n"], "1")
        let attached = try await store.actions(includeHistory: true).first { $0.id == taskID }
        XCTAssertEqual(attached?.parentID, outcome.id)
        XCTAssertEqual(attached?.version, first)
    }
}
