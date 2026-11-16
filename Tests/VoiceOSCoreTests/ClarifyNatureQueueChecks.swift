import XCTest
@testable import VoiceOSCore
import VoiceOSPlatform

/// The clarify queue's data contract. Questions, goals, and untriaged
/// suggestions partition the open outcomes, narration enters none of them,
/// and the triage and trial-answer writes converge on retry.
final class ClarifyNatureQueueChecks: XCTestCase {
    private var base: URL!
    private var root: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-clarify-nature-" + UUID().uuidString)
        root = base.appendingPathComponent("library")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: base) }

    private func openStore(_ directory: URL? = nil) async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: directory ?? root, inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }

    private func addAction(_ store: VoiceOSStore, title: String, kind: ActionKind = .opportunity) async throws -> ActionRecord {
        let source = try await store.recordUserExpression("需要核对的内容。")
        let context = try await store.prepareLocalTranscriptContext(sourceIDs: [source])
        let references = context.sources.map {
            ClaimReference(sourceID: $0.sourceID, transcriptVersionID: $0.transcriptVersionID, spanID: $0.spans[0].id)
        }
        let quote = try XCTUnwrap(context.sources.first?.text)
        let claimIDs = try await store.importOrganizedClaims(context: context, proposals: [
            .init(statement: title, ownership: .userTentative, references: references,
                  action: .init(title: title, kind: kind, quote: quote))
        ], commandID: "clarify-nature-claims-" + UUID().uuidString)
        let claimID = try XCTUnwrap(claimIDs.first)
        let actions = try await store.actions()
        return try XCTUnwrap(actions.first { $0.claimID == claimID })
    }

    private func classify(_ store: VoiceOSStore, _ action: ActionRecord, _ nature: ActionNature) async throws -> Int {
        try await store.setActionNature(id: action.id, expectedVersion: action.version, nature: nature,
                                        commandID: "clarify-nature-" + nature.rawValue + ":" + action.id)
    }

    func testQueueScopesPartitionOpenOutcomesAndExcludeNarration() async throws {
        let store = try await openStore()
        let question = try await addAction(store, title: "【问题】为什么要把问题与目标分开？")
        let goal = try await addAction(store, title: "【长期目标】跑通全流程")
        let untriaged = try await addAction(store, title: "【想法】随手记一条")
        let narration = try await addAction(store, title: "【录音中活动】正在接电话")
        let task = try await addAction(store, title: "【问题】已经变成待办", kind: .task)
        _ = try await classify(store, question, .question)
        _ = try await classify(store, goal, .goal)
        _ = try await classify(store, narration, .narration)

        let questions = try await store.openQuestions().map(\.id)
        let goals = try await store.openGoals().map(\.id)
        let suggestions = try await store.untriagedSuggestions().map(\.id)
        XCTAssertEqual(Set(questions), Set([question.id]))
        XCTAssertEqual(Set(goals), Set([goal.id]))
        XCTAssertEqual(Set(suggestions), Set([untriaged.id]))
        for list in [questions, goals, suggestions] {
            XCTAssertFalse(list.contains(narration.id), "旁白不进入任何队列")
            XCTAssertFalse(list.contains(task.id), "已成待办的内容不回到问题与目标")
        }
    }

    func testTriageReceiptConverges() async throws {
        let store = try await openStore()
        let item = try await addAction(store, title: "【想法】要不要学做面包")
        let command = "clarify-triage:" + item.id + ":question:" + String(item.version)
        let version = try await store.setActionNature(id: item.id, expectedVersion: item.version, nature: .question, commandID: command)
        let retry = try await store.setActionNature(id: item.id, expectedVersion: item.version, nature: .question, commandID: command)
        XCTAssertEqual(retry, version)

        let db = await store.db
        let revisions = try db.query("SELECT note FROM action_revisions WHERE action_id=?", [item.id])
        XCTAssertEqual(revisions.count, 1)
        let note = try XCTUnwrap(revisions.first?["note"])
        XCTAssertTrue(note.hasPrefix("归类："))

        let openQuestions = try await store.openQuestions()
        let suggestions = try await store.untriagedSuggestions()
        XCTAssertTrue(openQuestions.contains { $0.id == item.id })
        XCTAssertFalse(suggestions.contains { $0.id == item.id })

        do {
            _ = try await store.setActionNature(id: item.id, expectedVersion: item.version, nature: .goal, commandID: command)
            XCTFail("同一归类命令不能更换去向")
        } catch { XCTAssertTrue(error is VoiceOSError) }
    }

    func testTrialAnswerEnqueueKeepsTheQuestionOpenAndDeduplicates() async throws {
        let store = try await openStore()
        let item = try await addAction(store, title: "【问题】先让 VoiceOS 试答的问题")
        _ = try await classify(store, item, .question)
        let open = try await store.openQuestions()
        let question = try XCTUnwrap(open.first { $0.id == item.id })

        let first = try await store.enqueueAssistantExecution(actionID: question.id, expectedVersion: question.version, mode: .analysis)
        let retry = try await store.enqueueAssistantExecution(actionID: question.id, expectedVersion: question.version, mode: .analysis)
        XCTAssertEqual(retry.id, first.id, "同一版本的重复试答复用一个排队")
        XCTAssertEqual(first.state, "queued")

        let stillOpen = try await store.openQuestions()
        XCTAssertTrue(stillOpen.contains { $0.id == item.id }, "试答不会把问题移出队列")
    }
}
