import AppKit
import SwiftUI
import VoiceOSCore

struct WorkspaceDiscussionView: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: ControlCenter
    @Binding var draft: String
    let close: () -> Void
    let openSource: (String) -> Void
    @FocusState private var editorFocused: Bool
    @State private var confirmingEnd = false
    @State private var showingHistory = false
    @State private var followTail = true
    @State private var scrollMetricsKnown = false
    private var busy: Bool { model.discussionSaving || model.discussionSending || model.discussionExtracting || model.dictationActive }
    private var composing: Bool { editorFocused && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var canSend: Bool {
        model.discussionWritable && model.modelConfigured && !busy && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.discussionCanSend || model.discussionRecordingID != nil)
    }
    private var contextTitle: String {
        if let title = model.discussionReflection?.question?.title { return title }
        if model.discussionHistory.count == 1, let id = model.discussionHistory.first?.sourceID,
           let source = model.records.first(where: { $0.id == id }) { return source.displayTitle }
        return "\(model.discussionHistory.count) 份材料的讨论"
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Label("一起思考", systemImage: "sparkles").vosFont(WorkspaceText.rowTitle)
                    Text(contextTitle).vosFont(WorkspaceText.meta).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("历史讨论", systemImage: "clock.arrow.circlepath") { showingHistory = true }
                    .buttonStyle(.workspaceSecondaryCompact)
                    .disabled(busy)
                WorkspaceIconButton(systemImage: "xmark", label: "收起讨论，保留阅读位置") { close() }
            }.padding(18)
            WorkspaceListDivider()
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if let focus = model.discussionReflection, let topic = focus.question { Text(topic.title).vosFont(WorkspaceText.rowTitle) }
                        DisclosureGroup("本次讨论的依据") {
                            ForEach(model.discussionHistory, id: \.sourceID) { source in
                                Button { openSource(source.sourceID) } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(source.origin == "user" ? "我的表达" : source.origin == "ai" ? "AI 交付" : "外部资料").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                                        Text(source.text).lineLimit(3)
                                        if source.localOnly { Text("仅本地 · 发送前需在材料详情授权").vosFont(WorkspaceText.meta).foregroundStyle(palette.warning) }
                                    }.padding(.vertical, 4)
                                }.buttonStyle(.plain)
                            }
                        }.vosFont(WorkspaceText.meta)
                        ForEach(model.discussionTurns) { turn in
                            VStack(alignment: .leading, spacing: 10) {
                                Text("我").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                                Text(turn.text).textSelection(.enabled).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(palette.selection, in: RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
                                Button("整理为观点与行动") { model.understandDiscussionTurn(turn) }
                                    .buttonStyle(.workspaceSecondaryCompact)
                                    .disabled(!model.canUnderstandDiscussionTurn(turn))
                                Text("整理会发送本轮个人原话，提取待核对观点与明确行动；行动遵循已保存的提醒清单授权。").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                                ForEach(model.discussionReplies.filter { $0.replyToTurnID == turn.id }) { reply in
                                    Text(reply.validity == "current" ? "VoiceOS" : "VoiceOS · 历史依据").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                                    if reply.parts.isEmpty {
                                        if reply.state == "reserved" {
                                            Text("正在思考…").foregroundStyle(.secondary)
                                        } else {
                                            WorkspaceNoticeText(message: "这次回复未完成：" + (reply.error ?? "原因未登记"), severity: .danger)
                                            if model.discussionWritable {
                                                Button("重新提问") { editorFocused = true }.buttonStyle(.workspaceQuietCompact)
                                                Text("失败记录已保留在本轮；写下新的提问会作为下一轮发送。").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                    ForEach(Array(reply.parts.enumerated()), id: \.offset) { index, part in
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text(part.kind == .quotation ? "原文引用" : "AI 分析与建议").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                                            Text(.init(part.text)).textSelection(.enabled).lineSpacing(4)
                                            if part.kind == .aiSuggestion {
                                                let kept = model.discussionDerivations.first { $0.discussionAttemptID == reply.id && $0.partIndex == index }
                                                if let claimID = kept?.claimID, let claim = model.claims.first(where: { $0.id == claimID }), let sourceID = claim.references.first?.sourceID {
                                                    Button("已保留 · 打开候选") { openSource(sourceID) }.buttonStyle(.workspaceQuietCompact)
                                                } else {
                                                    Button("保留为待核对候选") {
                                                        Task { if await model.retainDiscussionCandidate(reply, index: index) { await model.refreshDiscussion() } }
                                                    }.buttonStyle(.workspaceSecondaryCompact)
                                                        .disabled(reply.validity != "current" || model.discussionSession?.validity != "current" || busy)
                                                }
                                                Text("待核对、未验证；保留不表示认可，也不创建行动。").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                                            }
                                            if !part.references.isEmpty {
                                                DisclosureGroup("原文依据") {
                                                    ForEach(Array(part.references.enumerated()), id: \.offset) { _, ref in
                                                        if let source=model.discussionHistory.first(where: { $0.sourceID == ref.sourceID && $0.transcriptVersionID == ref.transcriptVersionID }) { Text(source.text).textSelection(.enabled) }
                                                        Button("打开资料及历史") { openSource(ref.sourceID) }.buttonStyle(.workspaceQuietCompact)
                                                    }
                                                }.vosFont(WorkspaceText.meta)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        if !model.discussionOutcomes.isEmpty {
                            DisclosureGroup("已保留的讨论成果") {
                                ForEach(model.discussionOutcomes) { outcome in
                                    ForEach(Array(outcome.proposals.enumerated()), id: \.offset) { index, proposal in
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(proposal.statement).textSelection(.enabled)
                                            let sourceID = outcome.claimIDs.indices.contains(index) ? model.claims.first(where: { $0.id == outcome.claimIDs[index] })?.references.first?.sourceID : nil
                                            Button("打开候选") { if let sourceID { openSource(sourceID) } }
                                                .buttonStyle(.workspaceQuietCompact)
                                                .disabled(sourceID == nil)
                                        }.padding(.vertical, 5)
                                    }
                                }
                            }.vosFont(WorkspaceText.meta)
                        }
                        Color.clear.frame(height: 1).id("discussion-end")
                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.discussionReplies.count) { _, _ in followLatest(reader) }
                .onChange(of: model.discussionTurns.count) { _, _ in followLatest(reader) }
                .onScrollGeometryChange(for: DiscussionScrollMetrics.self) { geometry in
                    DiscussionScrollMetrics(contentHeight: geometry.contentSize.height,
                                            distanceToBottom: geometry.contentSize.height - geometry.visibleRect.maxY)
                } action: { oldValue, newValue in
                    guard !scrollMetricsKnown || newValue.contentHeight == oldValue.contentHeight else { return }
                    scrollMetricsKnown = true
                    followTail = newValue.distanceToBottom < 48
                }
            }
            WorkspaceListDivider()
            VStack(alignment: .leading, spacing: 10) {
                if model.discussionWritable {
                    TextEditor(text: $draft).vosFont(WorkspaceText.body).scrollContentBackground(.hidden).frame(height: 90).workspaceEditorSurface().focused($editorFocused).disabled(busy)
                    if let id = model.discussionRecordingID, let source = model.records.first(where: { $0.id == id }) {
                        Text(source.transcript ?? (model.dictationActive ? "正在录制…" : "正在本地转写…")).vosFont(WorkspaceText.meta).lineLimit(5).textSelection(.enabled)
                    }
                    HStack {
                        Button(model.dictationActive ? "停止口述" : "口述", systemImage: model.dictationActive ? "stop.circle" : "mic") {
                            if model.dictationActive { model.stopDictation() } else { Task { await model.startDiscussionDictation() } }
                        }.buttonStyle(.workspaceSecondary).disabled(model.discussionSending || model.discussionSaving || model.dictationBusy)
                        Spacer()
                        Button(model.discussionSending ? "思考中…" : "发送") { Task { await send() } }.buttonStyle(.workspacePrimary).keyboardShortcut(.return, modifiers: .command).disabled(!canSend)
                    }
                    if !model.modelConfigured {
                        HStack(spacing: 8) {
                            Text("发送需要先配置文本模型。").vosFont(WorkspaceText.caption).foregroundStyle(palette.warning)
                            Button("配置文本模型…") { model.chooseTextModel() }.buttonStyle(.workspaceQuietCompact)
                        }
                    }
                    Text("发送即允许本轮文字用于 AI 讨论，音频保留本机。").vosFont(WorkspaceText.caption).foregroundStyle(.secondary)
                } else {
                    Text(model.discussionSession?.state == "ended" ? "这段讨论已结束，历史仍可回看。" : "这段讨论的依据已变化，只能回看；结束它不会改变历史。").vosFont(WorkspaceText.meta).foregroundStyle(.secondary)
                }
                if !model.discussionStatus.isEmpty { Text(model.discussionStatus).vosFont(WorkspaceText.meta).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(4) }
                if model.discussionWritable {
                    Button("结束并整理讨论") { confirmingEnd = true }.buttonStyle(.workspaceQuietCompact).disabled(busy)
                } else if model.discussionSession?.state == "active" {
                    Button("结束这段讨论") { Task { await model.endDiscussion() } }.buttonStyle(.workspaceQuietCompact).disabled(busy)
                } else if model.discussionCanExtract { Button("整理讨论成果") { model.extractDiscussionOutcome() }.buttonStyle(.workspaceQuietCompact) }
            }.padding(16)
        }.background(palette.sidebar)
            .alert("结束并整理这段讨论？", isPresented: $confirmingEnd) {
                Button("取消", role: .cancel) {}
                Button("结束并整理", role: .destructive) {
                    Task { await model.endDiscussion(); if model.discussionCanExtract { model.extractDiscussionOutcome() } }
                }
            } message: {
                Text("将调用一次模型把讨论整理为记录，会产生用量。")
            }
            .sheet(isPresented: $showingHistory) {
                DiscussionHistoryView(model: model, close: { showingHistory = false })
            }
            .task {
                // A focus write before the field attaches to its window is dropped.
                guard model.discussionWritable, !busy, !model.dictationBusy, !editorFocused,
                      !(NSApp.keyWindow?.firstResponder is NSText) else { return }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard !Task.isCancelled, !busy, !model.dictationBusy, !editorFocused,
                      !(NSApp.keyWindow?.firstResponder is NSText) else { return }
                editorFocused = true
            }
            .onExitCommand { close() }
            .onDisappear { editorFocused = false }
    }
    private func followLatest(_ reader: ScrollViewProxy) {
        guard followTail, !composing else { return }
        withAnimation(reduceMotion ? nil : WorkspaceMotion.scroll) {
            reader.scrollTo("discussion-end", anchor: .bottom)
        }
    }
    private func send() async {
        if model.discussionRecordingID != nil, !(await model.attachDiscussionRecording(allowCloud: true)) { return }
        if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard await model.saveDiscussionText(draft, allowCloud: true) else { return }
            draft = ""
        }
        followTail = true
        await model.sendDiscussion()
    }
}

private struct DiscussionScrollMetrics: Equatable {
    let contentHeight: CGFloat
    let distanceToBottom: CGFloat
}
