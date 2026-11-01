import SwiftUI
import VoiceOSCore

struct RecordingFollowupSummary: View {
    @Environment(\.workspacePalette) private var palette
    let receipt: RecordingFollowupReceipt
    @ObservedObject var model: ControlCenter
    let open: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let result = receipt.result {
                Text("旧思想关联 \(result.thoughtUpdates.count) · 目标下一步 \(result.goalPlans.count)" + (result.english.isPractice ? " · 英语反馈已接续" : "")).font(.callout)
                if model.followupValidity[receipt.id]?.sourceCurrent != true { Text("录音依据已变化，历史结果保留；可重新生成跟进").font(.caption).foregroundStyle(.secondary) }
            } else {
                Text(receipt.state == "running" ? "正在后台生成思想关联与下一步" : receipt.state == "queued" ? "思想关联与下一步已排队，录音和任务已保存" : "自动跟进待完成，可重试").font(.callout)
            }
            Button("查看思想与下一步", action: open)
        }.padding(10).background(palette.surface, in: RoundedRectangle(cornerRadius: WorkspaceMetrics.controlRadius))
    }
}

struct RecordingFollowupView: View {
    @Environment(\.workspacePalette) private var palette
    @ObservedObject var model: ControlCenter
    let embedded: Bool
    let dismiss: () -> Void
    @State private var tab: String
    init(model: ControlCenter, initialTab: String = "thoughts", embedded: Bool = false, dismiss: @escaping () -> Void) {
        self.model = model; self.embedded = embedded; self.dismiss = dismiss; _tab = State(initialValue: initialTab)
    }
    @State private var sourceID = "all"
    @State private var includeHistory = false
    private var latest: [RecordingFollowupReceipt] {
        var seen = Set<String>()
        return model.recordingFollowups.reversed().filter { seen.insert($0.sourceID).inserted }
    }
    private var visible: [RecordingFollowupReceipt] {
        (includeHistory ? Array(model.recordingFollowups.reversed()) : latest).filter { sourceID == "all" || $0.sourceID == sourceID }
    }
    private var eligible: [SourceRecord] { model.records.filter { $0.origin == "user" && $0.speaker == "user" && !$0.localOnly && $0.transcript != nil } }
    private func sourceName(_ id: String) -> String { model.records.first(where: { $0.id == id })?.displayTitle ?? "历史录音" }
    private func thoughtCurrent(_ receipt: RecordingFollowupReceipt, _ id: String) -> Bool { model.followupValidity[receipt.id]?.thoughtIsCurrent(id) == true }
    private func goalCurrent(_ receipt: RecordingFollowupReceipt, _ id: String) -> Bool { model.followupValidity[receipt.id]?.goalIsCurrent(id) == true }
    private func englishCurrent(_ receipt: RecordingFollowupReceipt) -> Bool { model.followupValidity[receipt.id]?.sourceCurrent == true && model.followupValidity[receipt.id]?.english == true }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                WorkspaceHeading(eyebrow: "工具 · 思想与下一步", title: "思想与下一步")
                if !embedded { Button("完成", action: dismiss) }
            }
            Picker("查看", selection: $tab) {
                Text("思想变化").tag("thoughts"); Text("目标下一步").tag("goals"); Text("英语练习").tag("english")
            }.pickerStyle(.segmented)
            HStack {
                Picker("来源", selection: $sourceID) {
                    Text("全部录音").tag("all")
                    ForEach(eligible) { source in Text(source.displayTitle).tag(source.id) }
                }
                Button(sourceID == "all" ? "更新下一步" : "生成或重试跟进") {
                    if let id = sourceID == "all" ? nil : sourceID { model.refreshFollowup(id) }
                }.buttonStyle(.borderedProminent)
                    .disabled(model.followupBusy || model.fullRecordingBusy || eligible.isEmpty || sourceID == "all")
                if model.followupBusy { ProgressView().controlSize(.small) }
                if sourceID == "all", !eligible.isEmpty { Text("先在来源里选择一份录音，再生成跟进。").font(.caption).foregroundStyle(.secondary) }
            }
            Text(model.followupStatus).font(.caption).foregroundStyle(.secondary)
            Toggle("显示历史版本", isOn: $includeHistory).font(.caption)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if visible.isEmpty { ContentUnavailableView("新的录音会自动形成跟进", systemImage: "sparkles", description: Text("也可以选择已有录音，补齐思想关联、目标建议和练习反馈。")) }
                    if tab == "goals" { goalList }
                    else {
                        ForEach(visible) { receipt in
                            if let result = receipt.result {
                                if tab == "thoughts" && !result.thoughtUpdates.isEmpty {
                                    receiptHeader(receipt)
                                    ForEach(Array(result.thoughtUpdates.enumerated()), id: \.offset) { _, update in thoughtCard(update, receipt: receipt) }
                                }
                                if tab == "english" && result.english.isPractice {
                                    receiptHeader(receipt)
                                    practiceCard(result.english, receipt: receipt)
                                }
                            } else {
                                receiptHeader(receipt)
                                Text(receipt.error ?? (receipt.state == "running" ? "正在后台生成，你可以继续录音或关闭窗口，结果会自动保存。" : receipt.state == "queued" ? "等待后台继续；重开应用后会恢复，录音和任务已保存。" : "尚未完成，可重试。录音与已生成任务仍然保留。")).font(.caption).foregroundStyle(.secondary)
                                if receipt.retryAt != nil { Text("网络恢复后会自动重试，录音和任务已保留").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        if tab == "thoughts" && visible.allSatisfy({ $0.result?.thoughtUpdates.isEmpty != false }) { Text("这几份录音尚未形成有依据的旧思想关联。").foregroundStyle(.secondary) }
                        if tab == "english" && visible.allSatisfy({ $0.result?.english.isPractice != true }) { Text("尚未记录英语表达练习；英文练习录音整理后会自动生成反馈并沿用旧反馈。").foregroundStyle(.secondary) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
            }
        }.padding(24).frame(width: embedded ? nil : 820, height: embedded ? nil : 700)
    }
    private func receiptHeader(_ receipt: RecordingFollowupReceipt) -> some View {
        HStack {
            Text(sourceName(receipt.sourceID)).font(.headline).lineLimit(1)
            Spacer()
            if receipt.state == "running" { Text("生成中").font(.caption).foregroundStyle(.secondary) }
            else if receipt.state == "completed" && model.followupValidity[receipt.id]?.sourceCurrent != true { Text("录音依据 · 待刷新").font(.caption).foregroundStyle(palette.warning) }
            Button("原录音") { model.selected = receipt.sourceID; dismiss() }
        }
    }
    private func thoughtCard(_ update: ThoughtUpdate, receipt: RecordingFollowupReceipt) -> some View {
        let labels = ["supports": "新增支持", "qualifies": "理解被限定", "contradicts": "前后判断不同", "continues": "思考延续"]
        let target = receipt.input.thoughts.first { $0.id == update.claimID }
        return VStack(alignment: .leading, spacing: 8) {
            Text(labels[update.relation] ?? "思想关联").font(.caption).foregroundStyle(.secondary)
            if !thoughtCurrent(receipt, update.claimID) { Text("这条关联的依据已变化").font(.caption).foregroundStyle(palette.warning) }
            Text(update.understanding).font(.headline).textSelection(.enabled)
            DisclosureGroup("前后原话与出处") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(update.reason).font(.callout).foregroundStyle(.secondary)
                    Text("此前：" + update.historicalQuote).textSelection(.enabled)
                    if let old = target?.evidence.first(where: { $0.quote.contains(update.historicalQuote) }) {
                        quoteActions(sourceID: old.reference.sourceID, quote: update.historicalQuote)
                    }
                    Text("这次：" + update.currentQuote).textSelection(.enabled)
                    quoteActions(sourceID: receipt.sourceID, quote: update.currentQuote)
                    Text("依据个人表达形成的关系，不代表外部事实已经验证。").font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 6)
            }
        }.padding(12).background(palette.surface, in: RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
    }
    private var goalList: some View {
        var seen = Set<String>()
        let plans = visible.flatMap { receipt in (receipt.result?.goalPlans ?? []).compactMap { plan -> (RecordingFollowupReceipt, GoalPlan)? in
            guard includeHistory || seen.insert(plan.goalID).inserted else { return nil }; return (receipt, plan)
        } }
        return VStack(alignment: .leading, spacing: 14) {
            if plans.isEmpty { Text("明确的长期目标整理后，会自动形成阶段行动和下一步建议。").foregroundStyle(.secondary) }
            ForEach(Array(plans.enumerated()), id: \.offset) { _, pair in
                let receipt = pair.0, plan = pair.1
                VStack(alignment: .leading, spacing: 8) {
                    Text(receipt.input.goals.first(where: { $0.id == plan.goalID })?.title.replacingOccurrences(of: "【长期目标】", with: "") ?? plan.summary).font(.headline).lineLimit(2)
                    HStack(alignment: .top) {
                        Text("下一步：" + plan.nextStep.title).font(.callout).lineLimit(2)
                        Spacer()
                        Button(plan.nextStep.existingTaskID.isEmpty ? "选为待办" : "查看待办") {
                            if !plan.nextStep.existingTaskID.isEmpty { model.showTask(plan.nextStep.existingTaskID); dismiss() }
                            else { Task { await model.activateStep(plan.nextStep, plan: plan, receipt: receipt) } }
                        }.disabled(!goalCurrent(receipt, plan.goalID) || model.savingAction)
                        if !goalCurrent(receipt, plan.goalID) { Text("该目标或阶段任务已变化，请更新建议").font(.caption).foregroundStyle(palette.warning) }
                    }
                    DisclosureGroup("阶段、条件与依据") {
                        Text(plan.summary).font(.callout).textSelection(.enabled)
                        if !plan.nextStep.condition.isEmpty { Text("执行条件：" + plan.nextStep.condition).font(.callout).textSelection(.enabled) }
                        Text(plan.adjustment).font(.caption).foregroundStyle(.secondary)
                        ForEach(Array(plan.phases.enumerated()), id: \.offset) { _, phase in
                            Text(phase.title).font(.subheadline.bold()).padding(.top, 6)
                            ForEach(Array(phase.steps.enumerated()), id: \.offset) { _, step in
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(step.title)
                                        if !step.condition.isEmpty { Text(step.condition).font(.caption).foregroundStyle(.secondary) }
                                    }
                                    Spacer()
                                    Button(step.existingTaskID.isEmpty ? "选用" : "已有任务") { Task { await model.activateStep(step, plan: plan, receipt: receipt) } }.disabled(!goalCurrent(receipt, plan.goalID) || model.savingAction)
                                }.padding(.vertical, 4)
                            }
                        }
                        if let goal = receipt.input.goals.first(where: { $0.id == plan.goalID }) {
                            ForEach(Array(goal.thought.evidence.enumerated()), id: \.offset) { _, evidence in
                                Text("目标原话：" + evidence.quote).font(.caption).textSelection(.enabled)
                                quoteActions(sourceID: evidence.reference.sourceID, quote: evidence.quote)
                            }
                        }
                        Text("阶段步骤是 AI 建议；选用后才成为你的任务。").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(12).background(palette.surface, in: RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
            }
        }
    }
    private func practiceCard(_ practice: PracticeFollowup, receipt: RecordingFollowupReceipt) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !englishCurrent(receipt) { Text("英语练习的原话或比较依据已变化").font(.caption).foregroundStyle(palette.warning) }
            ForEach(Array(practice.suggestions.enumerated()), id: \.offset) { _, suggestion in
                VStack(alignment: .leading, spacing: 4) {
                    Text(suggestion.original).textSelection(.enabled)
                    Text(suggestion.suggested).fontWeight(.medium).textSelection(.enabled)
                    Text(suggestion.explanation).font(.caption).foregroundStyle(.secondary)
                    if suggestion.possibleTranscriptIssue { Text("可能是转写问题，建议回听核对").font(.caption).foregroundStyle(palette.warning) }
                    quoteActions(sourceID: receipt.sourceID, quote: suggestion.original)
                }
            }
            ForEach(Array(practice.comparisons.enumerated()), id: \.offset) { _, comparison in
                DisclosureGroup(["repeated": "上次问题再次出现", "improved": "这次表达有所改善", "changed": "表达方式变化", "uncertain": "变化尚不能确定"][comparison.change] ?? "练习比较") {
                    Text("此前：" + comparison.priorQuote).textSelection(.enabled)
                    Text("这次：" + comparison.currentQuote).textSelection(.enabled)
                    Text(comparison.explanation).font(.caption).foregroundStyle(.secondary)
                    quoteActions(sourceID: comparison.priorSourceID, quote: comparison.priorQuote)
                }
            }
            Text("下次可以试试：" + practice.nextExercise).font(.callout.bold())
            Text("基于原句的表达反馈，不提供发音或掌握度评分。").font(.caption).foregroundStyle(.secondary)
        }.padding(12).background(palette.surface, in: RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
    }
    private func quoteActions(sourceID: String, quote: String) -> some View {
        HStack {
            Text(sourceName(sourceID)).font(.caption).lineLimit(1).foregroundStyle(.secondary)
            Button("查看出处") { model.selected = sourceID; dismiss() }
            if model.records.first(where: { $0.id == sourceID })?.kind != "user_text" { Button("回听") { Task { await model.playFollowupQuote(sourceID: sourceID, quote: quote) } } }
        }.font(.caption)
    }
}
