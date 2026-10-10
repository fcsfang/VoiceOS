import Foundation
import Combine
import VoiceOSCore

/// View-owned query lifetime. Durable attempts belong to the store, not the view.
@MainActor
public final class RelevanceQueryCoordinator: ObservableObject {
    @Published public private(set) var snapshot: RelevanceSnapshot?
    @Published public private(set) var hits: [RetrievalHit]?
    @Published public private(set) var busy = false
    @Published public private(set) var status = ""
    @Published public private(set) var usage: [String:Int]?
    private var generation = UUID()
    private var worker: Task<Void,Never>?
    private var completeInput: RelevanceSnapshot?
    public init() {}
    public func cancel() {
        generation = UUID(); worker?.cancel(); worker = nil
        snapshot = nil; completeInput = nil; hits = nil; busy = false; status = ""; usage = nil
    }
    public func stop() {
        cancel(); status = "已停止等待 · 已发送的调用保留记录，不自动重发"
    }
    public func prepare(query: String, candidates: [RetrievalHit], store: VoiceOSStore) async {
        cancel(); let queryID = generation
        busy = true; status = "正在检查所选原文和文本权限…"
        do {
            let value = try await store.prepareRelevanceSnapshot(query:query,queryID:queryID,candidates:candidates,destination:.cloud,cloudQueryAllowed:true)
            guard generation == queryID, !Task.isCancelled else { return }
            snapshot = value; completeInput = value
            status = "已准备 \(candidates.count) 份原文 · 点击判断后发送本次问题和这些原文"
        } catch {
            guard generation == queryID else { return }
            status = error.localizedDescription
        }
        guard generation == queryID else { return }
        busy = false
    }
    public func run(store: VoiceOSStore, port: any RelevanceModelPort) {
        guard !busy, let value = snapshot, value.queryID == generation, hits == nil else { return }
        let queryID = generation
        busy = true; status = "正在判断相关性…"; usage = nil
        worker = Task {
            do {
                let result = try await store.performRelevanceSelection(value,using:port)
                try Task.checkCancellation()
                guard generation == queryID else { return }
                try await store.validateRelevanceSnapshot(value,currentQueryID:generation)
                guard generation == queryID, !Task.isCancelled else { return }
                hits = result
                status = result.isEmpty ? "所选原文中没有直接相关的内容" : "找到 \(result.count) 份相关原文 · 请核对出处"
            } catch {
                guard generation == queryID else { return }
                status = error.localizedDescription
            }
            guard generation == queryID else { return }
            if let rows = try? await store.relevanceAttempts() {
                guard generation == queryID else { return }
                usage = rows.first { $0.queryID == queryID }?.usage
            }
            guard generation == queryID else { return }
            // Consumed, even if rejected/unknown. Reopening never dispatches this snapshot.
            snapshot = nil; busy = false; worker = nil
        }
    }
    public func validate(store: VoiceOSStore) async {
        let queryID = generation
        do {
            if let completeInput { try await store.validateRelevanceSnapshot(completeInput,currentQueryID:queryID) }
        } catch {
            guard generation == queryID else { return }
            cancel(); status = "所选原文或权限已变化，请重新准备"
        }
    }
}
