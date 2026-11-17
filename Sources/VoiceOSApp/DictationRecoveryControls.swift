import SwiftUI
import VoiceOSCore

extension SourceRecord {
    var dictationRecoveryPending: Bool { state == "interrupted" }
}

extension ControlCenter {
    /// 返回失败原因；成功返回 nil。中断的行没有任务，恢复只能走封存。
    func workspaceRecoverDictation(_ record: SourceRecord) async -> String? {
        guard record.dictationRecoveryPending else { return "这份录音不需要恢复片段" }
        guard !dictationBusy, !dictationActive else { return dictationBusyReason ?? "请等待当前录音或文字处理结束" }
        await recoverDictation(record)
        return records.first(where: { $0.id == record.id })?.state == "saved" ? nil : status
    }
    /// 回收站通道只接受已保存的行，所以中断的录音先封存为可解码片段，再移入回收站。
    func workspaceTrashInterruptedDictation(_ record: SourceRecord) async -> String? {
        guard !dictationBusy, !dictationActive else { return dictationBusyReason ?? "请等待当前录音或文字处理结束" }
        if record.dictationRecoveryPending {
            await recoverDictation(record)
            guard let saved = records.first(where: { $0.id == record.id }), saved.state == "saved" else { return status }
            await manageMaterial(saved, disposition: .trashed)
        } else {
            await manageMaterial(record, disposition: .trashed)
        }
        return records.first(where: { $0.id == record.id })?.isTrashed == true ? nil : status
    }
}

struct DictationRecoveryControls: View {
    @Environment(\.workspacePalette) private var palette
    @ObservedObject var model: ControlCenter
    let source: SourceRecord
    @State private var busy = false
    @State private var activity = ""
    @State private var failure = ""
    @State private var confirmingTrash = false
    private var unavailable: Bool { busy || model.dictationBusy || model.dictationActive || model.fullRecordingBusy || model.processingActivity != nil }
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            HStack(spacing:10) {
                Button("保存可解码片段") { recover() }
                    .buttonStyle(.borderedProminent)
                    .disabled(unavailable)
                    .accessibilityLabel("保存可解码片段：" + source.displayTitle)
                Button("移入回收站",systemImage:"trash",role:.destructive) { confirmingTrash = true }
                    .disabled(unavailable)
                    .accessibilityLabel("把中断的录音移入回收站：" + source.displayTitle)
                if busy {
                    ProgressView().controlSize(.small)
                    Text(activity).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                }
            }
            if !failure.isEmpty {
                Text(failure).vosFont(WorkspaceText.meta).foregroundStyle(palette.danger).textSelection(.enabled)
            }
        }
        .alert("把这份中断的录音移入回收站？",isPresented:$confirmingTrash) {
            Button("取消",role:.cancel) {}
            Button("移入回收站",role:.destructive) { trash() }
        } message: {
            Text("先尽力封存可解码片段，再移入回收站。原件、原话和任务历史保留，可从回收站恢复；已连接的 Apple 提醒事项不会被修改。")
        }
    }
    private func recover() {
        guard !busy else { return }
        busy = true; failure = ""; activity = "正在保存可解码片段…"
        Task {
            defer { busy = false }
            if let message = await model.workspaceRecoverDictation(source) { failure = message }
        }
    }
    private func trash() {
        guard !busy else { return }
        busy = true; failure = ""; activity = "正在移入回收站…"
        Task {
            defer { busy = false }
            if let message = await model.workspaceTrashInterruptedDictation(source) { failure = message }
        }
    }
}
