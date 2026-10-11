import Foundation
import VoiceOSCore

/// Synthetic, offline outcome typing and recovery fixture. Never loads model credentials.
func runDiscussionQuestionFixture(_ store: VoiceOSStore) async throws {
    let history = try await store.recordUserExpression("合成讨论起点：猜想仍未验证。", commandID: "discussion-question-history")
    let source = try await store.recordUserExpression("合成个人疑问：哪些反例可以限制猜想？", commandID: "discussion-question-source")
    let id = try await store.beginConversation(sourceIDs: [history], commandID: "discussion-question-entry")
    _ = try await store.appendConversationUserSource(conversationID: id, sourceID: source, expectedVersion: 1, commandID: "discussion-question-turn")
    if try await store.discussionAttempts(conversationID: id).isEmpty {
        let input = try await store.prepareConversationInput(id: id, expectedVersion: 2, destination: .local)
        _ = try await store.performConversationReply(input, using: QuestionFixtureReply())
    }
    try await store.endConversation(id: id, expectedVersion: 2, commandID: "discussion-question-end")
    var calls = 0
    if try await store.conversationOutcomes(conversationID: id).isEmpty {
        let input = try await store.prepareReusableConversationOutcome(id: id, expectedVersion: 3, destination: .local, commandID: "discussion-question-outcome")
        _ = try await store.performConversationOutcome(input, using: QuestionFixtureOutcome())
        calls = 1
    }
    let questions = try await store.questions(), receipts = try await store.conversationOutcomes(conversationID: id)
    let output: [String: Any] = ["synthetic_only": true, "outcome_state": receipts.first?.state ?? "missing", "questions": questions.count,
        "ownership": questions.map(\.seed.ownership).sorted(), "statuses": questions.map { $0.status.rawValue },
        "claims": try await store.candidateClaims(includeFrozen: true).count, "actions": try await store.actions().count,
        "fixture_port_calls": calls, "network_calls": 0, "microphone_calls": 0, "external_task_writes": 0,
        "integrity": try await store.integrityCheck()]
    print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), as: UTF8.self))
}
private struct QuestionFixtureReply: DiscussionModelPort {
    let configuration = ModelConfiguration(provider: "fixture", model: "synthetic", promptVersion: "v1", schemaVersion: "v1", destination: .local)
    func reply(_ request: DiscussionModelRequest) async throws -> DiscussionModelResponse {
        .init(status: .completed, parts: [.init(kind: .aiSuggestion, text: "合成AI追问：哪些条件需要重新检查？")])
    }
}
private struct QuestionFixtureOutcome: ConversationOutcomePort {
    let configuration = ModelConfiguration(provider: "typed_fixture_outcome", model: "synthetic", promptVersion: "v2", schemaVersion: "v2", destination: .local)
    func extract(_ request: ConversationOutcomeRequest) async throws -> ConversationOutcomeResponse {
        guard let turn = request.snapshot.input.userTurns.first,
              let source = request.snapshot.context.sources.first(where: { $0.sourceID == turn.sourceID }),
              let reply = request.snapshot.replies.first else { throw VoiceOSError("synthetic discussion evidence missing") }
        let ref = ClaimReference(sourceID: source.sourceID, transcriptVersionID: source.transcriptVersionID, spanID: source.spans[0].id)
        return .init(status: .completed, proposals: [
            .init(statement: "哪些反例可以限制猜想？", ownership: .userTentative, sourceEvidence: [.init(reference: ref, quote: source.text)], contentKind: .question),
            .init(statement: reply.parts[0].text, ownership: .aiCandidate, sourceEvidence: [], replyEvidence: [.init(attemptID: reply.attemptID, partIndex: 0, quote: reply.parts[0].text)], contentKind: .question)
        ], inputTokens: 10, outputTokens: 20)
    }
}
