import Foundation
import VoiceOSCore
import VoiceOSPlatform

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
private actor ContinuationFixtureCognition: ModelPort {
    let configuration = ModelConfiguration(provider: "continuation_offline_fixture", model: "synthetic", promptVersion: "p1", schemaVersion: "s1", destination: .local)
    var calls = 0
    func generate(_ request: ModelRequest) async throws -> ModelResponse {
        calls += 1
        let source = request.context.sources[0]
        return .init(status: .completed, claims: [.init(statement: "哪些反例可以限制猜想？", ownership: .userTentative,
            references: [.init(sourceID: source.sourceID, transcriptVersionID: source.transcriptVersionID, spanID: source.spans[0].id)], contentKind: .question)], inputTokens: 11, outputTokens: 13)
    }
}
func runSourceContinuationFixture(_ store: VoiceOSStore) async throws {
    _ = try await store.recordUserExpression("合成旧表达：反例与猜想的限制条件。", commandID: "continuation-history")
    let source = try await store.recordUserExpression("合成个人疑问：哪些反例可以限制猜想？", commandID: "continuation-source")
    let cognition = ContinuationFixtureCognition(), association = AssociationFixturePort()
    let result = try await store.continueSourceUnderstanding(sourceID: source, using: cognition)
    var associationState = "not_run"
    if result.state == "completed" {
        associationState = try await store.processExpressionAssociation(sourceID: source, retrieval: AssociationFixtureRetrieval(), model: association).state.rawValue
    }
    let output: [String: Any] = ["synthetic_only": true, "understanding_state": result.state, "association_state": associationState,
        "cognition_calls": await cognition.calls, "association_calls": await association.calls,
        "claims": try await store.candidateClaims(includeFrozen: true).count, "questions": try await store.questions().count,
        "actions": try await store.actions().count, "integrity": try await store.integrityCheck(),
        "cloud_calls": 0, "microphone_calls": 0, "external_task_writes": 0]
    print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), as: UTF8.self))
}
func runAssociationFixture(_ store: VoiceOSStore, automatic: Bool = false, semanticRoot: URL? = nil) async throws {
    _ = try await store.recordUserExpression("合成旧表达：什么条件可以限制猜想？", commandID: "association-fixture-old")
    let current = try await store.recordUserExpression("合成新表达：我想重新核对猜想的限制条件。", commandID: "association-fixture-current")
    let port = AssociationFixturePort()
    let record: ExpressionAssociationAttempt?
    var processing = "not_run"
    if automatic {
        let retrieval: any LocalRetrievalPort
        if let semanticRoot { retrieval = CoreMLRetrieval(root: semanticRoot) }
        else { retrieval = AssociationFixtureRetrieval() }
        let result = try await store.processExpressionAssociation(sourceID: current, retrieval: retrieval, semantic: semanticRoot != nil, model: port)
        processing = result.state.rawValue; record = result.attempt
    } else {
        let candidates = try await store.retrieve("限制条件", using: AssociationFixtureRetrieval()).hits.filter { $0.document.sourceID != current }
        let snapshot = try await store.prepareExpressionAssociation(currentSourceID: current, candidates: candidates)
        record = try await store.performExpressionAssociation(snapshot, using: port)
    }
    let output: [String: Any] = ["synthetic_only": true, "processing": processing, "real_local_semantic": semanticRoot != nil, "state": record?.state ?? processing, "validity": record?.validity ?? "not_applicable", "proposals": record?.proposals.count ?? 0, "port_calls": await port.calls, "usage": record?.usage ?? [:], "claims": try await store.candidateClaims().count, "actions": try await store.actions().count, "integrity": try await store.integrityCheck(), "network_calls": 0]
    print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), as: UTF8.self))
}
func runAssociationIgnoreFixture(_ store: VoiceOSStore) async throws {
    guard let record = try await store.expressionAssociationAttempts().first(where: { $0.state == "completed" }),
          let proposal = record.proposals.first else { throw VoiceOSError("缺少合成已完成关联") }
    try await store.ignoreExpressionAssociation(attemptID: record.id, candidateID: proposal.candidateID, relation: proposal.relation, commandID: "association-fixture-ignore")
    print("{\"feedback_count\":\(try await store.expressionAssociationFeedback().count),\"integrity\":\(try await store.integrityCheck())}")
}

func runQuestionAssociationFixture(_ store: VoiceOSStore) async throws {
    let old = try await seedTypedCognitionFixture(store)
    let current = try await store.recordUserExpression("合成新表达：我再次比较反例与猜想的限制。", commandID: "question-association-current")
    let hits = try await store.retrieve("反例", using: AssociationFixtureRetrieval()).hits.filter { $0.document.sourceID == old }
    let snapshot = try await store.prepareExpressionAssociation(currentSourceID: current, candidates: hits), port = AssociationFixturePort()
    _ = try await store.performExpressionAssociation(snapshot, using: port)
    let items = try await store.expressionAssociationFeedback(currentSourceID: current)
    let output: [String: Any] = ["synthetic_only": true, "associations": items.count, "historical_questions": items.first?.historicalQuestions.count ?? 0, "question_status": items.first?.historicalQuestions.first?.status.rawValue ?? "none", "question_version": items.first?.historicalQuestions.first?.version ?? 0, "port_calls": await port.calls, "actions": try await store.actions().count, "network_calls": 0, "microphone_calls": 0, "external_task_writes": 0, "integrity": try await store.integrityCheck()]
    print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), as: UTF8.self))
}
