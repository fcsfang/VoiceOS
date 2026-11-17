import XCTest
import Foundation
import AVFoundation
@testable import VoiceOSCore
import VoiceOSPlatform

private let failureExitConfiguration = ModelConfiguration(provider: "fixture-exit", model: "flow",
    promptVersion: "v1", schemaVersion: "v1", destination: .local)

private struct ExitAcceptingModel: ModelPort {
    let configuration = failureExitConfiguration
    func generate(_ request: ModelRequest) async throws -> ModelResponse {
        let source = request.context.sources[0]
        let reference = ClaimReference(sourceID: source.sourceID,
            transcriptVersionID: source.transcriptVersionID, spanID: source.spans[0].id)
        return ModelResponse(status: .completed, claims: [ClaimProposal(
            statement: "重新理解后的有效陈述。", ownership: .userTentative, references: [reference])])
    }
}

private struct ExitRejectingModel: ModelPort {
    let configuration = failureExitConfiguration
    func generate(_ request: ModelRequest) async throws -> ModelResponse {
        throw ModelPortFailure.rejected("示例拒绝")
    }
}

private struct ExitUnknownModel: ModelPort {
    let configuration = failureExitConfiguration
    func generate(_ request: ModelRequest) async throws -> ModelResponse {
        throw URLError(.timedOut)
    }
}

private struct ExitAssociation: ExpressionAssociationPort {
    let configuration = failureExitConfiguration
    func associate(_ request: ExpressionAssociationRequest) async throws -> ExpressionAssociationResponse {
        ExpressionAssociationResponse(proposals: [])
    }
}

private struct ExitSpeech: SpeechPort {
    func transcribe(_ url: URL, locale: String) async throws -> SpeechText {
        SpeechText(text: "我认为重新核对处理条件值得研究。")
    }
}

