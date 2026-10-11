import SwiftUI
import VoiceOSCore

extension QuestionStatus {
    var displayLabel: String {
        switch self {
        case .open: return "尚未登记解决依据"
        case .exploring: return "明确继续研究"
        case .resolved: return "已登记答案 · 未代表客观验证"
        case .closed: return "已明确停止追踪"
        }
    }
}
struct QuestionStateView: View {
    let question: QuestionRecord
    @ObservedObject var model: ControlCenter
    @State private var changing = false
    @State private var answerHistory: QuestionRevision?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("问题第 \(question.version) 版 · \(question.status.displayLabel)").font(.callout)
            if question.seed.ownership == "ai_candidate" { Text("AI 提出的问题 · 不代表我的疑问").font(.caption).foregroundStyle(.secondary) }
            if question.validity == "frozen" { Text("历史状态 · 原话、归属或答案依据已变化，暂停当前使用").font(.caption).foregroundStyle(.orange) }
            if question.canReopen { Text("当前答案依据已变化；可明确重开，旧答案仍保留在历史中。").font(.caption).foregroundStyle(.secondary) }
            Button(question.canReopen ? "重新打开并保留历史…" : "登记问题状态…") { changing = true }.disabled((question.validity != "current" && !question.canReopen) || model.savingQuestion)
            if let revisions = model.questionRevisions[question.id], !revisions.isEmpty {
                DisclosureGroup("问题状态历史（\(revisions.count)）") {
                    ForEach(revisions) { revision in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("第 \(revision.input.expectedVersion + 1) 版 · \(revision.input.to.displayLabel)").font(.caption.bold())
                            Text("用户登记：" + revision.input.reason).font(.caption).textSelection(.enabled)
                            if let evidence = revision.input.resolution {
                                Text("答案原话：" + evidence.quote).font(.callout).textSelection(.enabled)
                                HStack {
                                    Button("核对当时答案版本") { answerHistory = revision }
                                    Button("查看答案来源当前页") { model.selected = evidence.reference.sourceID }
                                }
                            }
                            Text(revision.createdAt).font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 4)
                    }
                }
            }
        }.sheet(item: $answerHistory) { revision in
            VStack(alignment: .leading, spacing: 12) {
                Text("当时登记的答案依据").font(.title2)
                Text("这是历史版本。原话更正后仍保留原依据，当前状态可能已冻结。").font(.caption).foregroundStyle(.secondary)
                if let evidence = revision.input.resolution,
                   let source = revision.input.resolutionContext?.sources.first(where: { $0.sourceID == evidence.reference.sourceID }) {
                    Text("逐字稿版本：" + source.transcriptVersionID).font(.caption)
                    Text("引用：" + evidence.quote).textSelection(.enabled)
                    ScrollView { Text(source.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 260)
                }
                HStack { Spacer(); Button("完成") { answerHistory = nil }.keyboardShortcut(.cancelAction) }
            }.padding(24).frame(width: 620)
        }.sheet(isPresented: $changing) {
            QuestionTransitionView(question: question, model: model) { changing = false }
        }
    }
}
struct QuestionTransitionView: View {
    let question: QuestionRecord
    @ObservedObject var model: ControlCenter
    let dismiss: () -> Void
    @State private var target = QuestionStatus.exploring
    @State private var reason = ""
    @State private var answerSource = ""
    @State private var answerQuote = ""
    @State private var commandID = UUID().uuidString
    private var allowed: [QuestionStatus] {
        if question.status == .closed || question.status == .resolved { return [.open] }
        return [QuestionStatus.open, .exploring, .resolved, .closed].filter { $0 != question.status }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("登记问题状态").font(.title2)
            Text(question.seed.statement).textSelection(.enabled)
            Text("当前：" + question.status.displayLabel).foregroundStyle(.secondary)
            Picker("新状态", selection: $target) {
                ForEach(allowed, id: \.rawValue) { status in Text(status.displayLabel).tag(status) }
            }
            TextField("原因或研究进展（必填）", text: $reason)
            if target == .resolved {
                Text("选择一份明确回答这个问题的个人表达，并引用连续原话。记录解决不改变认知的未验证状态。").font(.caption)
                Picker("答案出处", selection: $answerSource) {
                    Text("请选择我的表达").tag("")
                    ForEach(model.records.filter { $0.origin == "user" && $0.speaker == "user" && $0.transcriptVersionID != nil }) { source in Text(source.name).tag(source.id) }
                }
                if let text = model.records.first(where: { $0.id == answerSource })?.transcript {
                    ScrollView { Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 130)
                }
                TextField("连续答案原话（必填）", text: $answerQuote)
            }
            Text(model.status).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("取消", action: dismiss).keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存状态") {
                    Task {
                        if await model.changeQuestion(question, to: target, reason: reason, answerSourceID: target == .resolved ? answerSource : nil, answerQuote: target == .resolved ? answerQuote : nil, commandID: commandID) { dismiss() }
                        else { commandID = UUID().uuidString }
                    }
                }.disabled(model.savingQuestion || reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (target == .resolved && (answerSource.isEmpty || answerQuote.isEmpty)))
            }
        }.padding(24).frame(width: 620)
        .onAppear { target = allowed[0] }
    }
}

/// Citation context only. AI relation proposals never become question lifecycle commands.
struct AssociationQuestionsView: View {
    let item: ExpressionAssociationFeedback
    @ObservedObject var model: ControlCenter
    var body: some View {
        if !item.historicalQuestions.isEmpty {
            DisclosureGroup("此历史出处登记的问题（\(item.historicalQuestions.count)）") {
                Text("这是出处中的问题记录；AI关联提案不确认两次表达是同一问题，也不改变解决状态。").font(.caption).foregroundStyle(.secondary)
                ForEach(item.historicalQuestions) { saved in
                    // Prefer the current local projection after an explicit state operation.
                    let question = model.questionRecords.first(where: { $0.id == saved.id }) ?? saved
                    VStack(alignment: .leading, spacing: 5) {
                        Text(question.seed.statement).textSelection(.enabled)
                        Text(question.seed.ownership == "user_tentative" ? "我的暂定问题 · 未验证" : question.seed.ownership == "ai_candidate" ? "AI 候选问题 · 未验证" : "来源问题 · 归属保持").font(.caption).foregroundStyle(.secondary)
                        QuestionStateView(question: question, model: model)
                    }.padding(.vertical, 5)
                }
            }
        }
    }
}
