import XCTest
@testable import VoiceOSCore
import VoiceOSPlatform

/// A question's follow-up enters the same durable queue as its first answer,
/// carries the user's instruction, and reuses the answer's references.
final class QuestionFollowupChecks: XCTestCase {
    private var base: URL!
    private var root: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-question-followup-" + UUID().uuidString)
        root = base.appendingPathComponent("library")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: base) }

    private func openStore() async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }

    private func addQuestion(_ store: VoiceOSStore, title: String) async throws -> ActionRecord {
        let source = try await store.recordUserExpression("需要核对的内容。")
        let context = try await store.prepareLocalTranscriptContext(sourceIDs: [source])
        let references = context.sources.map {
            ClaimReference(sourceID: $0.sourceID, transcriptVersionID: $0.transcriptVersionID, spanID: $0.spans[0].id)
        }
        let quote = try XCTUnwrap(context.sources.first?.text)
        let claimIDs = try await store.importOrganizedClaims(context: context, proposals: [
            .init(statement: title, ownership: .userTentative, references: references,
                  action: .init(title: title, kind: .opportunity, quote: quote))
        ], commandID: "question-followup-claims-" + UUID().uuidString)
        let claimID = try XCTUnwrap(claimIDs.first)
        let actions = try await store.actions()
        return try XCTUnwrap(actions.first { $0.claimID == claimID })
    }

    private func markCompleted(_ store: VoiceOSStore, _ id: String) async throws {
        let db = await store.db
        try db.execute("UPDATE assistant_executions SET state='completed',updated_at=created_at WHERE id=?", [id])
    }

    func testFollowupCarriesInstructionAndReusesTheAnswerReferences() async throws {
        let store = try await openStore()
        let question = try await addQuestion(store, title: "【问题】为什么要在回答后就地追问？")
        let answer = try await store.enqueueAssistantExecution(actionID: question.id, expectedVersion: question.version, mode: .analysis, fresh: true)
        XCTAssertEqual(answer.instruction, "")
        XCTAssertNil(answer.instructionSourceID)
        try await markCompleted(store, answer.id)

        let followup = try await store.enqueueAssistantExecution(actionID: question.id, expectedVersion: question.version, instruction: "  能举一个具体例子吗？\n", mode: .analysis, fresh: true)
        XCTAssertEqual(followup.actionID, question.id)
        XCTAssertEqual(followup.actionVersion, question.version)
        XCTAssertEqual(followup.mode.rawValue, AssistantMode.analysis.rawValue)
        XCTAssertEqual(followup.state, "queued")
        XCTAssertEqual(followup.instruction, "能举一个具体例子吗？", "追问保留用户指令并去掉首尾空白")
        XCTAssertNotNil(followup.instructionSourceID)
        XCTAssertEqual(followup.inputReferences, answer.inputReferences, "追问沿用原回答的 references 快照，不新增引用")

        let records = try await store.assistantExecutions(actionID: question.id)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.filter { $0.state == "queued" }.count, 1)
    }

    func testSameFollowupInstructionConvergesWhileQueued() async throws {
        let store = try await openStore()
        let question = try await addQuestion(store, title: "【问题】同一句追问会不会排两次？")
        let answer = try await store.enqueueAssistantExecution(actionID: question.id, expectedVersion: question.version, mode: .analysis, fresh: true)
        try await markCompleted(store, answer.id)

        let first = try await store.enqueueAssistantExecution(actionID: question.id, expectedVersion: question.version, instruction: "换个角度解释", mode: .analysis, fresh: true)
        let repeated = try await store.enqueueAssistantExecution(actionID: question.id, expectedVersion: question.version, instruction: "  换个角度解释 ", mode: .analysis, fresh: true)
        XCTAssertEqual(repeated.id, first.id, "同一版本、同一指令的 fresh 请求在排队中收敛为一次")
        let queued = try await store.assistantExecutions(actionID: question.id).filter { $0.state == "queued" }
        XCTAssertEqual(queued.count, 1)

        try await markCompleted(store, first.id)
        let next = try await store.enqueueAssistantExecution(actionID: question.id, expectedVersion: question.version, instruction: "换个角度解释", mode: .analysis, fresh: true)
        XCTAssertNotEqual(next.id, first.id, "fresh 跳过已完成去重，同一句追问再问会产生新的执行")
        let converged = try await store.enqueueAssistantExecution(actionID: question.id, expectedVersion: question.version, instruction: "换个角度解释", mode: .analysis, fresh: true)
        XCTAssertEqual(converged.id, next.id)
    }

    func testAnalysisEmptyInstructionKeepsTheExistingBehavior() async throws {
        let store = try await openStore()
        let question = try await addQuestion(store, title: "【问题】空指令仍按原回答处理")
        let answer = try await store.enqueueAssistantExecution(actionID: question.id, expectedVersion: question.version, instruction: "   ", mode: .analysis)
        XCTAssertEqual(answer.instruction, "", "空白的 analysis 指令仍归一为空")
        let repeatedWhileQueued = try await store.enqueueAssistantExecution(actionID: question.id, expectedVersion: question.version, instruction: "", mode: .analysis, fresh: true)
        XCTAssertEqual(repeatedWhileQueued.id, answer.id, "排队中的空指令 fresh 请求仍然收敛")

        try await markCompleted(store, answer.id)
        let cached = try await store.enqueueAssistantExecution(actionID: question.id, expectedVersion: question.version, mode: .analysis)
        XCTAssertEqual(cached.id, answer.id, "默认入队复用已完成的回答")

        let fresh = try await store.enqueueAssistantExecution(actionID: question.id, expectedVersion: question.version, mode: .analysis, fresh: true)
        XCTAssertNotEqual(fresh.id, answer.id, "fresh 产生新的回答执行")
        XCTAssertEqual(fresh.instruction, "")
        XCTAssertEqual(fresh.inputReferences, answer.inputReferences)
    }
}
