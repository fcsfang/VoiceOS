import XCTest
@testable import VoiceOSCore
import VoiceOSPlatform

final class ActionRowStatusChecks: XCTestCase {
    private struct RowCase {
        let name: String
        let configure: (inout ActionRowFacts) -> Void
        let status: String
        let tone: ActionRowTone
        let meta: String
    }

    private func facts(_ configure: (inout ActionRowFacts) -> Void) -> ActionRowStatus {
        var facts = ActionRowFacts()
        configure(&facts)
        return ActionRowLayout.status(facts)
    }

    private func action(id: String, parent: String?, state: String) -> ActionRecord {
        ActionRecord(id: id, claimID: "claim", claimReviewVersion: 1, title: "t", kind: "task",
                     intentActor: "user", note: "", state: state, validity: "current", version: 1,
                     autoSend: false, intent: nil, commandID: "c", createdAt: "", parentID: parent)
    }

    func testStatusMatrixCoversGroupsGoalsAndQuestions() {
        let cases: [RowCase] = [
            RowCase(name: "due wins over source",
                    configure: { facts in
                        facts.isGoal = true
                        facts.due = "到期 11月20日"
                        facts.sourceTitle = "早餐时的想法"
                    },
                    status: "", tone: .secondary, meta: "到期 11月20日"),
            RowCase(name: "source fallback",
                    configure: { facts in
                        facts.isGoal = true
                        facts.sourceTitle = "早餐时的想法"
                    },
                    status: "", tone: .secondary, meta: "来自『早餐时的想法』"),
            RowCase(name: "goal shows next step count",
                    configure: { facts in
                        facts.isGoal = true
                        facts.nextStepCount = 2
                        facts.sourceTitle = "早餐时的想法"
                    },
                    status: "2 个下一步", tone: .secondary, meta: "来自『早餐时的想法』"),
            RowCase(name: "goal with no next steps",
                    configure: { facts in
                        facts.isGoal = true
                        facts.nextStepCount = 0
                    },
                    status: "", tone: .secondary, meta: ""),
            RowCase(name: "needs review group does not reafirm",
                    configure: { facts in
                        facts.group = .needsReview
                        facts.requiresReview = true
                    },
                    status: "", tone: .secondary, meta: ""),
            RowCase(name: "needs review group frozen",
                    configure: { facts in
                        facts.group = .needsReview
                        facts.validity = "frozen"
                    },
                    status: "", tone: .secondary, meta: ""),
            RowCase(name: "needs review outside its group",
                    configure: { facts in
                        facts.requiresReview = true
                    },
                    status: "待核对", tone: .warning, meta: ""),
            RowCase(name: "completed group does not repeat completion",
                    configure: { facts in
                        facts.group = .completed
                        facts.state = "completed"
                    },
                    status: "", tone: .secondary, meta: ""),
            RowCase(name: "history frozen",
                    configure: { facts in
                        facts.group = .history
                        facts.validity = "frozen"
                    },
                    status: "", tone: .secondary, meta: ""),
            RowCase(name: "history dismissed",
                    configure: { facts in
                        facts.group = .history
                        facts.state = "dismissed"
                    },
                    status: "已放下", tone: .tertiary, meta: ""),
            RowCase(name: "local unsynced wins over next steps",
                    configure: { facts in
                        facts.isGoal = true
                        facts.nextStepCount = 3
                        facts.localUnsynced = true
                    },
                    status: "本地未同步", tone: .warning, meta: ""),
            RowCase(name: "question unanswered",
                    configure: { facts in
                        facts.isQuestion = true
                        facts.sourceTitle = "早餐时的想法"
                    },
                    status: "未回答", tone: .secondary, meta: "来自『早餐时的想法』"),
            RowCase(name: "question queued",
                    configure: { facts in
                        facts.isQuestion = true
                        facts.answerState = "queued"
                    },
                    status: "回答中", tone: .secondary, meta: ""),
            RowCase(name: "question running",
                    configure: { facts in
                        facts.isQuestion = true
                        facts.answerState = "running"
                    },
                    status: "回答中", tone: .secondary, meta: ""),
            RowCase(name: "question reserved",
                    configure: { facts in
                        facts.isQuestion = true
                        facts.answerState = "reserved"
                    },
                    status: "回答中", tone: .secondary, meta: ""),
            RowCase(name: "question blocked",
                    configure: { facts in
                        facts.isQuestion = true
                        facts.answerState = "blocked"
                    },
                    status: "回答中", tone: .secondary, meta: ""),
            RowCase(name: "question completed",
                    configure: { facts in
                        facts.isQuestion = true
                        facts.answerState = "completed"
                    },
                    status: "已回答", tone: .success, meta: ""),
            RowCase(name: "question failed",
                    configure: { facts in
                        facts.isQuestion = true
                        facts.answerState = "failed"
                    },
                    status: "回答失败", tone: .warning, meta: ""),
            RowCase(name: "question cancelled",
                    configure: { facts in
                        facts.isQuestion = true
                        facts.answerState = "cancelled"
                    },
                    status: "回答失败", tone: .warning, meta: ""),
            RowCase(name: "question unknown state",
                    configure: { facts in
                        facts.isQuestion = true
                        facts.answerState = "unknown"
                    },
                    status: "未回答", tone: .secondary, meta: ""),
            RowCase(name: "question wins over next steps",
                    configure: { facts in
                        facts.isQuestion = true
                        facts.nextStepCount = 2
                    },
                    status: "未回答", tone: .secondary, meta: ""),
            RowCase(name: "completed row shows completion date",
                    configure: { facts in
                        facts.group = .completed
                        facts.state = "completed"
                        facts.completedAt = "完成于 11月16日"
                        facts.sourceTitle = "早餐时的想法"
                    },
                    status: "", tone: .secondary, meta: "完成于 11月16日"),
            RowCase(name: "completion date only inside completed group",
                    configure: { facts in
                        facts.state = "completed"
                        facts.completedAt = "完成于 11月16日"
                        facts.sourceTitle = "早餐时的想法"
                    },
                    status: "已登记完成", tone: .secondary, meta: "来自『早餐时的想法』"),
        ]
        for c in cases {
            let row = facts(c.configure)
            XCTAssertEqual(row.status, c.status, c.name)
            XCTAssertEqual(row.tone, c.tone, c.name)
            XCTAssertEqual(row.meta, c.meta, c.name)
        }
    }

