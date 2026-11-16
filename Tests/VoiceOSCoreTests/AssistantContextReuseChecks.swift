import XCTest
@testable import VoiceOSCore
import VoiceOSPlatform

private struct QueuingAssistantPort: AssistantModelPort {
    let configuration = ModelConfiguration(provider: "fixture", model: "assistant-context", promptVersion: "v1", schemaVersion: "v1", destination: .local)
    func assess(_ input: AssistantTaskInput) async throws -> AssistantAssessment {
        .init(explicitDelegation: true, supported: true, kind: .draft, reason: "明确委托起草")
    }
    func execute(_ request: AssistantExecutionRequest) async throws -> AssistantExecutionResult {
        .init(title: request.input.title, markdown: "# 合成成果\n\n上下文复用验证。", responseID: UUID().uuidString)
    }
}

private struct QuietFollowupPort: RecordingFollowupPort {
    func generate(_ input: RecordingFollowupInput) async throws -> RecordingFollowupGeneration {
        .init(result: .init(thoughtUpdates: [], goalPlans: [],
                            english: .init(isPractice: false, evidenceQuote: "", suggestions: [], comparisons: [], nextExercise: "")),
              responseIDs: ["fixture-response"])
    }
}

final class AssistantContextReuseChecks: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-assistant-context-" + UUID().uuidString)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func openStore(named name: String) async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: root.appendingPathComponent(name), inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }

    private func seedTask(_ store: VoiceOSStore, text: String, title: String) async throws -> (sourceID: String, action: ActionRecord) {
        let sourceID = try await store.recordUserExpression(text)
        _ = try await store.setSourceLocalOnly(sourceID: sourceID, expectedVersion: 1, localOnly: false)
        let context = try await store.prepareLocalTranscriptContext(sourceIDs: [sourceID])
        let item = try XCTUnwrap(context.sources.first)
        _ = try await store.importOrganizedClaims(context: context, proposals: [
            .init(statement: text, ownership: .userTentative,
                  references: [.init(sourceID: sourceID, transcriptVersionID: item.transcriptVersionID, spanID: item.spans[0].id)],
                  action: .init(title: title, kind: .task, quote: text))
        ], commandID: "assistant-context-" + sourceID)
        let actions = try await store.actions()
        return (sourceID, try XCTUnwrap(actions.first { $0.title == title }))
    }

    private func executionInputJSON(action: ActionRecord, references: [ClaimReference], dropReferences: Bool) throws -> String {
        let input = AssistantTaskInput(actionID: action.id, actionVersion: action.version, claimID: action.claimID,
                                       claimReviewVersion: action.claimReviewVersion, title: action.title, note: action.note,
                                       instruction: "", context: LocalTranscriptContext(sources: [], scalarBudget: 4000, contentDigest: "fixture"),
                                       policyVersions: [:], references: references)
        let data = try JSONEncoder().encode(input)
        guard dropReferences else { return String(decoding: data, as: UTF8.self) }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "references")
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func insertExecution(_ store: VoiceOSStore, action: ActionRecord, id: String, inputJSON: String) async throws {
        let db = await store.db
        let now = "2026-11-17T00:00:00Z"
        try db.execute("INSERT INTO assistant_executions(id,action_id,action_version,input_json,sequence,state,validity,created_at,updated_at) VALUES(?,?,?,?,?,'completed','current',?,?)",
                       [id, action.id, String(action.version), inputJSON, "1", now, now])
    }

    func testDiscoverySharedContextQueuesSameAsPerItemEnqueue() async throws {
        let batch = try await openStore(named: "batch")
        let perItem = try await openStore(named: "single")
        let titles = ["整理检索质量", "整理评测集"]
        for title in titles {
            _ = try await seedTask(batch, text: "请帮我\(title)。", title: title)
            _ = try await seedTask(perItem, text: "请帮我\(title)。", title: title)
        }
        let perItemActions = try await perItem.actions()
        for title in titles {
            let action = try XCTUnwrap(perItemActions.first { $0.title == title })
            _ = try await perItem.enqueueAssistantExecution(actionID: action.id, expectedVersion: action.version)
        }

        let port = QueuingAssistantPort()
        let discovered = try await batch.discoverAutomaticAssistantExecutions(using: port)
        XCTAssertTrue(discovered)
        let batchExecutions = try await batch.assistantExecutions()
        let perItemExecutions = try await perItem.assistantExecutions()
        XCTAssertEqual(batchExecutions.count, 2)
        XCTAssertEqual(perItemExecutions.count, 2)

        func outcomes(_ rows: [AssistantExecutionRecord], _ actionTitles: [String: String]) -> [String: [String]] {
            Dictionary(uniqueKeysWithValues: rows.map { row in
                (actionTitles[row.actionID] ?? row.actionID, [row.state, row.validity, row.mode.rawValue, row.instruction])
            })
        }
        let batchTitles = Dictionary(uniqueKeysWithValues: (try await batch.actions()).map { ($0.id, $0.title) })
        let singleTitles = Dictionary(uniqueKeysWithValues: perItemActions.map { ($0.id, $0.title) })
        XCTAssertEqual(outcomes(batchExecutions, batchTitles), outcomes(perItemExecutions, singleTitles))
        XCTAssertTrue(batchExecutions.allSatisfy { $0.state == "queued" && $0.validity == "current" && $0.mode == .execution })

        let repeated = try await batch.discoverAutomaticAssistantExecutions(using: port)
        XCTAssertFalse(repeated)
        let batchCount = try await batch.assistantExecutions().count
        XCTAssertEqual(batchCount, 2)
    }

    func testDiscoveryRebuildsAfterFreezeAndQueuesRemainingTasks() async throws {
        let store = try await openStore(named: "freeze")
        let revoked = try await seedTask(store, text: "请帮我起草访谈提纲。", title: "起草访谈提纲")
        let valid = try await seedTask(store, text: "请帮我整理调研计划。", title: "整理调研计划")
        let stale = try await store.enqueueAssistantExecution(actionID: revoked.action.id, expectedVersion: revoked.action.version)
        _ = try await store.setSourceLocalOnly(sourceID: revoked.sourceID, expectedVersion: 2, localOnly: true)

        let port = QueuingAssistantPort()
        let discovered = try await store.discoverAutomaticAssistantExecutions(using: port)
        XCTAssertTrue(discovered)
        let executions = try await store.assistantExecutions()
        let frozen = try XCTUnwrap(executions.first { $0.id == stale.id })
        XCTAssertEqual(frozen.validity, "frozen")
        XCTAssertEqual(frozen.state, "cancelled")
        let queued = try XCTUnwrap(executions.first { $0.actionID == valid.action.id })
        XCTAssertEqual(queued.state, "queued")
        XCTAssertEqual(queued.validity, "current")
        XCTAssertEqual(executions.filter { $0.actionID == valid.action.id }.count, 1)
        let discoveredAgain = try await store.discoverAutomaticAssistantExecutions(using: port)
        XCTAssertFalse(discoveredAgain)
    }

    func testFollowupValidityBatchWithPreloadedRowsMatchesSingles() async throws {
        let store = try await openStore(named: "validity")
        let first = try await store.recordUserExpression("继续练英语讲解。")
        let second = try await store.recordUserExpression("整理下一轮练习重点。")
        for sourceID in [first, second] {
            _ = try await store.setSourceLocalOnly(sourceID: sourceID, expectedVersion: 1, localOnly: false)
            let completed = try await store.processRecordingFollowup(sourceID: sourceID, using: QuietFollowupPort())
            XCTAssertEqual(completed.state, "completed")
        }
        let receipts = try await store.recordingFollowups()
        XCTAssertEqual(receipts.count, 2)

        func batchValidity() async throws -> [String: RecordingFollowupValidity] {
            let catalog = try await store.sources()
            let claims = try await store.candidateClaims()
            let actions = try await store.actions(includeHistory: true)
            return try await store.recordingFollowupValidities(receipts, catalogRows: catalog, claimRows: claims, actionRows: actions)
        }
        func assertMatchesSingles(_ batch: [String: RecordingFollowupValidity]) async throws {
            XCTAssertEqual(Set(batch.keys), Set(receipts.map(\.id)))
            for receipt in receipts {
                let single = try await store.recordingFollowupValidity(receipt)
                let shared = try XCTUnwrap(batch[receipt.id])
                XCTAssertEqual(shared.sourceCurrent, single.sourceCurrent)
                XCTAssertEqual(shared.thoughtClaimIDs, single.thoughtClaimIDs)
                XCTAssertEqual(shared.goalIDs, single.goalIDs)
                XCTAssertEqual(shared.english, single.english)
            }
        }

        let before = try await batchValidity()
        XCTAssertTrue(before.values.allSatisfy(\.sourceCurrent))
        try await assertMatchesSingles(before)

        _ = try await store.setSourceLocalOnly(sourceID: second, expectedVersion: 2, localOnly: true)
        let after = try await batchValidity()
        let revokedID = try XCTUnwrap(receipts.first { $0.sourceID == second }).id
        let currentID = try XCTUnwrap(receipts.first { $0.sourceID == first }).id
        XCTAssertFalse(try XCTUnwrap(after[revokedID]).sourceCurrent)
        XCTAssertTrue(try XCTUnwrap(after[currentID]).sourceCurrent)
        try await assertMatchesSingles(after)
    }

    func testAssistantExecutionRecordReadsLegacyInputWithoutReferences() async throws {
        let store = try await openStore(named: "legacy-references")
        let seeded = try await seedTask(store, text: "请帮我核对回答依据。", title: "核对回答依据")
        let json = try executionInputJSON(action: seeded.action, references: [], dropReferences: true)
        try await insertExecution(store, action: seeded.action, id: "legacy-execution", inputJSON: json)
        let records = try await store.assistantExecutions()
        let record = try XCTUnwrap(records.first { $0.id == "legacy-execution" })
        XCTAssertTrue(record.inputReferences.isEmpty, "缺少 references 的旧输入应按空数组读取")
    }

    func testAssistantExecutionRecordKeepsInputReferenceOrder() async throws {
        let store = try await openStore(named: "ordered-references")
        let seeded = try await seedTask(store, text: "请帮我核对回答顺序。", title: "核对回答顺序")
        let references = (1...3).map { ClaimReference(sourceID: "source-\($0)", transcriptVersionID: "version-\($0)", spanID: "span-\($0)") }
        let json = try executionInputJSON(action: seeded.action, references: references, dropReferences: false)
        try await insertExecution(store, action: seeded.action, id: "ordered-execution", inputJSON: json)
        let records = try await store.assistantExecutions()
        let record = try XCTUnwrap(records.first { $0.id == "ordered-execution" })
        XCTAssertEqual(record.inputReferences, references, "应按 input_json 的原顺序解码")
    }
}
