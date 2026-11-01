import AppKit
import SwiftUI
import VoiceOSCore

struct WorkspaceDiscussionView: View {
    @Environment(\.workspacePalette) private var palette
    @ObservedObject var model: ControlCenter
    @Binding var draft: String
    let close: () -> Void
    let openSource: (String) -> Void
    @FocusState private var editorFocused: Bool
    private var busy: Bool { model.discussionSaving || model.discussionSending || model.discussionExtracting || model.dictationActive }
    private var canSend: Bool {
        model.discussionWritable && model.modelConfigured && !busy && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.discussionCanSend || model.discussionRecordingID != nil)
    }
    private var contextTitle: String {
        if let title = model.discussionReflection?.question?.title { return title }
        if model.discussionHistory.count == 1, let id = model.discussionHistory.first?.sourceID,
           let source = model.records.first(where: { $0.id == id }) { return source.workspaceTitle }
        return "\(model.discussionHistory.count) 份材料的讨论"
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Label("一起思考", systemImage: "sparkles").font(.headline)
                    Text(contextTitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.plain).help("收起讨论，保留阅读位置")
            }.padding(18)
            Divider()
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if let focus = model.discussionReflection, let topic = focus.question { Text(topic.title).font(.subheadline.weight(.medium)) }
                        DisclosureGroup("本次讨论的依据") {
                            ForEach(model.discussionHistory, id: \.sourceID) { source in
                                Button { openSource(source.sourceID) } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(source.origin == "user" ? "我的表达" : source.origin == "ai" ? "AI 交付" : "外部资料").font(.caption).foregroundStyle(.secondary)
                                        Text(source.text).lineLimit(3)
                                        if source.localOnly { Text("仅本地 · 发送前需在材料详情授权").font(.caption).foregroundStyle(.orange) }
                                    }.padding(.vertical, 6)
                                }.buttonStyle(.plain)
                            }
                        }.font(.caption)
                        if model.discussionTurns.isEmpty { Text("带着眼前的内容继续想。输入问题后直接发送。").foregroundStyle(.secondary) }
                        ForEach(model.discussionTurns) { turn in
                            VStack(alignment: .leading, spacing: 10) {
                                Text("我").font(.caption).foregroundStyle(.secondary)
                                Text(turn.text).textSelection(.enabled).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(palette.selection, in: RoundedRectangle(cornerRadius: 9))
                                ForEach(model.discussionReplies.filter { $0.replyToTurnID == turn.id }) { reply in
                                    Text(reply.validity == "current" ? "VoiceOS" : "VoiceOS · 历史依据").font(.caption).foregroundStyle(.secondary)
                                    if reply.parts.isEmpty { Text(reply.state == "reserved" ? "正在思考…" : "这次回复未完成，原因见下方。").foregroundStyle(.secondary) }
                                    ForEach(Array(reply.parts.enumerated()), id: \.offset) { _, part in
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text(.init(part.text)).textSelection(.enabled).lineSpacing(4)
                                            if !part.references.isEmpty {
                                                DisclosureGroup("原文依据") {
                                                    ForEach(Array(part.references.enumerated()), id: \.offset) { _, ref in
                                                        if let source=model.discussionHistory.first(where: { $0.sourceID == ref.sourceID && $0.transcriptVersionID == ref.transcriptVersionID }) { Text(source.text).textSelection(.enabled) }
                                                        Button("打开资料及历史") { openSource(ref.sourceID) }
                                                    }
                                                }.font(.caption)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        if !model.discussionOutcomes.isEmpty {
                            DisclosureGroup("已保留的讨论成果") {
                                ForEach(model.discussionOutcomes) { outcome in
                                    ForEach(Array(outcome.proposals.enumerated()), id: \.offset) { _, proposal in Text(proposal.statement).textSelection(.enabled).padding(.vertical, 5) }
                                }
                            }.font(.caption)
                        }
                        Color.clear.frame(height: 1).id("discussion-end")
                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.discussionReplies.count) { _, _ in withAnimation { reader.scrollTo("discussion-end", anchor: .bottom) } }
                .onChange(of: model.discussionTurns.count) { _, _ in withAnimation { reader.scrollTo("discussion-end", anchor: .bottom) } }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if model.discussionWritable {
                    TextEditor(text: $draft).font(.body).scrollContentBackground(.hidden).frame(height: 90).padding(7).background(palette.surface, in: RoundedRectangle(cornerRadius: 7)).focused($editorFocused).disabled(busy)
                    if let id = model.discussionRecordingID, let source = model.records.first(where: { $0.id == id }) {
                        Text(source.transcript ?? (model.dictationActive ? "正在录制…" : "正在本地转写…")).font(.caption).lineLimit(5).textSelection(.enabled)
                    }
                    HStack {
                        Button(model.dictationActive ? "停止口述" : "口述", systemImage: model.dictationActive ? "stop.circle" : "mic") {
                            if model.dictationActive { model.stopDictation() } else { Task { await model.startDiscussionDictation() } }
                        }.disabled(model.discussionSending || model.discussionSaving || model.dictationBusy)
                        Spacer()
                        Button(model.discussionSending ? "思考中…" : "发送") { Task { await send() } }.buttonStyle(.borderedProminent).disabled(!canSend)
                    }
                    Text("发送即允许本轮文字用于 AI 讨论，音频保留本机。").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text(model.discussionSession?.state == "ended" ? "这段讨论已结束，历史仍可回看。" : "依据已变化，请从当前内容重新进入讨论。").font(.callout).foregroundStyle(.secondary)
                }
                if !model.discussionStatus.isEmpty { Text(model.discussionStatus).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(4) }
                if model.discussionWritable {
                    Button("结束并整理讨论") { Task { await model.endDiscussion(); if model.discussionCanExtract { model.extractDiscussionOutcome() } } }.font(.caption).buttonStyle(.plain).foregroundStyle(.secondary).disabled(busy)
                } else if model.discussionCanExtract { Button("整理讨论成果") { model.extractDiscussionOutcome() }.font(.caption) }
            }.padding(16)
        }.background(palette.sidebar)
            .task {
                // A focus write before the field attaches to its window is dropped.
                guard model.discussionWritable, !busy, !model.dictationBusy, !editorFocused,
                      !(NSApp.keyWindow?.firstResponder is NSText) else { return }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard !Task.isCancelled, !busy, !model.dictationBusy, !editorFocused,
                      !(NSApp.keyWindow?.firstResponder is NSText) else { return }
                editorFocused = true
            }
            .onDisappear { editorFocused = false }
    }
    private func send() async {
        if model.discussionRecordingID != nil, !(await model.attachDiscussionRecording(allowCloud: true)) { return }
        if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard await model.saveDiscussionText(draft, allowCloud: true) else { return }
            draft = ""
        }
        await model.sendDiscussion()
    }
}
