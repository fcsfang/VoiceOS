import Foundation
import VoiceOSCore

private struct AssociationFixtureRetrieval: LocalRetrievalPort {
    func rank(query: String, documents: [RetrievalDocument], semantic: Bool) async throws -> [RetrievalMatch] {
        documents.map { RetrievalMatch(documentID: $0.id, score: 1, method: "exact") }
    }
}
private actor AssociationFixturePort: ExpressionAssociationPort {
    let configuration = ModelConfiguration(provider: "association_offline_fixture", model: "synthetic", promptVersion: "p1", schemaVersion: "s1", destination: .local)
    var calls = 0
    func associate(_ request: ExpressionAssociationRequest) async throws -> ExpressionAssociationResponse {
        calls += 1
        let source = request.snapshot.current.sources[0], hit = request.snapshot.candidates[0]
        let evidence = OutcomeSourceEvidence(reference: .init(sourceID: source.sourceID, transcriptVersionID: source.transcriptVersionID, spanID: source.spans[0].id), quote: source.text)
        return .init(proposals: [.init(candidateID: hit.id, current: evidence, historicalQuote: hit.document.text, relation: .sameQuestion, reason: "合成关联：当前和旧表达讨论相同的限制条件。")], inputTokens: 17, outputTokens: 23)
    }
}
func runAssociationFixture(_ store: VoiceOSStore) async throws {
    _ = try await store.recordUserExpression("合成旧表达：什么条件可以限制猜想？", commandID: "association-fixture-old")
    let current = try await store.recordUserExpression("合成新表达：我想重新核对猜想的限制条件。", commandID: "association-fixture-current")
    let candidates = try await store.retrieve("限制条件", using: AssociationFixtureRetrieval()).hits.filter { $0.document.sourceID != current }
    let snapshot = try await store.prepareExpressionAssociation(currentSourceID: current, candidates: candidates)
    let port = AssociationFixturePort(), record = try await store.performExpressionAssociation(snapshot, using: port)
    let output: [String: Any] = ["synthetic_only": true, "state": record.state, "validity": record.validity, "proposals": record.proposals.count, "port_calls": await port.calls, "usage": record.usage ?? [:], "claims": try await store.candidateClaims().count, "actions": try await store.actions().count, "integrity": try await store.integrityCheck(), "network_calls": 0]
    print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), as: UTF8.self))
}
func runAssociationIgnoreFixture(_ store: VoiceOSStore) async throws {
    guard let record = try await store.expressionAssociationAttempts().first(where: { $0.state == "completed" }),
          let proposal = record.proposals.first else { throw VoiceOSError("缺少合成已完成关联") }
    try await store.ignoreExpressionAssociation(attemptID: record.id, candidateID: proposal.candidateID, relation: proposal.relation, commandID: "association-fixture-ignore")
    print("{\"feedback_count\":\(try await store.expressionAssociationFeedback().count),\"integrity\":\(try await store.integrityCheck())}")
}
