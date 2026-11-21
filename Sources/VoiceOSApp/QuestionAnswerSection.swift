import SwiftUI
import VoiceOSCore

enum QuestionAnswerPhase {
    case none, running, completed, failed

    init(_ execution: AssistantExecutionRecord?) {
        guard let execution else { self = .none; return }
        switch execution.state {
        case "queued", "running", "reserved", "blocked": self = .running
        case "completed": self = .completed
        case "failed", "cancelled": self = .failed
        default: self = .none
        }
    }
}

/// Structural model failures read as one retryable message. The raw diagnostic
/// stays in the execution record and the log, never in the notice.
enum AssistantFailurePresentation {
    static func message(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return AssistantFailureMessage.isStructural(raw) ? AssistantFailureMessage.structural : raw
    }
}

/// The apex of a question page: what VoiceOS answered, or the way to ask.
struct QuestionAnswerSection: View {
    @Environment(\.workspacePalette) private var palette
    @ObservedObject var model: ControlCenter
    let action: ActionRecord
    let openDelivery: (String) -> Void
    let openSource: (String) -> Void
    @State private var error = ""
    @State private var followup = ""
    @State private var followupSending = false

    private var analysis: [AssistantExecutionRecord] {
        model.assistantExecutions.filter { $0.actionID == action.id && $0.mode == .analysis }
    }
    /// Follow-ups never displace the answer at the apex; they list below it.
    private var answer: AssistantExecutionRecord? { analysis.first { $0.instruction.isEmpty } }
    private var followups: [AssistantExecutionRecord] { analysis.filter { !$0.instruction.isEmpty } }
    private var phase: QuestionAnswerPhase { QuestionAnswerPhase(answer) }
    private var modelReady: Bool { model.modelConfigured }
    private var canFollowup: Bool { action.state == "open" && action.validity == "current" }

    var body: some View {
        WorkspaceSection(title: "VoiceOS 的回答", subtitle: subtitle, icon: "sparkles") {
            switch phase {
            case .none: emptyState
            case .running: runningState
            case .completed: completedState
            case .failed: failedState
            }
        }
    }

    private var subtitle: String {
        switch phase {
        case .none: return "让 VoiceOS 回答；答案会保存，可继续追问。"
        case .running: return "回答正在生成，可以先做别的事。"
        case .completed: return ""
        case .failed: return "这次回答没有完成；可以重试。"
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: WorkspaceMetrics.groupGap) {
            Text("这个问题还没有 VoiceOS 的回答。").vosFont(WorkspaceText.body)
            HStack(spacing: 12) {
                Button("让 VoiceOS 回答", systemImage: "sparkles") { ask(fresh: true) }
                    .buttonStyle(.workspacePrimary)
                    .disabled(model.assistantBusy || !modelReady)
                if !modelReady {
                    Text("开始回答需要先配置文本模型。").vosFont(WorkspaceText.meta).foregroundStyle(palette.warning)
                    Button("配置文本模型…") { model.chooseTextModel() }.buttonStyle(.workspaceQuiet)
                }
            }
            if !error.isEmpty { WorkspaceNoticeText(message: error, severity: .danger) }
        }.padding(.vertical, 16)
    }

    private var runningState: some View {
        HStack(spacing: 14) {
            ProgressView().controlSize(.small)
            Text(answer?.state == "queued" ? "已排队，等待 VoiceOS 回答。" : "VoiceOS 正在回答，完成后会保存在这里。")
        }.padding(.vertical, 30)
    }

