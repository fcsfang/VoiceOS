import XCTest
import Foundation
@testable import VoiceOSCore
import VoiceOSPlatform

final class TopicCurationChecks: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("voiceos-topic-curation-" + UUID().uuidString)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }
    private func openStore() async throws -> VoiceOSStore {
        let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
        try await store.recover()
        return store
    }

    func testPromoteTurnsAITopicIntoManualTopic() async throws {
        let store = try await openStore()
        let evidence = try await store.recordUserExpression("AI 提议的主题")
        let db = await store.db
        let id = UUID().uuidString, now = ISO8601DateFormatter().string(from: Date())
        try db.execute("INSERT INTO reflection_questions(id,title,title_source_id,ai_named,created_at,updated_at) VALUES(?,?,?,1,?,?)", [id, "AI 提议的主题", evidence, now, now])
        try db.execute("INSERT INTO reflection_question_sources(id,question_id,source_id) VALUES(?,?,?)", [UUID().uuidString, id, evidence])

        try await store.promoteReflectionQuestion(id: id)

        let questions = try await store.reflectionQuestions()
        let promoted = try XCTUnwrap(questions.first { $0.id == id })
        XCTAssertEqual(promoted.isAIOrganized, false)
        XCTAssertNotEqual(promoted.sourceID, evidence)
        XCTAssertEqual(try db.query("SELECT t.text FROM transcripts t WHERE t.source_id=?", [promoted.sourceID]).first?["text"], "AI 提议的主题")
        XCTAssertEqual(try db.query("SELECT version FROM reflection_questions WHERE id=?", [id]).first?["version"], "2")
        try VoiceOSStore.validateStoredReflectionQuestions(db)
        do {
            try await store.promoteReflectionQuestion(id: "missing")
            XCTFail("不存在的主题应抛错")
        } catch {
            XCTAssertEqual((error as? VoiceOSError)?.message, "找不到这个长期问题")
        }
    }

    func testMergeFoldsMaterialsJournalConfirmationsAndFeedback() async throws {
        let store = try await openStore()
        let db = await store.db
        let a = try await store.createReflectionQuestion(title: "甲主题")
        let b = try await store.createReflectionQuestion(title: "乙主题")
        let material = try await store.recordUserExpression("甲主题的补充材料")
        try await store.linkReflectionQuestionSource(questionID: a.id, sourceID: material)
        _ = try await store.addReflectionQuestionEntry(questionID: b.id, kind: .observation, text: "乙的记录")
        _ = try await store.addReflectionQuestionEntry(questionID: a.id, kind: .observation, text: "甲的记录")
        _ = try await store.setSourceLocalOnly(sourceID: material, expectedVersion: 1, localOnly: false)
        let context = try await store.prepareLocalTranscriptContext(sourceIDs: [material])
        let item = try XCTUnwrap(context.sources.first)
        let claimIDs = try await store.importOrganizedClaims(context: context, proposals: [
            .init(statement: item.text, ownership: .userTentative,
                  references: [.init(sourceID: material, transcriptVersionID: item.transcriptVersionID, spanID: item.spans[0].id)])
        ], commandID: "curation-claims-" + material)
        let claimID = try XCTUnwrap(claimIDs.first)
        _ = try await store.confirmTopicClaim(topicID: a.id, claimID: claimID)
        XCTAssertEqual(try db.query("SELECT claim_id FROM topic_claim_confirmations WHERE topic_id=?", [a.id]).first?["claim_id"], claimID)
        try await store.saveTopicFeedback(questionID: a.id, mode: .reduced, snooze: false)
        let versionRow = try db.query("SELECT version FROM reflection_questions WHERE id=?", [b.id]).first
        let versionBefore = Int(versionRow?["version"] ?? "")!

        try await store.mergeReflectionQuestion(id: a.id, into: b.id)

        let questions = try await store.reflectionQuestions()
        XCTAssertNil(questions.first { $0.id == a.id })
        let ids = try await store.reflectionQuestionSourceIDs(questionID: b.id)
        XCTAssertTrue(ids.contains(a.sourceID))
        XCTAssertTrue(ids.contains(b.sourceID))
        XCTAssertTrue(ids.contains(material))
        let entries = try await store.reflectionQuestionEntries(questionID: b.id)
        XCTAssertEqual(entries.map(\.text), ["乙的记录", "甲的记录"])
        let confirmations = try await store.confirmedTopicClaimIDs(topicID: b.id)
        XCTAssertEqual(confirmations, [claimID])
        let feedback = try await store.reflectionTopicFeedback()
        XCTAssertEqual(feedback.first { $0.id == b.id }?.mode, .reduced)
        XCTAssertNil(feedback.first { $0.id == a.id })
        XCTAssertEqual(try db.query("SELECT count(*) AS n FROM reflection_question_sources WHERE question_id=?", [a.id]).first?["n"], "0")
        XCTAssertEqual(try db.query("SELECT count(*) AS n FROM topic_claim_confirmations WHERE topic_id=?", [a.id]).first?["n"], "0")
        let versionAfter = try db.query("SELECT version FROM reflection_questions WHERE id=?", [b.id]).first?["version"]
        XCTAssertEqual(versionAfter, String(versionBefore + 1))
        try VoiceOSStore.validateStoredReflectionQuestions(db)
        try VoiceOSStore.validateStoredTopicFeedback(db)
    }

    func testMergeKeepsTargetFeedbackAndRejectsBadRequests() async throws {
        let store = try await openStore()
        let a = try await store.createReflectionQuestion(title: "甲主题")
        let b = try await store.createReflectionQuestion(title: "乙主题")
        try await store.saveTopicFeedback(questionID: a.id, mode: .paused, snooze: false)
        try await store.saveTopicFeedback(questionID: b.id, mode: .reduced, snooze: false)

        try await store.mergeReflectionQuestion(id: a.id, into: b.id)

        let feedback = try await store.reflectionTopicFeedback()
        XCTAssertEqual(feedback.first { $0.id == b.id }?.mode, .reduced)
        XCTAssertNil(feedback.first { $0.id == a.id })

        do {
            try await store.mergeReflectionQuestion(id: a.id, into: b.id)
            XCTFail("已合并的来源应抛错")
        } catch {
            XCTAssertEqual((error as? VoiceOSError)?.message, "找不到这个长期问题")
        }
        do {
            try await store.mergeReflectionQuestion(id: b.id, into: b.id)
            XCTFail("不能把主题合并到它自己")
        } catch {
            XCTAssertEqual((error as? VoiceOSError)?.message, "不能把主题合并到它自己")
        }
        do {
            try await store.mergeReflectionQuestion(id: b.id, into: "missing")
            XCTFail("目标不存在应抛错")
        } catch {
            XCTAssertEqual((error as? VoiceOSError)?.message, "找不到这个长期问题")
        }
    }
}