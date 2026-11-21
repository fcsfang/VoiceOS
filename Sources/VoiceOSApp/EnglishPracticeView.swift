import SwiftUI
import VoiceOSCore

struct EnglishInputPreview: View {
    @Environment(\.workspacePalette) private var palette
    let snapshot: EnglishPracticeSnapshot
    let dismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("待发送的英文练习文字").vosFont(WorkspaceText.sectionTitle).accessibilityAddTraits(.isHeader)
            Text("以下是完整选定文字；关闭此窗口不会发送。发送时会再次核对版本与授权，原始音频不上传。").vosFont(WorkspaceText.body).foregroundStyle(palette.secondaryText)
            ScrollView {
                VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
                    ForEach(Array(snapshot.context.sources.enumerated()), id: \.element.sourceID) { index, source in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(index == 0 ? "本次练习" : "旧练习 \(index)").vosFont(WorkspaceText.rowTitle)
                            Text(source.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            HStack { Spacer(); Button("返回", action: dismiss).keyboardShortcut(.cancelAction).buttonStyle(.workspaceSecondary) }
        }.padding(24).frame(width: 640, height: 480)
            .workspaceModalSurface()
    }
}
struct EnglishPracticeView: View {
    @Environment(\.workspacePalette) private var palette
    @ObservedObject var model: ControlCenter
    var embedded = false
    let dismiss: () -> Void
    var openCapture: (() -> Void)? = nil
    @State private var currentID = ""
    @State private var priorIDs: Set<String> = []
    @State private var showingInput = false
    @State private var suppressSelectionReset = false
    private var sources: [SourceRecord] {
        model.records.filter { $0.origin == "user" && $0.speaker == "user" && !($0.transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && ["saved", "reference_only"].contains($0.state) }
    }
    private var current: SourceRecord? { sources.first { $0.id == currentID } }
    private var priorCandidates: [SourceRecord] { sources.filter { $0.id != currentID } }
    private var sendHint: String? {
        if !model.modelConfigured { return "尚未配置文本模型；配置后可发送文本反馈。" }
        if model.englishBusy { return "正在准备或发送文本反馈，请稍候。" }
        if model.englishSnapshot == nil { return "先点“准备并核对文字”，核对待发送文字后才能发送。" }
        return nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: WorkspaceMetrics.sectionGap) {
            WorkspacePageHeading(eyebrow: "工具 · 英文练习", title: "英文表达反馈",
                                 subtitle: "只发送选定的个人文字和出处；原始音频不会上传。")
            if sources.isEmpty {
                WorkspaceEmptyState(title: "还没有可练习的英文原话", systemImage: "character.book.closed",
                                    description: "需要一份已保存、已完成文字转写的个人原话。完成一段英文录音并保存后，回到这里即可练习。") {
                    if let openCapture { Button("去记录英文表达", action: openCapture).buttonStyle(.workspacePrimary) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Picker("本次练习", selection: $currentID) {
                    Text("选择一份我的英文原话").tag("")
                    ForEach(sources) { source in
                        Text(String((source.transcript ?? source.displayTitle).prefix(90))).tag(source.id)
                    }
                }
                .disabled(model.englishBusy)
                .onChange(of: currentID) { _, _ in
                    if suppressSelectionReset { suppressSelectionReset = false; return }
                    priorIDs = priorIDs.filter { $0 != currentID }; model.englishSnapshot = nil; model.englishStatus = "选择已变化，请重新准备并核对文字。"
                }
                VStack(alignment: .leading, spacing: WorkspaceMetrics.rowGap) {
                    Text("可选旧练习（最多 2 份）").vosFont(WorkspaceText.rowTitle)
                    ScrollView {
                        ForEach(priorCandidates) { source in
                            Toggle(isOn: Binding(get: { priorIDs.contains(source.id) }, set: { value in
                                if value { if priorIDs.count < 2 { priorIDs.insert(source.id) } }
                                else { priorIDs.remove(source.id) }
                                model.englishSnapshot = nil; model.englishStatus = "选择已变化，请重新准备并核对文字。"
                            })) {
                                VStack(alignment: .leading) { Text(source.displayTitle); Text(source.transcript ?? "").lineLimit(2).vosFont(WorkspaceText.caption).foregroundStyle(palette.secondaryText) }
                            }.disabled(model.englishBusy || (!priorIDs.contains(source.id) && priorIDs.count >= 2))
                        }
                    }.frame(maxHeight: model.englishAttempts.isEmpty ? 210 : 110)
                }
                if englishStatusIsError {
                    WorkspaceNoticeText(message: model.englishStatus, severity: .danger)
                } else {
                    Text(model.englishStatus).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                }
                HStack {
                    Button("准备并核对文字") { if let current { Task { await model.prepareEnglishPractice(current: current, priorIDs: Array(priorIDs)) } } }
                        .buttonStyle(.workspaceSecondary)
                        .disabled(current == nil || model.englishBusy)
                    Button(model.englishBusy ? "正在发送…" : "发送文本反馈") { Task { await model.performEnglishPractice() } }
                        .buttonStyle(.workspacePrimary)
                        .disabled(model.englishSnapshot == nil || model.englishBusy || !model.modelConfigured)
                    if !model.modelConfigured { Button("配置文本模型…") { model.chooseTextModel() } }
                    if model.englishSnapshot != nil { Button("查看待发送文字…") { showingInput = true } }
                    Spacer(); if !embedded { Button("完成", action: dismiss).keyboardShortcut(.cancelAction).buttonStyle(.workspaceSecondary) }
                }
                if let hint = sendHint { Text(hint).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText) }
            }
            if !model.englishAttempts.isEmpty {
                WorkspaceListDivider(); Text("反馈历史（\(model.englishAttempts.count)）").vosFont(WorkspaceText.rowTitle.size, weight: .semibold, monospacedDigit: true)
                ScrollView {
                ForEach(model.englishAttempts) { attempt in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(attempt.state == "completed" ? "已保存" : attempt.state == "reserved" ? "等待结果" : "未完成 · 不自动重发") · \(ConversationReflectionFocus.date(attempt.createdAt)?.formatted(date:.abbreviated,time:.shortened) ?? "时间未知")").vosFont(WorkspaceText.meta)
                        if let reason = attempt.error { Text(reason).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText) }
                        if attempt.validity == "frozen" { Text("历史反馈 · 依据或授权已变化，暂停当前使用").vosFont(WorkspaceText.meta).foregroundStyle(palette.warning) }
                        if let result = attempt.result {
                            ForEach(Array(result.suggestions.enumerated()), id: \.offset) { index, suggestion in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("建议 \(index + 1) · \(suggestionKindLabel(suggestion.kind))").vosFont(WorkspaceText.rowTitle)
                                    Text("原句：\(suggestion.original.quote)").textSelection(.enabled)
                                    Text("建议：\(suggestion.suggestedText)").textSelection(.enabled)
                                    Text(suggestion.explanation).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                                    if suggestion.possibleTranscriptIssue { Text("可能是转写问题，需人工核对").vosFont(WorkspaceText.meta).foregroundStyle(palette.warning) }
                                }.padding(8).background(palette.surface, in: RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
                            }
                            ForEach(Array(result.comparisons.enumerated()), id: \.offset) { _, comparison in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("本次：\(comparison.current.quote)").textSelection(.enabled)
                                    Text("旧练习：\(comparison.prior.quote)").textSelection(.enabled)
                                    Text("比较：\(comparison.explanation)").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                                }
                            }
                            Text("文字建议不代表发音、熟练度或学习效果判断。").vosFont(WorkspaceText.caption).foregroundStyle(palette.secondaryText)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }.padding(24).frame(width: embedded ? nil : WorkspaceMetrics.modalMedium, height: embedded ? nil : 600)
        .sheet(isPresented: $showingInput) {
            if let snapshot = model.englishSnapshot { EnglishInputPreview(snapshot: snapshot) { showingInput = false } }
        }
        .task {
            guard currentID.isEmpty, let first = sources.first else { return }
            suppressSelectionReset = true
            currentID = first.id
            model.englishSnapshot = nil
            model.englishStatus = "已选择，准备并核对文字。"
        }
    }
    // ControlCenter stores the status and the failure in one string. These are
    // the only messages it and this view write, so anything else came from a catch.
    private var englishStatusIsError: Bool {
        let statuses = ["选择一份我的英文原话", "已选择", "选择已变化", "已准备 ", "正在发送选定文字", "反馈已保存", "反馈结果未知"]
        return !statuses.contains { model.englishStatus.hasPrefix($0) }
    }
    private func suggestionKindLabel(_ kind: EnglishSuggestionKind) -> String {
        switch kind { case .grammar: "语法"; case .organisation: "结构"; case .reusablePattern: "可复用表达" }
    }
}
