import AppKit
import SwiftUI
import VoiceOSCore

func taskInitiationRouteLabel(_ route: TaskInitiationRoute) -> String {
    switch route {
    case .agentHandoff: "交给 Agent"
    case .guidedStart: "自己动手"
    case .clarify: "先问一个关键问题"
    case .captureOnly: "仅记录"
    }
}

struct TaskInitiationView: View {
    @Environment(\.workspacePalette) private var palette
    @ObservedObject var model: ControlCenter
    let openSource: (String) -> Void
    @State private var selectedID: String?
    @State private var artifactDraft = ""
    @State private var mode = TaskInitiationMode.direct
    @State private var allowCloud = true
    @State private var answer = ""
    @State private var pendingSecretCopy: TaskInitiationRecord?

    private var records: [TaskInitiationRecord] { model.taskInitiations }
    private var selected: TaskInitiationRecord? {
        if let selectedID, let record = records.first(where: { $0.id == selectedID }) { return record }
        return records.first
    }
    private var syncKey: String { (selected?.id ?? "") + "/" + (selected?.updatedAt ?? "") }
    private var materialSources: [SourceRecord] {
        model.records.filter { $0.origin == "user" && $0.speaker == "user" && $0.transcript != nil && !$0.isArchived && !$0.isTrashed }
            .sorted { $0.createdAt > $1.createdAt }
    }
    private var overLimit: Bool { model.initiationText.unicodeScalars.count > 4000 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                WorkspaceHero(eyebrow: "", title: "启动")
                composer
                if let record = selected { package(record) }
                history
            }
            .frame(maxWidth: WorkspaceMetrics.pageWidth, alignment: .leading)
            .padding(WorkspaceMetrics.pagePadding)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .onAppear { artifactDraft = selected?.artifact ?? "" }
        .onChange(of: syncKey) { _, _ in
            artifactDraft = selected?.artifact ?? ""
            answer = ""
        }
        .alert("这份材料可能包含密码、密钥或令牌", isPresented: Binding(
            get: { pendingSecretCopy != nil },
            set: { if !$0 { pendingSecretCopy = nil } }
        ), presenting: pendingSecretCopy) { record in
            Button("取消", role: .cancel) { pendingSecretCopy = nil }
            Button("仍然复制", role: .destructive) { pendingSecretCopy = nil; copy(record) }
        } message: { _ in
            Text(TaskInitiationComposer.secretWarning(in: artifactDraft) ?? "")
        }
    }

    private var composer: some View {
        WorkspaceSection(title: "先说清楚要开始什么", icon: "text.cursor") {
            VStack(alignment: .leading, spacing: 14) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $model.initiationText).font(.body).scrollContentBackground(.hidden).frame(minHeight: 120)
                        .workspaceEditorSurface().accessibilityLabel("要启动的原话")
                        .accessibilityIdentifier("initiation.input")
                    if model.initiationText.isEmpty {
                        Text("例如：老师让我做一份 PPT，我不会，也不知道怎么开始。").font(.body)
                            .foregroundStyle(.tertiary).padding(.horizontal, 15).padding(.vertical, 16).allowsHitTesting(false)
                    }
                }
                HStack(spacing: 12) {
                    Menu("从最近材料带入") {
                        if materialSources.isEmpty { Button("还没有可用的个人原话") {}.disabled(true) }
                        ForEach(materialSources.prefix(20)) { source in
                            Button(source.displayTitle) {
                                model.initiationText = source.transcript ?? ""
                                model.initiationSourceID = source.id
                            }
                        }
                    }.fixedSize()
                    Spacer()
                    Text("\(model.initiationText.unicodeScalars.count) / 4000 字").font(.caption.monospacedDigit())
                        .foregroundStyle(overLimit ? palette.danger : .secondary)
                }
                Picker("生成方式", selection: $mode) {
                    Text("直接给草稿").tag(TaskInitiationMode.direct)
                    Text("先问一个关键问题").tag(TaskInitiationMode.interactive)
                }.pickerStyle(.segmented)
                Toggle("允许发送给云端模型", isOn: $allowCloud)
                Text("生成时会先把这段原话保存为你的材料，只把这段文字发送给模型；不会读取仓库、文件或其他材料，也不会创建任务或提醒。")
                    .font(.caption).foregroundStyle(.secondary)
                if !model.modelConfigured {
                    Text("尚未配置文本模型；请先在设置中连接模型。").font(.caption).foregroundStyle(palette.warning)
                }
                HStack(spacing: 12) {
                    Button(model.initiationBusy ? "正在生成…" : "生成启动材料") {
                        Task { await model.generateTaskInitiation(text: model.initiationText, sourceID: model.initiationSourceID, mode: mode, allowCloud: allowCloud) }
                    }
                    .buttonStyle(.borderedProminent).tint(palette.accent)
                    .disabled(model.initiationBusy || !model.modelConfigured || !allowCloud)
                    .accessibilityIdentifier("initiation.generate")
                    if model.initiationBusy { ProgressView().controlSize(.small) }
                    Spacer()
                }
                if !model.initiationStatus.isEmpty {
                    Text(model.initiationStatus).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
    }

    private func package(_ record: TaskInitiationRecord) -> some View {
        WorkspaceSection(title: "这次要启动的事", icon: "arrow.up.forward") {
            VStack(alignment: .leading, spacing: 16) {
                sourceLine(record)
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(taskInitiationRouteLabel(record.route)).font(.caption).foregroundStyle(palette.accent)
                        Text(record.proposal.title.isEmpty ? "尚未命名这次启动" : record.proposal.title)
                            .vosFont(21, weight: .semibold).textSelection(.enabled)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 6) {
                        statusChip(stateLabel(record))
                        if record.copiedAt != nil { statusChip("已复制 · 复制不代表已执行") }
                    }
                }
                if record.basisChanged {
                    WorkspaceNoticeText(message: "原话已更正，材料仍保留但依据已变化。", severity: .warning)
                }
                if record.state == "draft" { routePicker(record) }
                if record.isClarifying { clarify(record) }
                else if record.route == .captureOnly { captureOnly(record) }
                else { artifactEditor(record) }
            }
        }
    }

    private func sourceLine(_ record: TaskInitiationRecord) -> some View {
        let title = model.records.first(where: { $0.id == record.sourceID })?.displayTitle ?? "原话材料"
        return Button("依据：" + title) { openSource(record.sourceID) }.buttonStyle(.borderless).font(.caption)
    }

    private func routePicker(_ record: TaskInitiationRecord) -> some View {
        Picker("启动路线", selection: Binding(get: { record.route }, set: { route in
            Task { await model.switchTaskInitiationRoute(record, to: route) }
        })) {
            Text("交给 Agent").tag(TaskInitiationRoute.agentHandoff)
            Text("自己动手").tag(TaskInitiationRoute.guidedStart)
            Text("仅记录").tag(TaskInitiationRoute.captureOnly)
        }.pickerStyle(.segmented).disabled(model.initiationBusy)
            .accessibilityIdentifier("initiation.route")
    }

    private func clarify(_ record: TaskInitiationRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(record.proposal.clarifyQuestion).vosFont(18, weight: .semibold).textSelection(.enabled)
            Text("先回答这一个问题会更准确；也可以跳过，按显式假设给出草稿。").font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $answer).font(.body).scrollContentBackground(.hidden).frame(minHeight: 100)
                .workspaceEditorSurface().accessibilityLabel("澄清回答")
            HStack(spacing: 12) {
                Button(model.initiationBusy ? "正在整理…" : "按这个回答生成") {
                    Task { await model.answerTaskInitiation(record, answer: answer) }
                }.buttonStyle(.borderedProminent).tint(palette.accent)
                    .disabled(model.initiationBusy || answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("先不问，按假设生成") {
                    Task { await model.skipTaskInitiationClarification(record) }
                }.disabled(model.initiationBusy)
                Spacer()
            }
            statusText
        }
    }

    private func captureOnly(_ record: TaskInitiationRecord) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("已按你的意思仅记录，没有生成提示词、教程或任务。").font(.callout).textSelection(.enabled)
            HStack {
                discardButton(record)
                Spacer()
            }
            statusText
        }
    }

    private func artifactEditor(_ record: TaskInitiationRecord) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("执行偏好", selection: Binding(get: { record.proposal.preference }, set: { preference in
                Task { await model.setTaskInitiationPreference(record, preference: preference) }
            })) {
                Text("快速交付").tag(TaskInitiationPreference.quickDelivery)
                Text("边做边学").tag(TaskInitiationPreference.learnWhileDoing)
            }.pickerStyle(.segmented).frame(maxWidth: 300)
                .disabled(model.initiationBusy || record.editedArtifact != nil || record.isConfirmed)
            if record.editedArtifact != nil {
                Text("材料已手动编辑，偏好不再自动调整。").font(.caption).foregroundStyle(.secondary)
            }
            TextEditor(text: $artifactDraft).vosFont(14).frame(minHeight: 360)
                .workspaceEditorSurface().accessibilityLabel("启动材料")
            if let warning = TaskInitiationComposer.secretWarning(in: artifactDraft) {
                WorkspaceNoticeText(message: warning, severity: .warning)
            }
            HStack(spacing: 12) {
                Button("复制") { requestCopy(record) }.buttonStyle(.borderedProminent).tint(palette.accent)
                    .disabled(model.initiationBusy || artifactDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("initiation.copy")
                Button("确认这是我要的") {
                    Task { await model.confirmTaskInitiation(record, artifact: artifactDraft) }
                }
                .disabled(model.initiationBusy || record.isConfirmed || artifactDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("initiation.confirm")
                if record.isConfirmed {
                    Text("已确认 · 尚未执行").font(.caption).foregroundStyle(.secondary)
                } else {
                    discardButton(record)
                }
                Spacer()
            }
            statusText
        }
    }

    private func discardButton(_ record: TaskInitiationRecord) -> some View {
        Button("不保存这条启动记录") { Task { await model.discardTaskInitiation(record) } }
            .disabled(model.initiationBusy)
            .accessibilityIdentifier("initiation.discard")
    }

    private func statusChip(_ text: String) -> some View {
        Text(text).vosFont(12, weight: .medium).foregroundStyle(.secondary)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(palette.selection, in: Capsule())
    }

    @ViewBuilder private var statusText: some View {
        if !model.initiationStatus.isEmpty {
            Text(model.initiationStatus).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    private var history: some View {
        WorkspaceSection(title: "启动记录", subtitle: "生成过的材料都在这里；复制只代表已带走，不代表已经执行。", icon: "clock", count: records.count) {
            if records.isEmpty {
                Text("还没有启动记录。生成过的交接提示词、教程或澄清问题会出现在这里。")
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 14)
            } else {
                ForEach(records) { record in
                    Button { selectedID = record.id } label: {
                        HStack(alignment: .top, spacing: 14) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(record.proposal.title.isEmpty ? "未命名启动" : record.proposal.title)
                                    .vosFont(15, weight: .semibold).lineLimit(2)
                                Text(historySubtitle(record))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            if record.id == selected?.id {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(palette.accent)
                            }
                        }
                        .padding(.vertical, 12).padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("initiation.history.item")
                    .workspaceHoverHighlight()
                    if record.id != records.last?.id { Divider() }
                }
            }
        }
    }

    private func stateLabel(_ record: TaskInitiationRecord) -> String {
        if record.isClarifying { return "待澄清" }
        if record.isConfirmed { return "已确认" }
        return record.route == .captureOnly ? "已记录" : "草稿"
    }

    private func historySubtitle(_ record: TaskInitiationRecord) -> String {
        var parts = [taskInitiationRouteLabel(record.route), stateLabel(record)]
        if record.copiedAt != nil { parts.append("已复制") }
        parts.append(dateLabel(record.createdAt))
        return parts.joined(separator: " · ")
    }

    private func dateLabel(_ text: String) -> String {
        ConversationReflectionFocus.date(text)?.formatted(date: .abbreviated, time: .shortened) ?? text
    }

    private func requestCopy(_ record: TaskInitiationRecord) {
        if TaskInitiationComposer.secretWarning(in: artifactDraft) != nil { pendingSecretCopy = record }
        else { copy(record) }
    }

    private func copy(_ record: TaskInitiationRecord) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(artifactDraft, forType: .string)
        Task { await model.markTaskInitiationCopied(record, artifact: artifactDraft) }
    }
}
