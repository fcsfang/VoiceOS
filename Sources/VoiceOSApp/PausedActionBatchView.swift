import SwiftUI
import VoiceOSCore

enum PausedActionBatchPhase: Equatable {
    case confirming
    case running(PausedActionBatchProgress)
    case finished(PausedActionBatchSummary)
}

struct PausedActionBatchProgress: Equatable {
    let done: Int
    let total: Int
    let currentSourceID: String?
    let currentTitle: String
    var label: String { "正在重新识别 \(min(done + 1, total))/\(total)" }
}

struct PausedActionBatchRun: Equatable {
    let plan: PausedActionBatchPlan
    var phase: PausedActionBatchPhase
    var stopRequested: Bool
    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }
    var currentSourceID: String? {
        if case .running(let progress) = phase { return progress.currentSourceID }
        return nil
    }
}

struct PausedActionBatchSummary: Equatable {
    struct Updated: Equatable {
        let sourceID: String
        let reused: Bool
    }
    struct Skipped: Equatable {
        let sourceID: String
        let reason: PausedActionBatchSkipReason
        let message: String?
    }
    struct Failed: Equatable {
        let sourceID: String
        let message: String
        let remainingActionIDs: [String]
    }
    let updated: [Updated]
    let skipped: [Skipped]
    let failed: [Failed]
    let stoppedRemaining: Int
    let resolvedActionIDs: [String]
    let remainingActionIDs: [String]
    let reviewOnlyActionIDs: [String]
    let withdrawnActionIDs: [String]
    let unattachedActionIDs: [String]
}

enum SourceReidentifyReceipt: Sendable {
    case finished(reused: Bool)
    case skipped(PausedActionBatchSkipReason)
    case failed(String)
}

struct PausedActionBatchControl: View {
    @ObservedObject var model: ControlCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch model.pausedActionBatch?.phase {
            case .some(.confirming):
                EmptyView()
            case .some(.running(let progress)):
                ProgressView(value: Double(progress.done), total: Double(max(1, progress.total)))
                HStack {
                    Text(progress.label)
                    if !progress.currentTitle.isEmpty {
                        Text(progress.currentTitle).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button(model.pausedActionBatch?.stopRequested == true ? "将在当前材料完成后停止" : "停止") {
                        model.stopPausedActionBatch()
                    }
                    .disabled(model.pausedActionBatch?.stopRequested == true)
                }
            case .some(.finished(let summary)):
                Text("已更新 \(summary.updated.count) 份 · 跳过 \(summary.skipped.count) 份 · 失败 \(summary.failed.count) 份")
                if summary.stoppedRemaining > 0 {
                    Text("已停止，未处理 \(summary.stoppedRemaining) 份。").foregroundStyle(.secondary)
                }
                if !summary.remainingActionIDs.isEmpty {
                    Text("仍有 \(summary.remainingActionIDs.count) 条暂停待办需要打开任务核对。").foregroundStyle(.secondary)
                }
                if !summary.reviewOnlyActionIDs.isEmpty {
                    Text("另有 \(summary.reviewOnlyActionIDs.count) 条行动关系需逐条核对，本次未改动。").foregroundStyle(.secondary)
                }
                if !summary.withdrawnActionIDs.isEmpty {
                    Text("另有 \(summary.withdrawnActionIDs.count) 条已在后续录音中撤回，本次未改动。").foregroundStyle(.secondary)
                }
                if !summary.unattachedActionIDs.isEmpty {
                    Text("另有 \(summary.unattachedActionIDs.count) 条待办找不到可重新识别的材料，需在任务里单独查看。").foregroundStyle(.secondary)
                }
                DisclosureGroup("查看本次明细") {
                    ForEach(summary.updated, id: \.sourceID) { row in
                        Text(row.reused ? "沿用已有理解 · \(title(row.sourceID))" : "已更新 · \(title(row.sourceID))")
                            .font(.callout)
                    }
                    ForEach(summary.skipped, id: \.sourceID) { row in
                        Text("跳过 · \(title(row.sourceID)) · \(skipLabel(row.reason))")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(summary.failed, id: \.sourceID) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("失败 · \(title(row.sourceID))").font(.callout)
                            Text(row.message).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Button("关闭摘要") { model.dismissPausedActionBatch() }
            case .none:
                let preview = model.pausedActionBatchPreview
                if preview.isBatchable {
                    Button("重新识别全部暂停的待办…") { Task { await model.preparePausedActionBatch() } }
                        .disabled(model.pausedActionBatchUnavailableReason != nil)
                    Text("涉及 \(preview.affectedMaterialCount) 份材料、\(preview.targetActionCount) 条暂停待办。每份材料重新识别一次，会调用已配置的文本模型；长文字或完整录音沿用该材料的现有分段流程，部分材料会先校正完整转写，可能因此多一次模型调用。相同依据会复用，不会重复发送。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let reason = model.pausedActionBatchUnavailableReason {
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("当前没有可批量重新识别的暂停待办；上面的事项需要逐条打开核对。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.top, 12)
        .alert("重新识别 \(model.pausedActionBatch?.plan.affectedMaterialCount ?? 0) 份材料？",
               isPresented: Binding(get: {
                   if case .some(.confirming) = model.pausedActionBatch?.phase { return true }
                   return false
               }, set: { if !$0 { model.cancelPausedActionBatch() } })) {
            Button("开始重新识别") { model.startPausedActionBatch() }
            Button("取消", role: .cancel) { model.cancelPausedActionBatch() }
        } message: {
            if let plan = model.pausedActionBatch?.plan {
                Text(confirmationCopy(plan))
            }
        }
    }

    private func title(_ sourceID: String) -> String {
        model.records.first(where: { $0.id == sourceID })?.displayTitle ?? "已保存的材料"
    }

    private func skipLabel(_ reason: PausedActionBatchSkipReason) -> String {
        switch reason {
        case .quarantined: return "原件完整性待核对"
        case .unavailableSource: return "材料当前不可用"
        case .missingTranscript: return "没有可用文字"
        case .localOnly: return "仅本机保存"
        case .busy: return "正在处理"
        case .noLongerPaused: return "已不再暂停"
        }
    }

    private func confirmationCopy(_ plan: PausedActionBatchPlan) -> String {
        var text = "共 \(plan.targetActionCount) 条标记为“AI 提取已暂停”的待办，涉及 \(plan.affectedMaterialCount) 份材料。"
        text += "将按顺序逐份重新识别，每份材料只重新识别一次；普通文字会调用一次理解模型，长文字或完整录音会沿用该材料的现有分段流程。部分材料会先校正完整转写，可能因此多一次模型调用。已有相同依据的识别会复用，不会重复发送。"
        text += "旧待办转入历史，已登记的完成记录和提醒事项保留。"
        if !plan.skips.isEmpty {
            text += "本次跳过 \(plan.skips.count) 份材料（隔离、无可用文字、仅本机或正在处理）。"
        }
        if !plan.reviewOnlyActionIDs.isEmpty {
            text += "另有 \(plan.reviewOnlyActionIDs.count) 条行动关系需逐条核对，本次不会改动。"
        }
        if !plan.withdrawnActionIDs.isEmpty {
            text += "另有 \(plan.withdrawnActionIDs.count) 条已在后续录音中撤回，本次不会重发。"
        }
        if !plan.unattachedActionIDs.isEmpty {
            text += "另有 \(plan.unattachedActionIDs.count) 条待办找不到可重新识别的材料，需要在任务里单独查看。"
        }
        text += "可以随时停止；停止会在当前材料完成后生效。"
        return text
    }
}
