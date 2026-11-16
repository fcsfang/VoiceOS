import XCTest
@testable import VoiceOSCore
import VoiceOSPlatform

final class ActionRevisionHistoryChecks: XCTestCase {
    private var base: URL!
    private var root: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-revision-history-" + UUID().uuidString)
        root = base.appendingPathComponent("library")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: base) }

    private func openStore() async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }

    private func addAction(_ store: VoiceOSStore, title: String, kind: ActionKind) async throws -> ActionRecord {
        let source = try await store.recordUserExpression("需要核对的内容。")
        let context = try await store.prepareLocalTranscriptContext(sourceIDs: [source])
        let references = context.sources.map {
            ClaimReference(sourceID: $0.sourceID, transcriptVersionID: $0.transcriptVersionID, spanID: $0.spans[0].id)
        }
        let quote = try XCTUnwrap(context.sources.first?.text)
        let claimIDs = try await store.importOrganizedClaims(context: context, proposals: [
            .init(statement: title, ownership: .userTentative, references: references,
                  action: .init(title: title, kind: kind, quote: quote))
        ], commandID: "revision-claims-" + UUID().uuidString)
        let claimID = try XCTUnwrap(claimIDs.first)
        let actions = try await store.actions()
        return try XCTUnwrap(actions.first { $0.claimID == claimID })
    }

    func testActionRevisionsListCompletionStateAndNatureNewestFirst() async throws {
        let store = try await openStore()
        let outcome = try await addAction(store, title: "把厨房整理好", kind: .opportunity)

        let completed = try await store.completeOutcome(actionID: outcome.id, expectedVersion: outcome.version, commandID: "revision-complete")
        let reopened = try await store.setActionState(actionID: outcome.id, expectedVersion: completed, state: .open, note: "重新打开继续推进", commandID: "revision-reopen")
        let classified = try await store.setActionNature(id: outcome.id, expectedVersion: reopened, nature: .goal, commandID: "revision-nature")

        let revisions = try await store.actionRevisions(actionID: outcome.id)
        XCTAssertEqual(revisions.map(\.version), [classified, reopened, completed])
        XCTAssertEqual(revisions.map(\.state), ["open", "open", "completed"])
        XCTAssertEqual(revisions.map(\.note), ["归类：目标", "重新打开继续推进", "目标达成"])
        XCTAssertEqual(revisions.map(\.actor), ["user", "user", "user"])
        XCTAssertEqual(revisions.map(\.fromVersion), [reopened - 1, completed - 1, outcome.version])
        XCTAssertEqual(revisions.map(\.commandID), ["nature:revision-nature", "revision-reopen", "revision-complete"])
        XCTAssertTrue(revisions.allSatisfy { !$0.id.isEmpty && !$0.createdAt.isEmpty })

        let task = try await addAction(store, title: "买收纳盒", kind: .task)
        let empty = try await store.actionRevisions(actionID: task.id)
        XCTAssertTrue(empty.isEmpty)
    }
}
