import AppKit
import SwiftUI
import VoiceOSCore

func taskInitiationRouteLabel(_ route: TaskInitiationRoute) -> String {
    switch route {
    case .agentHandoff: "交给 Agent"
    case .guidedStart: "自己动手"
    case .clarify: "先问一个关键问题"
    case .captureOnly: "仅记录"
    case .answer: "直接回答"
    }
}

struct TaskInitiationView: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: ControlCenter
    let openSource: (String) -> Void
    @State private var selectedID: String?
    @State private var artifactDraft = ""
    @AppStorage("voiceos.initiation.mode") private var mode = TaskInitiationMode.direct
    @AppStorage("voiceos.initiation.allowCloud") private var allowCloud = true
    @AppStorage("voiceos.initiation.preference") private var preference = TaskInitiationPreference.quickDelivery
    @State private var answer = ""
    @State private var directAnswers: [String: String] = [:]
    @State private var pendingSecretCopy: TaskInitiationRecord?
    @State private var stepDraft = ""
    @State private var stepStatus = ""
    @State private var stepSaving = false
    @State private var stepCommandID = UUID().uuidString
    @State private var stepsByRecord: [String: [TaskInitiationStep]] = [:]
    @State private var archivedRecords: [TaskInitiationRecord] = []
    @State private var showArchived = false

    private var records: [TaskInitiationRecord] { model.taskInitiations }
    private var visibleRecords: [TaskInitiationRecord] { showArchived ? archivedRecords : records }
    private var selected: TaskInitiationRecord? {
        guard let selectedID else { return nil }
        return (records + archivedRecords).first(where: { $0.id == selectedID })
    }
    private var syncKey: String { (selected?.id ?? "") + "/" + (selected?.updatedAt ?? "") }
    private var materialSources: [SourceRecord] {
        model.records.filter { $0.origin == "user" && $0.speaker == "user" && $0.transcript != nil && !$0.isArchived && !$0.isTrashed }
            .sorted { $0.createdAt > $1.createdAt }
    }
    private var overLimit: Bool { model.initiationText.unicodeScalars.count > 4000 }
    private let packageAnchor = "initiation.package"
    /// One primary per state: the composer yields to the package's own action.
    private var generateStyle: WorkspaceButtonStyle {
        guard let record = selected else { return .workspacePrimary }
        return record.route == .captureOnly && !record.isClarifying ? .workspacePrimary : .workspaceSecondary
    }

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: WorkspaceMetrics.sectionGap) {
                    WorkspacePageHeading(title: "启动")
                    composer
                    if let record = selected { package(record).id(packageAnchor) }
                    history
                }
                .frame(maxWidth: WorkspaceMetrics.pageWidth, alignment: .leading)
                .padding(WorkspaceMetrics.pagePadding)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .onChange(of: selectedID) { _, _ in
                stepDraft = ""
                stepStatus = ""
                stepCommandID = UUID().uuidString
                guard selectedID != nil else { return }
                DispatchQueue.main.async { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { reader.scrollTo(packageAnchor, anchor: .top) } }
            }
        }
        .onAppear {
            artifactDraft = selected?.artifact ?? ""
            reloadSteps()
        }
        .onChange(of: records.map(\.id)) { _, _ in
            reloadSteps()
        }
        .onChange(of: showArchived) { _, shown in
            if shown { reloadArchived() }
        }
        .onChange(of: syncKey) { _, _ in
            artifactDraft = selected?.artifact ?? ""
            answer = ""
        }
        .onChange(of: stepDraft) { _, _ in stepCommandID = UUID().uuidString }
        .alert("这份材料可能包含密码、密钥或令牌", isPresented: Binding(
            get: { pendingSecretCopy != nil },
            set: { if !$0 { pendingSecretCopy = nil } }
        ), presenting: pendingSecretCopy) { record in
            Button("取消", role: .cancel) { pendingSecretCopy = nil }
            Button("仍然复制", role: .destructive) { pendingSecretCopy = nil; copy(record) }
        } message: { record in
            Text(TaskInitiationComposer.secretWarning(in: record.route == .answer ? record.proposal.answer : artifactDraft) ?? "")
        }
    }

    private var composer: some View {
        WorkspaceCard(padding: 18, radius: 8) {
            VStack(alignment: .leading, spacing: 14) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $model.initiationText).vosFont(WorkspaceText.body).scrollContentBackground(.hidden).frame(minHeight: 120)
                        .padding(10).accessibilityLabel("要启动的原话")
                        .accessibilityIdentifier("initiation.input")
                    if model.initiationText.isEmpty {
                        Text("你想了解什么，或从哪里开始？").vosFont(WorkspaceText.body)
                            .foregroundStyle(palette.tertiaryText).padding(.horizontal, 15).padding(.vertical, 16).allowsHitTesting(false)
                    }
                }
                HStack(spacing: 12) {
                    if !materialSources.isEmpty {
                        Menu {
                            ForEach(materialSources.prefix(20)) { source in
                                Button(source.displayTitle) {
                                    model.initiationText = source.transcript ?? ""
                                    model.initiationSourceID = source.id
                                }
                            }
                        } label: {
                            Text("从最近材料带入")
                        }.menuStyle(.button).buttonStyle(.workspaceSecondary).fixedSize()
                    }
                    Spacer()
                    if !model.initiationText.isEmpty {
                        Text("\(model.initiationText.unicodeScalars.count) / 4000 字").vosFont(WorkspaceText.caption.size, monospacedDigit: true)
                            .foregroundStyle(overLimit ? palette.danger : palette.tertiaryText)
                    }
                }
                Picker("生成方式", selection: $mode) {
                    Text("直接给草稿").tag(TaskInitiationMode.direct)
                    Text("先问一个关键问题").tag(TaskInitiationMode.interactive)
                }.pickerStyle(.segmented).fixedSize(horizontal: true, vertical: false)
                if !model.modelConfigured {
                    Text("尚未配置文本模型；请先在设置中连接模型。").vosFont(WorkspaceText.meta).foregroundStyle(palette.warning)
                }
                HStack(spacing: 12) {
                    Toggle("允许将这段文字发送给云端模型", isOn: $allowCloud)
                    Spacer()
                    Button(model.initiationBusy ? "正在处理…" : (mode == .direct ? "生成草稿" : "开始讨论")) { generate() }
                    .buttonStyle(generateStyle)
                    .disabled(model.initiationBusy || !model.modelConfigured || !allowCloud)
                    .accessibilityIdentifier("initiation.generate")
                    if model.initiationBusy { ProgressView().controlSize(.small) }
                }
                if !model.initiationStatus.isEmpty {
                    Text(model.initiationStatus).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).textSelection(.enabled)
                }
            }
        }
    }

    private func package(_ record: TaskInitiationRecord) -> some View {
        WorkspaceSection(title: record.route == .answer ? "这次的问题" : "这次要启动的事", icon: "arrow.up.forward") {
            VStack(alignment: .leading, spacing: WorkspaceMetrics.groupGap) {
                sourceLine(record)
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
                        Text(taskInitiationRouteLabel(record.route)).vosFont(WorkspaceText.meta).foregroundStyle(palette.accent)
                        Text(record.proposal.title.isEmpty ? "尚未命名这次启动" : record.proposal.title)
                            .vosFont(WorkspaceText.sectionTitle).accessibilityAddTraits(.isHeader).textSelection(.enabled)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: WorkspaceMetrics.rowGap) {
                        statusChip(stateLabel(record), tone: record.isConfirmed ? .accent : .neutral)
                        if record.copiedAt != nil {
                            statusChip(record.route == .answer ? "已复制回答" : "已复制 · 复制不代表已执行", tone: .accent)
                        }
                    }
                }
                if record.basisChanged {
                    WorkspaceNoticeText(message: "原话已更正，材料仍保留但依据已变化。", severity: .warning)
                }
                if record.state == "draft", record.route != .answer { routePicker(record) }
                if record.isClarifying { clarify(record) }
                else if record.route == .captureOnly { captureOnly(record) }
                else if record.route == .answer { answerCard(record) }
                else { artifactEditor(record) }
                directAnswerSection(record)
                if let steps = stepsByRecord[record.id], !steps.isEmpty { stepsList(steps) }
            }
        }
    }

    private func sourceLine(_ record: TaskInitiationRecord) -> some View {
        let title = model.records.first(where: { $0.id == record.sourceID })?.displayTitle ?? "原话材料"
        return Button("依据：" + title) { openSource(record.sourceID) }.buttonStyle(.workspaceQuiet)
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
            Text(record.proposal.clarifyQuestion).vosFont(WorkspaceText.sectionTitle).accessibilityAddTraits(.isHeader).textSelection(.enabled)
            TextEditor(text: $answer).vosFont(WorkspaceText.body).scrollContentBackground(.hidden).frame(minHeight: 100)
                .workspaceEditorSurface().accessibilityLabel("澄清回答")
            HStack(spacing: 12) {
                Button(model.initiationBusy ? "正在整理…" : "按这个回答生成") {
                    Task { await model.answerTaskInitiation(record, answer: answer) }
                }.buttonStyle(.workspacePrimary)
                    .disabled(model.initiationBusy || answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("先不问，按假设生成") {
                    Task { await model.skipTaskInitiationClarification(record) }
                }.buttonStyle(.workspaceSecondary)
                    .disabled(model.initiationBusy)
                Spacer()
            }
            statusText
        }
    }

    private func captureOnly(_ record: TaskInitiationRecord) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("已按你的意思仅记录，没有生成提示词、教程或任务。").vosFont(WorkspaceText.body).textSelection(.enabled)
            HStack {
                discardButton(record)
                Spacer()
            }
            statusText
        }
    }

    private func answerCard(_ record: TaskInitiationRecord) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(record.proposal.answer).vosFont(WorkspaceText.body).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(palette.selection, in: RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
                .overlay { RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius).strokeBorder(palette.border, lineWidth: 1) }
            HStack(spacing: 12) {
                Button("复制回答") { requestCopy(record) }
                    .buttonStyle(.workspacePrimary)
                    .disabled(model.initiationBusy || record.proposal.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("initiation.answer.copy")
                if record.isConfirmed {
                    Text("已保存 · 仅作为回答记录").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                    if record.isArchived { statusChip("已归档") }
                } else {
                    Button("归档保存") { saveAnswer(record) }
                        .buttonStyle(.workspaceSecondary)
                        .disabled(model.initiationBusy)
                        .accessibilityIdentifier("initiation.answer.archive")
                    discardButton(record)
                }
                Spacer()
            }
            statusText
        }
    }

    private func saveAnswer(_ record: TaskInitiationRecord) {
        Task {
            if await model.confirmTaskInitiation(record, artifact: record.proposal.answer) {
                selectedID = nil
                if showArchived { reloadArchived() }
            }
        }
    }

    private func directAnswerSection(_ record: TaskInitiationRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            WorkspaceListDivider()
            HStack(spacing: 12) {
                Button(model.initiationBusy ? "正在回答…" : "直接回答") { askDirect(record) }
                    .buttonStyle(.workspaceQuiet)
                    .disabled(model.initiationBusy || !model.modelConfigured || !allowCloud)
                    .accessibilityIdentifier("initiation.answer")
                Text("直接要一份回答，不创建任务或提醒。")
                    .vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                Spacer()
            }
            if let reply = directAnswers[record.id] {
                Text(reply).vosFont(WorkspaceText.body).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(palette.selection, in: RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
                    .overlay { RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius).strokeBorder(palette.border, lineWidth: 1) }
                HStack {
                    Button("复制这段回答") { copyText(reply) }.buttonStyle(.workspaceQuiet)
                    Spacer()
                }
            }
        }
    }

    private func askDirect(_ record: TaskInitiationRecord) {
        Task {
            if let reply = await model.directAnswerTaskInitiation(record, allowCloud: allowCloud) {
                directAnswers[record.id] = reply
            }
        }
    }

    private func copyText(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }

    private func artifactEditor(_ record: TaskInitiationRecord) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("执行偏好", selection: Binding(get: { record.proposal.preference }, set: { value in
                Task {
                    if await model.setTaskInitiationPreference(record, preference: value) { self.preference = value }
                }
            })) {
                Text("快速交付").tag(TaskInitiationPreference.quickDelivery)
                Text("边做边学").tag(TaskInitiationPreference.learnWhileDoing)
            }.pickerStyle(.segmented).frame(maxWidth: 300)
                .disabled(model.initiationBusy || record.editedArtifact != nil || record.isConfirmed)
            if record.editedArtifact != nil {
                Text("已手动编辑，偏好不再自动调整。").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
            }
            TextEditor(text: $artifactDraft).vosFont(WorkspaceText.body).frame(minHeight: 360)
                .workspaceEditorSurface().accessibilityLabel("启动材料")
            if let warning = TaskInitiationComposer.secretWarning(in: artifactDraft) {
                WorkspaceNoticeText(message: warning, severity: .warning)
            }
            HStack(spacing: 12) {
                Button("复制") { requestCopy(record) }.buttonStyle(.workspaceSecondary)
                    .disabled(model.initiationBusy || artifactDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("initiation.copy")
                Button("确认这是我要的") {
                    Task { await model.confirmTaskInitiation(record, artifact: artifactDraft) }
                }
                .buttonStyle(.workspacePrimary)
                .disabled(model.initiationBusy || record.isConfirmed || artifactDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("initiation.confirm")
                if record.isConfirmed {
                    Text("已确认 · 尚未执行").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                    if record.isArchived {
                        statusChip("已归档")
                    } else {
                        Button("归档这条记录") { archive(record) }
                            .buttonStyle(.workspaceSecondary)
                            .disabled(model.initiationBusy)
                            .accessibilityIdentifier("initiation.archive")
                    }
                } else {
                    discardButton(record)
                }
                Spacer()
            }
            if record.copiedAt != nil { stepNote(record) }
            statusText
        }
    }

    private func generate() {
        let known = Set(records.map(\.id))
        Task {
            guard await model.generateTaskInitiation(text: model.initiationText, sourceID: model.initiationSourceID, mode: mode, allowCloud: allowCloud),
                  let record = model.taskInitiations.first(where: { !known.contains($0.id) }) else { return }
            selectedID = record.id
            guard record.state == "draft",
                  record.route == .agentHandoff || record.route == .guidedStart,
                  record.proposal.preference != preference else { return }
            let status = model.initiationStatus
            if await model.setTaskInitiationPreference(record, preference: preference) { model.initiationStatus = status }
        }
    }

    @ViewBuilder private func stepNote(_ record: TaskInitiationRecord) -> some View {
        WorkspaceListDivider()
        VStack(alignment: .leading, spacing: 10) {
            Text("记下这一步").vosFont(WorkspaceText.rowTitle)
            Text("复制之后做了什么、卡在哪里，记一句。会存为你的原话；允许云端时继续整理成观点与待办。")
                .vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
            TextEditor(text: $stepDraft).vosFont(WorkspaceText.body).scrollContentBackground(.hidden).frame(minHeight: 90)
                .workspaceEditorSurface().accessibilityLabel("这一步的记录").disabled(stepSaving)
            HStack(spacing: 12) {
                Button(stepSaving ? "正在保存…" : "保存这一步") { saveStep(record) }
                    .buttonStyle(.workspaceSecondary)
                    .disabled(stepSaving || stepDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("initiation.step.save")
                Spacer()
            }
            if !stepStatus.isEmpty {
                Text(stepStatus).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).textSelection(.enabled)
            }
        }
    }

    private func saveStep(_ record: TaskInitiationRecord) {
        let text = stepDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !stepSaving else { return }
        stepSaving = true
        let cloud = allowCloud
        let commandID = "initiation-step:" + record.id + ":" + stepCommandID
        let title = stepTitle(record)
        Task {
            let saved = await model.saveCapturedText(text, title: title, ownership: .personal, allowCloud: cloud, commandID: commandID)
            stepSaving = false
            guard saved != nil else { stepStatus = model.status; return }
            stepDraft = ""
            stepCommandID = UUID().uuidString
            stepStatus = cloud && model.canUnderstandCapturedText
                ? "已存为你的原话；观点与待办会在后台整理。"
                : "已存为你的原话；仅保存在本机，可在资料页继续整理。"
            reloadSteps()
        }
    }

    private func stepTitle(_ record: TaskInitiationRecord) -> String {
        let title = record.proposal.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = title.isEmpty ? "启动后这一步" : "启动后：" + title
        return String(raw.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ").prefix(100))
    }

    private func stepsList(_ steps: [TaskInitiationStep]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            WorkspaceListDivider()
            Text("记下的步骤").vosFont(WorkspaceText.rowTitle)
            ForEach(steps) { step in
                Button {
                    openSource(step.id)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(step.title).vosFont(WorkspaceText.body).lineLimit(2)
                            Text(dateLabel(step.createdAt)).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "arrow.up.forward.square").foregroundStyle(palette.accent).accessibilityHidden(true)
                    }
                    .padding(.vertical, 8).padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("initiation.step.item")
                .workspaceHoverHighlight(cornerRadius: WorkspaceMetrics.panelRadius)
            }
        }
    }


    private func reloadSteps() {
        guard let store = model.store else { stepsByRecord = [:]; return }
        Task { stepsByRecord = (try? await store.taskInitiationSteps()) ?? [:] }
    }

    private func reloadArchived() {
        guard let store = model.store else { archivedRecords = []; return }
        Task { archivedRecords = ((try? await store.taskInitiations(includeArchived: true)) ?? []).filter(\.isArchived) }
    }

    private func archive(_ record: TaskInitiationRecord) {
        guard let store = model.store else { return }
        Task {
            do {
                _ = try await store.archiveTaskInitiation(id: record.id)
                selectedID = nil
                await model.refresh()
                if showArchived { reloadArchived() }
                model.initiationStatus = "已归档；可在启动记录里打开「查看归档」。"
            } catch {
                model.initiationStatus = InlineFailurePresentation.message(operation: "归档", reason: error.localizedDescription)
            }
        }
    }

    private func discardButton(_ record: TaskInitiationRecord) -> some View {
        Button("不保存这条启动记录") { Task { await model.discardTaskInitiation(record) } }
            .buttonStyle(.workspaceQuiet)
            .disabled(model.initiationBusy)
            .accessibilityIdentifier("initiation.discard")
    }

    private func statusChip(_ text: String, tone: WorkspaceBadge.Tone = .neutral) -> some View {
        WorkspaceBadge(text: text, tone: tone)
    }

    @ViewBuilder private var statusText: some View {
        if !model.initiationStatus.isEmpty {
            Text(model.initiationStatus).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).textSelection(.enabled)
        }
    }

    private var history: some View {
        WorkspaceListSection(title: "启动记录", count: visibleRecords.count) {
            HStack {
                Text("查看归档").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                Spacer()
                Toggle("查看归档", isOn: $showArchived)
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .accessibilityIdentifier("initiation.history.archived")
            }
            .padding(.vertical, 8)
            if visibleRecords.isEmpty {
                WorkspaceEmptyState(
                    title: showArchived ? "还没有归档的记录" : "还没有启动记录",
                    systemImage: "clock",
                    description: showArchived ? "已确认的启动记录和归档保存的回答会出现在这里。" : "生成过的交接提示词、教程、直接回答或澄清问题会出现在这里。"
                )
                .padding(.vertical, WorkspaceMetrics.groupGap)
            } else {
                ForEach(visibleRecords) { record in
                    Button { selectedID = record.id } label: {
                        HStack(alignment: .top, spacing: 14) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(record.proposal.title.isEmpty ? "未命名启动" : record.proposal.title)
                                    .vosFont(WorkspaceText.rowTitle).lineLimit(2)
                                Text(historySubtitle(record))
                                    .vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                            }
                            Spacer(minLength: 8)
                            if record.id == selected?.id {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(palette.accent).accessibilityHidden(true)
                            }
                        }
                        .padding(.vertical, 10).padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        .accessibilityElement(children: .combine)
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(record.id == selected?.id ? "当前选中" : "未选中")
                    .accessibilityIdentifier("initiation.history.item")
                    .workspaceHoverHighlight(cornerRadius: WorkspaceMetrics.panelRadius)
                    if record.id != visibleRecords.last?.id { WorkspaceListDivider() }
                }
            }
        }
    }

    private func stateLabel(_ record: TaskInitiationRecord) -> String {
        if record.isClarifying { return "待澄清" }
        if record.isConfirmed { return record.route == .answer ? "已保存" : "已确认" }
        if record.route == .answer { return "待保存" }
        return record.route == .captureOnly ? "已记录" : "草稿"
    }

    private func historySubtitle(_ record: TaskInitiationRecord) -> String {
        var parts = [taskInitiationRouteLabel(record.route), stateLabel(record)]
        if record.copiedAt != nil { parts.append("已复制") }
        if record.isArchived { parts.append("已归档") }
        if let count = stepsByRecord[record.id]?.count, count > 0 { parts.append("记下 \(count) 步") }
        parts.append(dateLabel(record.createdAt))
        return parts.joined(separator: " · ")
    }

    private func dateLabel(_ text: String) -> String {
        ConversationReflectionFocus.date(text)?.formatted(date: .abbreviated, time: .shortened) ?? text
    }

    private func requestCopy(_ record: TaskInitiationRecord) {
        let text = record.route == .answer ? record.proposal.answer : artifactDraft
        if TaskInitiationComposer.secretWarning(in: text) != nil { pendingSecretCopy = record }
        else { copy(record) }
    }

    private func copy(_ record: TaskInitiationRecord) {
        let text = record.route == .answer ? record.proposal.answer : artifactDraft
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        Task { await model.markTaskInitiationCopied(record, artifact: text) }
    }
}