    private var completedState: some View {
        VStack(alignment: .leading, spacing: WorkspaceMetrics.groupGap) {
            if let answer {
                if answer.validity != "current" {
                    Label("依据已变化，这份回答作为历史保留。", systemImage: "pause.circle")
                        .vosFont(WorkspaceText.meta).foregroundStyle(palette.warning)
                }
                if let report = answer.report, !report.isEmpty {
                    WorkspaceExpandableText(text: report, label: "完整回答", lines: 6, size: WorkspaceText.body.size)
                }
                if !answer.inputReferences.isEmpty {
                    VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
                        Text("依据原话").vosFont(WorkspaceText.rowTitle).accessibilityAddTraits(.isHeader)
                        ActionOriginalQuotes(model: model, action: action, openSource: openSource, explicitReferences: answer.inputReferences, quoteLimit: 120)
                    }
                }
                HStack(spacing: 12) {
                    Button("阅读结果", systemImage: "doc.text.magnifyingglass") { openDelivery(answer.id) }
                        .buttonStyle(.workspaceSecondary)
                    Button("重新回答", systemImage: "arrow.clockwise") { ask(fresh: true) }
                        .buttonStyle(.workspaceQuiet)
                        .disabled(model.assistantBusy || !modelReady)
                }
            }
            followupComposer
            if !followups.isEmpty { followupHistory }
            if !error.isEmpty { WorkspaceNoticeText(message: error, severity: .danger) }
        }.padding(.vertical, 16)
    }

    @ViewBuilder private var followupComposer: some View {
        if canFollowup {
            VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
                Text("接着追问").vosFont(WorkspaceText.rowTitle).accessibilityAddTraits(.isHeader)
                HStack(spacing: 10) {
                    TextField("对这份回答继续追问…", text: $followup)
                        .workspaceFieldSurface()
                        .onSubmit { sendFollowup() }
                        .disabled(!modelReady || followupSending)
                        .accessibilityLabel("追问内容")
                    Button("追问") { sendFollowup() }
                        .buttonStyle(.workspaceSecondary)
                        .disabled(!modelReady || followupSending || followup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if !modelReady {
                    HStack(spacing: 8) {
                        Text("追问需要先配置文本模型。").vosFont(WorkspaceText.meta).foregroundStyle(palette.warning)
                        Button("配置文本模型…") { model.chooseTextModel() }.buttonStyle(.workspaceQuiet)
                    }
                }
                if followups.first?.state == "queued" {
                    Label("追问已排队", systemImage: "clock").vosFont(WorkspaceText.meta).foregroundStyle(palette.accent)
                }
            }.padding(.top, 4)
        } else {
            Text(followupUnavailableNote).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
        }
    }

    private var followupUnavailableNote: String {
        if action.validity != "current" { return "依据已变化，暂时不能追问。" }
        if action.state == "completed" { return "这个问题已标记想清楚，暂时不能追问。" }
        return "这个问题已放下；重新打开后才能继续追问。"
    }

    private var followupHistory: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(followups) { record in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(record.instruction).vosFont(WorkspaceText.body).lineLimit(3).textSelection(.enabled)
                            Spacer(minLength: 8)
                            Text(followupStatus(record))
                                .vosFont(WorkspaceText.meta.size, weight: .medium)
                                .foregroundStyle(followupStatusTint(record))
                        }
                        Text(followupDate(record)).vosFont(WorkspaceText.caption).foregroundStyle(palette.secondaryText)
                        if let report = record.report, !report.isEmpty {
                            WorkspaceExpandableText(text: report, label: "完整追问回答", lines: 3, size: WorkspaceText.body.size)
                        } else if ["queued", "reserved", "blocked"].contains(record.state) {
                            Text("排队中，等待 VoiceOS 回答这次追问。").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                        } else if record.state == "running" {
                            Text("VoiceOS 正在回答这次追问。").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                        }
                        if let message = AssistantFailurePresentation.message(record.error) {
                            WorkspaceNoticeText(message: message, severity: .danger)
                        }
                    }.padding(.vertical, 12)
                    if record.id != followups.last?.id { WorkspaceListDivider() }
                }
            }.padding(.top, 10)
        } label: {
            Text("追问记录（\(followups.count)）").vosFont(WorkspaceText.rowTitle)
        }.padding(.top, 4)
    }

    private func followupStatus(_ record: AssistantExecutionRecord) -> String {
        if record.validity != "current" { return "已失效" }
        switch record.state {
        case "queued", "reserved", "blocked": return "排队"
        case "running": return "运行"
        case "completed": return "完成"
        case "failed": return "失败"
        case "cancelled": return "已取消"
        default: return record.state
        }
    }

    private func followupStatusTint(_ record: AssistantExecutionRecord) -> Color {
        switch record.state {
        case "failed", "cancelled": return palette.warning
        case "completed": return record.validity == "current" ? palette.success : palette.secondaryText
        default: return palette.secondaryText
        }
    }

    private func followupDate(_ record: AssistantExecutionRecord) -> String {
        ConversationReflectionFocus.date(record.createdAt)?.formatted(date: .abbreviated, time: .shortened) ?? record.createdAt
    }

    private var failedState: some View {
        VStack(alignment: .leading, spacing: WorkspaceMetrics.groupGap) {
            if let message = AssistantFailurePresentation.message(answer?.error) {
                WorkspaceNoticeText(message: message, severity: .danger)
            } else {
                WorkspaceNoticeText(message: "这次回答没有完成。", severity: .danger)
            }
            HStack(spacing: 12) {
                Button("重试", systemImage: "arrow.clockwise") { retry() }
                    .buttonStyle(.workspaceSecondary)
                    .disabled(model.assistantBusy || !modelReady || answer?.validity != "current")
                if !modelReady {
                    Text("重试需要先配置文本模型。").vosFont(WorkspaceText.meta).foregroundStyle(palette.warning)
                    Button("配置文本模型…") { model.chooseTextModel() }.buttonStyle(.workspaceQuiet)
                }
                if answer?.validity != "current" {
                    Text("依据已变化，旧回答不能重试；可在操作区重新回答。").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                }
            }
            if !error.isEmpty { WorkspaceNoticeText(message: error, severity: .danger) }
        }.padding(.vertical, 16)
    }

    private func ask(fresh: Bool = false) {
        Task {
            if await model.analyzeThought(action, fresh: fresh) { error = "" }
            else { error = model.assistantStatus }
        }
    }

    private func retry() {
        guard let answer else { return }
        Task {
            await model.retryAssistant(answer)
            let queued = model.assistantExecutions.first { $0.id == answer.id }?.state == "queued"
            error = queued ? "" : model.assistantStatus
        }
    }

    private func sendFollowup() {
        let text = followup.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !followupSending else { return }
        followupSending = true
        Task {
            if await model.askFollowup(action, instruction: text) {
                followup = ""; error = ""
            } else { error = model.assistantStatus }
            followupSending = false
        }
    }
}
