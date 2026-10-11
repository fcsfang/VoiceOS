import Foundation
import VoiceOSCore

/// Offline presentation seed. No classification inference, API configuration or external operations.
func runTypedCognitionFixture(_ store: VoiceOSStore) async throws {
    let source = try await store.recordUserExpression("合成个人疑问：哪些反例可以限制猜想？", commandID: "typed-cognition-fixture")
    if try await store.modelAttempts(sourceID: source).isEmpty {
        let context = try await store.prepareLocalTranscriptContext(sourceIDs: [source])
        let contextID = try await store.persistLocalContext(context, commandID: "typed-cognition-fixture-context")
        let attempt = try await store.reserveLocalModelAttempt(contextID: contextID, model: "synthetic", promptVersion: "typed-fixture", schemaVersion: "typed-fixture")
        let ref = context.sources[0]
        _ = try await store.commitLocalClaims(attemptID: attempt, proposals: [.init(statement: "哪些反例可以限制猜想？", ownership: .userTentative, references: [.init(sourceID: source, transcriptVersionID: ref.transcriptVersionID, spanID: ref.spans[0].id)], contentKind: .question)])
    }
    let claims = try await store.candidateClaims(includeFrozen: true), actions = try await store.actions()
    let output: [String: Any] = ["synthetic_only": true, "question_candidates": claims.filter { $0.contentKind == .question }.count, "questions": try await store.questions().count, "actions": actions.count, "network_calls": 0, "microphone_calls": 0, "external_task_writes": 0, "integrity": try await store.integrityCheck()]
    print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), as: UTF8.self))
}

/// Durable synthetic user close; exact input survives process interruption for command replay.
func runQuestionCloseFixture(_ store: VoiceOSStore) async throws {
    guard let question = try await store.questions().first else { throw VoiceOSError("question fixture missing") }
    let file = await store.root.appendingPathComponent("synthetic-question-transition.json")
    let input: QuestionTransitionSnapshot
    if FileManager.default.fileExists(atPath: file.path) {
        input = try JSONDecoder().decode(QuestionTransitionSnapshot.self, from: Data(contentsOf: file))
    } else {
        input = try await store.prepareStoredQuestionTransition(questionID: question.id, expectedVersion: question.version, to: .closed, reason: "合成用户明确停止追踪")
        try JSONEncoder().encode(input).write(to: file, options: .atomic)
    }
    _ = try await store.transitionQuestion(questionID: question.id, input: input, commandID: "synthetic-close-once")
    let record = try await store.questions()[0], history = try await store.questionHistory(questionID: question.id)
    let output: [String: Any] = ["synthetic_only": true, "questions": 1, "version": record.version, "status": record.status.rawValue, "validity": record.validity, "revisions": history.count, "network_calls": 0, "microphone_calls": 0, "external_task_writes": 0, "integrity": try await store.integrityCheck()]
    print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), as: UTF8.self))
}
