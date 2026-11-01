import SwiftUI
import VoiceOSCore

struct EnglishInputPreview: View {
    let snapshot: EnglishPracticeSnapshot
    let dismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("待发送的英文练习文字").font(.title2)
            Text("以下是完整选定文字；关闭此窗口不会发送。发送时会再次核对版本与授权，原始音频不上传。").font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(snapshot.context.sources.enumerated()), id: \.element.sourceID) { index, source in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(index == 0 ? "本次练习" : "旧练习 \(index)").font(.headline)
                            Text(source.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            HStack { Spacer(); Button("返回", action: dismiss).keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 640, height: 480)
    }
}
struct EnglishPracticeView: View {
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
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("英文表达反馈").font(.title2)
            Text("只发送选定的个人文字和出处；原始音频不会上传。反馈独立保存，不创建认知候选、行动或提醒事项。")
                .font(.callout).foregroundStyle(.secondary)
            if sources.isEmpty {
                ContentUnavailableView {
                    Label("还没有可练习的英文原话", systemImage: "character.book.closed")
                } description: {
                    Text("需要一份已保存、已完成文字转写的个人原话。完成一段英文录音并保存后，回到这里即可练习。")
                } actions: {
                    if let openCapture { Button("去记录英文表达", action: openCapture).buttonStyle(.borderedProminent) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Picker("本次练习", selection: $currentID) {
                    Text("选择一份我的英文原话").tag("")
                    ForEach(sources) { source in
                        Text(String((source.transcript ?? source.name).prefix(90))).tag(source.id)
                    }
                }
                .disabled(model.englishBusy)
                .onChange(of: currentID) { _, _ in
                    if suppressSelectionReset { suppressSelectionReset = false; return }
                    priorIDs = priorIDs.filter { $0 != currentID }; model.englishSnapshot = nil; model.englishStatus = "选择已变化，请重新准备并核对文字。"
                }
                Text("可选旧练习（最多 2 份）").font(.headline)
                ScrollView {
                    ForEach(priorCandidates) { source in
                        Toggle(isOn: Binding(get: { priorIDs.contains(source.id) }, set: { value in
                            if value { if priorIDs.count < 2 { priorIDs.insert(source.id) } }
                            else { priorIDs.remove(source.id) }
                            model.englishSnapshot = nil; model.englishStatus = "选择已变化，请重新准备并核对文字。"
                        })) {
                            VStack(alignment: .leading) { Text(source.name); Text(source.transcript ?? "").lineLimit(2).font(.caption).foregroundStyle(.secondary) }
                        }.disabled(model.englishBusy || (!priorIDs.contains(source.id) && priorIDs.count >= 2))
                    }
                }.frame(maxHeight: model.englishAttempts.isEmpty ? 210 : 110)
                Text(model.englishStatus).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("准备并核对文字") { if let current { Task { await model.prepareEnglishPractice(current: current, priorIDs: Array(priorIDs)) } } }
                        .disabled(current == nil || model.englishBusy)
                    Button(model.englishBusy ? "正在发送…" : "发送文本反馈") { Task { await model.performEnglishPractice() } }
                        .disabled(model.englishSnapshot == nil || model.englishBusy || !model.modelConfigured)
                    if !model.modelConfigured { Button("配置文本模型…") { model.chooseTextModel() } }
                    if model.englishSnapshot != nil { Button("查看待发送文字…") { showingInput = true } }
                    Spacer(); if !embedded { Button("完成", action: dismiss).keyboardShortcut(.cancelAction) }
                }
            }
            if !model.englishAttempts.isEmpty {
                Divider(); Text("反馈历史（\(model.englishAttempts.count)）").font(.headline)
                ScrollView {
                ForEach(model.englishAttempts) { attempt in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(attempt.state == "completed" ? "已保存" : attempt.state == "reserved" ? "等待结果" : "未完成 · 不自动重发") · \(attempt.createdAt)").font(.caption)
                        if let reason = attempt.error { Text(reason).font(.caption).foregroundStyle(.secondary) }
                        Text("用量：\(attempt.inputTokens.map(String.init) ?? "未知") / \(attempt.outputTokens.map(String.init) ?? "未知") tokens · 费用未知").font(.caption).foregroundStyle(.secondary)
                        if attempt.validity == "frozen" { Text("历史反馈 · 依据或授权已变化，暂停当前使用").font(.caption).foregroundStyle(.orange) }
                        if let result = attempt.result {
                            ForEach(Array(result.suggestions.enumerated()), id: \.offset) { index, suggestion in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("建议 \(index + 1) · \(suggestion.kind.rawValue)").font(.callout.bold())
                                    Text("原句：\(suggestion.original.quote)").textSelection(.enabled)
                                    Text("建议：\(suggestion.suggestedText)").textSelection(.enabled)
                                    Text(suggestion.explanation).font(.caption).foregroundStyle(.secondary)
                                    if suggestion.possibleTranscriptIssue { Text("可能是转写问题，需人工核对").font(.caption).foregroundStyle(.orange) }
                                }.padding(8).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                            }
                            ForEach(Array(result.comparisons.enumerated()), id: \.offset) { _, comparison in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("本次：\(comparison.current.quote)").textSelection(.enabled)
                                    Text("旧练习：\(comparison.prior.quote)").textSelection(.enabled)
                                    Text("比较：\(comparison.explanation)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Text("文字建议不代表发音、熟练度或学习效果判断。").font(.caption).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }.padding(24).frame(width: embedded ? nil : 700, height: embedded ? nil : 600)
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
}
