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
    let configuration: ModelConfiguration
    var calls = 0
    let empty: Bool
    let fail: Bool
    let all: Bool
    let callback: (@Sendable (ExpressionAssociationRequest) async throws -> Void)?
    init(empty: Bool = false, fail: Bool = false, all: Bool = false, model: String = "synthetic", destination: ModelDestination = .local, callback: (@Sendable (ExpressionAssociationRequest) async throws -> Void)? = nil) {
        self.empty = empty; self.fail = fail; self.all = all; self.callback = callback
        configuration = .init(provider: "in_memory_association", model: model, promptVersion: "p1", schemaVersion: "s1", destination: destination)
    }
    func associate(_ request: ExpressionAssociationRequest) async throws -> ExpressionAssociationResponse {
        calls += 1; try await callback?(request)
        if fail { throw ModelPortFailure.rejected("synthetic failure", inputTokens: 13, outputTokens: 7) }
        let source = request.snapshot.current.sources[0]
        let evidence = OutcomeSourceEvidence(reference: .init(sourceID: source.sourceID, transcriptVersionID: source.transcriptVersionID, spanID: source.spans[0].id), quote: source.text)
        return ExpressionAssociationResponse(proposals: empty ? [] : request.snapshot.candidates.prefix(all ? 2 : 1).map { hit in .init(candidateID: hit.id, current: evidence, historicalQuote: hit.document.text, relation: .sameQuestion, reason: "合成关联：两次原话讨论同一个限制条件。") }, inputTokens: 17, outputTokens: 23)
    }
}
private actor AssociationDriverRetrieval: LocalRetrievalPort {
    var queries: [String] = []
    var seenSources: Set<String> = []
    let empty: Bool
    let callback: (@Sendable () async throws -> Void)?
    init(empty: Bool = false, callback: (@Sendable () async throws -> Void)? = nil) { self.empty = empty; self.callback = callback }
    func rank(query: String, documents: [RetrievalDocument], semantic: Bool) async throws -> [RetrievalMatch] {
        queries.append(query); seenSources.formUnion(documents.map(\.sourceID)); try await callback?()
        return empty ? [] : documents.map { .init(documentID: $0.id, score: 1, method: "exact") }
    }
}
final class ExpressionAssociationStoreTests: XCTestCase {
    func testModelUpgradeReusesCompletedAndUnknownJudgmentWithoutRetrievalOrDispatch() async throws {
        for fail in [false, true] {
            let s = try await store(fail ? "unknown-upgrade" : "completed-upgrade"), snapshot = try await fixture(s)
            let old = AssociationStorePort(fail: fail), upgraded = AssociationStorePort(model: "upgraded"), retrieval = AssociationDriverRetrieval()
            do { _ = try await s.performExpressionAssociation(snapshot, using: old) } catch { XCTAssertTrue(fail) }
            let result = try await s.processExpressionAssociation(sourceID: snapshot.current.sources[0].sourceID, retrieval: retrieval, model: upgraded)
            XCTAssertEqual(result.state, fail ? .unknown : .completed)
            let direct = try await s.performExpressionAssociation(snapshot, using: upgraded)
            XCTAssertEqual(direct.id, result.attempt?.id)
            let calls = await upgraded.calls, queries = await retrieval.queries
            XCTAssertEqual(calls, 0); XCTAssertTrue(queries.isEmpty)
            let attempts = try await s.expressionAssociationAttempts(); XCTAssertEqual(attempts.count, 1)
        }
    }
    func testConcurrentUpgradeCannotDispatchSecondJudgmentWhileFirstIsInFlight() async throws {
        let s = try await store(), snapshot = try await fixture(s), upgraded = AssociationStorePort(model: "upgraded")
        let old = AssociationStorePort(callback: { request in
            do { _ = try await s.performExpressionAssociation(request.snapshot, using: upgraded); XCTFail("in-flight duplicate") } catch {}
        })
        _ = try await s.performExpressionAssociation(snapshot, using: old)
        let calls = await upgraded.calls; XCTAssertEqual(calls, 0)
        let attempts = try await s.expressionAssociationAttempts(); XCTAssertEqual(attempts.count, 1)
    }
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
    func testAutomaticDriverNoModelPrivatePausedAndBudgetNeverDispatch() async throws {
        let s = try await store(), snapshot = try await fixture(s), id = snapshot.current.sources[0].sourceID, retrieval = AssociationDriverRetrieval(), port = AssociationStorePort(destination: .cloud)
        let missing = try await s.processExpressionAssociation(sourceID: id, retrieval: retrieval, model: nil)
        XCTAssertEqual(missing.state, .modelUnavailable)
        let privateSource = try await s.processExpressionAssociation(sourceID: id, retrieval: retrieval, model: port)
        XCTAssertEqual(privateSource.state, .localOnly)
        try await s.setCognitiveFeedbackMode(.paused, expectedVersion: 0)
        let paused = try await s.processExpressionAssociation(sourceID: id, retrieval: retrieval, model: port)
        XCTAssertEqual(paused.state, .paused)
        try await s.setCognitiveFeedbackMode(.normal, expectedVersion: 1)
        _ = try await s.correctTranscript(sourceID: id, expectedVersionID: snapshot.current.sources[0].transcriptVersionID, text: String(repeating: "字", count: 8001))
        let budget = try await s.processExpressionAssociation(sourceID: id, retrieval: retrieval, model: AssociationStorePort())
        XCTAssertEqual(budget.state, .budgetExceeded)
        let calls = await port.calls, queries = await retrieval.queries
        XCTAssertEqual(calls, 0); XCTAssertTrue(queries.isEmpty)
        let history = try await s.expressionAssociationAttempts(); XCTAssertTrue(history.isEmpty)
    }
    func testAutomaticDriverFullExpressionRecallAndReplayOnce() async throws {
        let s = try await store(), snapshot = try await fixture(s), id = snapshot.current.sources[0].sourceID
        let text = String(repeating: "完整个人表达，", count: 100)
        _ = try await s.correctTranscript(sourceID: id, expectedVersionID: snapshot.current.sources[0].transcriptVersionID, text: text)
        let retrieval = AssociationDriverRetrieval(), port = AssociationStorePort()
        let result = try await s.processExpressionAssociation(sourceID: id, retrieval: retrieval, model: port)
        XCTAssertEqual(result.state, .completed); XCTAssertEqual(result.attempt?.snapshot.current.sources[0].text, text)
        let queries = await retrieval.queries; XCTAssertEqual(queries.joined(), text); XCTAssertEqual(queries.count, 2)
        _ = try await s.processExpressionAssociation(sourceID: id, retrieval: retrieval, model: port)
        let calls = await port.calls, replayQueries = await retrieval.queries
        XCTAssertEqual(calls, 1); XCTAssertEqual(replayQueries.count, 2)
    }
    func testAutomaticDriverFiltersPrivateHistoryBeforeRanking() async throws {
        let s = try await store(), snapshot = try await fixture(s), current = snapshot.current.sources[0].sourceID, authorized = snapshot.candidates[0].document.sourceID
        for id in [current, authorized] { _ = try await s.setSourceLocalOnly(sourceID: id, expectedVersion: 1, localOnly: false) }
        let retrieval = AssociationDriverRetrieval(), port = AssociationStorePort(destination: .cloud)
        let result = try await s.processExpressionAssociation(sourceID: current, retrieval: retrieval, model: port)
        XCTAssertEqual(result.state, .completed); XCTAssertEqual(result.attempt?.snapshot.candidates.count, 1)
        let seen = await retrieval.seenSources; XCTAssertEqual(seen, [authorized])
    }
    func testAutomaticDriverLateRevocationBeforeModelNeverDispatches() async throws {
        let s = try await store(), snapshot = try await fixture(s), current = snapshot.current.sources[0].sourceID
        _ = try await s.setSourceLocalOnly(sourceID: current, expectedVersion: 1, localOnly: false)
        _ = try await s.setSourceLocalOnly(sourceID: snapshot.candidates[0].document.sourceID, expectedVersion: 1, localOnly: false)
        let retrieval = AssociationDriverRetrieval {
            _ = try await s.setSourceLocalOnly(sourceID: current, expectedVersion: 2, localOnly: true)
        }, port = AssociationStorePort(destination: .cloud)
        do { _ = try await s.processExpressionAssociation(sourceID: current, retrieval: retrieval, model: port); XCTFail("revoked") } catch {}
        let calls = await port.calls; XCTAssertEqual(calls, 0)
        let history = try await s.expressionAssociationAttempts(); XCTAssertTrue(history.isEmpty)
    }
    func testAutomaticDriverNoCandidatesAndUnknownAreDistinct() async throws {
        let s = try await store(), snapshot = try await fixture(s), current = snapshot.current.sources[0].sourceID, port = AssociationStorePort(fail: true)
        let none = try await s.processExpressionAssociation(sourceID: current, retrieval: AssociationDriverRetrieval(empty: true), model: port)
        XCTAssertEqual(none.state, .noCandidates)
        let retrieval = AssociationDriverRetrieval()
        let unknown = try await s.processExpressionAssociation(sourceID: current, retrieval: retrieval, model: port)
        XCTAssertEqual(unknown.state, .unknown); XCTAssertEqual(unknown.attempt?.usage?["input_tokens"], 13)
        _ = try await s.processExpressionAssociation(sourceID: current, retrieval: retrieval, model: port)
        let calls = await port.calls, queries = await retrieval.queries
        XCTAssertEqual(calls, 1); XCTAssertEqual(queries.count, 1)
    }
    func testFeedbackIgnoreSurvivesReopenAndMigrationWithoutCalls() async throws {
        var s: VoiceOSStore? = try await store()
        let snapshot = try await fixture(s!), port = AssociationStorePort()
        let record = try await s!.performExpressionAssociation(snapshot, using: port)
        let items = try await s!.expressionAssociationFeedback(currentSourceID: record.currentSourceID)
        XCTAssertEqual(items.count, 1); XCTAssertEqual(items[0].proposal.reason, record.proposals[0].reason)
        let p = record.proposals[0]
        try await s!.ignoreExpressionAssociation(attemptID: record.id, candidateID: p.candidateID, relation: p.relation, commandID: "ignore-one")
        try await s!.ignoreExpressionAssociation(attemptID: record.id, candidateID: p.candidateID, relation: p.relation, commandID: "ignore-one")
        do { try await s!.ignoreExpressionAssociation(attemptID: record.id, candidateID: p.candidateID, relation: .qualification, commandID: "ignore-one"); XCTFail("command collision") } catch {}
        let fresh = try await s!.prepareExpressionAssociation(currentSourceID: record.currentSourceID, candidates: snapshot.candidates)
        _ = try await s!.performExpressionAssociation(fresh, using: AssociationStorePort(model: "synthetic-v2"))
        let duplicates = try await s!.expressionAssociationFeedback(); XCTAssertTrue(duplicates.isEmpty)
        let package = base.appendingPathComponent("ignored-package")
        try await s!.exportPackage(to: package)
        s = nil
        let reopened = try await store(), hidden = try await reopened.expressionAssociationFeedback()
        XCTAssertTrue(hidden.isEmpty)
        try await VoiceOSStore.restorePackage(from: package, to: base.appendingPathComponent("ignored-restored"), inspector: AssociationStoreInspector())
        let restored = try await store("ignored-restored"), frozen = try await restored.expressionAssociationFeedback()
        XCTAssertTrue(frozen.isEmpty)
        let attempts = try await restored.expressionAssociationAttempts(); XCTAssertEqual(attempts.first?.validity, "frozen")
        let calls = await port.calls; XCTAssertEqual(calls, 1)
    }
    func testCompletedFeedbackSurvivesPreferenceChangesButFreezesOnCorrection() async throws {
        let s = try await store(), snapshot = try await fixture(s)
        let record = try await s.performExpressionAssociation(snapshot, using: AssociationStorePort(all: true))
        try await s.setCognitiveFeedbackMode(.paused, expectedVersion: 0)
        let paused = try await s.expressionAssociationFeedback(); XCTAssertTrue(paused.isEmpty)
        let history = try await s.expressionAssociationAttempts(); XCTAssertEqual(history.first?.validity, "current")
        try await s.setCognitiveFeedbackMode(.reduced, expectedVersion: 1)
        let reduced = try await s.expressionAssociationFeedback(); XCTAssertEqual(reduced.count, 1)
        try await s.setCognitiveFeedbackMode(.normal, expectedVersion: 2)
        let normal = try await s.expressionAssociationFeedback(); XCTAssertEqual(normal.count, 2)
        let source = snapshot.current.sources[0]
        _ = try await s.correctTranscript(sourceID: source.sourceID, expectedVersionID: source.transcriptVersionID, text: "更正的个人表达。")
        let current = try await s.expressionAssociationFeedback(); XCTAssertTrue(current.isEmpty)
        do { try await s.ignoreExpressionAssociation(attemptID: record.id, candidateID: record.proposals[0].candidateID, relation: .sameQuestion); XCTFail("frozen receipt") } catch {}
    }
    func testUnknownAndEmptyHaveNoFeedback() async throws {
        for empty in [true, false] {
            let s = try await store(empty ? "empty-feedback" : "unknown-feedback"), snapshot = try await fixture(s)
            do { _ = try await s.performExpressionAssociation(snapshot, using: AssociationStorePort(empty: empty, fail: !empty)) } catch { XCTAssertFalse(empty) }
            let items = try await s.expressionAssociationFeedback(); XCTAssertTrue(items.isEmpty)
        }
    }
    func testSchema21UpgradeAndIgnoreTamperingRejectsRestore() async throws {
        let s = try await store(), snapshot = try await fixture(s)
        let record = try await s.performExpressionAssociation(snapshot, using: AssociationStorePort())
        try await s.ignoreExpressionAssociation(attemptID: record.id, candidateID: record.proposals[0].candidateID, relation: .sameQuestion)
        let package = base.appendingPathComponent("ignored-tamper")
        try await s.exportPackage(to: package)
        let file = package.appendingPathComponent("expression_association_ignores.jsonl")
        var row = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        row["relation"] = "qualification"
        try JSONSerialization.data(withJSONObject: row).write(to: file)
        let manifest = package.appendingPathComponent("manifest.json")
        var data = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any]), files = data["files"] as! [[String: Any]]
        let index = try XCTUnwrap(files.firstIndex { $0["path"] as? String == file.lastPathComponent }), digest = try DurableFiles.hash(file)
        files[index]["bytes"] = digest.0; files[index]["sha256"] = digest.1; data["files"] = files
        try JSONSerialization.data(withJSONObject: data).write(to: manifest)
        let target = base.appendingPathComponent("ignored-tamper-rejected")
        do { try await VoiceOSStore.restorePackage(from: package, to: target, inspector: AssociationStoreInspector()); XCTFail("ignore tampering") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        let dbURL = base.appendingPathComponent("schema21.sqlite")
        do { let db = try Database(dbURL); try db.execute("DROP TABLE expression_association_ignores"); try db.execute("DROP TABLE question_revisions"); try db.execute("DROP TABLE questions"); try db.execute("ALTER TABLE claims DROP COLUMN content_kind"); try db.execute("PRAGMA user_version=21") }
        let upgraded = try Database(dbURL)
        XCTAssertEqual(try upgraded.query("PRAGMA user_version").first?["user_version"], "29")
        XCTAssertTrue(try upgraded.query("SELECT * FROM expression_association_ignores").isEmpty)
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
            XCTAssertEqual(data["version"] as? Int, 24); XCTAssertEqual(data["databaseSchema"] as? Int, 25)
        var counts = data["counts"] as! [String: Any], files = data["files"] as! [[String: Any]]
        counts.removeValue(forKey: "questions"); counts.removeValue(forKey: "question_revisions");
        counts.removeValue(forKey: "expression_association_attempts"); counts.removeValue(forKey: "expression_association_ignores")
        files.removeAll { ["expression_association_attempts.jsonl", "expression_association_ignores.jsonl", "questions.jsonl", "question_revisions.jsonl"].contains($0["path"] as? String ?? "") }
        try FileManager.default.removeItem(at: package.appendingPathComponent("questions.jsonl"))
        try FileManager.default.removeItem(at: package.appendingPathComponent("question_revisions.jsonl"))
        data["counts"] = counts; data["files"] = files; data["version"] = 19; data["databaseSchema"] = 20
        try FileManager.default.removeItem(at: package.appendingPathComponent("expression_association_attempts.jsonl"))
        try FileManager.default.removeItem(at: package.appendingPathComponent("expression_association_ignores.jsonl"))
        try JSONSerialization.data(withJSONObject: data).write(to: manifest)
        try await VoiceOSStore.restorePackage(from: package, to: base.appendingPathComponent("legacy-restored"), inspector: AssociationStoreInspector())
        let restored = try await store("legacy-restored"), sources = try await restored.sources(), attempts = try await restored.expressionAssociationAttempts()
        XCTAssertEqual(sources.count, 3); XCTAssertTrue(attempts.isEmpty)
        let englishHistory = try await restored.englishFeedbackAttempts(); XCTAssertEqual(englishHistory.first?.id, englishID); XCTAssertEqual(englishHistory.first?.state, "completed")
        let dbURL = base.appendingPathComponent("upgrade.sqlite")
        do {
            let db = try Database(dbURL)
            try db.execute("DROP TABLE expression_association_ignores"); try db.execute("DROP TABLE expression_association_attempts"); try db.execute("DROP TABLE question_revisions"); try db.execute("DROP TABLE questions"); try db.execute("ALTER TABLE claims DROP COLUMN content_kind"); try db.execute("PRAGMA user_version=20")
        }
        let upgraded = try Database(dbURL)
            XCTAssertEqual(try upgraded.query("PRAGMA user_version").first?["user_version"], "29")
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
