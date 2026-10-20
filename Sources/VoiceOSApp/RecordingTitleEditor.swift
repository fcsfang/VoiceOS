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
        _title = State(initialValue: record.contentTitle ?? "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("修改录音标题").font(.title2)
            TextField("内容标题", text: $title)
            Text(record.recordingSubtitle).font(.caption).foregroundStyle(.secondary)
            Text("标题用于 VoiceOS 资料库。手动标题会保留，后续自动整理不会覆盖。").font(.callout).foregroundStyle(.secondary)
            Text("原文件名：" + record.name).font(.caption).textSelection(.enabled)
            if !model.recordingTitleStatus.isEmpty { Text(model.recordingTitleStatus).font(.caption).foregroundStyle(.secondary) }
            HStack {
                if record.presentation?.manualTitle != nil {
                    Button("恢复自动标题") {
                        saving = true
                        Task { if await model.renameRecording(record, title: nil) { dismiss() }; saving = false }
                    }
                }
                Spacer(); Button("取消", action: dismiss).keyboardShortcut(.cancelAction)
                Button("保存") {
                    saving = true
                    Task { if await model.renameRecording(record, title: title) { dismiss() }; saving = false }
                }.keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.count > 100)
            }.disabled(saving)
        }.padding(24).frame(width: 600)
    }
}
