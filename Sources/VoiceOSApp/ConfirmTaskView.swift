import SwiftUI
import VoiceOSCore

struct ConfirmTaskView: View {
    let action: ActionRecord
    @ObservedObject var model: ControlCenter
    let dismiss: () -> Void
    @State private var title = ""
    @State private var error = ""
    @State private var commandID = UUID().uuidString
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("核对为明确待办").font(.title2)
            Text("确认这是你仍需跟进的事情，并把标题改成实际要做的动作。保存后会同步到已连接的提醒事项清单。")
                .font(.callout).foregroundStyle(.secondary)
            TextField("需要跟进什么", text: $title).disabled(model.savingAction)
            ScrollView { Text(action.note).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 160)
            if !error.isEmpty { WorkspaceNoticeText(message: error, severity: .danger) }
            HStack {
                Button("取消", action: dismiss).disabled(model.savingAction)
                Spacer()
                Button("确认为待办") {
                    Task {
                        if await model.confirmTask(action, title: title, commandID: commandID) { dismiss() }
                        else { error = model.status }
                    }
                }.buttonStyle(.borderedProminent).disabled(model.savingAction || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: WorkspaceMetrics.modalSmall)
        .onAppear {
            title = action.title.replacingOccurrences(of: "（待核对）", with: "")
            if title.hasPrefix("【"), let end = title.firstIndex(of: "】") { title = String(title[title.index(after: end)...]) }
        }
        .interactiveDismissDisabled(model.savingAction)
    }
}
