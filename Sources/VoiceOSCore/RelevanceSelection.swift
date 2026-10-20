import Foundation
import CryptoKit

/// A bounded, immutable preview. A cloud preview is not a durable send reservation.
/// Production cloud dispatch still requires a persisted attempt and policy checks.
public struct RelevanceSnapshot: Codable, Sendable {
    public let id: String
    public let queryID: UUID
    public let query: String
    public let destination: ModelDestination
    public let cloudQueryAllowed: Bool
    public let candidates: [RetrievalHit]
    public let scalarBudget: Int
    public let contentDigest: String
}
public struct RelevanceSelection: Sendable {
    public let snapshotID: String
    public let queryID: UUID
    public let candidateIDs: [String]
    public init(snapshotID: String, queryID: UUID, candidateIDs: [String]) {
        self.snapshotID = snapshotID; self.queryID = queryID; self.candidateIDs = candidateIDs
    }
}
/// Local implementations only. Cloud implementations require a separate durable boundary.
public protocol LocalRelevancePort: Sendable {
    func select(_ snapshot: RelevanceSnapshot) async throws -> RelevanceSelection
}

extension VoiceOSStore {
    /// Do not silently drop private candidates or truncate original text to fit a cloud request.
    public func prepareRelevanceSnapshot(query: String, queryID: UUID, candidates: [RetrievalHit],
                                         destination: ModelDestination = .local, cloudQueryAllowed: Bool = false,
                                         scalarBudget: Int = 4000) throws -> RelevanceSnapshot {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              query.unicodeScalars.count <= 512, (1...8).contains(candidates.count),
              Set(candidates.map(\.id)).count == candidates.count,
              (1...4000).contains(scalarBudget),
              query.unicodeScalars.count + candidates.reduce(0, { $0 + $1.document.text.unicodeScalars.count }) <= scalarBudget else {
            throw VoiceOSError("相关性上下文超过查询、候选或文字预算；请明确缩小范围")
        }
        for candidate in candidates {
            guard candidate.score.isFinite, (0...1).contains(candidate.score),
                  ["exact", "local_semantic"].contains(candidate.method) else { throw VoiceOSError("相关性候选方法或分数无效") }
            try validateRetrievalHit(candidate)
        }
        if destination == .cloud {
            guard cloudQueryAllowed, candidates.allSatisfy({ !$0.document.localOnly }) else {
                throw VoiceOSError("查询或候选未授权云端处理；没有自动过滤或上传仅本地内容")
            }
        }
        let digest = try Self.relevanceDigest(query: query, queryID: queryID, candidates: candidates,
                                         destination: destination, cloudQueryAllowed: cloudQueryAllowed, scalarBudget: scalarBudget)
        return RelevanceSnapshot(id: UUID().uuidString, queryID: queryID, query: query, destination: destination,
                                 cloudQueryAllowed: cloudQueryAllowed, candidates: candidates,
                                 scalarBudget: scalarBudget, contentDigest: digest)
    }

    /// Validate all input candidates, including ones the selector rejected or did not return.
    /// A changed excluded input can also change the meaning of the selection.
    public func validateRelevanceSnapshot(_ snapshot: RelevanceSnapshot, currentQueryID: UUID) throws {
        guard snapshot.queryID == currentQueryID, UUID(uuidString: snapshot.id) != nil else {
            throw VoiceOSError("相关性查询已结束或变化，请重新准备")
        }
        let current = try prepareRelevanceSnapshot(query: snapshot.query, queryID: snapshot.queryID,
                                                   candidates: snapshot.candidates, destination: snapshot.destination,
                                                   cloudQueryAllowed: snapshot.cloudQueryAllowed, scalarBudget: snapshot.scalarBudget)
        guard current.contentDigest == snapshot.contentDigest else { throw VoiceOSError("相关性上下文内容不一致") }
    }

    public func acceptRelevanceSelection(_ selection: RelevanceSelection, for snapshot: RelevanceSnapshot,
                                         currentQueryID: UUID) throws -> [RetrievalHit] {
        try Task.checkCancellation()
        try validateRelevanceSnapshot(snapshot, currentQueryID: currentQueryID)
        guard selection.snapshotID == snapshot.id, selection.queryID == snapshot.queryID,
              selection.candidateIDs.count <= 3,
              Set(selection.candidateIDs).count == selection.candidateIDs.count else {
            throw VoiceOSError("相关性结果身份、数量或候选重复不符")
        }
        let lookup = Dictionary(uniqueKeysWithValues: snapshot.candidates.map { ($0.id, $0) })
        return try selection.candidateIDs.map {
            guard let hit = lookup[$0] else { throw VoiceOSError("相关性结果引用未知候选；未生成原文或关系") }
            return hit
        }
    }

    /// Read-only local selection. It cannot upgrade provenance, evidence or action state.
    public func selectLocalRelevant(query: String, queryID: UUID, candidates: [RetrievalHit],
                                     using port: any LocalRelevancePort) async throws -> [RetrievalHit] {
        try Task.checkCancellation()
        let snapshot = try prepareRelevanceSnapshot(query: query, queryID: queryID, candidates: candidates)
        let selection = try await port.select(snapshot)
        return try acceptRelevanceSelection(selection, for: snapshot, currentQueryID: queryID)
    }

    static func relevanceDigest(query: String, queryID: UUID, candidates: [RetrievalHit],
                                  destination: ModelDestination, cloudQueryAllowed: Bool, scalarBudget: Int) throws -> String {
        struct Payload: Encodable {
            let purpose = "relevance-preview-v1"
            let query: String
            let queryID: UUID
            let documents: [RetrievalDocument]
            let destination: String
            let cloudQueryAllowed: Bool
            let scalarBudget: Int
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Payload(query: query, queryID: queryID, documents: candidates.map(\.document),
                                               destination: destination.rawValue, cloudQueryAllowed: cloudQueryAllowed,
                                               scalarBudget: scalarBudget))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
