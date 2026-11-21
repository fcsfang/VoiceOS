import SwiftUI
import VoiceOSCore

struct FeynmanPractice: View {
    @Environment(\.workspacePalette) private var palette
    @ObservedObject var model: ControlCenter
    let claimID: String
    let dismiss: () -> Void
    @State private var claim = ""
    @State private var response = ""
    @State private var feedback: FeynmanFeedback?
    @State private var showsOriginal = false
    @State private var errorText = ""
    private var trimmed: String { response.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var claimReady: Bool { !claim.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("工具 · 费曼复述").vosFont(WorkspaceText.caption.size, weight: .semibold, design: .monospaced)
                    .tracking(1.4).textCase(.uppercase).foregroundStyle(palette.accent)
                Text("复述一遍").vosFont(WorkspaceText.sectionTitle).accessibilityAddTraits(.isHeader)
            }
            Text("不看原话，用自己的话讲一遍。").vosFont(WorkspaceText.body).foregroundStyle(.secondary)
            if let feedback {
                result(feedback)
            } else {
                TextEditor(text: $response).frame(minHeight: 200).workspaceEditorSurface().accessibilityLabel("复述内容")
                HStack {
                    Text("\(trimmed.count) 字").vosFont(WorkspaceText.caption.size, monospacedDigit: true).foregroundStyle(.secondary)
                    Button("取消", action: dismiss).keyboardShortcut(.cancelAction).buttonStyle(.workspaceSecondary)
                    Spacer()
                    Button("对照原话") { submit() }.buttonStyle(.workspacePrimary).keyboardShortcut(.defaultAction).disabled(!claimReady || trimmed.isEmpty)
                }.vosFont(WorkspaceText.meta)
            }
            Text("只对照词面，不判断语义，也不保存复述。").vosFont(WorkspaceText.caption).foregroundStyle(.secondary)
            if !errorText.isEmpty { WorkspaceNoticeText(message: errorText, severity: .danger) }
        }
        .padding(24)
        .frame(width: WorkspaceMetrics.modalSmall, height: 520)
        .workspaceModalSurface()
        .task {
            guard claim.isEmpty else { return }
            do { claim = try await model.claimStatement(claimID: claimID) }
            catch { errorText = error.localizedDescription }
        }
    }
    @ViewBuilder private func result(_ report: FeynmanFeedback) -> some View {
        ScrollView {
            WorkspaceCard(padding: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    if !report.covered.isEmpty {
                        Text("覆盖到的要点").vosFont(WorkspaceText.rowTitle).accessibilityAddTraits(.isHeader)
                        Text(report.covered.joined(separator: "、")).vosFont(WorkspaceText.body).textSelection(.enabled)
                    }
                    Text("还没讲到的").vosFont(WorkspaceText.rowTitle).accessibilityAddTraits(.isHeader)
                    if report.missed.isEmpty {
                        Text("原话里的词都讲到了。").vosFont(WorkspaceText.body).foregroundStyle(.secondary)
                    } else {
                        Text(report.missed.joined(separator: "、")).vosFont(WorkspaceText.body).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if let vague = report.vague { WorkspaceNoticeText(message: vague, severity: .warning) }
                    DisclosureGroup("展开原话核对", isExpanded: $showsOriginal) {
                        Text(claim).vosFont(WorkspaceText.body).lineSpacing(4).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                    }
                }
            }
        }
        HStack {
            Button("再试一次") { response = ""; feedback = nil; showsOriginal = false }
            Spacer()
            Button("完成", action: dismiss).keyboardShortcut(.cancelAction).buttonStyle(.workspaceSecondary)
        }
    }
    private func submit() {
        guard claimReady, !trimmed.isEmpty else { return }
        feedback = FeynmanCompare.compare(claim: claim, response: trimmed)
    }
}
