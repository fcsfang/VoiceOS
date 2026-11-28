import XCTest
@testable import VoiceOSCore
import VoiceOSPlatform

final class SourceExtractionFlagChecks: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-extraction-flag-" + UUID().uuidString)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }
    private func openStore() async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }

    func testEmptyExtractionRuleBoundaries() {
        func check(_ text: String?, origin: String = "user", speaker: String = "user", expressionState: String? = nil, references: Int = 0) -> Bool {
            VoiceOSStore.indicatesEmptyExtraction(SourceExtractionFacts(origin: origin, speaker: speaker, transcript: text, expressionState: expressionState, referenceCount: references))
        }
        XCTAssertTrue(check(String(repeating: "观", count: 200)), "200 个标量即达到实质文字")
        XCTAssertFalse(check(String(repeating: "观", count: 199)), "不够 200 个标量不标记")
        XCTAssertTrue(check("\n  " + String(repeating: "观", count: 200) + "\n\t "), "空白不计入实质文字")
        XCTAssertFalse(check(String(repeating: "观", count: 300), origin: "external"), "外部节目的零观点合法")
        XCTAssertFalse(check(String(repeating: "观", count: 300), origin: "ai"), "AI 文本不走整理器，不标记")
        XCTAssertFalse(check(String(repeating: "观", count: 300), speaker: "unknown"), "说话人不是用户时不标记")
        XCTAssertTrue(check(String(repeating: "观", count: 300), expressionState: "completed"))
        XCTAssertFalse(check(String(repeating: "观", count: 300), expressionState: "pending"), "表达未落定前不标记")
        XCTAssertFalse(check(String(repeating: "观", count: 300), references: 1), "有引用即不是零提取")
        XCTAssertFalse(check(nil), "没有文字不标记")
    }

    func testZeroReferenceOrganizeMarksEmptyAndAcknowledgementSticks() async throws {
        let store = try await openStore()
        let id = try await store.recordUserExpression(String(repeating: "零提取状态需要可被重新整理。", count: 20))
        let context = try await store.prepareLocalTranscriptContext(sourceIDs: [id])
        _ = try await store.importOrganizedClaims(context: context, proposals: [], commandID: "organized-empty-fixture")
        try await store.evaluateSourceExtractionFlags(sourceIDs: [id])
        let flagged = try await store.sourceExtractionFlag(sourceID: id)
        XCTAssertEqual(flagged, .empty)
        let allFlags = try await store.sourceExtractionFlags()
        XCTAssertEqual(allFlags, [id: .empty])
        let db = await store.db
        let row = try XCTUnwrap(try db.query("SELECT state,detected_at,updated_at FROM source_extraction_flags WHERE source_id=?", [id]).first)
        XCTAssertEqual(row["state"], "empty")
        XCTAssertNotNil(row["detected_at"]); XCTAssertNotNil(row["updated_at"])

        try await store.acknowledgeEmptyExtraction(sourceID: id)
        let acknowledged = try await store.sourceExtractionFlag(sourceID: id)
        XCTAssertEqual(acknowledged, .acknowledged)
        _ = try await store.importOrganizedClaims(context: context, proposals: [], commandID: "organized-empty-fixture-2")
        try await store.evaluateSourceExtractionFlags(sourceIDs: [id])
        let afterSecondZero = try await store.sourceExtractionFlag(sourceID: id)
        XCTAssertEqual(afterSecondZero, .acknowledged, "已确认的零提取不因再次零提取而重标")
    }

    func testExpressionGateAndReferencesResolveTheFlag() async throws {
        let store = try await openStore()
        let id = try await store.recordUserExpression(String(repeating: "整段表达会掩盖没有贡献的分段。", count: 20))
        let records = try await store.sources()
        let record = try XCTUnwrap(records.first { $0.id == id })
        let context = try await store.prepareLocalTranscriptContext(sourceIDs: [id])
        let member = context.sources[0]

        var expression = RecordingExpression(id: UUID().uuidString, sourceIDs: [id], title: "表达", summary: "摘要", reason: "依据",
                                             responseIDs: ["r1", "r2"], versions: [id: member.transcriptVersionID], policies: [id: 1],
                                             state: "pending", previousActionIDs: [])
        var presentation = record.presentation ?? RecordingPresentation()
        presentation.expression = expression
        try await store.saveExpressionPresentation(presentation, sourceID: id)
        _ = try await store.importOrganizedClaims(context: context, proposals: [], commandID: "organized-pending-fixture")
        try await store.evaluateSourceExtractionFlags(sourceIDs: [id])
        let pending = try await store.sourceExtractionFlag(sourceID: id)
        XCTAssertNil(pending, "表达未落定前不标记")

        expression.state = "completed"
        presentation.expression = expression
        try await store.saveExpressionPresentation(presentation, sourceID: id)
        try await store.evaluateSourceExtractionFlags(sourceIDs: [id])
        let settled = try await store.sourceExtractionFlag(sourceID: id)
        XCTAssertEqual(settled, .empty)

        let reference = ClaimReference(sourceID: id, transcriptVersionID: member.transcriptVersionID, spanID: member.spans[0].id)
        _ = try await store.importOrganizedClaims(context: context, proposals: [ClaimProposal(statement: "这段表达了明确的观点。", ownership: .userTentative, references: [reference], contentKind: .statement)], commandID: "organized-claim-fixture")
        try await store.evaluateSourceExtractionFlags(sourceIDs: [id])
        let resolved = try await store.sourceExtractionFlag(sourceID: id)
        XCTAssertNil(resolved, "后续整理找到观点时标记清除")
    }

    func testMigration69AddsFlagTableAndRetriesSafely() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("voiceos.sqlite")
        do {
            let db = try Database(url)
            XCTAssertEqual(try db.query("PRAGMA user_version").first?["user_version"], String(Database.schemaVersion))
            XCTAssertEqual(try db.query("SELECT count(*) AS n FROM sqlite_master WHERE type='table' AND name='source_extraction_flags'").first?["n"], "1")
            try db.execute("DROP TABLE source_extraction_flags")
            try db.execute("PRAGMA user_version=69")
        }
        do {
            let migrated = try Database(url)
            XCTAssertEqual(try migrated.query("PRAGMA user_version").first?["user_version"], String(Database.schemaVersion))
            XCTAssertEqual(try migrated.query("SELECT count(*) AS n FROM sqlite_master WHERE type='table' AND name='source_extraction_flags'").first?["n"], "1")
            // Simulate a retry that created the table before bumping the version.
            try migrated.execute("PRAGMA user_version=69")
        }
        let retried = try Database(url)
        XCTAssertEqual(try retried.query("PRAGMA user_version").first?["user_version"], String(Database.schemaVersion))
        XCTAssertEqual(try retried.query("SELECT count(*) AS n FROM sqlite_master WHERE type='table' AND name='source_extraction_flags'").first?["n"], "1")
    }
}
