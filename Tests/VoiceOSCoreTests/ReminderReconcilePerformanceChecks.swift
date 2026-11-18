import XCTest
@testable import VoiceOSCore
import VoiceOSPlatform

private actor ReminderPerfPort: RemindersPort {
    private(set) var findCalls = 0
    func find(calendarID: String, externalID: String?, marker: String) async throws -> [ReminderSnapshot] {
        findCalls += 1
        return [.init(id: "external-" + marker, title: "远程任务", completed: false, marker: marker)]
    }
    func create(calendarID: String, title: String, marker: String, context: String) async throws {
        throw VoiceOSError("对账不应创建外部任务")
    }
}

final class ReminderReconcilePerformanceChecks: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-reminder-perf-" + UUID().uuidString)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func openStore() async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }

    /// `reminder_links.action_id` is unique, so every link owns its action and the
    /// live shape is many links over the same unchanged library.
    private func makeFixture(_ store: VoiceOSStore, sourceCount: Int, claimsPerSource: Int, linkCount: Int) async throws -> (actions: Int, links: Int) {
        let access = try await store.setReminderAccess(calendarID: "perf", title: "VoiceOS", enabled: true, expectedVersion: 0)
        let filler = String(repeating: "这是一段用于性能对照的连续转写内容，覆盖提醒对账读取全文的路径。", count: 60)
        var actionCount = 0
        for sourceIndex in 0..<sourceCount {
            let text = "第\(sourceIndex)份录音。" + filler
            let sourceID = try await store.recordUserExpression(text)
            _ = try await store.setSourceLocalOnly(sourceID: sourceID, expectedVersion: 1, localOnly: false)
            let context = try await store.prepareLocalTranscriptContext(sourceIDs: [sourceID])
            let references = context.sources.map {
                ClaimReference(sourceID: $0.sourceID, transcriptVersionID: $0.transcriptVersionID, spanID: $0.spans[0].id)
            }
            let quote = String(text.prefix(12))
            let proposals = (0..<claimsPerSource).map { index in
                ClaimProposal(statement: "第\(sourceIndex)份录音的观点\(index)",
                              ownership: .userTentative, references: references,
                              action: .init(title: "任务 \(sourceIndex)-\(index)", kind: .task, quote: quote))
            }
            _ = try await store.importOrganizedClaims(context: context, proposals: proposals, commandID: "perf-source-\(sourceIndex)")
            actionCount += proposals.count
        }
        let actions = try await store.actions()
        XCTAssertEqual(actions.count, actionCount, "fixture 应包含全部提取任务")
        let database = await store.db
        var linkCountActual = 0
        for action in actions.prefix(linkCount) {
            let id = UUID().uuidString
            try database.execute("INSERT INTO reminder_links(id,action_id,action_version,calendar_id,marker,desired_title,state,created_at) VALUES(?,?,?,?,?,?,'unknown',?)",
                                 [id, action.id, String(action.version), access.calendarID, "voiceos-action:" + id, action.title, "2026-01-01T00:00:00Z"])
            linkCountActual += 1
        }
        return (actionCount, linkCountActual)
    }

    func testReconcileLargeFixturePrintsTiming() async throws {
        let store = try await openStore()
        let fixture = try await makeFixture(store, sourceCount: 20, claimsPerSource: 25, linkCount: 120)
        let port = ReminderPerfPort()
        var runs: [Double] = []
        for _ in 0..<3 {
            let begin = ContinuousClock.now
            try await store.reconcileReminders(expectedAccessVersion: 1, using: port)
            let elapsed = begin.duration(to: .now)
            runs.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
        }
        let finds = await port.findCalls
        let links = try await store.reminderLinks()
        XCTAssertEqual(links.count, fixture.links, "全部关联都应参与对账")
        XCTAssertTrue(links.allSatisfy { $0.state == "linked" }, "对账后每条关联都应确认唯一外部任务")
        print("M72_PERF links=\(fixture.links) actions=\(fixture.actions) finds=\(finds) runs_ms=\(runs)")
    }

    func testReconcileLoadsObservationDataOncePerRound() async throws {
        let store = try await openStore()
        let fixture = try await makeFixture(store, sourceCount: 4, claimsPerSource: 5, linkCount: 20)
        let port = ReminderPerfPort()
        let stats = ReminderObservationStats()
        try await store.reconcileReminders(expectedAccessVersion: 1, using: port, observationStats: stats)
        let firstFinds = await port.findCalls
        XCTAssertEqual(firstFinds, fixture.links, "每条关联都应按原顺序回读一次外部任务")
        XCTAssertEqual(stats.fullObservationLoads, 1, "同一轮对账只应全量加载一次观察数据，而不是每条关联各加载一次")
        try await store.reconcileReminders(expectedAccessVersion: 1, using: port, observationStats: stats)
        let secondFinds = await port.findCalls
        XCTAssertEqual(secondFinds, fixture.links * 2, "第二轮仍应逐条回读")
        XCTAssertEqual(stats.fullObservationLoads, 2, "每一轮对账各全量加载一次")
    }
}
