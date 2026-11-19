import XCTest
@testable import VoiceOSCore
import VoiceOSPlatform

final class LatestClaimAttributionChecks: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-claim-attribution-" + UUID().uuidString)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func openStore() async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }

    private struct Seeded {
        let sourceID: String
        let statements: [String]
    }

    /// One completed claim extraction for a source, then a later completed
    /// topic organization attempt over the same source that writes no claims.
    private func seedTopicAfterClaims(_ store: VoiceOSStore) async throws -> Seeded {
        let sourceID = try await store.recordUserExpression("先把材料里的观点整理出来，再决定下一步怎么做。")
        _ = try await store.setSourceLocalOnly(sourceID: sourceID, expectedVersion: 1, localOnly: false)
        let context = try await store.prepareLocalTranscriptContext(sourceIDs: [sourceID])
        let item = try XCTUnwrap(context.sources.first)
        let statements = ["这份材料提醒我要先核对观点归属。", "材料里的待办是整理完成后再做决定。"]
        let commandID = "attribution-claims-" + UUID().uuidString
        _ = try await store.importOrganizedClaims(context: context, proposals: statements.map { statement in
            ClaimProposal(statement: statement, ownership: .userTentative,
                          references: [.init(sourceID: sourceID, transcriptVersionID: item.transcriptVersionID, spanID: item.spans[0].id)])
        }, commandID: commandID)
        let database = await store.db
        let contextID = try XCTUnwrap(try database.query("SELECT id FROM contexts WHERE command_id=?", [commandID]).first?["id"])
        try database.execute("""
            INSERT INTO model_attempts(id,context_id,provider,model,prompt_version,schema_version,state,result_digest,created_at,producer_sequence)
            VALUES(?,?,'topic_skeleton','unspecified','topic-skeleton-v1','topics-v1','completed',?,?,?)
            """, [UUID().uuidString, contextID, "topic-result", ISO8601DateFormatter().string(from: Date()), try database.nextModelProducerSequence()])
        return Seeded(sourceID: sourceID, statements: statements)
    }

    func testLatestClaimsBySourceIgnoreLaterTopicOrganization() async throws {
        let store = try await openStore()
        let seeded = try await seedTopicAfterClaims(store)
        let latest = try await store.latestCandidateClaimsBySource()
        XCTAssertEqual(Set((latest[seeded.sourceID] ?? []).map(\.statement)), Set(seeded.statements),
                       "主题整理调用不产观点，不能遮蔽材料自己的观点提取结果")
    }

    func testLatestClaimsForSourceIgnoreLaterTopicOrganization() async throws {
        let store = try await openStore()
        let seeded = try await seedTopicAfterClaims(store)
        let claims = try await store.latestCandidateClaims(for: seeded.sourceID)
        XCTAssertEqual(Set(claims.map(\.statement)), Set(seeded.statements),
                       "单来源查询同样应返回观点提取结果，而不是更晚的主题整理调用")
    }
}
