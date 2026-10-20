import XCTest
import Foundation
@testable import VoiceOSCore

private struct Inspector: MediaInspector {
    func inspect(_ url: URL) async throws -> MediaInfo {
        guard try Data(contentsOf: url).starts(with: Data("fixture:".utf8)) else { throw VoiceOSError("invalid fixture") }
        return MediaInfo(duration: 1, kind: "audio")
    }
}
private struct Speech: SpeechPort {
    let backendIdentity = "synthetic-test-speech"
    let text: String
    func transcribe(_ url: URL, locale: String) async throws -> SpeechText { SpeechText(text: text) }
}
private struct FailedSpeech: SpeechPort {
    func transcribe(_ url: URL, locale: String) async throws -> SpeechText { throw VoiceOSError("backend unavailable") }
}
private actor TestModelPort: ModelPort {
    nonisolated let configuration: ModelConfiguration
    let response: ModelResponse.Status
    let suspended: Bool
    let fail: Bool
    var calls = 0
    var started: CheckedContinuation<Void, Never>?
    var gate: CheckedContinuation<Void, Never>?
    init(destination: ModelDestination = .local, response: ModelResponse.Status = .completed, suspended: Bool = false, fail: Bool = false) {
        configuration = ModelConfiguration(provider: "test_in_memory", model: "test", promptVersion: "p1", schemaVersion: "s1", destination: destination)
        self.response = response; self.suspended = suspended; self.fail = fail
    }
    func generate(_ request: ModelRequest) async throws -> ModelResponse {
        calls += 1
        if suspended { await withCheckedContinuation { gate = $0; started?.resume(); started = nil } }
        if fail { throw VoiceOSError("test transport failure") }
        let input = request.context.sources[0]
        return ModelResponse(status: response, claims: [ClaimProposal(statement: "模拟端口候选", ownership: .aiCandidate, references: [ClaimReference(sourceID: input.sourceID, transcriptVersionID: input.transcriptVersionID, spanID: input.spans[0].id)])], inputTokens: 10, outputTokens: 5)
    }
    func waitStarted() async { if gate == nil { await withCheckedContinuation { started = $0 } } }
    func release() { gate?.resume(); gate = nil }
}
private actor TestReminders: RemindersPort {
    var items: [ReminderSnapshot] = []
    var creates = 0
    var loseReceipt = false
    var deny = false
    var suspended = false
    var suspendCreate = false
    var gate: CheckedContinuation<Void, Never>?
    var started: CheckedContinuation<Void, Never>?
    init(loseReceipt: Bool = false, suspended: Bool = false, suspendCreate: Bool = false) { self.loseReceipt = loseReceipt; self.suspended = suspended; self.suspendCreate = suspendCreate }
    func find(calendarID: String, externalID: String?, marker: String) async throws -> [ReminderSnapshot] {
        if suspended { suspended = false; await withCheckedContinuation { gate = $0; started?.resume(); started = nil } }
        if deny { throw VoiceOSError("permission denied") }
        return items.filter { $0.marker == marker || $0.id == externalID }
    }
    func create(calendarID: String, title: String, marker: String) async throws {
        creates += 1
        if deny { throw VoiceOSError("permission denied") }
        items.append(ReminderSnapshot(id: UUID().uuidString, title: title, completed: false, marker: marker))
        if suspendCreate { await withCheckedContinuation { gate = $0; started?.resume(); started = nil } }
        if loseReceipt { throw VoiceOSError("lost receipt after save") }
    }
    func edit(title: String? = nil, completed: Bool = false, corruptMarker: Bool = false) {
        let item = items[0]; items[0] = ReminderSnapshot(id: item.id, title: title ?? item.title, completed: completed, marker: corruptMarker ? "edited" : item.marker)
    }
    func duplicate() { let item = items[0]; items.append(ReminderSnapshot(id: UUID().uuidString, title: item.title, completed: item.completed, marker: item.marker)) }
    func removeAll() { items = [] }
    func setDeny() { deny = true }
    func suspendRead() { suspended = true }
    func waitStarted() async { if gate == nil { await withCheckedContinuation { started = $0 } } }
    func release() { gate?.resume(); gate = nil }
}
private struct MalformedModelHTTP: ModelHTTPTransport {
    func send(_ request: URLRequest) async throws -> ModelHTTPReply {
        ModelHTTPReply(status: 200, body: Data(#"{"status":"completed","usage":{"input_tokens":12,"output_tokens":7},"output":[{"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"{\"claims\":[{\"userConfirmed\":true}]}"}]}]}"#.utf8))
    }
}
final class StoreTests: XCTestCase {
    private var base: URL!
    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceOS-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: base) }
    private func fixture(_ text: String = "fixture:independent test") throws -> URL {
        let url = base.appendingPathComponent("input.wav")
        try Data(text.utf8).write(to: url)
        return url
    }
    private func store() async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: base.appendingPathComponent("store"), inspector: Inspector())
        try await store.recover()
        return store
    }
    func testPortableTranscriptRetainsActualBackendInsteadOfClaimingNativeRecognition() async throws {
        let store=try await store();_=try await store.importFile(fixture())
        try await store.processTranscriptions(using:Speech(text:"合成转写原文"))
        let package=base.appendingPathComponent("backend-package")
        try await store.exportPackage(to:package)
        let row=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:package.appendingPathComponent("transcripts.jsonl"))) as? [String:Any])
        XCTAssertEqual(row["backend"] as? String,"synthetic-test-speech")
        let target=base.appendingPathComponent("backend-restored")
        try await VoiceOSStore.restorePackage(from:package,to:target,inspector:Inspector())
        let r=try VoiceOSStore(root:target,inspector:Inspector());try await r.recover()
        let restoredPackage=base.appendingPathComponent("backend-restored-package");try await r.exportPackage(to:restoredPackage)
        let restored=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:restoredPackage.appendingPathComponent("transcripts.jsonl"))) as? [String:Any])
        XCTAssertEqual(restored["backend"] as? String,"synthetic-test-speech")
    }
    func testMalformedRealDriverResponseRetainsUsageButNeverCommitsClaims() async throws {
        let store = try await store(); let source = try await store.importFile(fixture())
        try await store.processTranscriptions(using: Speech(text: "外部测试观点"))
        _ = try await store.setSourceLocalOnly(sourceID: source, expectedVersion: 1, localOnly: false)
        let snapshot = try await store.prepareLocalTranscriptContext(sourceIDs: [source])
        let context = try await store.persistLocalContext(snapshot, destination: .cloud)
        let port = try ResponsesModelPort(baseURL: URL(string: "https://api.chiyi.cc/v1")!, apiKey: "test", model: "test", transport: MalformedModelHTTP())
        do { _ = try await store.generateClaims(contextID: context, using: port); XCTFail("must reject") } catch {}
        let attempts = try await store.modelAttempts(); XCTAssertEqual(attempts.count, 1)
        XCTAssertEqual(attempts[0].state, "rejected"); XCTAssertEqual(attempts[0].usage?["input_tokens"], 12)
        XCTAssertEqual(attempts[0].usage?["output_tokens"], 7)
        let claims = try await store.candidateClaims(); XCTAssertTrue(claims.isEmpty)
    }
    func testUnderstandingDoesNotRepeatCompletedVersionButAllowsCorrection() async throws {
        let store = try await store(); let source = try await store.importFile(fixture())
        try await store.processTranscriptions(using: Speech(text: "外部资料"))
        let port = TestModelPort()
        _ = try await store.understandSource(sourceID: source, using: port)
        do { _ = try await store.understandSource(sourceID: source, using: port); XCTFail("must not resend") } catch {}
        var calls = await port.calls; XCTAssertEqual(calls, 1)
        let package = base.appendingPathComponent("completed-understanding-package")
        try await store.exportPackage(to: package, includeMedia: true)
        let root = base.appendingPathComponent("completed-understanding-restored")
        try await VoiceOSStore.restorePackage(from: package, to: root, inspector: Inspector())
        let restored = try VoiceOSStore(root: root, inspector: Inspector()); try await restored.recover()
        do { _ = try await restored.understandSource(sourceID: source, using: port); XCTFail("restored completed resend") } catch {}
        calls = await port.calls; XCTAssertEqual(calls, 1)
        let rows = try await store.sources()
        let version = try XCTUnwrap(rows.first?.transcriptVersionID)
        _ = try await store.correctTranscript(sourceID: source, expectedVersionID: version, text: "更正后的外部资料")
        _ = try await store.understandSource(sourceID: source, using: port)
        calls = await port.calls; XCTAssertEqual(calls, 2)
        let all = try await store.candidateClaims(includeFrozen: true)
        XCTAssertEqual(all.filter { $0.validity == "frozen" }.count, 1)
        XCTAssertEqual(all.filter { $0.validity == "current" }.count, 1)
    }
    func testUnderstandingUnknownAndConcurrentAttemptsNeverResend() async throws {
        let store = try await store(); let source = try await store.importFile(fixture())
        try await store.processTranscriptions(using: Speech(text: "外部资料"))
        let port = TestModelPort(suspended: true, fail: true)
        let running = Task { try await store.understandSource(sourceID: source, using: port) }
        await port.waitStarted()
        do { _ = try await store.understandSource(sourceID: source, using: port); XCTFail("concurrent resend") } catch {}
        await port.release()
        do { _ = try await running.value; XCTFail("transport must fail") } catch {}
        do { _ = try await store.understandSource(sourceID: source, using: port); XCTFail("unknown resend") } catch {}
        let calls = await port.calls; XCTAssertEqual(calls, 1)
        let attempts = try await store.modelAttempts(sourceID: source)
        XCTAssertEqual(attempts.count, 1); XCTAssertEqual(attempts[0].state, "unknown")
        let package = base.appendingPathComponent("understanding-package")
        try await store.exportPackage(to: package, includeMedia: true)
        let root = base.appendingPathComponent("understanding-restored")
        try await VoiceOSStore.restorePackage(from: package, to: root, inspector: Inspector())
        let restored = try VoiceOSStore(root: root, inspector: Inspector()); try await restored.recover()
        do { _ = try await restored.understandSource(sourceID: source, using: port); XCTFail("restored unknown resend") } catch {}
        let finalCalls = await port.calls; XCTAssertEqual(finalCalls, 1)
    }
    private func reviewFixture(_ store: VoiceOSStore) async throws -> CandidateClaim {
        let source = try await store.importFile(fixture())
        try await store.processTranscriptions(using: Speech(text: "外部测试资料"))
        _ = try await store.understandSource(sourceID: source, using: TestModelPort())
        let claims = try await store.candidateClaims(); return try XCTUnwrap(claims.first)
    }
    func testClaimEndorsementReceiptRejectAndCASRemainSeparateFromEvidence() async throws {
        let store = try await store(); let claim = try await reviewFixture(store)
        _ = try await store.reviewClaim(claimID: claim.id, expectedVersion: 0, action: .endorse, commandID: "endorse")
        let replay = try await store.reviewClaim(claimID: claim.id, expectedVersion: 0, action: .endorse, commandID: "endorse")
        XCTAssertEqual(replay, 1)
        do { _ = try await store.reviewClaim(claimID: claim.id, expectedVersion: 0, action: .reject); XCTFail("stale review") } catch {}
        do { _ = try await store.reviewClaim(claimID: claim.id, expectedVersion: 0, action: .reject, commandID: "endorse"); XCTFail("changed receipt") } catch {}
        var claims = try await store.candidateClaims(); XCTAssertEqual(claims[0].reviewState, "endorsed")
        XCTAssertEqual(claims[0].evidenceState, "unverified"); XCTAssertEqual(claims[0].ownership, "ai_candidate")
        _ = try await store.reviewClaim(claimID: claim.id, expectedVersion: 1, action: .reject)
        claims = try await store.candidateClaims(); XCTAssertTrue(claims.isEmpty)
        let history = try await store.claimReviewHistory(claimID: claim.id); XCTAssertEqual(history.count, 3)
        let historical = try await store.candidateClaims(includeFrozen: true); XCTAssertEqual(historical[0].reviewState, "rejected")
    }
    func testClaimCorrectionPreservesOriginalAndResetsEndorsementAcrossRestore() async throws {
        let store = try await store(); let claim = try await reviewFixture(store)
        _ = try await store.reviewClaim(claimID: claim.id, expectedVersion: 0, action: .endorse)
        _ = try await store.reviewClaim(claimID: claim.id, expectedVersion: 1, action: .correct, statement: "用户纠正后的外部说法", ownership: .external, note: "纠正 AI 错误归属")
        let current = try await store.candidateClaims()[0]
        XCTAssertEqual(current.reviewState, "pending"); XCTAssertEqual(current.ownership, "external")
        XCTAssertEqual(current.evidenceState, "unverified")
        let history = try await store.claimReviewHistory(claimID: claim.id)
        XCTAssertEqual(history[0].statement, claim.statement); XCTAssertEqual(history.last?.reason, "correction")
        let package = base.appendingPathComponent("claim-reviews"); try await store.exportPackage(to: package, includeMedia: true)
        let root = base.appendingPathComponent("reviews-restored")
        try await VoiceOSStore.restorePackage(from: package, to: root, inspector: Inspector())
        let restored = try VoiceOSStore(root: root, inspector: Inspector()); try await restored.recover()
        let versions = try await restored.claimReviewHistory(claimID: claim.id)
        XCTAssertEqual(versions.map(\.statement), history.map(\.statement))
        let read = try await restored.candidateClaims()[0]; XCTAssertEqual(read.reviewVersion, 2)
    }
    func testFrozenClaimCannotBeEndorsedAndEmptyCorrectionCannotCommit() async throws {
        let store = try await store(); let claim = try await reviewFixture(store)
        do { _ = try await store.reviewClaim(claimID: claim.id, expectedVersion: 0, action: .correct, statement: "更正", note: ""); XCTFail("missing correction reason") } catch {}
        let source = try await store.sources()[0]
        _ = try await store.correctTranscript(sourceID: source.id, expectedVersionID: source.transcriptVersionID!, text: "新来源文字")
        do { _ = try await store.reviewClaim(claimID: claim.id, expectedVersion: 0, action: .endorse); XCTFail("frozen endorsement") } catch {}
        let history = try await store.claimReviewHistory(claimID: claim.id); XCTAssertEqual(history.count, 1)
    }
    func testRestoreRejectsMissingClaimReviewHistoryDespiteMatchingFileHashes() async throws {
        let store = try await store(); let claim = try await reviewFixture(store)
        _ = try await store.reviewClaim(claimID: claim.id, expectedVersion: 0, action: .endorse)
        let package = base.appendingPathComponent("broken-review-history"); try await store.exportPackage(to: package)
        let file = package.appendingPathComponent("claim_reviews.jsonl"); try Data().write(to: file)
        let manifestFile = package.appendingPathComponent("manifest.json")
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestFile)) as! [String: Any]
        var counts = manifest["counts"] as! [String: Int]; counts["claim_reviews"] = 0; manifest["counts"] = counts
        var files = manifest["files"] as! [[String: Any]]; let index = files.firstIndex { $0["path"] as? String == "claim_reviews.jsonl" }!
        let digest = try DurableFiles.hash(file); files[index]["sha256"] = digest.1; files[index]["bytes"] = digest.0; manifest["files"] = files
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestFile)
        let target = base.appendingPathComponent("review-history-rejected")
        do { try await VoiceOSStore.restorePackage(from: package, to: target, inspector: Inspector()); XCTFail("missing review history") }
        catch { XCTAssertTrue(error.localizedDescription.contains("审阅历史")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }
    func testActionKindsCannotTurnAISuggestionOrOpportunityIntoCompletedTask() async throws {
        let store = try await store(); let claim = try await reviewFixture(store)
        let opportunity = try await store.createAction(claimID: claim.id, expectedClaimReviewVersion: 0, title: "有空探索", kind: .opportunity)
        _ = try await store.createAction(claimID: claim.id, expectedClaimReviewVersion: 0, title: "AI 提议", kind: .aiSuggestion, intentActor: .ai)
        do { _ = try await store.createAction(claimID: claim.id, expectedClaimReviewVersion: 0, title: "AI 承诺", kind: .task, intentActor: .ai); XCTFail("AI cannot commit") } catch {}
        do { _ = try await store.createAction(claimID: claim.id, expectedClaimReviewVersion: 0, title: "假归属", kind: .aiSuggestion); XCTFail("actor mismatch") } catch {}
        do { _ = try await store.createAction(claimID: claim.id, expectedClaimReviewVersion: 0, title: " ", kind: .task); XCTFail("empty task") } catch {}
        do { _ = try await store.setActionState(actionID: opportunity, expectedVersion: 1, state: .completed); XCTFail("opportunity completion") } catch {}
        let actions = try await store.actions(); XCTAssertEqual(actions.count, 2)
    }
    func testActionReceiptsCASCompletionAndHistorySurviveRestoreWithoutVerifyingClaim() async throws {
        let store = try await store(); let claim = try await reviewFixture(store)
        let id = try await store.createAction(claimID: claim.id, expectedClaimReviewVersion: 0, title: "验证说法", kind: .task, commandID: "task")
        let replay = try await store.createAction(claimID: claim.id, expectedClaimReviewVersion: 0, title: "验证说法", kind: .task, commandID: "task")
        XCTAssertEqual(id, replay)
        do { _ = try await store.createAction(claimID: claim.id, expectedClaimReviewVersion: 0, title: "更换", kind: .task, commandID: "task"); XCTFail("changed receipt") } catch {}
        _ = try await store.setActionState(actionID: id, expectedVersion: 1, state: .completed, note: "完成操作，不是证据", commandID: "done")
        let version = try await store.setActionState(actionID: id, expectedVersion: 1, state: .completed, note: "完成操作，不是证据", commandID: "done")
        XCTAssertEqual(version, 2)
        do { _ = try await store.setActionState(actionID: id, expectedVersion: 1, state: .open); XCTFail("stale state") } catch {}
        let active = try await store.actions(); XCTAssertTrue(active.isEmpty)
        let candidate = try await store.candidateClaims()[0]; XCTAssertEqual(candidate.evidenceState, "unverified"); XCTAssertEqual(candidate.reviewState, "pending")
        let package = base.appendingPathComponent("actions-package"); try await store.exportPackage(to: package, includeMedia: true)
        let root = base.appendingPathComponent("actions-restored"); try await VoiceOSStore.restorePackage(from: package, to: root, inspector: Inspector())
        let restored = try VoiceOSStore(root: root, inspector: Inspector()); try await restored.recover()
        let history = try await restored.actionHistory(actionID: id); XCTAssertEqual(history.map(\.state), ["open","completed"])
        XCTAssertEqual(history.last?.note, "完成操作，不是证据")
    }
    func testReviewAndSourceChangesFreezeActionsWithoutErasingCompletionOrReactivatingReceipt() async throws {
        let store = try await store(); let claim = try await reviewFixture(store)
        let id = try await store.createAction(claimID: claim.id, expectedClaimReviewVersion: 0, title: "任务", kind: .task, commandID: "task")
        _ = try await store.setActionState(actionID: id, expectedVersion: 1, state: .completed)
        _ = try await store.reviewClaim(claimID: claim.id, expectedVersion: 0, action: .endorse)
        var actions = try await store.actions(includeHistory: true); XCTAssertEqual(actions[0].validity, "frozen"); XCTAssertEqual(actions[0].state, "completed")
        _ = try await store.createAction(claimID: claim.id, expectedClaimReviewVersion: 0, title: "任务", kind: .task, commandID: "task")
        do { _ = try await store.setActionState(actionID: id, expectedVersion: 2, state: .open); XCTFail("frozen action") } catch {}
        do { _ = try await store.createAction(claimID: claim.id, expectedClaimReviewVersion: 0, title: "旧认知", kind: .task); XCTFail("stale claim pin") } catch {}
        _ = try await store.createAction(claimID: claim.id, expectedClaimReviewVersion: 1, title: "新版探索", kind: .opportunity)
        let source = try await store.sources()[0]
        _ = try await store.correctTranscript(sourceID: source.id, expectedVersionID: source.transcriptVersionID!, text: "来源更正")
        actions = try await store.actions(includeHistory: true); XCTAssertTrue(actions.allSatisfy { $0.validity == "frozen" })
    }
    func testRestoreRejectsMissingActionHistoryDespiteMatchingManifestHashes() async throws {
        let store = try await store(); let claim = try await reviewFixture(store)
        let id = try await store.createAction(claimID: claim.id, expectedClaimReviewVersion: 0, title: "任务", kind: .task)
        _ = try await store.setActionState(actionID: id, expectedVersion: 1, state: .completed)
        let package = base.appendingPathComponent("broken-actions"); try await store.exportPackage(to: package)
        let file = package.appendingPathComponent("action_revisions.jsonl"); try Data().write(to: file)
        let manifestFile = package.appendingPathComponent("manifest.json")
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestFile)) as! [String: Any]
        var counts = manifest["counts"] as! [String: Int]; counts["action_revisions"] = 0; manifest["counts"] = counts
        var files = manifest["files"] as! [[String: Any]]; let index = files.firstIndex { $0["path"] as? String == "action_revisions.jsonl" }!
        let digest = try DurableFiles.hash(file); files[index]["sha256"] = digest.1; files[index]["bytes"] = digest.0; manifest["files"] = files
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestFile)
        let target = base.appendingPathComponent("invalid-actions-target")
        do { try await VoiceOSStore.restorePackage(from: package, to: target, inspector: Inspector()); XCTFail("missing action history") } catch { XCTAssertTrue(error.localizedDescription.contains("行动状态历史")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }
    private func reminderFixture(_ store: VoiceOSStore) async throws -> (CandidateClaim, String) {
        let source = try await store.importFile(fixture())
        _ = try await store.setSourceLocalOnly(sourceID: source, expectedVersion: 1, localOnly: false)
        try await store.processTranscriptions(using: Speech(text: "允许外发的合成测试资料"))
        _ = try await store.understandSource(sourceID: source, using: TestModelPort())
        let claim = try await store.candidateClaims()[0]
        let id = try await store.createAction(claimID: claim.id, expectedClaimReviewVersion: 0, title: "明确验证任务", kind: .task)
        return (claim,id)
    }
    func testLocalOnlyDerivedTaskCannotSendToExternalReminders() async throws {
        let store = try await store(); let claim = try await reviewFixture(store)
        let id = try await store.createAction(claimID: claim.id, expectedClaimReviewVersion: 0, title: "本地资料派生任务", kind: .task)
        let port = TestReminders()
        do { try await store.sendTaskToReminders(actionID: id, expectedVersion: 1, calendarID: "authorized", using: port); XCTFail("local-only leak") } catch { XCTAssertTrue(error.localizedDescription.contains("仅本地")) }
        let links = try await store.reminderLinks(); XCTAssertTrue(links.isEmpty)
        let creates = await port.creates; XCTAssertEqual(creates, 0)
    }
    func testRemindersLostSaveReceiptOnlyReadsAndNeverCreatesAgain() async throws {
        let store = try await store(); let (_,id) = try await reminderFixture(store); let port = TestReminders(loseReceipt: true)
        do { try await store.sendTaskToReminders(actionID: id, expectedVersion: 1, calendarID: "authorized", using: port); XCTFail("lost ack") } catch {}
        let unknown = try await store.reminderLinks()[0]; XCTAssertEqual(unknown.state, "unknown")
        try await store.sendTaskToReminders(actionID: id, expectedVersion: 1, calendarID: "authorized", using: port)
        let link = try await store.reminderLinks()[0]; XCTAssertEqual(link.state, "linked")
        let creates = await port.creates; XCTAssertEqual(creates, 1)
        do { try await store.sendTaskToReminders(actionID: id, expectedVersion: 1, calendarID: "other", using: port); XCTFail("scope change") } catch {}
    }
    func testRemindersExternalRenameCompletionAndRestoreKeepEvidenceSeparate() async throws {
        let store = try await store(); let (_,id) = try await reminderFixture(store); let port = TestReminders()
        try await store.sendTaskToReminders(actionID: id, expectedVersion: 1, calendarID: "authorized", using: port)
        let link = try await store.reminderLinks()[0]
        await port.edit(title: "外部手动改名", completed: true)
        try await store.readReminder(linkID: link.id, calendarID: "authorized", using: port)
        try await store.readReminder(linkID: link.id, calendarID: "authorized", using: port)
        let action = try await store.actions(includeHistory: true)[0]; XCTAssertEqual(action.state, "completed"); XCTAssertEqual(action.version, 2); XCTAssertEqual(action.title, "明确验证任务")
        let claim = try await store.candidateClaims()[0]; XCTAssertEqual(claim.reviewState, "pending"); XCTAssertEqual(claim.evidenceState, "unverified")
        let package = base.appendingPathComponent("reminders-package"); try await store.exportPackage(to: package, includeMedia: true)
        let root = base.appendingPathComponent("reminders-restored"); try await VoiceOSStore.restorePackage(from: package, to: root, inspector: Inspector())
        let restored = try VoiceOSStore(root: root, inspector: Inspector()); try await restored.recover()
        let restoredLink = try await restored.reminderLinks()[0]; XCTAssertEqual(restoredLink.remoteTitle, "外部手动改名"); XCTAssertEqual(restoredLink.remoteCompleted, true)
        try await restored.sendTaskToReminders(actionID: id, expectedVersion: 2, calendarID: "authorized", using: port)
        let creates = await port.creates; XCTAssertEqual(creates, 1)
        let history = try await restored.actionHistory(actionID: id); XCTAssertEqual(history.count, 2)
    }
    func testMissingDuplicateAndEditedReminderMarkersCannotCompleteOrRecreate() async throws {
        for scenario in 0..<3 {
            let root = base.appendingPathComponent("case-\(scenario)"); let store = try VoiceOSStore(root: root, inspector: Inspector()); try await store.recover()
            let (_,id) = try await reminderFixture(store); let port = TestReminders()
            try await store.sendTaskToReminders(actionID: id, expectedVersion: 1, calendarID: "authorized", using: port)
            let link = try await store.reminderLinks()[0]
            if scenario == 0 { await port.removeAll() }
            else if scenario == 1 { await port.edit(completed: true); await port.duplicate() }
            else { await port.edit(completed: true, corruptMarker: true) }
            try await store.readReminder(linkID: link.id, calendarID: "authorized", using: port)
            try await store.sendTaskToReminders(actionID: id, expectedVersion: 1, calendarID: "authorized", using: port)
            let current = try await store.reminderLinks()[0]; XCTAssertEqual(current.state, scenario == 0 ? "missing" : "conflict")
            let action = try await store.actions(includeHistory: true)[0]; XCTAssertEqual(action.state, "open")
            let creates = await port.creates; XCTAssertEqual(creates, 1)
        }
    }
    func testFrozenActionRetainsRemoteCompletionObservationWithoutChangingLocalFact() async throws {
        let store = try await store(); let (claim,id) = try await reminderFixture(store); let port = TestReminders()
        try await store.sendTaskToReminders(actionID: id, expectedVersion: 1, calendarID: "authorized", using: port)
        _ = try await store.reviewClaim(claimID: claim.id, expectedVersion: 0, action: .reject)
        await port.edit(completed: true)
        let link = try await store.reminderLinks()[0]; try await store.readReminder(linkID: link.id, calendarID: "authorized", using: port)
        let action = try await store.actions(includeHistory: true)[0]; XCTAssertEqual(action.validity, "frozen"); XCTAssertEqual(action.state, "open")
        let current = try await store.reminderLinks()[0]; XCTAssertEqual(current.remoteCompleted, true)
    }
    func testLocalStateChangeAndExternalReopenRemainConflicts() async throws {
        let store = try await store(); let (_,id) = try await reminderFixture(store); let port = TestReminders()
        try await store.sendTaskToReminders(actionID: id, expectedVersion: 1, calendarID: "authorized", using: port)
        _ = try await store.setActionState(actionID: id, expectedVersion: 1, state: .dismissed)
        await port.edit(completed: true)
        let link = try await store.reminderLinks()[0]; try await store.readReminder(linkID: link.id, calendarID: "authorized", using: port)
        var current = try await store.reminderLinks()[0]; XCTAssertEqual(current.state, "conflict")
        var action = try await store.actions(includeHistory: true)[0]; XCTAssertEqual(action.state, "dismissed")
        _ = try await store.setActionState(actionID: id, expectedVersion: 2, state: .completed)
        await port.edit(completed: false)
        try await store.readReminder(linkID: link.id, calendarID: "authorized", using: port)
        current = try await store.reminderLinks()[0]; XCTAssertEqual(current.state, "conflict")
        action = try await store.actions(includeHistory: true)[0]; XCTAssertEqual(action.state, "completed")
    }
    func testPreflightConcurrentSendAndChangedDependencyBlockExternalCreate() async throws {
        let store = try await store(); let (claim,id) = try await reminderFixture(store); let port = TestReminders(suspended: true)
        let running = Task { try await store.sendTaskToReminders(actionID: id, expectedVersion: 1, calendarID: "authorized", using: port) }
        await port.waitStarted()
        do { try await store.sendTaskToReminders(actionID: id, expectedVersion: 1, calendarID: "authorized", using: port); XCTFail("concurrent send") } catch {}
        _ = try await store.reviewClaim(claimID: claim.id, expectedVersion: 0, action: .reject)
        await port.release()
        do { try await running.value; XCTFail("stale preflight") } catch {}
        let creates = await port.creates; XCTAssertEqual(creates, 0)
        let link = try await store.reminderLinks()[0]; XCTAssertEqual(link.state, "unknown")
    }
    func testPermissionTighteningDuringInFlightSaveFreezesActionAndKeepsObservation() async throws {
        let store = try await store(); let (_,id) = try await reminderFixture(store); let port = TestReminders(suspendCreate: true)
        let running = Task { try await store.sendTaskToReminders(actionID: id, expectedVersion: 1, calendarID: "authorized", using: port) }
        await port.waitStarted()
        let source = try await store.sources()[0]
        _ = try await store.setSourceLocalOnly(sourceID: source.id, expectedVersion: source.policyVersion, localOnly: true)
        await port.edit(completed: true); await port.release(); try await running.value
        let action = try await store.actions(includeHistory: true)[0]; XCTAssertEqual(action.validity, "frozen"); XCTAssertEqual(action.state, "open"); XCTAssertEqual(action.version, 1)
        let link = try await store.reminderLinks()[0]; XCTAssertEqual(link.remoteCompleted, true)
        let creates = await port.creates; XCTAssertEqual(creates, 1)
        let history = try await store.actionHistory(actionID: id); XCTAssertEqual(history.count, 1)
    }
    func testPermissionFailureCannotBecomeSuccessOrTriggerCreateRetry() async throws {
        let store = try await store(); let (_,id) = try await reminderFixture(store); let port = TestReminders(); await port.setDeny()
        do { try await store.sendTaskToReminders(actionID: id, expectedVersion: 1, calendarID: "authorized", using: port); XCTFail("permission") } catch {}
        do { try await store.sendTaskToReminders(actionID: id, expectedVersion: 1, calendarID: "authorized", using: port); XCTFail("permission retry") } catch {}
        let creates = await port.creates; XCTAssertEqual(creates, 0)
        let link = try await store.reminderLinks()[0]; XCTAssertEqual(link.state, "unknown")
    }
    func testRestoreRejectsMissingReminderFeedbackEvidenceEvenWithCorrectFileHashes() async throws {
        let store = try await store(); let (_,id) = try await reminderFixture(store); let port = TestReminders()
        try await store.sendTaskToReminders(actionID: id, expectedVersion: 1, calendarID: "authorized", using: port)
        await port.edit(completed: true)
        let link = try await store.reminderLinks()[0]; try await store.readReminder(linkID: link.id, calendarID: "authorized", using: port)
        let package = base.appendingPathComponent("broken-reminder-feedback"); try await store.exportPackage(to: package)
        let file = package.appendingPathComponent("reminder_observations.jsonl"); try Data().write(to: file)
        let manifestFile = package.appendingPathComponent("manifest.json")
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestFile)) as! [String: Any]
        var counts = manifest["counts"] as! [String: Int]; counts["reminder_observations"] = 0; manifest["counts"] = counts
        var files = manifest["files"] as! [[String: Any]]; let index = files.firstIndex { $0["path"] as? String == "reminder_observations.jsonl" }!
        let digest = try DurableFiles.hash(file); files[index]["sha256"] = digest.1; files[index]["bytes"] = digest.0; manifest["files"] = files
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestFile)
        let target = base.appendingPathComponent("missing-feedback-target")
        do { try await VoiceOSStore.restorePackage(from: package, to: target, inspector: Inspector()); XCTFail("missing remote evidence") } catch { XCTAssertTrue(error.localizedDescription.contains("回读")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }
    func testReminderAccessCASPersistenceAndPortableRestoreDoesNotTransferAuthority() async throws {
        let store = try await store(); _ = try await reminderFixture(store)
        let access = try await store.setReminderAccess(calendarID: "authorized", title: "专用清单", enabled: true, expectedVersion: 0)
        XCTAssertEqual(access.version, 1)
        let same = try await store.setReminderAccess(calendarID: "authorized", title: "专用清单", enabled: true, expectedVersion: 1); XCTAssertEqual(same.version, 1)
        do { _ = try await store.setReminderAccess(calendarID: "other", title: "另一个", enabled: true, expectedVersion: 0); XCTFail("stale authorization") } catch {}
        let package = base.appendingPathComponent("local-access-package"); try await store.exportPackage(to: package)
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.appendingPathComponent("reminder_access.jsonl").path))
        let root = base.appendingPathComponent("local-access-restored"); try await VoiceOSStore.restorePackage(from: package, to: root, inspector: Inspector())
        let restored = try VoiceOSStore(root: root, inspector: Inspector()); try await restored.recover()
        let migratedAccess = try await restored.reminderAccess(); XCTAssertNil(migratedAccess)
        let stop = try await store.setReminderAccess(calendarID: "authorized", title: "专用清单", enabled: false, expectedVersion: 1); XCTAssertEqual(stop.version, 2)
    }
    func testRevokedAccessDiscardsLateReadWithoutCompletingAction() async throws {
        let store = try await store(); let (_,id) = try await reminderFixture(store); let port = TestReminders()
        let access = try await store.setReminderAccess(calendarID: "authorized", title: "专用清单", enabled: true, expectedVersion: 0)
        try await store.sendTaskToReminders(actionID: id, expectedVersion: 1, calendarID: "authorized", using: port, expectedAccessVersion: access.version)
        let link = try await store.reminderLinks()[0]; await port.suspendRead()
        let running = Task { try await store.readReminder(linkID: link.id, calendarID: "authorized", using: port, expectedAccessVersion: 1) }
        await port.waitStarted()
        _ = try await store.setReminderAccess(calendarID: "authorized", title: "专用清单", enabled: false, expectedVersion: 1)
        await port.edit(completed: true); await port.release()
        do { try await running.value; XCTFail("late completion") } catch {}
        let action = try await store.actions(includeHistory: true)[0]; XCTAssertEqual(action.state, "open"); XCTAssertEqual(action.version, 1)
        let updated = try await store.reminderLinks()[0]; XCTAssertEqual(updated.remoteCompleted, false)
        do { try await store.reconcileReminders(expectedAccessVersion: 2, using: port); XCTFail("disabled access") } catch {}
    }
    func testAutomaticReconciliationOnlyReadsExistingScopedLinksAndDeduplicatesHistory() async throws {
        let store = try await store(); let (claim,id) = try await reminderFixture(store); let port = TestReminders(loseReceipt: true)
        do { try await store.sendTaskToReminders(actionID: id, expectedVersion: 1, calendarID: "authorized", using: port) } catch {}
        _ = try await store.createAction(claimID: claim.id, expectedClaimReviewVersion: 0, title: "尚未发送的明确任务", kind: .task)
        _ = try await store.setReminderAccess(calendarID: "other", title: "其他清单", enabled: true, expectedVersion: 0)
        try await store.reconcileReminders(expectedAccessVersion: 1, using: port)
        var link = try await store.reminderLinks()[0]; XCTAssertEqual(link.state, "unknown")
        _ = try await store.setReminderAccess(calendarID: "authorized", title: "专用清单", enabled: true, expectedVersion: 1)
        for _ in 0..<3 { try await store.reconcileReminders(expectedAccessVersion: 2, using: port) }
        link = try await store.reminderLinks()[0]; XCTAssertEqual(link.state, "linked"); XCTAssertNotNil(link.lastCheckedAt)
        let creates = await port.creates; XCTAssertEqual(creates, 1)
        let package = base.appendingPathComponent("deduplicated-observations"); try await store.exportPackage(to: package)
        let lines = try String(contentsOf: package.appendingPathComponent("reminder_observations.jsonl")).split(separator: "\n"); XCTAssertEqual(lines.count, 1)
    }
    func testSameCommandIsIdempotentButNewCommandKeepsDistinctEvent() async throws {
        let store = try await store(); let input = try fixture()
        let a = try await store.importFile(input, commandID: "one")
        let replay = try await store.importFile(input, commandID: "one")
        let b = try await store.importFile(input, commandID: "two")
        XCTAssertEqual(a, replay); XCTAssertNotEqual(a, b)
        let rows = try await store.sources()
        XCTAssertEqual(rows.count, 2); XCTAssertTrue(rows.allSatisfy { $0.state == "saved" && $0.jobState == "queued" })
        let integrity = try await store.integrityCheck(); XCTAssertTrue(integrity)
    }
    func testCommandContentChangeRejected() async throws {
        let store = try await store(); let input = try fixture()
        _ = try await store.importFile(input, commandID: "one")
        try Data("fixture:changed".utf8).write(to: input)
        do { _ = try await store.importFile(input, commandID: "one"); XCTFail("must reject changed command") } catch {}
        let rows = try await store.sources(); XCTAssertEqual(rows.count, 1)
    }
    func testOwnedOriginalSurvivesInputRemoval() async throws {
        let store = try await store(); let input = try fixture(); let original = try Data(contentsOf: input)
        let id = try await store.importFile(input)
        try FileManager.default.removeItem(at: input)
        let saved = try await store.playableURL(sourceID: id)
        XCTAssertEqual(try Data(contentsOf: saved), original)
    }
    func testCorruptionBlocksProcessingAndHidesTranscript() async throws {
        let store = try await store(); let id = try await store.importFile(fixture())
        try await store.processTranscriptions(using: Speech(text: "retained"))
        let url = try await store.playableURL(sourceID: id)
        try Data("broken".utf8).write(to: url)
        do { _ = try await store.playableURL(sourceID: id); XCTFail("must quarantine") } catch {}
        let row = try await store.sources().first!
        XCTAssertEqual(row.state, "quarantined"); XCTAssertEqual(row.jobState, "blocked"); XCTAssertNil(row.transcript)
    }
    func testEmptyTranscriptIsCompletedNotInventedSpeech() async throws {
        let store = try await store(); _ = try await store.importFile(fixture())
        try await store.processTranscriptions(using: Speech(text: ""))
        let row = try await store.sources().first!
        XCTAssertEqual(row.jobState, "completed"); XCTAssertEqual(row.transcript, "")
        try await store.processTranscriptions(using: Speech(text: "must not replace"))
        let again = try await store.sources().first!; XCTAssertEqual(again.transcript, "")
    }
    func testFailedTranscriptionRequiresExplicitRetry() async throws {
        let store = try await store(); let id = try await store.importFile(fixture())
        try await store.processTranscriptions(using: FailedSpeech())
        let failed = try await store.sources().first!; XCTAssertEqual(failed.jobState, "failed")
        try await store.retryTranscription(sourceID: id)
        try await store.processTranscriptions(using: Speech(text: "恢复的文字"))
        let row = try await store.sources().first!; XCTAssertEqual(row.transcript, "恢复的文字"); XCTAssertEqual(row.jobState, "completed")
    }
    func testInvalidMediaNeverQueuesJob() async throws {
        let store = try await store()
        do { _ = try await store.importFile(fixture("not a fixture")); XCTFail("must fail validation") } catch {}
        let row = try await store.sources().first!; XCTAssertEqual(row.state, "interrupted"); XCTAssertNil(row.jobState)
    }
    func testSecondStoreCannotOwnSameRoot() async throws {
        let first = try await store()
        do { _ = try VoiceOSStore(root: base.appendingPathComponent("store"), inspector: Inspector()); XCTFail("must reject another writer") } catch {}
        let integrity = try await first.integrityCheck(); XCTAssertTrue(integrity)
    }
    func testStructuredRestoreRetainsIdentityTextButDoesNotPretendMediaExists() async throws {
        let store = try await store(); let id = try await store.importFile(fixture())
        try await store.processTranscriptions(using: Speech(text: "原始逐字稿"))
        let package = base.appendingPathComponent("structured")
        try await store.exportPackage(to: package)
        let target = base.appendingPathComponent("restored")
        try await VoiceOSStore.restorePackage(from: package, to: target, inspector: Inspector())
        let restored = try VoiceOSStore(root: target, inspector: Inspector()); try await restored.recover()
        let row = try await restored.sources().first!
        XCTAssertEqual(row.id, id); XCTAssertEqual(row.state, "reference_only"); XCTAssertEqual(row.transcript, "原始逐字稿")
        do { _ = try await restored.playableURL(sourceID: id); XCTFail("missing media must not play") } catch {}
    }
    func testMediaRestorePreservesBytesAndPausesPendingWork() async throws {
        let store = try await store(); let input = try fixture(); let bytes = try Data(contentsOf: input)
        let id = try await store.importFile(input)
        let package = base.appendingPathComponent("full")
        try await store.exportPackage(to: package, includeMedia: true)
        let target = base.appendingPathComponent("restored")
        try await VoiceOSStore.restorePackage(from: package, to: target, inspector: Inspector())
        let restored = try VoiceOSStore(root: target, inspector: Inspector()); try await restored.recover()
        let row = try await restored.sources().first!
        XCTAssertEqual(row.id, id); XCTAssertEqual(row.state, "saved"); XCTAssertEqual(row.jobState, "blocked")
        let url = try await restored.playableURL(sourceID: id); XCTAssertEqual(try Data(contentsOf: url), bytes)
        try await restored.processTranscriptions(using: Speech(text: "must stay paused"))
        let unchanged = try await restored.sources().first!; XCTAssertNil(unchanged.transcript)
    }
    func testDamagedPackageRejectedBeforeDestinationExists() async throws {
        let store = try await store(); _ = try await store.importFile(fixture())
        let package = base.appendingPathComponent("full"); try await store.exportPackage(to: package, includeMedia: true)
        try Data("corrupted".utf8).write(to: package.appendingPathComponent("sources.jsonl"))
        let target = base.appendingPathComponent("restored")
        do { try await VoiceOSStore.restorePackage(from: package, to: target, inspector: Inspector()); XCTFail("must reject damage") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }
    func testRestoreRefusesExistingDestination() async throws {
        let store = try await store(); _ = try await store.importFile(fixture())
        let package = base.appendingPathComponent("full"); try await store.exportPackage(to: package, includeMedia: true)
        let target = base.appendingPathComponent("store")
        do { try await VoiceOSStore.restorePackage(from: package, to: target, inspector: Inspector()); XCTFail("must not overwrite") } catch {}
        let rows = try await store.sources(); XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows[0].state, "saved")
    }
    func testManifestTraversalRejected() async throws {
        let store = try await store(); _ = try await store.importFile(fixture())
        let package = base.appendingPathComponent("full"); try await store.exportPackage(to: package)
        let manifest = package.appendingPathComponent("manifest.json")
        var content = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: Any]
        var files = content["files"] as! [[String: Any]]; files[0]["path"] = "../input.wav"; content["files"] = files
        try JSONSerialization.data(withJSONObject: content).write(to: manifest)
        let target = base.appendingPathComponent("restored")
        do { try await VoiceOSStore.restorePackage(from: package, to: target, inspector: Inspector()); XCTFail("must reject traversal") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }
    func testPackageSymlinkRejected() async throws {
        let store = try await store(); _ = try await store.importFile(fixture())
        let package = base.appendingPathComponent("full"); try await store.exportPackage(to: package)
        let file = package.appendingPathComponent("sources.jsonl"); let outside = base.appendingPathComponent("outside.jsonl")
        try FileManager.default.moveItem(at: file, to: outside)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        do { try await VoiceOSStore.restorePackage(from: package, to: base.appendingPathComponent("restored"), inspector: Inspector()); XCTFail("must reject symlink") } catch {}
    }

    func testUnicodeAndEmbeddedNullRoundTrip() async throws {
        let store = try await store(); _ = try await store.importFile(fixture())
        let expected = "中文🙂\0之后仍保留"
        try await store.processTranscriptions(using: Speech(text: expected))
        let row = try await store.sources().first!; XCTAssertEqual(row.transcript, expected)
        let package = base.appendingPathComponent("structured"); try await store.exportPackage(to: package)
        let target = base.appendingPathComponent("restored")
        try await VoiceOSStore.restorePackage(from: package, to: target, inspector: Inspector())
        let restored = try VoiceOSStore(root: target, inspector: Inspector()); try await restored.recover()
        let restoredRow = try await restored.sources().first!; XCTAssertEqual(restoredRow.transcript, expected)
    }

    func testCorrectionPreservesOriginalAndRejectsStaleVersion() async throws {
        let store = try await store(); let id = try await store.importFile(fixture())
        try await store.processTranscriptions(using: Speech(text: "识别有误"))
        let original = try await store.sources().first!
        let version = try await store.correctTranscript(sourceID: id, expectedVersionID: original.transcriptVersionID!, text: "识别正确", commandID: "correction-one")
        let replay = try await store.correctTranscript(sourceID: id, expectedVersionID: original.transcriptVersionID!, text: "识别正确", commandID: "correction-one")
        XCTAssertEqual(version, replay)
        do { _ = try await store.correctTranscript(sourceID: id, expectedVersionID: original.transcriptVersionID!, text: "过期编辑"); XCTFail("must reject stale editor") } catch {}
        let current = try await store.sources().first!
        XCTAssertEqual(current.transcript, "识别正确"); XCTAssertEqual(current.transcriptVersionID, version)
        let history = try await store.transcriptHistory(sourceID: id)
        XCTAssertEqual(history.count, 2); XCTAssertEqual(history[1].text, "识别有误"); XCTAssertEqual(history[0].reason, "transcription_error")
        let oldTrusted = try await store.isCurrentTranscriptVersion(original.transcriptVersionID!); XCTAssertFalse(oldTrusted)
        let newTrusted = try await store.isCurrentTranscriptVersion(version); XCTAssertTrue(newTrusted)
        let package = base.appendingPathComponent("corrected-package"); try await store.exportPackage(to: package, includeMedia: true)
        let target = base.appendingPathComponent("restored")
        try await VoiceOSStore.restorePackage(from: package, to: target, inspector: Inspector())
        let restored = try VoiceOSStore(root: target, inspector: Inspector()); try await restored.recover()
        let restoredHistory = try await restored.transcriptHistory(sourceID: id)
        XCTAssertEqual(restoredHistory.map(\.id), history.map(\.id)); XCTAssertEqual(restoredHistory.map(\.text), history.map(\.text))
    }
    func testInvalidTranscriptOffsetsAndTimesRejected() throws {
        XCTAssertThrowsError(try SpeechText(text: "🙂中", spans: [TranscriptSpan(textStart: 0, textEnd: 3)]).validate(duration: 1))
        XCTAssertThrowsError(try SpeechText(text: "🙂中", spans: [TranscriptSpan(textStart: 0, textEnd: 2, startMS: 0, endMS: 2000)]).validate(duration: 1))
        XCTAssertNoThrow(try SpeechText(text: "🙂中", spans: [TranscriptSpan(textStart: 0, textEnd: 2, startMS: 0, endMS: 800)]).validate(duration: 1))
    }

    func testRestoreRejectsMissingRevisionEvenWhenPackageHashesMatch() async throws {
        let store = try await store(); let id = try await store.importFile(fixture())
        try await store.processTranscriptions(using: Speech(text: "原稿"))
        let original = try await store.sources().first!
        _ = try await store.correctTranscript(sourceID: id, expectedVersionID: original.transcriptVersionID!, text: "更正稿")
        let package = base.appendingPathComponent("broken-history")
        try await store.exportPackage(to: package)
        let revisionFile = package.appendingPathComponent("transcript_revisions.jsonl")
        try Data().write(to: revisionFile)
        let manifestFile = package.appendingPathComponent("manifest.json")
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestFile)) as! [String: Any]
        var counts = manifest["counts"] as! [String: Int]; counts["transcript_revisions"] = 0; manifest["counts"] = counts
        var files = manifest["files"] as! [[String: Any]]
        let index = files.firstIndex { $0["path"] as? String == "transcript_revisions.jsonl" }!
        let digest = try DurableFiles.hash(revisionFile)
        files[index]["bytes"] = digest.0; files[index]["sha256"] = digest.1; manifest["files"] = files
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestFile)
        let target = base.appendingPathComponent("must-not-restore")
        do {
            try await VoiceOSStore.restorePackage(from: package, to: target, inspector: Inspector())
            XCTFail("matching checksums must not conceal a missing correction receipt")
        } catch { XCTAssertTrue(error.localizedDescription.contains("版本链")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testLocalContextRetainsExternalIdentityAndRejectsStaleInput() async throws {
        let store = try await store(); let id = try await store.importFile(fixture())
        try await store.processTranscriptions(using: Speech(text: "外部材料中的观点🙂"))
        let context = try await store.prepareLocalTranscriptContext(sourceIDs: [id])
        XCTAssertEqual(context.sources[0].origin, "external")
        XCTAssertEqual(context.sources[0].speaker, "unknown")
        XCTAssertTrue(context.sources[0].localOnly)
        XCTAssertEqual(context.sources[0].text, "外部材料中的观点🙂")
        try await store.validateLocalTranscriptContext(context)
        _ = try await store.correctTranscript(sourceID: id, expectedVersionID: context.sources[0].transcriptVersionID, text: "更正的材料")
        do { try await store.validateLocalTranscriptContext(context); XCTFail("old async input must fail revalidation") } catch {}
        let current = try await store.prepareLocalTranscriptContext(sourceIDs: [id])
        try await store.validateLocalTranscriptContext(current)
        XCTAssertNotEqual(current.contentDigest, context.contentDigest)
    }
    func testLocalContextRejectsPartialSelectionAndBudgetOverflow() async throws {
        let store = try await store(); let id = try await store.importFile(fixture())
        do { _ = try await store.prepareLocalTranscriptContext(sourceIDs: [id]); XCTFail("untranscribed input must fail") } catch {}
        try await store.processTranscriptions(using: Speech(text: "🙂中"))
        let exact = try await store.prepareLocalTranscriptContext(sourceIDs: [id], scalarBudget: 2)
        XCTAssertEqual(exact.sources[0].text, "🙂中")
        for ids in [[id,id], [id,UUID().uuidString], []] {
            do { _ = try await store.prepareLocalTranscriptContext(sourceIDs: ids); XCTFail("selection must fail atomically") } catch {}
        }
        do { _ = try await store.prepareLocalTranscriptContext(sourceIDs: [id], scalarBudget: 1); XCTFail("do not silently truncate") } catch {}
    }
    func testLocalContextRejectsTamperedTextAndQuarantinedSource() async throws {
        let store = try await store(); let id = try await store.importFile(fixture())
        try await store.processTranscriptions(using: Speech(text: "原始材料"))
        let context = try await store.prepareLocalTranscriptContext(sourceIDs: [id])
        var raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(context)) as! [String: Any]
        var sources = raw["sources"] as! [[String: Any]]; sources[0]["text"] = "篡改材料"; raw["sources"] = sources
        let tampered = try JSONDecoder().decode(LocalTranscriptContext.self, from: JSONSerialization.data(withJSONObject: raw))
        do { try await store.validateLocalTranscriptContext(tampered); XCTFail("must reject altered snapshot") } catch {}
        let file = try await store.playableURL(sourceID: id)
        try Data("damaged".utf8).write(to: file)
        do { try await store.validateLocalTranscriptContext(context); XCTFail("quarantine must block old input") } catch {}
        let row = try await store.sources().first!; XCTAssertEqual(row.state, "quarantined")
    }

    func testPersistedContextReceiptAndCorrectionFreezeClaims() async throws {
        let store = try await store(); let id = try await store.importFile(fixture())
        try await store.processTranscriptions(using: Speech(text: "材料中的观点"))
        let context = try await store.prepareLocalTranscriptContext(sourceIDs: [id])
        let contextID = try await store.persistLocalContext(context, commandID: "context-one")
        let replay = try await store.persistLocalContext(context, commandID: "context-one"); XCTAssertEqual(replay, contextID)
        let attempt = try await store.reserveLocalModelAttempt(contextID: contextID, model: "fixture", promptVersion: "v1", schemaVersion: "v1")
        let source = context.sources[0]
        let proposals = [ClaimProposal(statement: "候选解释", ownership: .aiCandidate, references: [ClaimReference(sourceID: id, transcriptVersionID: source.transcriptVersionID, spanID: source.spans[0].id)])]
        let claims = try await store.commitLocalClaims(attemptID: attempt, proposals: proposals)
        let replayClaims = try await store.commitLocalClaims(attemptID: attempt, proposals: proposals); XCTAssertEqual(claims, replayClaims)
        let before = try await store.candidateClaims(); XCTAssertEqual(before.count, 1); XCTAssertEqual(before[0].ownership, "ai_candidate"); XCTAssertEqual(before[0].evidenceState, "unverified")
        _ = try await store.correctTranscript(sourceID: id, expectedVersionID: source.transcriptVersionID, text: "更正材料")
        let visible = try await store.candidateClaims(); XCTAssertTrue(visible.isEmpty)
        let historical = try await store.candidateClaims(includeFrozen: true); XCTAssertEqual(historical[0].validity, "frozen")
        do { _ = try await store.localContext(id: contextID); XCTFail("stale context must not reopen as current") } catch {}
        let receipt = try await store.persistLocalContext(context, commandID: "context-one"); XCTAssertEqual(receipt, contextID)
        let current = try await store.prepareLocalTranscriptContext(sourceIDs: [id])
        do { _ = try await store.persistLocalContext(current, commandID: "context-one"); XCTFail("receipt cannot change input") } catch {}
        let package = base.appendingPathComponent("frozen-package"); try await store.exportPackage(to: package)
        let target = base.appendingPathComponent("frozen-restored")
        try await VoiceOSStore.restorePackage(from: package, to: target, inspector: Inspector())
        let restored = try VoiceOSStore(root: target, inspector: Inspector()); try await restored.recover()
        let restoredClaims = try await restored.candidateClaims(includeFrozen: true)
        XCTAssertEqual(restoredClaims.map(\.id), historical.map(\.id)); XCTAssertEqual(restoredClaims[0].validity, "frozen")
    }
    func testLateModelResultAndForeignReferencesNeverCommit() async throws {
        let store = try await store(); let id = try await store.importFile(fixture())
        try await store.processTranscriptions(using: Speech(text: "旧材料"))
        let context = try await store.prepareLocalTranscriptContext(sourceIDs: [id])
        let contextID = try await store.persistLocalContext(context)
        let bad = try await store.reserveLocalModelAttempt(contextID: contextID, model: "fixture", promptVersion: "v1", schemaVersion: "v1")
        let input = context.sources[0]
        let valid = ClaimProposal(statement: "解释", ownership: .aiCandidate, references: [ClaimReference(sourceID: id, transcriptVersionID: input.transcriptVersionID, spanID: input.spans[0].id)])
        let invalid = ClaimProposal(statement: "无依据", ownership: .external, references: [ClaimReference(sourceID: id, transcriptVersionID: input.transcriptVersionID, spanID: UUID().uuidString)])
        do { _ = try await store.commitLocalClaims(attemptID: bad, proposals: [valid,invalid]); XCTFail("no partial output") } catch {}
        let empty = try await store.candidateClaims(includeFrozen: true); XCTAssertTrue(empty.isEmpty)
        let late = try await store.reserveLocalModelAttempt(contextID: contextID, model: "fixture", promptVersion: "v1", schemaVersion: "v1")
        _ = try await store.correctTranscript(sourceID: id, expectedVersionID: input.transcriptVersionID, text: "新材料")
        do { _ = try await store.commitLocalClaims(attemptID: late, proposals: [valid]); XCTFail("late callback must not revive input") } catch {}
        let stillEmpty = try await store.candidateClaims(includeFrozen: true); XCTAssertTrue(stillEmpty.isEmpty)
    }
    func testReservedAttemptBecomesUnknownAfterRestartAndRestore() async throws {
        let input = try fixture(); let target = base.appendingPathComponent("store"); let package = base.appendingPathComponent("reserved-package")
        var attempt = ""; var contextID = ""
        do {
            let first = try VoiceOSStore(root: target, inspector: Inspector()); try await first.recover()
            let id = try await first.importFile(input); try await first.processTranscriptions(using: Speech(text: "待处理"))
            let context = try await first.prepareLocalTranscriptContext(sourceIDs: [id]); contextID = try await first.persistLocalContext(context)
            attempt = try await first.reserveLocalModelAttempt(contextID: contextID, model: "fixture", promptVersion: "v1", schemaVersion: "v1")
            try await first.exportPackage(to: package)
        }
        let reopened = try VoiceOSStore(root: target, inspector: Inspector()); try await reopened.recover()
        do { _ = try await reopened.commitLocalClaims(attemptID: attempt, proposals: []); XCTFail("unknown must not replay") } catch {}
        _ = try await reopened.localContext(id: contextID)
        let restoreRoot = base.appendingPathComponent("reserved-restored")
        try await VoiceOSStore.restorePackage(from: package, to: restoreRoot, inspector: Inspector())
        let restored = try VoiceOSStore(root: restoreRoot, inspector: Inspector()); try await restored.recover()
        do { _ = try await restored.commitLocalClaims(attemptID: attempt, proposals: []); XCTFail("restore must not replay unknown attempt") } catch {}
        _ = try await restored.localContext(id: contextID)
    }
    func testCognitiveRestoreRejectsResultMismatchAndCorruptionFreezesRead() async throws {
        let store = try await store(); let id = try await store.importFile(fixture())
        try await store.processTranscriptions(using: Speech(text: "测试材料"))
        let context = try await store.prepareLocalTranscriptContext(sourceIDs: [id]); let input = context.sources[0]
        let contextID = try await store.persistLocalContext(context)
        let attempt = try await store.reserveLocalModelAttempt(contextID: contextID, model: "fixture", promptVersion: "v1", schemaVersion: "v1")
        _ = try await store.commitLocalClaims(attemptID: attempt, proposals: [ClaimProposal(statement: "候选解释", ownership: .aiCandidate, references: [ClaimReference(sourceID: id, transcriptVersionID: input.transcriptVersionID, spanID: input.spans[0].id)])])
        let package = base.appendingPathComponent("altered-candidate"); try await store.exportPackage(to: package)
        let file = package.appendingPathComponent("claims.jsonl")
        var claim = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        claim["statement"] = "改写的候选"
        var bytes = try JSONSerialization.data(withJSONObject: claim); bytes.append(0x0A); try bytes.write(to: file)
        let manifestFile = package.appendingPathComponent("manifest.json")
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestFile)) as! [String: Any]
        var files = manifest["files"] as! [[String: Any]]; let index = files.firstIndex { $0["path"] as? String == "claims.jsonl" }!
        let digest = try DurableFiles.hash(file); files[index]["sha256"] = digest.1; files[index]["bytes"] = digest.0; manifest["files"] = files
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestFile)
        let target = base.appendingPathComponent("rejected-candidate")
        do { try await VoiceOSStore.restorePackage(from: package, to: target, inspector: Inspector()); XCTFail("file checksums cannot override original result receipt") }
        catch { XCTAssertTrue(error.localizedDescription.contains("结果摘要")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        let media = try await store.playableURL(sourceID: id); try Data("broken".utf8).write(to: media)
        let current = try await store.candidateClaims(); XCTAssertTrue(current.isEmpty)
        let history = try await store.candidateClaims(includeFrozen: true); XCTAssertEqual(history[0].validity, "frozen")
    }
    func testCloudBoundaryRejectsLocalOnlyAndWrongDestinationBeforePortCall() async throws {
        let store = try await store(); let id = try await store.importFile(fixture()); try await store.processTranscriptions(using: Speech(text: "本地材料"))
        let context = try await store.prepareLocalTranscriptContext(sourceIDs: [id])
        do { _ = try await store.persistLocalContext(context, destination: .cloud); XCTFail("no cloud context for local-only input") } catch {}
        let contextID = try await store.persistLocalContext(context)
        let port = TestModelPort(destination: .cloud)
        do { _ = try await store.generateClaims(contextID: contextID, using: port); XCTFail("wrong destination must not reach port") } catch {}
        let calls = await port.calls; XCTAssertEqual(calls, 0)
        let attempts = try await store.modelAttempts(); XCTAssertTrue(attempts.isEmpty)
    }
    func testPolicyABAPreventsLateResultAndPreservesHistoryAcrossRestore() async throws {
        let store = try await store(); let id = try await store.importFile(fixture()); try await store.processTranscriptions(using: Speech(text: "授权文字"))
        let version = try await store.setSourceLocalOnly(sourceID: id, expectedVersion: 1, localOnly: false, commandID: "allow-text")
        let replay = try await store.setSourceLocalOnly(sourceID: id, expectedVersion: 1, localOnly: false, commandID: "allow-text"); XCTAssertEqual(version, replay)
        let context = try await store.prepareLocalTranscriptContext(sourceIDs: [id]); let contextID = try await store.persistLocalContext(context, destination: .cloud)
        let port = TestModelPort(destination: .cloud, suspended: true)
        let task = Task { try await store.generateClaims(contextID: contextID, using: port) }
        await port.waitStarted()
        _ = try await store.setSourceLocalOnly(sourceID: id, expectedVersion: 2, localOnly: true)
        _ = try await store.setSourceLocalOnly(sourceID: id, expectedVersion: 3, localOnly: false)
        await port.release()
        do { _ = try await task.value; XCTFail("allow-revoke-allow cannot revive old request") } catch {}
        let claims = try await store.candidateClaims(includeFrozen: true); XCTAssertTrue(claims.isEmpty)
        let attempts = try await store.modelAttempts(); XCTAssertEqual(attempts[0].state, "rejected"); XCTAssertEqual(attempts[0].usage?["output_tokens"], 5); XCTAssertEqual(attempts[0].billingState, "unknown")
        let package = base.appendingPathComponent("policy-history"); try await store.exportPackage(to: package)
        let target = base.appendingPathComponent("policy-restored"); try await VoiceOSStore.restorePackage(from: package, to: target, inspector: Inspector())
        let restored = try VoiceOSStore(root: target, inspector: Inspector()); try await restored.recover()
        let policy = try await restored.sourcePolicy(sourceID: id); XCTAssertEqual(policy.version, 4); XCTAssertFalse(policy.localOnly)
        do { _ = try await restored.localContext(id: contextID); XCTFail("old context must remain stale after migration") } catch {}
    }
    func testModelPortCompletedRejectedAndUnknownResponses() async throws {
        let store = try await store(); let id = try await store.importFile(fixture()); try await store.processTranscriptions(using: Speech(text: "端口输入"))
        let context = try await store.prepareLocalTranscriptContext(sourceIDs: [id]); let contextID = try await store.persistLocalContext(context)
        let accepted = try await store.generateClaims(contextID: contextID, using: TestModelPort()); XCTAssertEqual(accepted.count, 1)
        for status in [ModelResponse.Status.incomplete, .refused] {
            do { _ = try await store.generateClaims(contextID: contextID, using: TestModelPort(response: status)); XCTFail("only completed response can commit") } catch {}
        }
        let failed = TestModelPort(fail: true)
        do { _ = try await store.generateClaims(contextID: contextID, using: failed); XCTFail("unknown result must remain unknown") } catch {}
        let calls = await failed.calls; XCTAssertEqual(calls, 1)
        let attempts = try await store.modelAttempts()
        XCTAssertEqual(attempts.filter { $0.state == "completed" }.count, 1)
        XCTAssertEqual(attempts.filter { $0.state == "rejected" }.count, 2)
        XCTAssertEqual(attempts.filter { $0.state == "unknown" }.count, 1)
        XCTAssertTrue(attempts.filter { $0.state == "rejected" }.allSatisfy { $0.usage?["input_tokens"] == 10 })
        XCTAssertNil(attempts.first { $0.state == "unknown" }?.usage)
        let claims = try await store.candidateClaims(); XCTAssertEqual(claims.count, 1)
    }
    func testRestoreRejectsCloudPermissionWithoutItsRevisionHistory() async throws {
        let store = try await store(); let id = try await store.importFile(fixture())
        _ = try await store.setSourceLocalOnly(sourceID: id, expectedVersion: 1, localOnly: false)
        let package = base.appendingPathComponent("missing-policy-history"); try await store.exportPackage(to: package)
        let file = package.appendingPathComponent("source_policy_revisions.jsonl"); try Data().write(to: file)
        let manifestFile = package.appendingPathComponent("manifest.json")
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestFile)) as! [String: Any]
        var counts = manifest["counts"] as! [String: Int]; counts["source_policy_revisions"] = 0; manifest["counts"] = counts
        var files = manifest["files"] as! [[String: Any]]; let index = files.firstIndex { $0["path"] as? String == "source_policy_revisions.jsonl" }!
        let digest = try DurableFiles.hash(file); files[index]["sha256"] = digest.1; files[index]["bytes"] = digest.0; manifest["files"] = files
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestFile)
        let target = base.appendingPathComponent("policy-history-rejected")
        do { try await VoiceOSStore.restorePackage(from: package, to: target, inspector: Inspector()); XCTFail("permissions require a consistent history") }
        catch { XCTAssertTrue(error.localizedDescription.contains("授权历史")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

}
