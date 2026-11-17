import XCTest
@testable import VoiceOSCore
import VoiceOSPlatform

private struct LinkingFollowupPort: RecordingFollowupPort {
    func generate(_ input: RecordingFollowupInput) async throws -> RecordingFollowupGeneration {
        let english = PracticeFollowup(isPractice: false, evidenceQuote: "", suggestions: [], comparisons: [], nextExercise: "")
        guard let thought = input.thoughts.first, let evidence = thought.evidence.first else {
            return .init(result: .init(thoughtUpdates: [], goalPlans: [], english: english), responseIDs: ["fixture-linking"])
        }
        let update = ThoughtUpdate(claimID: thought.id, currentQuote: input.current.sources[0].text, historicalQuote: evidence.quote,
                                   relation: "supports", understanding: "这轮继续谈到同一主题", reason: "原话延续了旧观点")
        return .init(result: .init(thoughtUpdates: [update], goalPlans: [], english: english), responseIDs: ["fixture-linking"])
    }
}

final class FollowupValidityLatestChecks: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-followup-latest-" + UUID().uuidString)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func openStore() async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }
    private func allowCloud(_ store: VoiceOSStore, _ sourceID: String) async throws {
        _ = try await store.setSourceLocalOnly(sourceID: sourceID, expectedVersion: 1, localOnly: false)
    }
    private func importClaim(_ store: VoiceOSStore, sourceID: String, statement: String, commandID: String) async throws -> CandidateClaim {
        let context = try await store.prepareLocalTranscriptContext(sourceIDs: [sourceID])
        let item = try XCTUnwrap(context.sources.first)
        _ = try await store.importOrganizedClaims(context: context, proposals: [
            .init(statement: statement, ownership: .userTentative,
                  references: [.init(sourceID: sourceID, transcriptVersionID: item.transcriptVersionID, spanID: item.spans[0].id)])
        ], commandID: commandID)
        let claims = try await store.candidateClaims()
        return try XCTUnwrap(claims.first { $0.statement == statement })
    }
    /// One thought on an earlier source, then a followup on a later source that
    /// links back to it, so the receipt records the thought as current.
    private func seedReceipt(_ store: VoiceOSStore) async throws -> (thoughtSource: String, receipt: RecordingFollowupReceipt, claim: CandidateClaim) {
        let thoughtSource = try await store.recordUserExpression("检索质量决定回答质量。")
        let practiceSource = try await store.recordUserExpression("这轮继续打磨检索评测。")
        try await allowCloud(store, thoughtSource)
        try await allowCloud(store, practiceSource)
        let claim = try await importClaim(store, sourceID: thoughtSource, statement: "检索质量决定回答质量。", commandID: "latest-thought")
        let receipt = try await store.processRecordingFollowup(sourceID: practiceSource, using: LinkingFollowupPort())
        XCTAssertEqual(receipt.state, "completed")
        let validity = try await store.recordingFollowupValidity(receipt)
        XCTAssertTrue(validity.thoughtClaimIDs.contains(claim.id), "跟进回执应记下当时的有效观点")
        return (thoughtSource, receipt, claim)
    }
    /// A newer cognition pass reads the same source, so the old claim is no longer latest.
    private func replaceCognition(_ store: VoiceOSStore, thoughtSource: String) async throws {
        _ = try await importClaim(store, sourceID: thoughtSource, statement: "检索质量需要按查询逐条评估。", commandID: "latest-thought-replacement")
    }

    func testProvidedLatestMapMatchesDatabaseRead() async throws {
        let store = try await openStore()
        let seeded = try await seedReceipt(store)
        try await replaceCognition(store, thoughtSource: seeded.thoughtSource)
        // The reload path passes the core snapshot's map, which includes frozen rows.
        let core = try await store.workspaceSnapshot(.core)
        let latest = core.currentClaimsBySource
        XCTAssertNil(latest[seeded.thoughtSource]?.first { $0.id == seeded.claim.id })
        let fallbackRows = try await store.recordingFollowupValidities([seeded.receipt])
        let fallback = try XCTUnwrap(fallbackRows[seeded.receipt.id])
        let reusedRows = try await store.recordingFollowupValidities([seeded.receipt], latest: latest)
        let reused = try XCTUnwrap(reusedRows[seeded.receipt.id])
        XCTAssertEqual(reused.sourceCurrent, fallback.sourceCurrent)
        XCTAssertEqual(reused.thoughtClaimIDs, fallback.thoughtClaimIDs)
        XCTAssertEqual(reused.goalIDs, fallback.goalIDs)
        XCTAssertEqual(reused.english, fallback.english)
        XCTAssertFalse(fallback.thoughtClaimIDs.contains(seeded.claim.id))
    }

    func testNilLatestKeepsDatabaseFallback() async throws {
        let store = try await openStore()
        let seeded = try await seedReceipt(store)
        try await replaceCognition(store, thoughtSource: seeded.thoughtSource)
        let after = try await store.recordingFollowupValidity(seeded.receipt)
        XCTAssertFalse(after.thoughtClaimIDs.contains(seeded.claim.id), "nil 形参保持现读；新的整理会让旧初稿失效")
        let stale: [String: [CandidateClaim]] = [seeded.thoughtSource: [seeded.claim]]
        let reusedRows = try await store.recordingFollowupValidities([seeded.receipt], latest: stale)
        let reused = try XCTUnwrap(reusedRows[seeded.receipt.id])
        XCTAssertTrue(reused.thoughtClaimIDs.contains(seeded.claim.id), "显式传入的 latest 由调用方负责，函数不再现读")
    }
}