final class ProcessingFailureExitChecks: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-processing-exit-" + UUID().uuidString)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func openStore() async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }

    private func queueIntent(_ store: VoiceOSStore, text: String, commandID: String) async throws -> ExpressionProcessingIntentRecord {
        let sourceID = try await store.recordUserExpression(text)
        let snapshot = try await store.prepareExpressionProcessingIntent(sourceID: sourceID,
            cognition: failureExitConfiguration, association: failureExitConfiguration)
        return try await store.enqueueExpressionProcessingIntent(snapshot, commandID: commandID,
            cognition: failureExitConfiguration, association: failureExitConfiguration)
    }

    func testRejectedIntentCanBeUnderstoodAgainUnderANewCommand() async throws {
        let store = try await openStore()
        let database = await store.db
        XCTAssertEqual(try database.query("PRAGMA user_version").first?["user_version"],
                       TestSchema.currentVersion, "数据库应升级到当前版本")

        let queued = try await queueIntent(store, text: "我想验证被拒绝后的重新理解。", commandID: "exit-rejected")
        let rejected = try await store.runExpressionProcessingIntent(id: queued.id, retrieval: NativeRetrieval(),
            cognitionPort: ExitRejectingModel(), associationPort: ExitAssociation())
        XCTAssertEqual(rejected.state, .rejected, "被拒绝的理解应停在 rejected")
        XCTAssertTrue(rejected.canReprocess, "rejected 应提供重新理解入口")

        let retried = try await store.reprocessExpressionProcessingIntent(id: rejected.id,
            cognition: failureExitConfiguration, association: failureExitConfiguration)
        XCTAssertTrue(retried.commandID.hasPrefix("expression-reprocess:\(rejected.id):"),
                      "重新理解必须使用新的命令号")
        XCTAssertEqual(retried.state, .queued, "重新理解应把新命令排入队列")

        let old = try await store.processingIntent(id: rejected.id)
        XCTAssertEqual(old.state, .rejected, "旧记录必须保留")
        XCTAssertEqual(old.supersededBy, retried.id, "旧记录应指向新的理解记录")

        let completed = try await store.runExpressionProcessingIntent(id: retried.id, retrieval: NativeRetrieval(),
            cognitionPort: ExitAcceptingModel(), associationPort: ExitAssociation())
        XCTAssertEqual(completed.state, .completed, "重新理解成功后应完成")
        let attention = try await store.processingIntentsNeedingAttention()
        XCTAssertTrue(attention.isEmpty, "被取代的失败记录不应再计入注意力")
    }

    func testUnknownIntentCanBeRetriedWithoutResendingTheOldReceipt() async throws {
        let store = try await openStore()
        let queued = try await queueIntent(store, text: "我想验证结果未知后的重新理解。", commandID: "exit-unknown")
        let unknown = try await store.runExpressionProcessingIntent(id: queued.id, retrieval: NativeRetrieval(),
            cognitionPort: ExitUnknownModel(), associationPort: ExitAssociation())
        XCTAssertEqual(unknown.state, .unknown, "传输未返回结果时应停在 unknown")
        XCTAssertTrue(unknown.canReprocess, "unknown 应提供重新理解入口")

        let retried = try await store.reprocessExpressionProcessingIntent(id: unknown.id,
            cognition: failureExitConfiguration, association: failureExitConfiguration)
        let completed = try await store.runExpressionProcessingIntent(id: retried.id, retrieval: NativeRetrieval(),
            cognitionPort: ExitAcceptingModel(), associationPort: ExitAssociation())
        XCTAssertEqual(completed.state, .completed, "结果未知后重新理解应能完成")
    }

    func testIgnoredFailureLeavesTheAttentionSetAndPersists() async throws {
        let blockedID: String = try await {
            let store = try await openStore()
            let queued = try await queueIntent(store, text: "我想验证忽略后的注意力。", commandID: "exit-ignore")
            let blocked = try await store.runExpressionProcessingIntent(id: queued.id, retrieval: NativeRetrieval(),
                cognitionPort: ExitAcceptingModel(), associationPort: nil)
            XCTAssertEqual(blocked.state, .blocked, "关联端口缺失时应停在 blocked")
            XCTAssertTrue(blocked.canIgnore, "blocked 应提供忽略入口")
            XCTAssertTrue(blocked.needsAttention, "未忽略的 blocked 应计入注意力")

            let ignored = try await store.ignoreExpressionProcessingIntent(id: blocked.id, reason: "这次先不处理")
            XCTAssertNotNil(ignored.ignoredAt, "忽略应记录时间")
            XCTAssertEqual(ignored.ignoreReason, "这次先不处理", "忽略应记录原因")
            XCTAssertFalse(ignored.needsAttention, "忽略后不再计入注意力")
            let attention = try await store.processingIntentsNeedingAttention()
            XCTAssertTrue(attention.isEmpty, "忽略后注意力集合应为空")
            return blocked.id
        }()

        let reopened = try await openStore()
        let persisted = try await reopened.processingIntent(id: blockedID)
        XCTAssertEqual(persisted.ignoreReason, "这次先不处理", "忽略原因应落盘")
        XCTAssertNotNil(persisted.ignoredAt, "忽略时间应落盘")
    }

    func testBlockedRecordingRequestRechecksAndIsConsumed() async throws {
        let store = try await openStore()
        let recording = try await store.beginProcessingDictation(cognition: failureExitConfiguration,
            association: failureExitConfiguration)
        try writeAudio(to: recording)
        try await store.sealDictation(sourceID: recording.sourceID)
        try await store.processTranscriptions(using: ExitSpeech())

        let changed = ModelConfiguration(provider: "fixture-other", model: "flow",
            promptVersion: "v1", schemaVersion: "v1", destination: .local)
        try await store.reconcileRecordingProcessingRequests(cognition: changed, association: changed)
        let blockedRequests = try await store.recordingProcessingRequests()
        let blocked = try XCTUnwrap(blockedRequests.first)
        XCTAssertEqual(blocked.state, "blocked", "模型身份变化后应停在 blocked")
        XCTAssertNotNil(blocked.error, "blocked 应保留最近原因")

        try await store.retryRecordingProcessingRequest(id: blocked.id)
        let waitingRequests = try await store.recordingProcessingRequests()
        let waiting = try XCTUnwrap(waitingRequests.first)
        XCTAssertEqual(waiting.state, "waiting", "重新核对应回到 waiting 走既有流程")

        try await store.reconcileRecordingProcessingRequests(cognition: failureExitConfiguration,
            association: failureExitConfiguration)
        let enqueuedRequests = try await store.recordingProcessingRequests()
        let enqueued = try XCTUnwrap(enqueuedRequests.first)
        XCTAssertEqual(enqueued.state, "enqueued", "条件恢复后应进入既有队列")
        let intents = try await store.processingIntents()
        let queue = try XCTUnwrap(intents.first { $0.commandID == "record-process:" + blocked.id })
        let result = try await store.runExpressionProcessingIntent(id: queue.id, retrieval: NativeRetrieval(),
            cognitionPort: ExitAcceptingModel(), associationPort: ExitAssociation())
        XCTAssertEqual(result.state, .completed, "重新核对后的请求应被消费并完成")
    }

    func testPendingReminderSyncKeepsLatestFailureAndClearsOnSuccess() throws {
        var entry = PendingReminderSync(actionID: "a", linkID: "l", calendarID: "c", externalID: "e",
            marker: "m", title: "任务", desiredState: LocalActionState.completed.rawValue,
            createdAt: "2026-11-17T00:00:00Z")
        XCTAssertNil(entry.lastFailureReason, "新排队项不应带旧失败原因")

        entry.recordFailure("网络中断", at: "2026-11-17T01:00:00Z")
        entry.recordFailure("系统权限被拒绝", at: "2026-11-17T02:00:00Z")
        XCTAssertEqual(entry.lastFailureReason, "系统权限被拒绝", "再次失败应覆盖为最新原因")

        let data = try JSONEncoder().encode([entry.actionID: entry])
        let restored = try XCTUnwrap(JSONDecoder().decode([String: PendingReminderSync].self, from: data)[entry.actionID])
        XCTAssertEqual(restored.lastFailureReason, "系统权限被拒绝", "失败原因应随记录落盘")
        XCTAssertEqual(restored.lastFailureAt, "2026-11-17T02:00:00Z", "失败时间应随记录落盘")

        var cleared = restored
        cleared.clearFailure()
        XCTAssertNil(cleared.lastFailureReason, "成功回读后应清除原因")
        XCTAssertNil(cleared.lastFailureAt, "成功回读后应清除时间")

        let legacy = Data(#"{"pending":{"actionID":"a","linkID":"l","calendarID":"c","externalID":"e","marker":"m","title":"任务","desiredState":"completed","createdAt":"2026-11-17T00:00:00Z"}}"#.utf8)
        let old = try XCTUnwrap(JSONDecoder().decode([String: PendingReminderSync].self, from: legacy)["pending"])
        XCTAssertNil(old.lastFailureReason, "旧版待同步记录应继续读取")
    }

    private func writeAudio(to intent: RecordingIntent) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 12000)!
        buffer.frameLength = 12000
        for index in 0..<12000 { buffer.floatChannelData![0][index] = 0.01 * sin(Float(index) * 0.1) }
        let file = try AVAudioFile(forWriting: intent.stagingURL, settings: format.settings)
        try file.write(from: buffer)
    }
}
