import SwiftUI
import AppKit
import AVFoundation
import VoiceOSPlatform

private struct OnboardingStep: Identifiable, Sendable {
    let id: Int
    let title: String
    let detail: String
    let symbol: String
}

private let onboardingSteps: [OnboardingStep] = [
    OnboardingStep(id: 0, title: "开始之前", detail: "麦克风用于口述与录音，开口即可记录想法。\n提醒事项用于把待办提醒带回系统，到点由系统提醒你。", symbol: "hand.raised"),
    OnboardingStep(id: 1, title: "记录想法", detail: "按 ⌥⌘D 开始口述，或从菜单栏打开速记（⌥⌘N）。想法先留在本机，再慢慢整理。", symbol: "mic"),
    OnboardingStep(id: 2, title: "资料与行动", detail: "导入录音或文字后，VoiceOS 在本机整理成资料、理解与行动。完成的行动可以回来记录结果。", symbol: "books.vertical"),
    OnboardingStep(id: 3, title: "快捷键", detail: "", symbol: "keyboard"),
    OnboardingStep(id: 4, title: "完成", detail: "菜单栏图标常驻，随时速记；每周结束到行动页打开每周回顾。", symbol: "checkmark.circle")
]

struct OnboardingView: View {
    @ObservedObject var model: ControlCenter
    let finish: () -> Void
    @Environment(\.workspacePalette) private var palette
    @Environment(\.vosTextScale) private var textScale
    @State private var step = 0
    @State private var microphone = OnboardingView.currentMicrophoneAuthorization()

