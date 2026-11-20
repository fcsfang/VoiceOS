import SwiftUI
import AppKit
import UniformTypeIdentifiers
import VoiceOSCore

struct AssistantSheetSelection: Identifiable {
    let executionID: String?
    var id: String { executionID ?? "all" }
}

func assistantExecutionLabel(_ execution: AssistantExecutionRecord) -> String {
    if execution.validity != "current" { return "依据已变化 · 暂停使用" }
    let analysis = execution.mode == .analysis
    switch execution.state {
    case "queued": return analysis ? "等待分析" : "已排队"
    case "running": return analysis ? "正在分析" : "正在执行"
    case "completed": return analysis ? "分析已就绪" : "成果已就绪"
    case "failed": return analysis ? "分析未完成" : "需要重试"
    case "cancelled": return "已取消"
    default: return execution.state
    }
}

/// Delegation is a separate, explicit action; extraction alone never authorizes execution.
struct AssistantDelegationView: View {
    @Environment(\.workspacePalette) private var palette
    let action: ActionRecord
    @ObservedObject var model: ControlCenter
    let dismiss: () -> Void
    @State private var instruction = ""
    @State private var questionID = ""
    @State private var questions: [ReflectionQuestion] = []
    @State private var saving = false
    @State private var error = ""
    @State private var allowCloud = false
    private var taskSources: [SourceRecord] {
        let ids = Set(model.claims.first(where: { $0.id == action.claimID })?.references.map(\.sourceID) ?? [])
        return model.records.filter { ids.contains($0.id) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("交给 AI 助理", systemImage: "sparkles").vosFont(WorkspaceText.sectionTitle)
            Text(action.title).vosFont(WorkspaceText.rowTitle).textSelection(.enabled)
            Text("写下你想要的结果。应用会调研、比较或起草；可以关闭窗口，稍后回来查看。").vosFont(WorkspaceText.body).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
                Text("交付要求").vosFont(WorkspaceText.rowTitle)
                TextEditor(text: $instruction).vosFont(WorkspaceText.body).frame(height: 190)
                    .padding(8).background(palette.surface, in: RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
                    .overlay { RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius).stroke(palette.accent.opacity(0.2)) }
            }
            Picker("关联主题", selection: $questionID) {
                Text("暂不关联").tag("")
                ForEach(questions) { Text($0.title).tag($0.id) }
            }
            Text("本次使用完整任务原文与交付要求。关联主题用于保存成果；AI 产出、实际任务完成情况和你的认识分别保留。").vosFont(WorkspaceText.caption).foregroundStyle(.secondary)
            DisclosureGroup("本次使用的任务原文 · \(taskSources.count) 份") {
                ScrollView {
                    VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
                        ForEach(taskSources) { source in
                            Text(source.displayTitle).vosFont(WorkspaceText.rowTitle)
                            Text(source.transcript ?? "尚无可用文字").textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }.frame(maxHeight: 150)
            }
            Toggle("允许交付要求与以上完整任务原文用于云端代办", isOn: $allowCloud).vosFont(WorkspaceText.body)
            if !error.isEmpty { Text(error).vosFont(WorkspaceText.meta).foregroundStyle(palette.danger).textSelection(.enabled) }
            HStack {
                Button("取消", action: dismiss).buttonStyle(.workspaceSecondary).disabled(saving)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("委托并开始") {
                    saving = true; error = ""
                    Task {
                        if await model.enqueueAssistant(action, instruction: instruction, questionID: questionID.isEmpty ? nil : questionID, allowCloud: allowCloud) { dismiss() }
                        else { error = InlineFailurePresentation.message(operation: "委托", reason: model.assistantStatus.isEmpty ? model.status : model.assistantStatus) }
                        saving = false
                    }
                }.buttonStyle(.workspacePrimary)
                    .disabled(saving || !allowCloud || !model.modelConfigured || instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if !model.modelConfigured { Text("先配置模型连接，才能开始代办。").vosFont(WorkspaceText.meta).foregroundStyle(.secondary) }
        }.padding(24).frame(width: WorkspaceMetrics.modalSmall)
            .background(palette.canvas)
            .interactiveDismissDisabled(saving)
            .task {
                instruction = action.title + "\n\n请给出清晰的结论和可用的交付物；调研时附可核查的来源，并说明尚不能确定的地方。"
                do { questions = try await model.loadReflectionQuestions() }
                catch { self.error = InlineFailurePresentation.message(operation: "读取主题", reason: error.localizedDescription) }
            }
    }
}

private enum ExecutionCommand: String, Identifiable {
    case cancel, retry
    var id: String { rawValue }
}

struct AssistantExecutionView: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(\.vosTextScale) private var textScale
    @ObservedObject var model: ControlCenter
    var initialExecutionID: String? = nil
    let dismiss: () -> Void
    @State private var selectedID: String?
    @State private var questions: [ReflectionQuestion] = []
    @State private var questionID = ""
    @State private var showingDiscussion = false
    @State private var saving = false
    @State private var error = ""
    @State private var includeCancelled = false
    @State private var feedbackAction: ActionRecord?
    @State private var confirmingCommand: ExecutionCommand?
    private var visible: [AssistantExecutionRecord] { model.assistantExecutions.filter { includeCancelled || $0.state != "cancelled" } }
    private var selected: AssistantExecutionRecord? { visible.first { $0.id == selectedID } ?? visible.first }
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                WorkspaceHero(eyebrow: "YOUR ASSISTANT", title: "把事情，推进到有结果", subtitle: "明确委托，查看成果，再带回自己的主题与行动。")
                Spacer()
                Button("完成", action: dismiss).buttonStyle(.workspaceSecondary).keyboardShortcut(.cancelAction)
            }.padding(24)
            WorkspaceListDivider()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("代办与成果").vosFont(WorkspaceText.rowTitle)
                    Toggle("显示已取消", isOn: $includeCancelled).vosFont(WorkspaceText.meta)
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(visible) { execution in
                                Button {
                                    selectedID = execution.id; questionID = execution.questionID ?? ""; error = ""
                                } label: {
                                    WorkspaceCard(padding: 14, radius: WorkspaceMetrics.panelRadius) {
                                        VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
                                            Text(.init(execution.title)).vosFont(WorkspaceText.rowTitle).lineLimit(3)
                                            Text(assistantExecutionLabel(execution)).vosFont(WorkspaceText.meta).foregroundStyle(execution.state == "failed" ? palette.warning : .secondary)
                                        }
                                        .background(selected?.id == execution.id ? palette.selection : .clear, in: RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
                                    }
                                    .overlay {
                                        if selected?.id == execution.id {
                                            RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius).stroke(palette.accent.opacity(0.5))
                                        }
                                    }
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }.padding(18).frame(width: 250 * vosLayoutScale(textScale))
                Divider()
                if let execution = selected { detail(execution) }
                else {
                    WorkspaceEmptyState(title: "还没有代办或成果", systemImage: "sparkles",
                                        description: "在行动页的任务里点「交给 AI」开始；调研、比较或起草的结果会回到这里。")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            WorkspaceListDivider()
            HStack {
                if model.assistantBusy { ProgressView().controlSize(.small) }
                Text(model.assistantStatus).vosFont(WorkspaceText.meta).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
            }.padding(.horizontal, 24).padding(.vertical, 10)
        }.foregroundStyle(palette.text).background(palette.canvas).frame(width: 1030, height: 730)
            .sheet(isPresented: $showingDiscussion) { DiscussionView(model: model) { showingDiscussion = false } }
            .sheet(item: $feedbackAction) { action in ActionFeedbackView(action: action, model: model) { feedbackAction = nil } }
            .task {
                selectedID = initialExecutionID ?? visible.first?.id
                do { questions = try await model.loadReflectionQuestions() }
                catch { self.error = InlineFailurePresentation.message(operation: "读取主题", reason: error.localizedDescription) }
                questionID = selected?.questionID ?? ""
            }
    }
    private func detail(_ execution: AssistantExecutionRecord) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(.init(execution.title)).vosFont(WorkspaceText.sectionTitle).textSelection(.enabled)
            HStack {
                Label(assistantExecutionLabel(execution), systemImage: execution.state == "completed" ? "doc.text" : execution.state == "failed" ? "exclamationmark.circle" : "hourglass")
                    .vosFont(WorkspaceText.meta).foregroundStyle(palette.accent)
                Spacer()
                if ["queued", "running"].contains(execution.state) {
                    Button("取消代办") { confirmingCommand = .cancel }.buttonStyle(.workspaceSecondary).disabled(saving)
                }
                if execution.validity == "current", ["failed", "cancelled"].contains(execution.state) {
                    Button("重新执行") { confirmingCommand = .retry }.buttonStyle(.workspaceQuiet).disabled(saving)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    DisclosureGroup("本次交付要求") { Text(execution.instruction).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6) }
                    if execution.validity != "current" {
                        Label("原始任务或资料已有变化。保留这份历史成果，接续使用前请核对当前依据。", systemImage: "pause.circle").vosFont(WorkspaceText.meta).foregroundStyle(palette.warning)
                    }
                    if let report = execution.report, !report.isEmpty {
                        VStack(alignment: .leading, spacing: WorkspaceMetrics.groupGap) {
                            HStack {
                                Text("AI 交付物").vosFont(WorkspaceText.rowTitle).foregroundStyle(palette.accent)
                                Spacer()
                                Button("保存完整报告…") { exportReport(execution) }.buttonStyle(.workspaceSecondary)
                            }
                            AssistantReportView(report: report)
                            DisclosureGroup("查看完整报告原文") {
                                Text(verbatim: report).vosFont(WorkspaceText.body.size, design: .monospaced).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                            }.vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                        }
                        if !execution.references.isEmpty {
                            WorkspaceListDivider()
                            Text("可核查的来源").vosFont(WorkspaceText.rowTitle)
                            ForEach(Array(execution.references.enumerated()), id: \.offset) { _, reference in
                                if let url = URL(string: reference.url), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Link(reference.title.isEmpty ? reference.url : reference.title, destination: url).tint(palette.accent)
                                        Text(reference.url).vosFont(WorkspaceText.meta).foregroundStyle(.secondary).textSelection(.enabled)
                                    }
                                }
                            }
                        }
                    } else if ["queued", "running"].contains(execution.state) {
                        VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
                            ProgressView().controlSize(.small)
                            Text(execution.state == "queued" ? "委托已保存，等待应用执行。" : "正在完成交付要求，成果准备好后会保存在这里。")
                            Text("可以关闭窗口；VoiceOS 需要保持运行。").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                        }.padding(.vertical, 20)
                    }
                    if let message = execution.error, !message.isEmpty {
                        Text(InlineFailurePresentation.message(operation: "代办", reason: message)).foregroundStyle(palette.danger).textSelection(.enabled)
                    }
                    Text("这是 AI 产出。它不会自动成为你的观点，也不会把原任务标为完成；采纳与实际结果可以在后续记录。").vosFont(WorkspaceText.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if execution.state == "completed", execution.validity == "current" {
                WorkspaceListDivider()
                HStack {
                    Picker("接回主题", selection: $questionID) {
                        Text("选择主题").tag("")
                        ForEach(questions) { Text($0.title).tag($0.id) }
                    }.frame(maxWidth: 340)
                    Button("关联成果") {
                        saving = true; error = ""
                        Task {
                            if !(await model.attachAssistantResult(execution, questionID: questionID)) { error = InlineFailurePresentation.message(operation: "关联成果", reason: model.assistantStatus) }
                            saving = false
                        }
                    }.buttonStyle(.workspacePrimary).disabled(questionID.isEmpty || saving)
                    Spacer()
                    if let action = model.actionRecords.first(where: { $0.id == execution.actionID && $0.validity == "current" }) {
                        Button("记录使用结果") { feedbackAction = action }.buttonStyle(.workspaceSecondary).disabled(model.savingFeedback)
                    }
                    Button("带着成果继续讨论") {
                        Task { if await model.beginAssistantDiscussion(execution) { showingDiscussion = true } }
                    }.buttonStyle(.workspaceSecondary)
                        .disabled(model.discussionSaving || model.discussionSending || model.discussionExtracting || model.dictationActive || saving)
                }
                if execution.questionID != nil { Text("成果已关联主题。").vosFont(WorkspaceText.meta).foregroundStyle(.secondary) }
            }
            if !error.isEmpty { Text(error).vosFont(WorkspaceText.meta).foregroundStyle(palette.danger).textSelection(.enabled) }
        }.padding(22).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .alert(confirmingCommand == .cancel ? "取消这次代办？" : "重新执行这次代办？",
                   isPresented: Binding(get: { confirmingCommand != nil }, set: { if !$0 { confirmingCommand = nil } })) {
                if confirmingCommand == .cancel {
                    Button("取消代办", role: .destructive) {
                        guard !saving else { return }
                        saving = true
                        Task { await model.cancelAssistant(execution); saving = false }
                    }.disabled(saving)
                } else {
                    Button("重新执行") {
                        guard !saving else { return }
                        saving = true
                        Task { await model.retryAssistant(execution); saving = false }
                    }.disabled(saving)
                }
                Button("返回", role: .cancel) {}
            } message: {
                Text(confirmingCommand == .cancel ? "取消后这次代办不再继续；已保存的交付要求会保留。" : "重新执行会再调用一次模型，可能产生新的用量。")
            }
    }
    private func exportReport(_ execution: AssistantExecutionRecord) {
        guard let report = execution.report else { return }
        let panel = NSSavePanel()
        panel.title = "保存完整 AI 报告"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = execution.title.replacingOccurrences(of: "/", with: "-") + ".md"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let citations = execution.references.map { "- [\($0.title.isEmpty ? $0.url : $0.title)](\($0.url))" }.joined(separator: "\n")
                let text = report + (citations.isEmpty ? "" : "\n\n## 可核查的来源\n\n" + citations) + "\n\n---\nAI 交付物，不代表用户观点。\n"
                try text.write(to: url, atomically: true, encoding: .utf8)
                model.assistantStatus = "完整报告与来源已保存"
            } catch { self.error = InlineFailurePresentation.message(operation: "保存报告", reason: error.localizedDescription) }
        }
    }
}