    func testNextStepCountsCountOpenChildrenPerOutcome() {
        let actions = [
            action(id: "a", parent: "goal", state: "open"),
            action(id: "b", parent: "goal", state: "completed"),
            action(id: "c", parent: "goal", state: "open"),
            action(id: "d", parent: nil, state: "open"),
            action(id: "e", parent: "other", state: "open"),
        ]
        XCTAssertEqual(ActionRowLayout.nextStepCounts(actions), ["goal": 2, "other": 1])
    }

    private func reminderRow(state: String, due: ReminderDueDate) -> ActionRowStatus {
        var facts = ActionRowFacts()
        facts.reminderLinkState = state
        facts.reminderDue = due
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 10))!
        return ActionRowLayout.status(facts, now: now, calendar: calendar)
    }

    func testReminderMetaMatrix() {
        let cases: [(name: String, state: String, due: ReminderDueDate, meta: String)] = [
            ("linked due today", "linked", .dateOnly(localDate: "2026-11-19", timeZone: nil), "已写入提醒事项 · 今天"),
            ("linked due tomorrow", "linked", .dateOnly(localDate: "2026-11-20", timeZone: nil), "已写入提醒事项 · 明天"),
            ("conflict overdue", "conflict", .dateOnly(localDate: "2026-11-18", timeZone: nil), "提醒待核对 · 已逾期 11月18日"),
            ("linked beyond a week", "linked", .dateOnly(localDate: "2026-12-01", timeZone: nil), "已写入提醒事项 · 12月1日"),
        ]
        for c in cases {
            let row = reminderRow(state: c.state, due: c.due)
            XCTAssertEqual(row.meta, c.meta, c.name)
        }
    }
}

final class ActionCompletionTimeChecks: XCTestCase {
    private var base: URL!
    private var root: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-completion-time-" + UUID().uuidString)
        root = base.appendingPathComponent("library")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: base) }

    private func openStore() async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }

    private func addAction(_ store: VoiceOSStore) async throws -> ActionRecord {
        let source = try await store.recordUserExpression("整理桌面。")
        let context = try await store.prepareLocalTranscriptContext(sourceIDs: [source])
        let references = context.sources.map {
            ClaimReference(sourceID: $0.sourceID, transcriptVersionID: $0.transcriptVersionID, spanID: $0.spans[0].id)
        }
        let quote = try XCTUnwrap(context.sources.first?.text)
        let claimIDs = try await store.importOrganizedClaims(context: context, proposals: [
            .init(statement: "整理桌面", ownership: .userTentative, references: references,
                  action: .init(title: "整理桌面", kind: .task, quote: quote))
        ], commandID: "completion-time-claims")
        let claimID = try XCTUnwrap(claimIDs.first)
        let actions = try await store.actions()
        return try XCTUnwrap(actions.first { $0.claimID == claimID })
    }

    func testCompletedAtTracksTheNewestCompletionRevision() async throws {
        let store = try await openStore()
        let action = try await addAction(store)
        let firstCompletion = try await store.setActionState(actionID: action.id, expectedVersion: action.version, state: .completed)
        let db = await store.db
        try db.execute("UPDATE action_revisions SET created_at='2025-01-01T00:00:00Z' WHERE action_id=? AND version=?", [action.id, String(firstCompletion)])
        var actions = try await store.actions(includeHistory: true)
        var record = try XCTUnwrap(actions.first { $0.id == action.id })
        XCTAssertEqual(record.completedAt, "2025-01-01T00:00:00Z")
        let reopened = try await store.setActionState(actionID: action.id, expectedVersion: record.version, state: .open)
        actions = try await store.actions(includeHistory: true)
        record = try XCTUnwrap(actions.first { $0.id == action.id })
        XCTAssertEqual(record.completedAt, "2025-01-01T00:00:00Z")
        _ = try await store.setActionState(actionID: action.id, expectedVersion: reopened, state: .completed)
        let history = try await store.actionHistory(actionID: action.id)
        actions = try await store.actions(includeHistory: true)
        record = try XCTUnwrap(actions.first { $0.id == action.id })
        XCTAssertEqual(history.last?.state, "completed")
        XCTAssertEqual(record.completedAt, history.last?.createdAt)
        XCTAssertNotEqual(record.completedAt, "2025-01-01T00:00:00Z")
    }
}