    private var current: OnboardingStep { onboardingSteps[step] }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkspaceMetrics.sectionGap) {
            ScrollView {
                VStack(alignment: .leading, spacing: WorkspaceMetrics.sectionGap) {
                    Text("欢迎使用 VoiceOS").vosFont(WorkspaceText.pageTitle)
                    HStack(spacing: WorkspaceMetrics.controlPadding) {
                        Image(systemName: current.symbol)
                            .vosFont(28)
                            .foregroundStyle(palette.secondaryText)
                            .frame(width: 40 * vosLayoutScale(textScale))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(current.title).vosFont(WorkspaceText.rowTitle)
                            if !current.detail.isEmpty {
                                Text(current.detail)
                                    .vosFont(WorkspaceText.body)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    stepExtra
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: 520)
            stepDots
            HStack {
                Button("跳过", action: finish)
                    .buttonStyle(.workspaceQuiet)
                Spacer()
                if step > 0 {
                    Button("上一步") { step -= 1 }
                        .buttonStyle(.workspaceSecondary)
                }
                Button(step == onboardingSteps.count - 1 ? "开始使用" : "下一步") {
                    if step == onboardingSteps.count - 1 { finish() } else { step += 1 }
                }
                .buttonStyle(.workspacePrimary)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: WorkspaceMetrics.modalSmall)
        .workspaceModalSurface()
        .interactiveDismissDisabled()
    }

    @ViewBuilder private var stepExtra: some View {
        if current.id == 1 {
            Button("立即试一次") {
                QuickNoteController.shared.show()
                finish()
            }.buttonStyle(.workspaceSecondary)
        } else if current.id == 3 {
            VStack(alignment: .leading, spacing: 5) {
                Text("⌥⌘D 口述")
                Text("⌥⌘N 速记")
                Text("⌘F 搜索")
            }.vosFont(WorkspaceText.body).help("更多快捷键见「设置 › 键盘快捷键」。")
        } else if current.id == 4 {
            readinessChecklist
        }
    }

    private var readinessChecklist: some View {
        VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
            VStack(alignment: .leading, spacing: 0) {
                WorkspaceSectionHeading("开始前检查")
                Text("未完成的项不影响开始使用；之后可以在设置中补齐。")
                    .vosFont(WorkspaceText.caption).foregroundStyle(.secondary)
                    .padding(.top, 3)
                    .padding(.bottom, 10)
                WorkspaceListDivider()
            }
            OnboardingCheckRow(
                title: "文本模型",
                detail: model.textModelConfigured ? "已就绪" : "尚未配置",
                ready: model.textModelConfigured,
                action: model.textModelConfigured ? nil : "配置文本模型",
                perform: { model.chooseTextModel() }
            )
            OnboardingCheckRow(
                title: "本地语音",
                detail: model.speechConfigured ? "已就绪" : "在设置 › 模型与服务中配置",
                ready: model.speechConfigured,
                action: model.speechConfigured ? nil : "打开设置",
                perform: openWorkspaceSettings
            )
            microphoneCheckRow
            reminderCheckRow
            notificationCheckRow
        }
        .task { resampleAuthorizations() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            resampleAuthorizations()
        }
    }

    private func resampleAuthorizations() {
        microphone = OnboardingView.currentMicrophoneAuthorization()
        Task { await model.refreshNoticeAuthorization() }
    }

    private var microphoneCheckRow: OnboardingCheckRow {
        switch microphone {
        case .authorized:
            return OnboardingCheckRow(title: "麦克风", detail: "已就绪", ready: true)
        case .notDetermined:
            return OnboardingCheckRow(title: "麦克风", detail: "尚未授权", ready: false, action: "授权", perform: requestMicrophone)
        case .denied, .restricted:
            return OnboardingCheckRow(title: "麦克风", detail: "系统已拒绝", ready: false, action: "打开系统设置", perform: openMicrophoneSettings)
        @unknown default:
            return OnboardingCheckRow(title: "麦克风", detail: "状态未知，请在系统设置中检查", ready: false, action: "打开系统设置", perform: openMicrophoneSettings)
        }
    }

    private var reminderCheckRow: OnboardingCheckRow {
        let authorization = Self.currentReminderAuthorization()
        if model.reminderAccess?.enabled == true, authorization == .granted {
            return OnboardingCheckRow(title: "提醒事项", detail: model.reminderAccess?.title ?? "已连接", ready: true)
        }
        if authorization == .denied {
            return OnboardingCheckRow(title: "提醒事项", detail: "系统权限已拒绝", ready: false, action: "打开系统设置", perform: openReminderSettings)
        }
        return OnboardingCheckRow(title: "提醒事项", detail: "未连接", ready: false, action: "打开设置", perform: openWorkspaceSettings)
    }

    private var notificationCheckRow: OnboardingCheckRow {
        switch model.noticeAuthorization {
        case .authorized:
            return OnboardingCheckRow(title: "系统通知", detail: model.noticeAuthorizationDetail, ready: true)
        case .notRequested:
            return OnboardingCheckRow(title: "系统通知", detail: model.noticeAuthorizationDetail, ready: false)
        case .denied:
            return OnboardingCheckRow(title: "系统通知", detail: model.noticeAuthorizationDetail, ready: false, action: "打开系统通知设置", perform: { model.openNoticeSettings() })
        }
    }

    private static func currentMicrophoneAuthorization() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    private static func currentReminderAuthorization() -> RemindersAuthorization {
        NativeReminders.authorizationStatus()
    }

    private func requestMicrophone() {
        Task {
            _ = await model.requestMicrophoneAccess()
            microphone = OnboardingView.currentMicrophoneAuthorization()
        }
    }

    private func openWorkspaceSettings() {
        finish()
        model.pendingWorkspaceRoute = .settings
    }

    private func openMicrophoneSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    private func openReminderSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")!)
    }

    private var stepDots: some View {
        HStack(spacing: 8) {
            ForEach(onboardingSteps) { item in
                Button { step = item.id } label: {
                    Circle()
                        .fill(item.id == step ? palette.accent : palette.secondaryText.opacity(0.28))
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

private struct OnboardingCheckRow: View {
    @Environment(\.workspacePalette) private var palette
    let title: String
    let detail: String
    let ready: Bool
    var action: String? = nil
    var perform: () -> Void = {}

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: ready ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ready ? palette.success : palette.secondaryText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).vosFont(WorkspaceText.rowTitle)
                Text(detail)
                    .vosFont(WorkspaceText.meta)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let action {
                Button(action, action: perform).buttonStyle(.workspaceQuietCompact)
            }
        }
        .accessibilityElement(children: .combine)
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
            .onChange(of: model.onboardingRequested) { _, requested in
                guard requested else { return }
                model.onboardingRequested = false
                showing = true
            }
            .sheet(isPresented: $showing) {
                OnboardingView(model: model) {
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
