import SwiftUI
import VoiceOSCore

struct ConfirmTaskView: View {
    let action: ActionRecord
    @ObservedObject var model: ControlCenter
    let dismiss: () -> Void
    @State private var title = ""
    @State private var error = ""
    @State private var commandID = UUID().uuidString
    @FocusState private var titleFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("核对为明确待办").vosFont(WorkspaceText.sectionTitle).accessibilityAddTraits(.isHeader)
            Text("确认这是你仍需跟进的事情，并把标题改成实际要做的动作。保存后会同步到已连接的提醒事项清单。")
                .vosFont(WorkspaceText.body).foregroundStyle(.secondary)
            TextField("需要跟进什么", text: $title).focused($titleFocused).disabled(model.savingAction)
            ScrollView { Text(action.note).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 160)
            if !error.isEmpty { WorkspaceNoticeText(message: error, severity: .danger) }
            HStack {
                Button("取消", action: dismiss).keyboardShortcut(.cancelAction).disabled(model.savingAction).buttonStyle(.workspaceSecondary)
                Spacer()
                Button("确认为待办") {
                    Task {
                        if await model.confirmTask(action, title: title, commandID: commandID) { dismiss() }
                        else { error = model.status }
                    }
                }.buttonStyle(.workspacePrimary).keyboardShortcut(.defaultAction).disabled(model.savingAction || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: WorkspaceMetrics.modalSmall)
        .workspaceModalSurface()
        .onAppear {
            title = action.title.replacingOccurrences(of: "（待核对）", with: "")
            if title.hasPrefix("【"), let end = title.firstIndex(of: "】") { title = String(title[title.index(after: end)...]) }
        }
        .interactiveDismissDisabled(model.savingAction)
        .task { try? await Task.sleep(for: .milliseconds(100)); titleFocused = true }
    }
}
