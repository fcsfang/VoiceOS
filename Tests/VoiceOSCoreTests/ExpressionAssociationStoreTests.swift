import XCTest
@testable import VoiceOSCore

private struct AssociationStoreInspector: MediaInspector {
    func inspect(_ url: URL) async throws -> MediaInfo { throw VoiceOSError("text") }
}
private struct AssociationStoreRetrieval: LocalRetrievalPort {
    func rank(query: String, documents: [RetrievalDocument], semantic: Bool) async throws -> [RetrievalMatch] {
        documents.map { RetrievalMatch(documentID: $0.id, score: 1, method: "exact") }
    }
}
private actor AssociationStorePort: ExpressionAssociationPort {
    let configuration = ModelConfiguration(provider: "in_memory_association", model: "synthetic", promptVersion: "p1", schemaVersion: "s1", destination: .local)
    var calls = 0
    let empty: Bool
    let fail: Bool
    let callback: (@Sendable (ExpressionAssociationRequest) async throws -> Void)?
    init(empty: Bool = false, fail: Bool = false, callback: (@Sendable (ExpressionAssociationRequest) async throws -> Void)? = nil) {
        self.empty = empty; self.fail = fail; self.callback = callback
    }
    func associate(_ request: ExpressionAssociationRequest) async throws -> ExpressionAssociationResponse {
        calls += 1; try await callback?(request)
        if fail { throw ModelPortFailure.rejected("synthetic failure", inputTokens: 13, outputTokens: 7) }
        let source = request.snapshot.current.sources[0], hit = request.snapshot.candidates[0]
        let evidence = OutcomeSourceEvidence(reference: .init(sourceID: source.sourceID, transcriptVersionID: source.transcriptVersionID, spanID: source.spans[0].id), quote: source.text)
        return ExpressionAssociationResponse(proposals: empty ? [] : [.init(candidateID: hit.id, current: evidence, historicalQuote: hit.document.text, relation: .sameQuestion, reason: "合成关联：两次原话讨论同一个限制条件。")], inputTokens: 17, outputTokens: 23)
    }
}
final class ExpressionAssociationStoreTests: XCTestCase {
    var base: URL!
    override func setUpWithError() throws { base = FileManager.default.temporaryDirectory.appendingPathComponent("association-store-" + UUID().uuidString) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: base) }
    func store(_ name: String = "root") async throws -> VoiceOSStore {
        let s = try VoiceOSStore(root: base.appendingPathComponent(name), inspector: AssociationStoreInspector()); try await s.recover(); return s
    }
    func fixture(_ s: VoiceOSStore) async throws -> ExpressionAssociationSnapshot {
        _ = try await s.recordUserExpression("旧表达：什么条件可以限制这个猜想？")
        _ = try await s.recordUserExpression("旧表达：需要寻找反例。")
        let current = try await s.recordUserExpression("新表达：我还在研究猜想的限制条件。")
        let hits = try await s.retrieve("表达", using: AssociationStoreRetrieval()).hits.filter { $0.document.sourceID != current }
        return try await s.prepareExpressionAssociation(currentSourceID: current, candidates: hits)
    }
    func testConcurrentDuplicateAndTerminalReplaySendOnceWithoutClaimsOrActions() async throws {
        let s = try await store(), snapshot = try await fixture(s), second = AssociationStorePort()
        let first = AssociationStorePort { request in
            do { _ = try await s.performExpressionAssociation(request.snapshot, using: second); XCTFail("duplicate in-flight") } catch {}
        }
        let record = try await s.performExpressionAssociation(snapshot, using: first)
        XCTAssertEqual(record.state, "completed"); XCTAssertEqual(record.proposals.count, 1); XCTAssertEqual(record.usage?["input_tokens"], 17)
        let replay = try await s.performExpressionAssociation(snapshot, using: second)
        XCTAssertEqual(record.id, replay.id)
        let firstCalls = await first.calls, secondCalls = await second.calls
        XCTAssertEqual(firstCalls, 1); XCTAssertEqual(secondCalls, 0)
        let claims = try await s.candidateClaims(), actions = try await s.actions()
        XCTAssertTrue(claims.isEmpty); XCTAssertTrue(actions.isEmpty)
    }
    func testUnknownFailureRetainsUsageAndDoesNotResend() async throws {
        let s = try await store(), snapshot = try await fixture(s), port = AssociationStorePort(fail: true)
        do { _ = try await s.performExpressionAssociation(snapshot, using: port); XCTFail("failure") } catch {}
        let replay = try await s.performExpressionAssociation(snapshot, using: port)
        XCTAssertEqual(replay.state, "unknown"); XCTAssertEqual(replay.usage?["input_tokens"], 13); XCTAssertTrue(replay.proposals.isEmpty)
        let calls = await port.calls; XCTAssertEqual(calls, 1)
    }
    func testPendingRestartAndPackageRestoreNeverResend() async throws {
        var s: VoiceOSStore? = try await store()
        let snapshot = try await fixture(s!), port = AssociationStorePort()
        let id = try await s!.reserveExpressionAssociation(snapshot, configuration: port.configuration)
        let package = base.appendingPathComponent("pending-package"); try await s!.exportPackage(to: package)
        s = nil
        let reopened = try await store(), records = try await reopened.expressionAssociationAttempts()
        XCTAssertEqual(records.first?.id, id); XCTAssertEqual(records.first?.state, "unknown")
        try await VoiceOSStore.restorePackage(from: package, to: base.appendingPathComponent("restored"), inspector: AssociationStoreInspector())
        let restored = try await store("restored"), frozen = try await restored.expressionAssociationAttempts()
        XCTAssertEqual(frozen.first?.state, "unknown"); XCTAssertEqual(frozen.first?.validity, "frozen")
        _ = try await restored.performExpressionAssociation(snapshot, using: port)
        let calls = await port.calls; XCTAssertEqual(calls, 0)
    }
    func testLateCandidateCorrectionOrPauseRejectsAndKeepsUsage() async throws {
        for pause in [false, true] {
            let s = try await store(pause ? "paused" : "corrected"), snapshot = try await fixture(s)
            let port = AssociationStorePort { request in
                if pause { try await s.setCognitiveFeedbackMode(.paused, expectedVersion: 0) }
                else {
                    let d = request.snapshot.candidates[1].document
                    _ = try await s.correctTranscript(sourceID: d.sourceID, expectedVersionID: d.transcriptVersionID, text: "更正：原来表达有误。")
                }
            }
            do { _ = try await s.performExpressionAssociation(snapshot, using: port); XCTFail("stale result") } catch {}
            let records = try await s.expressionAssociationAttempts()
            XCTAssertEqual(records.first?.state, "unknown"); XCTAssertEqual(records.first?.validity, "frozen")
            XCTAssertEqual(records.first?.usage?["output_tokens"], 23); XCTAssertTrue(records.first!.proposals.isEmpty)
        }
    }
    func testCompletedAndEmptyResultsRoundTripFrozen() async throws {
        for empty in [false, true] {
            let name = empty ? "empty" : "complete", s = try await store(name), snapshot = try await fixture(s)
            _ = try await s.performExpressionAssociation(snapshot, using: AssociationStorePort(empty: empty))
            let package = base.appendingPathComponent(name + "-package"), destination = base.appendingPathComponent(name + "-restored")
            try await s.exportPackage(to: package); try await VoiceOSStore.restorePackage(from: package, to: destination, inspector: AssociationStoreInspector())
            let restored = try await store(name + "-restored"), records = try await restored.expressionAssociationAttempts()
            XCTAssertEqual(records.first?.state, "completed"); XCTAssertEqual(records.first?.validity, "frozen")
            XCTAssertEqual(records.first?.proposals.count, empty ? 0 : 1); XCTAssertEqual(records.first?.usage?["input_tokens"], 17)
        }
    }
    func testEditedResultWithRehashedPackageIsRejectedAtomically() async throws {
        let s = try await store(), snapshot = try await fixture(s)
        _ = try await s.performExpressionAssociation(snapshot, using: AssociationStorePort())
        let package = base.appendingPathComponent("tampered"); try await s.exportPackage(to: package)
        let file = package.appendingPathComponent("expression_association_attempts.jsonl")
        var row = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]); row["result_json"] = "[]"
        try JSONSerialization.data(withJSONObject: row).write(to: file)
        let manifest = package.appendingPathComponent("manifest.json")
        var data = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any]), files = data["files"] as! [[String: Any]]
        let index = try XCTUnwrap(files.firstIndex { $0["path"] as? String == file.lastPathComponent }), digest = try DurableFiles.hash(file)
        files[index]["bytes"] = digest.0; files[index]["sha256"] = digest.1; data["files"] = files
        try JSONSerialization.data(withJSONObject: data).write(to: manifest)
        let target = base.appendingPathComponent("rejected")
        do { try await VoiceOSStore.restorePackage(from: package, to: target, inspector: AssociationStoreInspector()); XCTFail("edited result") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }
    func testSchema20UpgradeAndLegacy19PackagePreserveEnglishAndSources() async throws {
        let s = try await store(), snapshot = try await fixture(s)
        let sourcesBefore = try await s.sources()
        for source in sourcesBefore { _ = try await s.setSourceLocalOnly(sourceID: source.id, expectedVersion: source.policyVersion, localOnly: false) }
        let english = try await s.prepareEnglishPractice(currentSourceID: snapshot.current.sources[0].sourceID, priorSourceIDs: [snapshot.candidates[0].document.sourceID], destination: .cloud)
        let englishID = try await s.reserveEnglishFeedback(english, configuration: .init(provider: "synthetic", model: "synthetic", promptVersion: "p1", schemaVersion: "s1", destination: .cloud))
        try await s.completeEnglishFeedback(attemptID: englishID, response: .init(suggestions: [], comparisons: []))
        let package = base.appendingPathComponent("legacy19"); try await s.exportPackage(to: package)
        let manifest = package.appendingPathComponent("manifest.json")
        var data = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        XCTAssertEqual(data["version"] as? Int, 20); XCTAssertEqual(data["databaseSchema"] as? Int, 21)
        var counts = data["counts"] as! [String: Any], files = data["files"] as! [[String: Any]]
        counts.removeValue(forKey: "expression_association_attempts")
        files.removeAll { $0["path"] as? String == "expression_association_attempts.jsonl" }
        data["counts"] = counts; data["files"] = files; data["version"] = 19; data["databaseSchema"] = 20
        try FileManager.default.removeItem(at: package.appendingPathComponent("expression_association_attempts.jsonl"))
        try JSONSerialization.data(withJSONObject: data).write(to: manifest)
        try await VoiceOSStore.restorePackage(from: package, to: base.appendingPathComponent("legacy-restored"), inspector: AssociationStoreInspector())
        let restored = try await store("legacy-restored"), sources = try await restored.sources(), attempts = try await restored.expressionAssociationAttempts()
        XCTAssertEqual(sources.count, 3); XCTAssertTrue(attempts.isEmpty)
        let englishHistory = try await restored.englishFeedbackAttempts(); XCTAssertEqual(englishHistory.first?.id, englishID); XCTAssertEqual(englishHistory.first?.state, "completed")
        let dbURL = base.appendingPathComponent("upgrade.sqlite")
        do {
            let db = try Database(dbURL)
            try db.execute("DROP TABLE expression_association_attempts"); try db.execute("PRAGMA user_version=20")
        }
        let upgraded = try Database(dbURL)
        XCTAssertEqual(try upgraded.query("PRAGMA user_version").first?["user_version"], "21")
        XCTAssertTrue(try upgraded.query("SELECT * FROM expression_association_attempts").isEmpty)
        XCTAssertTrue(try upgraded.query("PRAGMA foreign_key_check").isEmpty)
        XCTAssertFalse(snapshot.candidates.isEmpty)
    }
    func testPauseResumeCannotResendSameExpressionUnderNewPreview() async throws {
        let s = try await store(), snapshot = try await fixture(s), port = AssociationStorePort(fail: true)
        do { _ = try await s.performExpressionAssociation(snapshot, using: port); XCTFail("transport failure") } catch {}
        try await s.setCognitiveFeedbackMode(.paused, expectedVersion: 0)
        try await s.setCognitiveFeedbackMode(.normal, expectedVersion: 1)
        let fresh = try await s.prepareExpressionAssociation(currentSourceID: snapshot.current.sources[0].sourceID, candidates: snapshot.candidates)
        XCTAssertNotEqual(fresh.contentDigest, snapshot.contentDigest)
        let record = try await s.performExpressionAssociation(fresh, using: port)
        XCTAssertEqual(record.state, "unknown"); XCTAssertEqual(record.validity, "frozen")
        let calls = await port.calls; XCTAssertEqual(calls, 1)
    }
    func testCancellationKeepsUsageButNeverCommitsProposals() async throws {
        let s = try await store(), snapshot = try await fixture(s)
        let port = AssociationStorePort { _ in withUnsafeCurrentTask { $0?.cancel() } }
        let work = Task { try await s.performExpressionAssociation(snapshot, using: port) }
        do { _ = try await work.value; XCTFail("cancelled response") } catch {}
        let records = try await s.expressionAssociationAttempts()
        XCTAssertEqual(records.first?.state, "unknown"); XCTAssertEqual(records.first?.usage?["input_tokens"], 17)
        XCTAssertTrue(records.first!.proposals.isEmpty)
    }
}
