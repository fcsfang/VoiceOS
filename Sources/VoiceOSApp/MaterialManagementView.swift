import SwiftUI
import VoiceOSCore

struct MaterialManagementControls: View {
    enum Style { case full, compact }
    @ObservedObject var model: ControlCenter
    let source: SourceRecord
    var style: Style = .full
    @State private var confirmingTrash = false
    @State private var busy = false
    private var count: Int {
        source.recordingExpression(in:Dictionary(uniqueKeysWithValues:model.records.map { ($0.id,$0) }))?.sourceIDs.count ?? 1
    }
    var body: some View {
        Group {
            if style == .compact { compactControls } else { fullControls }
        }.disabled(busy)
            .alert("将材料移入回收站？",isPresented:$confirmingTrash) {
                Button("取消",role:.cancel) {}
                Button("移入回收站",role:.destructive) { update(.trashed) }
            } message: {
                Text("“\(source.workspaceTitle)”\(count > 1 ? "包含 \(count) 段连续录音，将一起移入回收站" : "将从日常列表移除")。停止云端处理并暂停相关理解，原件、原话和任务历史保留，可恢复为仅本机材料。已连接的 Apple 提醒事项仍可能通知，请在提醒事项中单独处理。")
            }
    }
    private var fullControls: some View {
        HStack(spacing:12) {
            if source.isTrashed {
                restoreButton
            } else {
                Button(source.isArchived ? "取消归档" : "归档",systemImage:"archivebox") { update(source.isArchived ? .active : .archived) }
                Button("移入回收站",systemImage:"trash",role:.destructive) { confirmingTrash=true }
            }
            busyIndicator
        }
    }
    private var compactControls: some View {
        HStack(spacing:10) {
            if source.isTrashed {
                restoreButton
            } else {
                if source.isArchived {
                    Button("取消归档",systemImage:"archivebox") { update(.active) }
                }
                Menu {
                    if !source.isArchived { Button("归档",systemImage:"archivebox") { update(.archived) } }
                    Button("移入回收站",systemImage:"trash",role:.destructive) { confirmingTrash=true }
                } label: {
                    Image(systemName:"ellipsis.circle")
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("更多材料操作").help("更多材料操作")
            }
            busyIndicator
        }
    }
    private var restoreButton: some View {
        Button("恢复材料",systemImage:"arrow.uturn.backward") { update(.active) }
    }
    @ViewBuilder private var busyIndicator: some View {
        if busy { ProgressView().controlSize(.small) }
    }
    private func update(_ disposition: MaterialDisposition) {
        busy=true
        Task { await model.manageMaterial(source,disposition:disposition);busy=false }
    }
}

struct TrashedMaterialView: View {
    @ObservedObject var model: ControlCenter
    let source: SourceRecord
    var body: some View {
        VStack(alignment:.leading,spacing:22) {
            WorkspaceHeading(eyebrow:"材料 · 回收站",title:source.workspaceTitle,subtitle:"原件和历史保留；这份材料已停止用于当前理解。")
            Text("恢复后仅本机保存。需要云端理解时，请重新允许并整理；之前的结论和任务不会自动重新启用。已连接的 Apple 提醒事项未被删除或取消。")
                .foregroundStyle(.secondary)
            MaterialManagementControls(model:model,source:source)
            Text(model.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Spacer()
        }.padding(30).frame(maxWidth:820,alignment:.leading).frame(maxWidth:.infinity,alignment:.top)
    }
}
