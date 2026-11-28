import XCTest
@testable import VoiceOSCore
import VoiceOSPlatform

final class RecentClueOverrideChecks: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-clue-" + UUID().uuidString)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: base) }

    private func openStore() async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: base.appendingPathComponent("library"), inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }

    private func clueOverride(_ clue: String, title: String? = nil, mergeInto: String? = nil,
                              hidden: Bool = false) -> RecentClueOverride {
        RecentClueOverride(clue: clue, displayTitle: title, mergeInto: mergeInto,
                           hidden: hidden, updatedAt: "2026-01-01T00:00:00Z")
    }

    private func thought(_ id: String, _ statement: String) -> RecentContentThought {
        RecentContentThought(claimID: id, statement: statement)
    }

    private func source(_ id: String, createdAt: String, transcript: String = "原话内容") -> SourceRecord {
        SourceRecord(id: id, assetID: "asset-" + id, name: id, state: "saved", kind: "user_text", createdAt: createdAt,
                     bytes: 1, duration: nil, jobState: "completed", transcript: transcript, error: nil,
                     relativePath: "assets/" + id, transcriptVersionID: "t-" + id, transcriptionBackend: nil,
                     spans: [], localOnly: false, policyVersion: 1, origin: "user", speaker: "user",
                     feedbackActionID: nil, feedbackActionVersion: nil, feedbackKind: nil, feedbackRelation: nil,
                     timeZone: "Asia/Shanghai", presentation: nil)
    }

    private func claim(_ id: String, sourceIDs: [String], statement: String) -> CandidateClaim {
        CandidateClaim(contentKind: nil, id: id, statement: statement, ownership: "user_tentative",
                       evidenceState: "unverified", validity: "current",
                       references: sourceIDs.map { ClaimReference(sourceID: $0, transcriptVersionID: "t-" + $0, spanID: "span-" + $0) },
                       reviewVersion: 1, reviewState: "pending")
    }

    private func action(_ id: String, claimID: String, title: String) -> ActionRecord {
        ActionRecord(id: id, claimID: claimID, claimReviewVersion: 1, title: title, kind: "task",
                     intentActor: "user", note: "", state: "open", validity: "current", version: 1,
                     autoSend: true, intent: nil, commandID: "test:" + id, createdAt: "2026-01-01T00:00:00Z", parentID: nil)
    }

    func testRenameAppliesToTheThreadTitle() {
        let digest = RecentContentDigest.build(
            thoughts: [thought("c1", "实习项目需要先交付"), thought("c2", "学习 GPT 和代码")],
            duration: 0, overrides: [clueOverride("work", title: "交付节奏")])
        XCTAssertEqual(digest.threads.first(where: { $0.id == "work" })?.title, "交付节奏")
        XCTAssertEqual(digest.threads.first(where: { $0.id == "career" })?.title, "职业与学习")
    }

    func testMergeMovesThoughtsIntoRenamedTargetAfterItsOwn() {
        let digest = RecentContentDigest.build(
            thoughts: [thought("c1", "实习项目需要先交付"), thought("c2", "学习 GPT 和代码")],
            duration: 0, overrides: [clueOverride("work", mergeInto: "career"), clueOverride("career", title: "成长")])
        XCTAssertNil(digest.threads.first(where: { $0.id == "work" }))
        guard let career = digest.threads.first(where: { $0.id == "career" }) else { return XCTFail("career thread missing") }
        XCTAssertEqual(career.title, "成长")
        XCTAssertEqual(career.thoughts.map(\.claimID), ["c2", "c1"])
        XCTAssertEqual(digest.thoughtCount, 2)
    }

    func testHiddenWinsOverMergeAndKeepsItsThoughtsOut() {
        let digest = RecentContentDigest.build(
            thoughts: [thought("c1", "实习项目需要先交付"), thought("c2", "学习 GPT 和代码")],
            duration: 0, overrides: [clueOverride("work", mergeInto: "career", hidden: true)])
        XCTAssertEqual(digest.threads.map(\.id), ["career"])
        XCTAssertEqual(digest.threads.first?.thoughts.map(\.claimID), ["c2"])
        XCTAssertEqual(digest.thoughtCount, 1)
    }

    func testMergeTargetWithoutOwnThoughtsBecomesItsOwnThread() {
        let digest = RecentContentDigest.build(
            thoughts: [thought("c1", "实习项目需要先交付")],
            duration: 0, overrides: [clueOverride("work", mergeInto: "delivery")])
        XCTAssertEqual(digest.threads.map(\.id), ["delivery"])
        XCTAssertEqual(digest.threads.first?.thoughts.map(\.claimID), ["c1"])
    }

    func testHomeSnapshotDropsTasksOfHiddenThreads() {
        let sources = [source("s1", createdAt: "2024-05-01T10:00:00Z")]
        let claims = [claim("c1", sourceIDs: ["s1"], statement: "【观点】实习项目需要先交付")]
        let actions = [action("a1", claimID: "c1", title: "打磨汇报")]

        let visible = RecentContentHomeSnapshot.build(sources: sources, claims: claims, actions: actions)
        XCTAssertEqual(visible.digests["s1"]?.tasks.map(\.id), ["a1"])

        let hidden = RecentContentHomeSnapshot.build(sources: sources, claims: claims, actions: actions,
                                                    overrides: [clueOverride("work", hidden: true)])
        XCTAssertEqual(hidden.digests["s1"]?.threads.count, 0)
        XCTAssertEqual(hidden.digests["s1"]?.tasks.count, 0)
    }

    func testCoreSnapshotCarriesOverrides() async throws {
        let store = try await openStore()
        try await store.setRecentClueHidden(clue: "life", hidden: true, commandID: "snap-hide")
        let snapshot = try await store.workspaceSnapshot(.core)
        XCTAssertEqual(snapshot.recentClueOverrides.map(\.clue), ["life"])
        XCTAssertEqual(snapshot.recentClueOverrides.first?.hidden, true)
    }

    func testOverrideWritesRoundTripAndReplayIsIdempotent() async throws {
        let store = try await openStore()
        try await store.setRecentClueTitle(clue: "work", title: "交付节奏", commandID: "clue-title-1")
        var overrides = try await store.recentClueOverrides()
        XCTAssertEqual(overrides.map(\.clue), ["work"])
        XCTAssertEqual(overrides.first?.displayTitle, "交付节奏")

        let db = await store.db
        try db.execute("UPDATE recent_clue_overrides SET updated_at='sentinel' WHERE clue='work'")
        try await store.setRecentClueTitle(clue: "work", title: "交付节奏", commandID: "clue-title-1")
        XCTAssertEqual(try db.query("SELECT updated_at FROM recent_clue_overrides WHERE clue='work'").first?["updated_at"],
                       "sentinel", "重放不得重写覆盖行")
        do {
            try await store.setRecentClueTitle(clue: "work", title: "另一个标题", commandID: "clue-title-1")
            XCTFail("同一命令更换标题应失败")
        } catch {
            XCTAssertTrue(error is VoiceOSError)
        }

        try await store.mergeRecentClue("work", into: "career", commandID: "clue-merge-1")
        try await store.setRecentClueHidden(clue: "life", hidden: true, commandID: "clue-hide-1")
        overrides = try await store.recentClueOverrides()
        let byClue = Dictionary(uniqueKeysWithValues: overrides.map { ($0.clue, $0) })
        XCTAssertEqual(byClue["work"]?.displayTitle, "交付节奏")
        XCTAssertEqual(byClue["work"]?.mergeInto, "career")
        XCTAssertEqual(byClue["life"]?.hidden, true)

        try await store.setRecentClueHidden(clue: "not-a-rule", hidden: true, commandID: "clue-unknown-1")
        let withUnknown = try await store.recentClueOverrides()
        XCTAssertEqual(withUnknown.first(where: { $0.clue == "not-a-rule" })?.hidden, true)

        try await store.setRecentClueHidden(clue: "life", hidden: false, commandID: "clue-show-1")
        overrides = try await store.recentClueOverrides()
        XCTAssertEqual(overrides.first(where: { $0.clue == "life" })?.hidden, false)
    }

    func testMigration66CreatesOverrideTableAndRetriesSafely() throws {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = base.appendingPathComponent("voiceos.sqlite")
        do {
            let db = try Database(url)
            XCTAssertEqual(try db.query("PRAGMA user_version").first?["user_version"], String(Database.schemaVersion))
            XCTAssertEqual(try db.query("SELECT count(*) AS n FROM sqlite_master WHERE type='table' AND name='recent_clue_overrides'").first?["n"], "1")
            try db.execute("DROP TABLE recent_clue_overrides")
            try db.execute("PRAGMA user_version=65")
        }
        do {
            let migrated = try Database(url)
            XCTAssertEqual(try migrated.query("PRAGMA user_version").first?["user_version"], String(Database.schemaVersion))
            XCTAssertEqual(try migrated.query("SELECT count(*) AS n FROM sqlite_master WHERE type='table' AND name='recent_clue_overrides'").first?["n"], "1")
            // Simulate a retry that created the table before bumping the version.
            try migrated.execute("PRAGMA user_version=65")
        }

        let retried = try Database(url)
        XCTAssertEqual(try retried.query("PRAGMA user_version").first?["user_version"], String(Database.schemaVersion))
        XCTAssertEqual(try retried.query("SELECT count(*) AS n FROM sqlite_master WHERE type='table' AND name='recent_clue_overrides'").first?["n"], "1")
    }
}
