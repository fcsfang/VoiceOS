import SwiftUI
import VoiceOSCore

@MainActor
final class PanoramaScreenModel: ObservableObject {
    @Published private(set) var state: PanoramaState?
    @Published private(set) var message = "正在核对完整材料与使用许可"
    @Published var selection: PanoramaSelection?
    @Published private(set) var isGenerating = false
    @Published private(set) var modelConfigured = false
    private var worker: Task<Void,Never>?
    private var refreshVersion = 0

    func refresh(store: VoiceOSStore?, port: (any PanoramaModelPort)?) async {
        modelConfigured = port != nil
        guard let store else { return }
        refreshVersion += 1
        let version = refreshVersion
        do {
            let current = try await store.panoramaState()
            guard version == refreshVersion else { return }
            if state?.snapshot?.id != current.snapshot?.id { selection = nil }
            state = current
            message = current.error ?? statusMessage(current, configured: port != nil)
            guard worker == nil, current.canGenerate, let port else { return }
            generate(store: store, port: port, retry: false)
        } catch {
            guard version == refreshVersion else { return }
            state = nil; selection = nil; message = error.localizedDescription
        }
    }
    func retry(store: VoiceOSStore?, port: (any PanoramaModelPort)?) {
        guard worker == nil, let store, let port else { return }
        generate(store: store, port: port, retry: true)
    }
    private func generate(store: VoiceOSStore, port: any PanoramaModelPort, retry: Bool) {
        message = "正在阅读全部合格原文，生成后另行独立核对每个问题与联系"
        isGenerating = true
        worker = Task { [weak self] in
            do { try await store.generatePanorama(using: port, retry: retry) }
            catch { self?.message = error.localizedDescription }
            guard let self else { return }
            self.worker = nil
            self.isGenerating = false
            await self.refresh(store: store, port: port)
        }
    }
    private func statusMessage(_ state: PanoramaState, configured: Bool) -> String {
        if state.snapshot != nil { return "长期脉络 · AI 归纳与候选联系，原话可逐条核对" }
        if state.input.units.isEmpty { return "完整整理后的授权材料将在这里形成思考全景；可先打开材料或记录想法" }
        if !configured { return "材料已就绪，请选择文本模型配置后生成全景" }
        return state.status == "running" ? "正在生成并独立核对全景，材料仍可使用" : "当前完整材料等待生成全景"
    }
}
