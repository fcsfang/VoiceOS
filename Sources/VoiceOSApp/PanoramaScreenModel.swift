import SwiftUI
import VoiceOSCore

@MainActor
final class PanoramaScreenModel: ObservableObject {
    @Published private(set) var state: PanoramaState?
    @Published private(set) var message = "正在核对完整材料与使用许可"
    @Published private(set) var readError: String?
    @Published var selection: PanoramaSelection?
    @Published private(set) var isGenerating = false
    @Published private(set) var modelConfigured = false
    private var worker: Task<Void,Never>?
    private var refreshVersion = 0
    private var progressWorker: Task<Void,Never>?
    private var lastStore: VoiceOSStore?
    private var lastPort: (any PanoramaModelPort)?

    func refresh(store: VoiceOSStore?, port: (any PanoramaModelPort)?) async {
        modelConfigured = port != nil
        guard let store else { return }
        lastStore = store
        lastPort = port
        refreshVersion += 1
        let version = refreshVersion
        do {
            let current = try await store.panoramaState()
            guard version == refreshVersion else { return }
            if state?.snapshot?.id != current.snapshot?.id { selection = nil }
            if let selection {
                let exists: Bool
                switch selection {
                case .question(let id): exists=current.snapshot?.proposal.questions.contains { $0.id == id } == true
                case .relation(let id): exists=current.snapshot?.proposal.relations.contains { $0.id == id } == true
                }
                if !exists { self.selection=nil }
            }
            state = current
            readError = nil
            message = current.error ?? statusMessage(current, configured: port != nil)
            guard worker == nil, current.canGenerate, let port else { return }
            generate(store: store, port: port, retry: false)
        } catch {
            guard version == refreshVersion else { return }
            readError = error.localizedDescription
        }
    }
    func retryRefresh() {
        Task { await refresh(store: lastStore, port: lastPort) }
    }
    func dismissReadError() {
        readError = nil
    }
    func retry(store: VoiceOSStore?, port: (any PanoramaModelPort)?) {
        guard worker == nil, let store, let port else { return }
        generate(store: store, port: port, retry: true)
    }
    private func generate(store: VoiceOSStore, port: any PanoramaModelPort, retry: Bool) {
        message = "逐个阅读全文并独立核对；通过核对的区域会先显示"
        isGenerating = true
        progressWorker = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.isGenerating else { return }
                await self.refresh(store: store, port: port)
            }
        }
        worker = Task { [weak self] in
            do { try await store.generatePanorama(using: port, retry: retry) }
            catch { self?.message = error.localizedDescription }
            guard let self else { return }
            self.progressWorker?.cancel()
            self.progressWorker = nil
            self.worker = nil
            self.isGenerating = false
            await self.refresh(store: store, port: port)
        }
    }
    private func statusMessage(_ state: PanoramaState, configured: Bool) -> String {
        if let progress=state.progress, state.snapshot?.isPartial == true || state.status == "running" {
            let count="已核对 \(progress.verifiedUnitCount)/\(progress.totalUnitCount) 个完整单元"
            let remaining=progress.phase == .units ? "其余材料仍在核对" : "跨单元联系与全局覆盖仍在核对"
            return count + " · " + remaining + "；当前仅显示已核对区域，尚非完整全景"
        }
        if state.snapshot != nil { return "长期脉络 · AI 归纳与候选联系，原话可逐条核对" }
        if state.input.units.isEmpty { return "完整整理后的授权材料将在这里形成思考全景；可先打开材料或记录想法" }
        if !configured { return "材料已就绪，请选择文本模型配置后生成全景" }
        return state.status == "running" ? "正在生成并独立核对全景，材料仍可使用" : "当前完整材料等待生成全景"
    }
}
