import SwiftUI
import VoiceOSCore

/// Topics and questions retain the user's own words; AI discussion remains an explicit next step.
struct ReflectionQuestionsView: View {
    @Environment(\.workspacePalette) private var palette
    @ObservedObject var model: ControlCenter
    let period: ReflectionPeriod
    let anchor: Date
    let reflect: (ConversationReflectionFocus, String) async -> Bool
    let dismissAtlas: () -> Void
    var initialQuestionID: String? = nil
    var selectTopic: ((String) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var questions: [ReflectionQuestion] = []
    @State private var selectedID: String?
    @State private var entries: [ReflectionQuestionEntry] = []
    @State private var sourceIDs: [String] = []
    @State private var resurfacing: [ReflectionTopicResurfacing] = []
    @State private var topicFeedback: [ReflectionTopicFeedback] = []
    @State private var sourceMode = "sources"
    @State private var busy = false
    @State private var error: String?
    @State private var creating = false
    @State private var editingQuestion: ReflectionQuestion?
    @State private var title = ""
    @State private var titleCloud = false
    @State private var text = ""
    @State private var kind = ReflectionQuestionEntryKind.observation
    @State private var allowCloud = false
    @State private var evidenceIDs: Set<String> = []
    @State private var managingSources = false
    @State private var sourceQuery = ""
    @State private var onlyLinked = false
    @State private var entryFilter = "all"
    @State private var periodicReview = false
    @State private var chosenPeriod: ReflectionPeriod?
    @State private var chosenAnchor: Date?
    @State private var reviewing = false
    private var selected: ReflectionQuestion? { questions.first { $0.id == selectedID } }
    private var reviewPeriod: ReflectionPeriod { chosenPeriod ?? period }
    private var reviewAnchor: Date { chosenAnchor ?? anchor }
    private var interval: DateInterval { reviewPeriod.interval(containing: reviewAnchor) }
    private var dateLabel: String {
        interval.start.formatted(date: .abbreviated, time: .omitted) + " — " + interval.end.addingTimeInterval(-1).formatted(date: .abbreviated, time: .omitted)
    }
    private var availableSources: [SourceRecord] {
        model.records.filter { ["saved", "reference_only"].contains($0.state) && !($0.transcript ?? "").isEmpty }
    }
    private var protectedSourceIDs: Set<String> { Set(entries.flatMap { [$0.sourceID] + $0.sourceIDs } + [selected?.sourceID].compactMap { $0 }) }
    private var visibleSources: [SourceRecord] {
        availableSources.filter {
            (!onlyLinked || sourceIDs.contains($0.id)) &&
            (sourceQuery.isEmpty || ($0.displayTitle + "\n" + ($0.transcript ?? "")).localizedCaseInsensitiveContains(sourceQuery))
        }
    }
    private var availableKnowledge: [CandidateClaim] {
        let taskIDs = Set(model.actionRecords.map(\.claimID))
        let currentIDs = Set(model.currentClaimsBySource.values.flatMap { $0 }.map(\.id))
        return model.claims.filter { claim in
            claim.validity == "current" && claim.reviewState != "rejected" &&
            !taskIDs.contains(claim.id) && (currentIDs.contains(claim.id) || claim.reviewState == "endorsed" || claim.ownership == "ai_candidate") &&
            (!onlyLinked || claim.references.allSatisfy { sourceIDs.contains($0.sourceID) }) &&
            (sourceQuery.isEmpty || claim.statement.localizedCaseInsensitiveContains(sourceQuery))
        }
    }
    private var availableTasks: [ActionRecord] {
        model.actionRecords.filter { action in
            action.validity == "current" &&
            (!onlyLinked || model.claims.first(where: { $0.id == action.claimID })?.references.allSatisfy { sourceIDs.contains($0.sourceID) } == true) &&
            (sourceQuery.isEmpty || action.title.localizedCaseInsensitiveContains(sourceQuery))
        }
    }
    private var visibleEntries: [ReflectionQuestionEntry] {
        entries.filter { entryFilter == "all" || $0.kind.rawValue == entryFilter }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                WorkspaceHero(eyebrow: "TOPICS IN PROGRESS", title: "主题与问题", subtitle: "把跨越时间的材料、认识、尝试与结果接到同一个主题。")
                Spacer()
                Button("返回地图") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
            }.padding(24)
            Divider()
            HStack(spacing: 0) {
                questionList.frame(width: 240)
                Divider()
                if let question = selected { detail(question) }
                else {
                    ContentUnavailableView("从一个持续关心的主题开始", systemImage: "bubble.left.and.text.bubble.right", description: Text("例如：Agent 记忆，或怎样让 AI Agent 稳定完成真实任务？\n主题与问题都可以承载持续的探索。"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if let error { Text(error).font(.callout).foregroundStyle(palette.danger).textSelection(.enabled).padding(12) }
        }
        .foregroundStyle(palette.text).background(palette.canvas).frame(width: 1020, height: 760)
        .task { selectedID = initialQuestionID; await reload() }
        .sheet(isPresented: $creating) { createSheet }
        .sheet(isPresented: $managingSources) { sourcesSheet }
    }
    private var questionList: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("长期探索").font(.headline)
                Spacer()
                WorkspaceIconButton(systemImage: "plus", label: "新增主题或问题") { beginCreating() }.disabled(busy)
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    if let item = resurfacing.first {
                        TopicResurfacingCard(item: item, busy: busy, open: {
                            selectedID = item.id; selectTopic?(item.id); text = ""; evidenceIDs = []
                            Task { await visitTopic(item.id) }
                        }, feedback: { mode, snooze in
                            Task { await setTopicFeedback(item.id, mode: mode, snooze: snooze) }
                        }).padding(.bottom, 6)
                    }
                    ForEach(questions) { question in
                        Button {
                            guard !busy else { return }
                            selectedID = question.id; selectTopic?(question.id); text = ""; evidenceIDs = []
                            Task { await visitTopic(question.id) }
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(question.title).font(.system(size: 14, weight: .medium)).multilineTextAlignment(.leading).lineLimit(4)
                                Text("更新于 " + date(question.updatedAt)).font(.caption).foregroundStyle(.secondary)
                            }.padding(13).frame(maxWidth: .infinity, alignment: .leading)
                                .background(selectedID == question.id ? palette.selection : palette.surface, in: RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
                                .overlay { RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius).stroke(selectedID == question.id ? palette.accent.opacity(0.5) : .clear) }
                        }.buttonStyle(.plain).disabled(busy)
                    }
                }
            }
            Button("新增主题或问题") { beginCreating() }.disabled(busy)
        }.padding(18)
    }
    private func detail(_ question: ReflectionQuestion) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(question.title).font(.system(size: 22, weight: .medium, design: .serif)).textSelection(.enabled)
            HStack {
                Button("关联资料 · \(sourceIDs.count)") { managingSources = true }.disabled(busy)
                Button("查看标题原文") { openSource(question.sourceID) }.disabled(busy)
                Menu("提示设置") {
                    Button("正常显示静默提示") { Task { await setTopicFeedback(question.id, mode: .normal, snooze: false) } }
                    Button("减少提示 · 至少间隔 30 天") { Task { await setTopicFeedback(question.id, mode: .reduced, snooze: false) } }
                    Button("暂停此主题提示") { Task { await setTopicFeedback(question.id, mode: .paused, snooze: false) } }
                }.disabled(busy)
                Button("修改标题") {
                    editingQuestion = question; title = question.title
                    titleCloud = model.records.first(where: { $0.id == question.sourceID })?.localOnly == false
                    creating = true
                }.disabled(busy)
                Spacer()
                Button {
                    Task { await startReview(question) }
                } label: {
                    HStack(spacing: 6) {
                        if reviewing { ProgressView().controlSize(.small) }
                        Label(periodicReview ? "一起回顾" : "一起探索", systemImage: "sparkles")
                    }
                }.buttonStyle(.borderedProminent).tint(palette.accent).disabled(busy || reviewing)
            }
            if let feedback = topicFeedback.first(where: { $0.id == question.id }), feedback.mode != .normal || feedback.snoozedUntil != nil {
                Text(feedback.mode == .paused ? "此主题的静默提示已暂停，可从提示设置恢复。" : feedback.mode == .reduced ? "此主题已减少提示；不会据此判断你失去兴趣。" : "此主题已选择稍后提示。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Picker("探索范围", selection: $periodicReview) {
                    Text("全部历史").tag(false)
                    Text("周期回顾").tag(true)
                }.labelsHidden().pickerStyle(.segmented).frame(width: 210)
                if periodicReview {
                    Picker("回顾周期", selection: Binding(get: { reviewPeriod }, set: { chosenPeriod = $0 })) {
                        ForEach(ReflectionPeriod.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.labelsHidden().pickerStyle(.segmented).frame(width: 130)
                    DatePicker("回顾日期", selection: Binding(get: { reviewAnchor }, set: { chosenAnchor = $0 }), displayedComponents: .date).labelsHidden().frame(width: 110)
                }
                Spacer()
            }
            if periodicReview { Text(reviewPeriod.reviewTitle + " · " + dateLabel).font(.caption).foregroundStyle(.secondary) }
            Text(periodicReview ? "回顾这个周期的进展，同时带上已关联的完整历史作为依据；下方记录仍显示整个主题。" : "沿着整个主题探索，不按日历截断。已关联的完整资料、个人记录与成果共同构成讨论依据。").font(.caption).foregroundStyle(.secondary)
            Picker("记录视角", selection: $entryFilter) {
                Text("全部记录").tag("all")
                Text("认识变化").tag(ReflectionQuestionEntryKind.change.rawValue)
                Text("尝试与结果").tag("practice")
            }.pickerStyle(.segmented)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if entries.isEmpty {
                        Text("先关联一份材料，或留下你现在的理解。以后可以回来对照它如何变化。").font(.callout).foregroundStyle(.secondary).padding(.vertical, 18)
                    }
                    ForEach(entryFilter == "practice" ? entries.filter { $0.kind == .experiment || $0.kind == .result } : visibleEntries) { entry in
                        entryCard(entry)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            composer(question)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private func entryCard(_ entry: ReflectionQuestionEntry) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(entry.kind.label, systemImage: icon(entry.kind)).font(.caption).foregroundStyle(palette.accent)
                Spacer()
                Text(date(entry.createdAt) + " · 我的记录").font(.caption).foregroundStyle(.secondary)
            }
            Text(entry.text).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if !entry.unavailableSourceIDs.isEmpty {
                Text("部分依据已变化或暂停使用；请重新核对，这条历史记录保留原文。").font(.caption).foregroundStyle(palette.warning)
            }
            HStack {
                Button("查看记录原文") { openSource(entry.sourceID) }
                if !entry.sourceIDs.isEmpty {
                    Menu("所附依据 · \(entry.sourceIDs.count)") {
                        ForEach(entry.sourceIDs, id: \.self) { id in
                            Button(sourceTitle(id)) { openSource(id) }
                        }
                    }
                }
                Spacer()
                Menu {
                    Button("停止用于这个主题", role: .destructive) {
                        Task { await perform { try await model.stopReflectionQuestionEntry(entry.id) } }
                    }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 22).help("更多操作").accessibilityLabel("更多操作")
            }.font(.caption).disabled(busy)
        }.padding(14).background(palette.surface, in: RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
    }
    private func composer(_ question: ReflectionQuestion) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Picker("留下什么", selection: $kind) {
                    ForEach(ReflectionQuestionEntryKind.allCases, id: \.self) { Text($0.label).tag($0) }
                }.frame(width: 215)
                Text("\(text.unicodeScalars.count) / 4000").font(.caption).foregroundStyle(text.unicodeScalars.count > 4000 ? palette.danger : .secondary)
                Spacer()
                Menu("附上依据 · \(evidenceIDs.count)") {
                    ForEach(availableSources.filter { sourceIDs.contains($0.id) && $0.id != question.sourceID }) { source in
                        Toggle(source.displayTitle, isOn: Binding(get: { evidenceIDs.contains(source.id) }, set: { value in
                            if value { evidenceIDs.insert(source.id) } else { evidenceIDs.remove(source.id) }
                        }))
                    }
                }
            }
            Text(prompt(kind)).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text).font(.body).scrollContentBackground(.hidden).padding(6)
                .frame(height: 78).background(palette.surface, in: RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
                .overlay { RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius).stroke(palette.text.opacity(0.14)) }
            HStack {
                Toggle("允许这条文字用于云端回顾", isOn: $allowCloud).font(.caption)
                Spacer()
                Button(busy ? "正在保存…" : "保存我的记录") {
                    Task {
                        let saved = await perform {
                            try await model.saveReflectionQuestionEntry(questionID: question.id, kind: kind, text: text, sourceIDs: evidenceIDs.sorted(), allowCloud: allowCloud)
                        }
                        if saved { text = ""; evidenceIDs = [] }
                    }
                }.buttonStyle(.borderedProminent).tint(palette.accent)
                    .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.unicodeScalars.count > 4000)
            }
        }.disabled(busy)
    }
    private var createSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(editingQuestion == nil ? "你想持续探索什么？" : "重新表述主题或问题").font(.title2)
            Text("可以写一个主题，也可以写一个具体问题。无需问句；相关资料、想法与实践以后逐渐加入。").foregroundStyle(.secondary)
            TextField("例如：Agent 记忆，或如何评估记忆效果？", text: $title).textFieldStyle(.roundedBorder)
            Text("\(title.unicodeScalars.count) / 200").font(.caption).foregroundStyle(.secondary)
            Toggle("允许标题用于云端讨论", isOn: $titleCloud).font(.callout)
            HStack {
                Button("取消") { creating = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(editingQuestion == nil ? "建立主题或问题" : "保存标题") {
                    Task {
                        busy = true; error = nil
                        do {
                            if let editingQuestion {
                                try await model.renameReflectionQuestion(editingQuestion.id, title: title, allowCloud: titleCloud)
                                selectedID = editingQuestion.id
                            } else {
                                let question = try await model.createReflectionQuestion(title, allowCloud: titleCloud)
                                selectedID = question.id
                            }
                            if let selectedID { selectTopic?(selectedID) }
                            creating = false; editingQuestion = nil; title = ""; titleCloud = false
                            text = ""; evidenceIDs = []
                            await reload()
                        } catch { self.error = error.localizedDescription; creating = false }
                        busy = false
                    }
                }.buttonStyle(.borderedProminent).tint(palette.accent).keyboardShortcut(.defaultAction)
                    .disabled(busy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.unicodeScalars.count > 200)
            }
        }.padding(28).frame(width: 560).background(palette.canvas)
    }
    private var sourcesSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("这个主题的资料").font(.title2)
                Spacer()
                Button("完成") { managingSources = false }.disabled(busy).keyboardShortcut(.cancelAction)
            }
            Text("从原文、已有知识或任务接回主题，时间不限。关联保留原话与归属，不代表认可观点或完成任务。").font(.callout).foregroundStyle(.secondary)
            Picker("关联内容", selection: $sourceMode) {
                Text("表达与资料").tag("sources")
                Text("已有知识").tag("knowledge")
                Text("任务与目标").tag("tasks")
            }.pickerStyle(.segmented)
            HStack {
                WorkspaceSearchField(text: $sourceQuery, placeholder: sourceMode == "sources" ? "搜索标题或完整原文" : "搜索知识或任务标题")
                Toggle("只看已关联", isOn: $onlyLinked).toggleStyle(.checkbox)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if sourceMode == "knowledge" {
                        ForEach(availableKnowledge) { claim in knowledgeLinkCard(claim) }
                        if availableKnowledge.isEmpty { Text("没有符合条件的当前知识卡片。").foregroundStyle(.secondary).padding() }
                    } else if sourceMode == "tasks" {
                        ForEach(availableTasks) { action in taskLinkCard(action) }
                        if availableTasks.isEmpty { Text("没有符合条件的当前任务或目标。").foregroundStyle(.secondary).padding() }
                    } else {
                    ForEach(visibleSources) { source in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(alignment: .top) {
                                Toggle(isOn: Binding(get: { sourceIDs.contains(source.id) }, set: { linked in
                                    guard let id = selectedID else { return }
                                    Task { await perform { try await model.linkReflectionQuestionSource(questionID: id, sourceID: source.id, linked: linked) } }
                                })) {
                                    Text(source.displayTitle).font(.headline).lineLimit(3)
                                }.disabled(busy || protectedSourceIDs.contains(source.id))
                                Spacer()
                                Text(source.localOnly ? "仅本地" : "文字可云端回顾").font(.caption).foregroundStyle(.secondary)
                            }
                            DisclosureGroup("查看完整原文") { Text(source.transcript ?? "").font(.callout).textSelection(.enabled) }
                            if source.localOnly {
                                Button("查看原文并设置文字许可") { openSource(source.id) }.font(.caption)
                            }
                        }.padding(12).background(palette.surface, in: RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
                    }
                    if visibleSources.isEmpty { Text("没有符合条件的文字资料。").foregroundStyle(.secondary).padding() }
                    }
                }
            }
        }.padding(24).frame(width: 740, height: 600).background(palette.canvas)
    }
    private func knowledgeLinkCard(_ claim: CandidateClaim) -> some View {
        let ids = Set(claim.references.map(\.sourceID))
        let linked = !ids.isEmpty && ids.allSatisfy { sourceIDs.contains($0) }
        return VStack(alignment: .leading, spacing: 9) {
            Text(claim.statement).font(.headline).textSelection(.enabled)
            Text(claim.ownership == "ai_candidate" ? "AI 建议 · 关联不代表认可" : claim.ownership == "external" ? "外部主张 · 保留原有归属" : "个人表达的整理 · 仍可核对原话").font(.caption).foregroundStyle(.secondary)
            HStack {
                Menu("原话依据 · \(ids.count)") {
                    ForEach(ids.sorted(), id: \.self) { id in Button(sourceTitle(id)) { openSource(id) } }
                }
                Spacer()
                Button(linked ? "已关联" : "接回这个主题") {
                    guard let selectedID else { return }
                    Task { await perform { try await model.linkTopicClaim(questionID: selectedID, claimID: claim.id, expectedReviewVersion: claim.reviewVersion) } }
                }.disabled(linked || busy || ids.isEmpty)
            }.font(.caption)
        }.padding(13).background(palette.surface, in: RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
    }
    private func taskLinkCard(_ action: ActionRecord) -> some View {
        let claim = model.claims.first { $0.id == action.claimID }
        let ids = Set(claim?.references.map(\.sourceID) ?? [])
        let linked = !ids.isEmpty && ids.allSatisfy { sourceIDs.contains($0) }
        return VStack(alignment: .leading, spacing: 9) {
            Text(action.title).font(.headline).textSelection(.enabled)
            Text((action.kind == "task" ? "任务" : action.kind == "ai_suggestion" ? "AI 建议" : "意图与目标") + " · " + (action.state == "completed" ? "已完成登记" : action.state == "dismissed" ? "已放下" : "待跟进")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Menu("原话依据 · \(ids.count)") {
                    ForEach(ids.sorted(), id: \.self) { id in Button(sourceTitle(id)) { openSource(id) } }
                }
                Spacer()
                Button(linked ? "已关联" : "接回这个主题") {
                    guard let selectedID else { return }
                    Task { await perform { try await model.linkTopicAction(questionID: selectedID, actionID: action.id, expectedVersion: action.version) } }
                }.disabled(linked || busy || ids.isEmpty)
            }.font(.caption)
        }.padding(13).background(palette.surface, in: RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
    }
    private func visitTopic(_ id: String) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            try await model.markTopicReviewed(id)
            resurfacing = try await model.loadTopicResurfacing()
            topicFeedback = try await model.loadTopicFeedback()
            await loadDetails(id)
        } catch { self.error = error.localizedDescription }
    }
    private func setTopicFeedback(_ id: String, mode: CognitiveFeedbackMode, snooze: Bool) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            try await model.saveTopicFeedback(id, mode: mode, snooze: snooze)
            resurfacing = try await model.loadTopicResurfacing()
            topicFeedback = try await model.loadTopicFeedback()
        } catch { self.error = error.localizedDescription }
    }
    private func reload() async {
        do {
            questions = try await model.loadReflectionQuestions()
            resurfacing = try await model.loadTopicResurfacing()
            topicFeedback = try await model.loadTopicFeedback()
            if !questions.contains(where: { $0.id == selectedID }) { selectedID = questions.first?.id }
            if let id = selectedID { await loadDetails(id) }
        } catch { self.error = error.localizedDescription }
    }
    private func loadDetails(_ id: String) async {
        busy = true; defer { busy = false }
        do {
            let details = try await model.loadReflectionQuestionDetails(id)
            guard selectedID == id else { return }
            entries = details.entries; sourceIDs = details.sourceIDs
        } catch { self.error = error.localizedDescription }
    }
    @discardableResult private func perform(_ operation: () async throws -> Void) async -> Bool {
        guard !busy else { return false }
        busy = true; error = nil
        defer { busy = false }
        do { try await operation(); await reload(); return true }
        catch { self.error = error.localizedDescription; return false }
    }
    private func startReview(_ question: ReflectionQuestion) async {
        guard !busy, !reviewing else { return }
        reviewing = true; busy = true; error = nil
        defer { reviewing = false; busy = false }
        do {
            let focus: ConversationReflectionFocus
            let prompt: String
            if periodicReview {
                focus = try await model.loadQuestionReflection(question.id, interval: interval, period: reviewPeriod)
                prompt = reviewPeriod.reviewPrompt(dateLabel: dateLabel, questionTitle: question.title)
            } else {
                focus = try await model.loadTopicReflection(question.id)
                prompt = focus.topicReviewPrompt
            }
            try await model.markTopicReviewed(question.id)
            if await reflect(focus, prompt) {
                dismiss()
                dismissAtlas()
            } else {
                error = model.status.isEmpty ? "这次回顾没有完成，请稍后重试。" : model.status
            }
        } catch { self.error = error.localizedDescription }
    }
    private func openSource(_ id: String) { model.requestWorkspaceSource(id); dismiss(); dismissAtlas() }
    private func beginCreating() { editingQuestion = nil; title = ""; titleCloud = false; creating = true }
    private func sourceTitle(_ id: String) -> String { model.records.first { $0.id == id }?.displayTitle ?? "历史来源 · \(id.prefix(8))" }
    private func date(_ text: String) -> String { ConversationReflectionFocus.date(text)?.formatted(date: .abbreviated, time: .shortened) ?? text }
    private func icon(_ kind: ReflectionQuestionEntryKind) -> String {
        switch kind { case .observation: "text.bubble"; case .change: "arrow.triangle.branch"; case .experiment: "flask"; case .result: "leaf" }
    }
    private func prompt(_ kind: ReflectionQuestionEntryKind) -> String {
        switch kind {
        case .observation: "我现在怎么理解？还有什么没有想清楚？"
        case .change: "我之前怎么想，现在怎么想？哪些材料或经历促成了变化？"
        case .experiment: "要检验什么判断？准备怎么试？观察什么？什么结果会让我修正认识？"
        case .result: "实际做了什么、观察到什么？哪些支持原判断，哪些仍不能确定？可注明对应的尝试。"
        }
    }
}
