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
    OnboardingStep(id: 2, title: "快捷键", detail: "常用三条，随时可用。", symbol: "keyboard"),
    OnboardingStep(id: 3, title: "完成", detail: "菜单栏图标常驻，随时速记；每周结束到行动页打开每周回顾。", symbol: "checkmark.circle")
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
            stepExtra
            stepDots
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

    @ViewBuilder private var stepExtra: some View {
        if current.id == 0 {
            Button("立即试一次") {
                QuickNoteController.shared.show()
                finish()
            }.buttonStyle(.bordered)
        } else if current.id == 2 {
            VStack(alignment: .leading, spacing: 5) {
                Text("⌥⌘D 口述")
                Text("⌥⌘N 速记")
                Text("⌘F 搜索")
                Text("更多快捷键见「设置 › 键盘快捷键」。")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 3)
            }.font(.callout)
        }
    }

    private var stepDots: some View {
        HStack(spacing: 8) {
            ForEach(onboardingSteps) { item in
                Button { step = item.id } label: {
                    Circle()
                        .fill(item.id == step ? Color.accentColor : Color.secondary.opacity(0.28))
                        .frame(width: 8, height: 8)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("第 \(item.id + 1) 步")
                .accessibilityLabel("第 \(item.id + 1) 步")
                .accessibilityAddTraits(item.id == step ? [.isSelected] : [])
            }
        }
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
                guard model.records.isEmpty, model.actionRecords.isEmpty else {
                    completed = true
                    return
                }
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
