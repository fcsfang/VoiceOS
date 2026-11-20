import SwiftUI
import VoiceOSCore

struct MaterialManagementControls: View {
    enum Style { case full, compact }
    @Environment(\.workspacePalette) private var palette
    @ObservedObject var model: ControlCenter
    let source: SourceRecord
    var style: Style = .full
    @State private var confirmingTrash = false
    @State private var busy = false
    @State private var failure: Failure?
    private struct Failure {
        var disposition: MaterialDisposition
        var message: String
    }
    private var count: Int {
        model.sourcePageIndex.expression(for: source.id)?.sourceIDs.count ?? 1
    }
    var body: some View {
        Group {
            if style == .compact { compactControls } else { fullControls }
        }.disabled(busy)
            .alert("将材料移入回收站？",isPresented:$confirmingTrash) {
                Button("取消",role:.cancel) {}
                Button("移入回收站",role:.destructive) { update(.trashed) }
            } message: {
                Text("“\(source.displayTitle)”\(count > 1 ? "包含 \(count) 段连续录音，将一起移入回收站" : "将从日常列表移除")。停止云端处理并暂停相关理解，原件、原话和任务历史保留，可恢复。已连接的 Apple 提醒事项需在提醒事项中单独处理。")
            }
    }
    private var fullControls: some View {
        VStack(alignment:.leading,spacing:8) {
            HStack(spacing:12) {
                if source.isTrashed {
                    restoreButton
                } else {
                    Button(source.isArchived ? "取消归档" : "归档",systemImage:"archivebox") { update(source.isArchived ? .active : .archived) }
                    Button("移入回收站",systemImage:"trash",role:.destructive) { confirmingTrash=true }
                }
                busyIndicator
            }
            if let failure { failureRow(failure) }
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
            if let failure {
                Image(systemName:"exclamationmark.circle").foregroundStyle(palette.warning)
                Text(operationLabel(failure.disposition) + "失败").vosFont(WorkspaceText.meta).lineLimit(1)
                    .help(failure.message)
                Button("重试") { retry(failure.disposition) }.vosFont(WorkspaceText.meta)
                    .accessibilityLabel("重试：" + failure.message)
            }
        }.preference(key: MaterialRowFailurePreferenceKey.self, value: failure != nil)
    }
    private var restoreButton: some View {
        Button("恢复材料",systemImage:"arrow.uturn.backward") { update(.active) }
    }
    @ViewBuilder private var busyIndicator: some View {
        if busy { ProgressView().controlSize(.small).accessibilityLabel("正在处理材料") }
    }
    private func failureRow(_ failure: Failure) -> some View {
        HStack(spacing:8) {
            Image(systemName:"exclamationmark.circle").foregroundStyle(palette.warning)
            Text(failure.message).vosFont(WorkspaceText.meta).lineLimit(2).textSelection(.enabled)
            Button("重试") { retry(failure.disposition) }.vosFont(WorkspaceText.meta).buttonStyle(.borderless)
                .accessibilityLabel("重试：" + failure.message)
        }
    }
    private func operationLabel(_ disposition: MaterialDisposition) -> String {
        switch disposition {
        case .archived: return "归档"
        case .trashed: return "移入回收站"
        case .active: return source.isTrashed ? "恢复材料" : "取消归档"
        }
    }
    private func update(_ disposition: MaterialDisposition) {
        guard !busy else { return }
        busy=true
        Task {
            let message = await model.manageMaterial(source,disposition:disposition)
            busy=false
            failure = message.map { Failure(disposition: disposition, message: InlineFailurePresentation.message(operation: operationLabel(disposition), reason: $0)) }
        }
    }
    private func retry(_ disposition: MaterialDisposition) {
        failure = nil
        update(disposition)
    }
}

struct TrashedMaterialView: View {
    @Environment(\.workspacePalette) private var palette
    @ObservedObject var model: ControlCenter
    let source: SourceRecord
    var body: some View {
        VStack(alignment:.leading,spacing:22) {
            WorkspaceHeading(eyebrow:"材料 · 回收站",title:source.displayTitle,subtitle:"原件和历史保留；这份材料已停止用于当前理解。")
            Text("恢复后仅本机保存。需要云端理解时，请重新允许并整理；之前的结论和任务不会自动重新启用。已连接的 Apple 提醒事项未被删除或取消。").vosFont(WorkspaceText.body)
                .foregroundStyle(palette.secondaryText)
            MaterialManagementControls(model:model,source:source)
            Text(model.status).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).textSelection(.enabled)
            Spacer()
        }.padding(WorkspaceMetrics.pagePadding).frame(maxWidth:WorkspaceMetrics.pageWidth,alignment:.leading).frame(maxWidth:.infinity,alignment:.top)
    }
}