struct AssistantReportView: View {
    @Environment(\.workspacePalette) private var palette
    let report: String
    private struct Block {
        let text: String
        let heading: Int
        let literal: Bool
    }
    private var blocks: [Block] {
        var result: [Block] = [], paragraph: [String] = []
        var fenced = false
        func flush() {
            guard !paragraph.isEmpty else { return }
            let text = paragraph.joined(separator: "\n")
            let table = paragraph.filter { $0.contains("|") }.count >= 2
            result.append(Block(text: text, heading: 0, literal: fenced || table))
            paragraph = []
        }
        for line in report.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flush()
                fenced.toggle()
                continue
            }
            if fenced { paragraph.append(line); continue }
            if trimmed.isEmpty { flush(); continue }
            let level = trimmed.prefix(while: { $0 == "#" }).count
            if (1...3).contains(level), trimmed.dropFirst(level).first == " " {
                flush()
                result.append(Block(text: String(trimmed.dropFirst(level + 1)), heading: level, literal: false))
            } else { paragraph.append(line) }
        }
        flush()
        return result
    }
    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                if block.literal {
                    ScrollView(.horizontal) {
                        Text(verbatim: block.text).vosFont(WorkspaceText.body.size, design: .monospaced).lineSpacing(5).textSelection(.enabled)
                            .padding(16)
                    }.background(palette.canvas, in: RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
                        .overlay { RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius).strokeBorder(palette.border,lineWidth:1) }
                } else {
                    Text(inline(block.text))
                        .vosFont(block.heading == 1 ? WorkspaceText.pageTitle : block.heading > 0 ? WorkspaceText.sectionTitle : WorkspaceText.body)
                        .lineSpacing(block.heading > 0 ? 3 : 6)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, block.heading > 0 ? 18 : 0)
                        .accessibilityAddTraits(block.heading > 0 ? [.isHeader] : [])
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
