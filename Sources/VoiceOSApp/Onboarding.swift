import SwiftUI

private struct OnboardingStep: Identifiable, Sendable {
    let id: Int
    let title: String
    let detail: String
    let symbol: String
}

private let onboardingSteps: [OnboardingStep] = [
    OnboardingStep(id: 0, title: "记录想法", detail: "按 ⌥⌘D 开始口述，或从菜单栏打开速记（⌥⌘N）。想法先留在本机，再慢慢整理。", symbol: "mic"),
    OnboardingStep(id: 1, title: "资料与行动", detail: "导入录音或文字后，VoiceOS 在本机整理成资料、理解与行动。完成的行动可以回来记录结果。", symbol: "books.vertical"),
    OnboardingStep(id: 2, title: "快捷键", detail: "⌥⌘D 口述 · ⌥⌘V 保存剪贴板 · ⌥⌘N 速记 · ⌘F 搜索 · ⌘1 到 ⌘5 切换页面", symbol: "keyboard")
]

struct OnboardingView: View {
    let finish: () -> Void
    @State private var step = 0

    private var current: OnboardingStep { onboardingSteps[step] }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("欢迎使用 VoiceOS").font(.title2)
            HStack(spacing: 14) {
                Image(systemName: current.symbol)
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 6) {
                    Text(current.title).font(.headline)
                    Text(current.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("第 \(step + 1) 步，共 \(onboardingSteps.count) 步")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("跳过", action: finish)
                Spacer()
                if step > 0 { Button("上一步") { step -= 1 } }
                Button(step == onboardingSteps.count - 1 ? "开始使用" : "下一步") {
                    if step == onboardingSteps.count - 1 { finish() } else { step += 1 }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: WorkspaceMetrics.modalSmall)
        .interactiveDismissDisabled()
    }
}

private struct OnboardingPresenter: ViewModifier {
    @ObservedObject var model: ControlCenter
    @AppStorage("voiceos.onboarding.completed.v1") private var completed = false
    @State private var showing = false

    func body(content: Content) -> some View {
        content
            .task(id: model.initialized) {
                guard model.initialized, !completed else { return }
                showing = true
            }
            .sheet(isPresented: $showing) {
                OnboardingView {
                    completed = true
                    showing = false
                }
            }
    }
}

extension View {
    func onboarding(model: ControlCenter) -> some View {
        modifier(OnboardingPresenter(model: model))
    }
}
