import SwiftUI
import VoiceOSCore

struct RecordingTitleEditor: View {
    let record: SourceRecord
    @ObservedObject var model: ControlCenter
    let dismiss: () -> Void
    @State private var title: String
    @State private var saving = false
    init(record: SourceRecord, model: ControlCenter, dismiss: @escaping () -> Void) {
        self.record = record; self.model = model; self.dismiss = dismiss
        // Only a real content title may prefill; saving the derived displayTitle
        // would freeze an automatic name as manual.
        _title = State(initialValue: record.contentTitle ?? "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("修改录音标题").vosFont(WorkspaceText.sectionTitle)
            TextField("内容标题", text: $title, prompt: Text("当前显示：\(record.displayTitle)"))
            Text(record.recordingSubtitle).vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
            Text("标题用于资料库；手动标题不会被自动整理覆盖。").vosFont(WorkspaceText.body).foregroundStyle(.secondary)
            Text("原文件名：" + MaterialNaming.displayName(record.name)).vosFont(WorkspaceText.meta).textSelection(.enabled)
            if !model.recordingTitleStatus.isEmpty { Text(model.recordingTitleStatus).vosFont(WorkspaceText.meta).foregroundStyle(.secondary) }
            HStack {
                if record.presentation?.manualTitle != nil {
                    Button("恢复自动标题") {
                        saving = true
                        Task { if await model.renameRecording(record, title: nil) { dismiss() }; saving = false }
                    }.buttonStyle(.workspaceQuiet)
                }
                Spacer(); Button("取消", action: dismiss).buttonStyle(.workspaceSecondary).keyboardShortcut(.cancelAction)
                Button("保存") {
                    saving = true
                    Task { if await model.renameRecording(record, title: title) { dismiss() }; saving = false }
                }.buttonStyle(.workspacePrimary).keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.count > 100)
            }.disabled(saving)
        }.padding(24).frame(width: 600)
            .workspaceModalSurface()
    }
}
