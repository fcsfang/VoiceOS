import XCTest
@testable import VoiceOSCore
import VoiceOSPlatform

final class ReminderSyncAnomalyChecks: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-reminder-anomalies-" + UUID().uuidString)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func openStore() async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }

    private func makeTask(_ store: VoiceOSStore, title: String, commandID: String) async throws -> ActionRecord {
        let text = "我打算\(title)。"
        let sourceID = try await store.recordUserExpression(text)
        _ = try await store.setSourceLocalOnly(sourceID: sourceID, expectedVersion: 1, localOnly: false)
        let context = try await store.prepareLocalTranscriptContext(sourceIDs: [sourceID])
        let references = context.sources.map {
            ClaimReference(sourceID: $0.sourceID, transcriptVersionID: $0.transcriptVersionID, spanID: $0.spans[0].id)
        }
        _ = try await store.importOrganizedClaims(context: context, proposals: [
            .init(statement: text, ownership: .userTentative, references: references,
                  action: .init(title: title, kind: .task, quote: text))
        ], commandID: commandID)
        let actions = try await store.actions()
        return try XCTUnwrap(actions.first { $0.title == title })
    }

    private func insertLink(_ store: VoiceOSStore, action: ActionRecord, state: String) async throws -> String {
        let id = UUID().uuidString
        let database = await store.db
        try database.execute("INSERT INTO reminder_links(id,action_id,action_version,calendar_id,marker,desired_title,state,created_at) VALUES(?,?,?,?,?,?,?,?)",
                             [id, action.id, String(action.version), "calendar-check", "voiceos-action:" + id, action.title, state, "2026-01-01T00:00:00Z"])
        return id
    }

    func testAnomalySummaryGroupsUnconfirmedLinksWithTaskTitles() async throws {
        let store = try await openStore()
        let missing = try await makeTask(store, title: "整理桌面", commandID: "anomaly-missing")
        let conflict = try await makeTask(store, title: "预约体检", commandID: "anomaly-conflict")
        let unknown = try await makeTask(store, title: "读完手册", commandID: "anomaly-unknown")
        let linked = try await makeTask(store, title: "回复邮件", commandID: "anomaly-linked")
        let missingID = try await insertLink(store, action: missing, state: "missing")
        _ = try await insertLink(store, action: conflict, state: "conflict")
        _ = try await insertLink(store, action: unknown, state: "unknown")
        _ = try await insertLink(store, action: linked, state: "linked")

        let summary = try await store.reminderSyncAnomalies()
        XCTAssertEqual(summary.total, 3)
        XCTAssertEqual(summary.count("missing"), 1)
        XCTAssertEqual(summary.count("conflict"), 1)
        XCTAssertEqual(summary.count("unknown"), 1)
        XCTAssertEqual(summary.items.map(\.state), ["missing", "conflict", "unknown"])
        XCTAssertEqual(summary.items.map(\.actionTitle), ["整理桌面", "预约体检", "读完手册"])
        let item = try XCTUnwrap(summary.items.first)
        XCTAssertEqual(item.id, missingID)
        XCTAssertEqual(item.actionID, missing.id)
        XCTAssertEqual(item.desiredTitle, "整理桌面")
        XCTAssertEqual(item.marker, "voiceos-action:" + missingID)
        XCTAssertFalse(summary.items.contains { $0.actionTitle == "回复邮件" })
    }

    func testWithoutAnomaliesSummaryIsEmpty() async throws {
        let store = try await openStore()
        let summary = try await store.reminderSyncAnomalies()
        XCTAssertEqual(summary.total, 0)
        XCTAssertTrue(summary.items.isEmpty)
        XCTAssertEqual(summary.count("missing"), 0)
        XCTAssertEqual(summary.count("conflict"), 0)
        XCTAssertEqual(summary.count("unknown"), 0)
    }
}
