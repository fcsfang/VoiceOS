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

    private var latest: AssistantExecutionRecord? {
        model.assistantExecutions.first { $0.actionID == action.id && $0.mode == .analysis }
    }
    private var phase: QuestionAnswerPhase { QuestionAnswerPhase(latest) }
    private var modelReady: Bool { model.modelConfigured }

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
        case .none: return "让 VoiceOS 先回答；答案会保存下来，可以继续追问。"
        case .running: return "回答正在生成，可以继续做别的事。"
        case .completed: return "回答已保存，可以阅读完整结果或继续思考。"
        case .failed: return "这次回答没有完成；可以重试。"
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("这个问题还没有 VoiceOS 的回答。").vosFont(WorkspaceText.body)
            HStack(spacing: 12) {
                Button("让 VoiceOS 回答", systemImage: "sparkles") { ask(fresh: true) }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.assistantBusy || !modelReady)
                if !modelReady {
                    Text("开始回答需要先配置文本模型。").vosFont(WorkspaceText.meta).foregroundStyle(palette.warning)
                    Button("配置文本模型…") { model.chooseTextModel() }.vosFont(WorkspaceText.meta)
                }
            }
            if !error.isEmpty { WorkspaceNoticeText(message: error, severity: .danger) }
        }.padding(.vertical, 16)
    }

    private var runningState: some View {
        HStack(spacing: 14) {
            ProgressView().controlSize(.small)
            Text(latest?.state == "queued" ? "已排队，等待 VoiceOS 回答。" : "VoiceOS 正在回答，完成后会保存在这里。")
        }.padding(.vertical, 30)
    }

    private var completedState: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let latest {
                if latest.validity != "current" {
                    Label("依据已变化，这份回答作为历史保留。", systemImage: "pause.circle")
                        .vosFont(WorkspaceText.meta).foregroundStyle(palette.warning)
                }
                if let report = latest.report, !report.isEmpty {
                    WorkspaceExpandableText(text: report, label: "完整回答", lines: 6, size: WorkspaceText.body.size)
                } else {
                    Text("回答已就绪。").vosFont(WorkspaceText.body)
                }
                if !latest.inputReferences.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("依据原话").vosFont(WorkspaceText.rowTitle).accessibilityAddTraits(.isHeader)
                        ActionOriginalQuotes(model: model, action: action, openSource: openSource, explicitReferences: latest.inputReferences, quoteLimit: 120)
                    }
                }
                HStack(spacing: 12) {
                    Button("阅读结果", systemImage: "doc.text.magnifyingglass") { openDelivery(latest.id) }
                    Button("重新回答", systemImage: "arrow.clockwise") { ask(fresh: true) }
                        .disabled(model.assistantBusy || !modelReady)
                }
            }
        }.padding(.vertical, 16)
    }

    private var failedState: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let message = AssistantFailurePresentation.message(latest?.error) {
                WorkspaceNoticeText(message: message, severity: .danger)
            } else {
                WorkspaceNoticeText(message: "这次回答没有完成。", severity: .danger)
            }
            HStack(spacing: 12) {
                Button("重试", systemImage: "arrow.clockwise") { retry() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.assistantBusy || !modelReady || latest?.validity != "current")
                if !modelReady {
                    Text("重试需要先配置文本模型。").vosFont(WorkspaceText.meta).foregroundStyle(palette.warning)
                    Button("配置文本模型…") { model.chooseTextModel() }.vosFont(WorkspaceText.meta)
                }
                if latest?.validity != "current" {
                    Text("依据已变化，旧回答不能重试；可以在操作区重新回答。").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
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
        guard let latest else { return }
        Task {
            await model.retryAssistant(latest)
            let queued = model.assistantExecutions.first { $0.id == latest.id }?.state == "queued"
            error = queued ? "" : model.assistantStatus
        }
    }
}
