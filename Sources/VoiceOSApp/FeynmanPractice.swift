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
            WorkspaceHeading(eyebrow: "工具 · 费曼复述", title: "复述一遍")
            Text("不看原话，用自己的话讲一遍。").vosFont(14).foregroundStyle(.secondary)
            if let feedback {
                result(feedback)
            } else {
                TextEditor(text: $response).frame(minHeight: 200).workspaceEditorSurface().accessibilityLabel("复述内容")
                HStack {
                    Text("\(trimmed.count) 字").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("取消", action: dismiss).keyboardShortcut(.cancelAction)
                    Button("对照原话") { submit() }.buttonStyle(.borderedProminent).disabled(!claimReady || trimmed.isEmpty)
                }.font(.caption)
            }
            Text("只对照词面，不判断语义，也不保存复述。").font(.caption).foregroundStyle(.secondary)
            if !errorText.isEmpty { Text(errorText).font(.caption).foregroundStyle(palette.danger) }
        }
        .padding(24)
        .frame(width: WorkspaceMetrics.modalSmall, height: 520)
        .task {
            guard claim.isEmpty else { return }
            do { claim = try await model.claimStatement(claimID: claimID) }
            catch { errorText = error.localizedDescription }
        }
    }
    @ViewBuilder private func result(_ report: FeynmanFeedback) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !report.covered.isEmpty {
                    Text("覆盖到的要点").vosFont(13, weight: .semibold).accessibilityAddTraits(.isHeader)
                    Text(report.covered.joined(separator: "、")).vosFont(14).textSelection(.enabled)
                }
                Text("还没讲到的").vosFont(13, weight: .semibold).accessibilityAddTraits(.isHeader)
                if report.missed.isEmpty {
                    Text("原话里的词都讲到了。").vosFont(13).foregroundStyle(.secondary)
                } else {
                    Text(report.missed.joined(separator: "、")).vosFont(14).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let vague = report.vague { WorkspaceNoticeText(message: vague, severity: .warning) }
                DisclosureGroup("展开原话核对", isExpanded: $showsOriginal) {
                    Text(claim).vosFont(14).lineSpacing(4).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
            .overlay { RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius).strokeBorder(palette.border, lineWidth: 1) }
        }
        HStack {
            Button("再试一次") { response = ""; feedback = nil; showsOriginal = false }
            Spacer()
            Button("完成", action: dismiss).keyboardShortcut(.cancelAction)
        }
    }
    private func submit() {
        guard claimReady, !trimmed.isEmpty else { return }
        feedback = FeynmanCompare.compare(claim: claim, response: trimmed)
    }
}
