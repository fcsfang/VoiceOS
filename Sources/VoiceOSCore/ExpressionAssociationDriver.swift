import Foundation

public enum ExpressionAssociationProcessingState: String, Sendable {
    case paused, localOnly, modelUnavailable, budgetExceeded, noCandidates, inFlight, completed, unknown
}
public struct ExpressionAssociationProcessing: Sendable {
    public let state: ExpressionAssociationProcessingState
    public let attempt: ExpressionAssociationAttempt?
}
extension VoiceOSStore {
    /// Called by an application-owned processing task. No backfill, retries, notifications or actions.
    public func processExpressionAssociation(sourceID: String, retrieval: any LocalRetrievalPort, semantic: Bool = false, model: (any ExpressionAssociationPort)?) async throws -> ExpressionAssociationProcessing {
        try Task.checkCancellation()
        guard ready else { throw VoiceOSError("资料库尚未就绪") }
        if try cognitiveFeedbackPreference().mode == .paused { return .init(state: .paused, attempt: nil) }
        guard let model else { return .init(state: .modelUnavailable, attempt: nil) }
        let policy = try sourcePolicy(sourceID: sourceID)
        if model.configuration.destination == .cloud && policy.localOnly { return .init(state: .localOnly, attempt: nil) }
        guard let text = try sources().first(where: { $0.id == sourceID })?.transcript else { throw VoiceOSError("表达没有当前逐字稿") }
        if text.unicodeScalars.count >= 8000 { return .init(state: .budgetExceeded, attempt: nil) }
        let context = try prepareLocalTranscriptContext(sourceIDs: [sourceID], scalarBudget: 8000)
        let current = context.sources[0]
        guard current.origin == "user", current.speaker == "user" else { throw VoiceOSError("自动关联只处理明确的个人表达") }
        let baseline = try prepareExpressionAssociation(currentSourceID: sourceID, candidates: [], destination: model.configuration.destination)
        let key = try Self.expressionAssociationKey(baseline, model.configuration)
        if let row = try db.query("SELECT id,state FROM expression_association_attempts WHERE request_key=?", [key]).first {
            if row["state"] == "reserved" { return .init(state: .inFlight, attempt: nil) }
            guard let record = try expressionAssociationAttempts().first(where: { $0.id == row["id"] }) else { throw VoiceOSError("关联历史缺失") }
            return .init(state: record.state == "completed" ? .completed : .unknown, attempt: record)
        }
        // Filter the local catalog before ranking; a cloud-bound candidate set never includes private history.
        let documents = try retrievalDocuments(window: semantic ? retrieval.semanticWindow : .init(scalars: 800, overlap: 512))
            .filter { $0.sourceID != sourceID && (model.configuration.destination != .cloud || !$0.localOnly) }
        if documents.isEmpty { return .init(state: .noCandidates, attempt: nil) }
        let lookup = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })
        let scalars = Array(current.text.unicodeScalars)
        var hits: [String: RetrievalHit] = [:]
        // Local recall uses all bounded expression windows; the model still receives the full original.
        for start in stride(from: 0, to: scalars.count, by: 512) {
            try Task.checkCancellation(); try validateExpressionAssociation(baseline)
            let query = String(String.UnicodeScalarView(scalars[start..<min(start + 512, scalars.count)]))
            let matches = try await retrieval.rank(query: query, documents: documents, semantic: semantic)
            try Task.checkCancellation(); try validateExpressionAssociation(baseline)
            guard Set(matches.map(\.documentID)).count == matches.count else { throw VoiceOSError("自动召回包含重复候选") }
            for match in matches {
                guard let document = lookup[match.documentID], match.score.isFinite, (0...1).contains(match.score), ["exact", "local_semantic"].contains(match.method) else { throw VoiceOSError("自动召回目录或排序无效") }
                let hit = RetrievalHit(document: document, method: match.method, score: match.score)
                try validateRetrievalHit(hit)
                if let old = hits[hit.id] {
                    if old.method != hit.method && old.method == "exact" { continue }
                    if old.method == hit.method && old.score >= hit.score { continue }
                }
                hits[hit.id] = hit
            }
        }
        let sorted = hits.values.sorted { if $0.method != $1.method { return $0.method == "exact" }; if $0.score != $1.score { return $0.score > $1.score }; return $0.id < $1.id }
        var selected: [RetrievalHit] = [], seen = Set<String>(), remaining = 8000 - scalars.count
        for hit in sorted {
            guard !seen.contains(hit.document.sourceID), hit.document.text.unicodeScalars.count <= remaining else { continue }
            selected.append(hit); seen.insert(hit.document.sourceID); remaining -= hit.document.text.unicodeScalars.count
            if selected.count == 8 { break }
        }
        guard !selected.isEmpty else { return .init(state: hits.isEmpty ? .noCandidates : .budgetExceeded, attempt: nil) }
        let snapshot = try prepareExpressionAssociation(currentSourceID: sourceID, candidates: selected, destination: model.configuration.destination)
        do {
            let record = try await performExpressionAssociation(snapshot, using: model)
            return .init(state: record.state == "completed" ? .completed : .unknown, attempt: record)
        } catch {
            // Only a terminal durable receipt may turn a transport failure into an unknown status.
            if let row = try db.query("SELECT id FROM expression_association_attempts WHERE request_key=? AND state='unknown'", [key]).first,
               let record = try expressionAssociationAttempts().first(where: { $0.id == row["id"] }) {
                return .init(state: .unknown, attempt: record)
            }
            throw error
        }
    }
}
