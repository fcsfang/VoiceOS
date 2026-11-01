import SwiftUI
import VoiceOSCore

struct ReflectionEventListView: View {
    @Environment(\.workspacePalette) private var palette
    @ObservedObject var model: ControlCenter
    let dismiss: () -> Void
    let discuss: (CandidateClaim) -> Void
    let focus: ConversationReflectionFocus
    var openSource: ((String)->Void)? = nil
    @State private var query = ""

    private func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    private func knowledge(_ source: SourceRecord) -> [CandidateClaim] {
        let taskClaims = Set(model.actionRecords.filter { $0.kind == "task" }.map(\.claimID))
        return (model.currentClaimsBySource[source.id] ?? []).filter {
            $0.validity == "current" && $0.reviewState != "rejected" && !taskClaims.contains($0.id)
        }
    }
    private func tasks(_ source: SourceRecord) -> [ActionRecord] {
        let claimIDs = Set(model.claims.filter { claim in
            claim.references.contains { $0.sourceID == source.id }
        }.map(\.id))
        return model.actionRecords.filter { $0.kind == "task" && $0.validity == "current" && claimIDs.contains($0.claimID) }
    }
    private func updates(_ source: SourceRecord) -> [ThoughtUpdate] {
        var seen = Set<String>()
        return model.recordingFollowups.reversed().filter { $0.sourceID == source.id }.flatMap { receipt in
            (receipt.result?.thoughtUpdates ?? []).filter { update in
                model.followupValidity[receipt.id]?.thoughtIsCurrent(update.claimID) == true &&
                seen.insert(update.claimID + ":" + update.currentQuote).inserted
            }
        }
    }
    private func action(_ feedback: ActionFeedbackRecord) -> ActionRecord? {
        model.actionRecords.first { $0.id == feedback.actionID }
    }
    private func matches(_ text: String) -> Bool {
        query.split(whereSeparator: \.isWhitespace).allSatisfy { text.localizedCaseInsensitiveContains(String($0)) }
    }
    private var events: [ReflectionTimelineEvent] {
        let periodSources = Set(focus.expressions.filter(\.isInPeriod).map(\.id))
        let sources = model.records.filter { source in
            periodSources.contains(source.id) && ["saved", "reference_only"].contains(source.state) &&
            matches(([source.displayTitle, source.name, source.transcript ?? ""] +
                knowledge(source).map(\.statement) + tasks(source).map(\.title) + updates(source).map(\.understanding)).joined(separator: "\n"))
        }.map { ReflectionTimelineEvent(id: "source:" + $0.id, date: $0.expressedDate ?? date($0.createdAt), source: $0, feedback: nil, completion: nil) }
        let outcomes = focus.outcomes.filter {
            ["saved", "reference_only"].contains($0.sourceState) && matches((action($0)?.title ?? "") + "\n" + $0.text)
        }.map { ReflectionTimelineEvent(id: "outcome:" + $0.id, date: date($0.createdAt), source: nil, feedback: $0, completion: nil) }
        let completions = focus.completions.filter { completion in
            matches(focus.tasks.first { $0.actionID == completion.actionID }?.title ?? "任务完成")
        }.map { ReflectionTimelineEvent(id: "completion:" + $0.id, date: date($0.revision.createdAt), source: nil, feedback: nil, completion: $0) }
        return (sources + outcomes + completions).filter { event in
            event.date.map { focus.contains($0) } ?? false
        }.sorted {
            if $0.date == $1.date { return $0.id < $1.id }
            return ($0.date ?? .distantPast) > ($1.date ?? .distantPast)
        }
    }
    private func days(_ events: [ReflectionTimelineEvent]) -> [ReflectionTimelineDay] {
        var result: [ReflectionTimelineDay] = []
        for event in events {
            let day = event.date.map { Calendar.current.startOfDay(for: $0) }
            if result.last?.date == day, !result.isEmpty { result[result.count - 1].events.append(event) }
            else { result.append(.init(date: day, events: [event])) }
        }
        return result
    }

    var body: some View {
        let visible = events
        VStack(alignment: .leading, spacing: 14) {
            WorkspaceSearchField(text: $query, placeholder: "查找录音、思考、任务或结果")
            Text("\(visible.filter { $0.source != nil }.count) 条表达 · \(visible.filter { $0.feedback != nil }.count) 条结果与反思 · \(visible.filter { $0.completion != nil }.count) 条完成登记")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if visible.isEmpty {
                        ContentUnavailableView(query.isEmpty ? (focus.isTopicOverview ? "这个主题还没有关联记录" : "这段时间还没有记录") : "没有找到相关记录", systemImage: "clock", description: Text(focus.isTopicOverview ? "可以关联一份资料、留下认识，或换一个关键词。" : "可以扩大时间范围，或换一个关键词。"))
                    }
                    ForEach(days(visible)) { day in
                        Text(day.date?.formatted(date: .complete, time: .omitted) ?? "时间待核对").font(.headline)
                        ForEach(day.events) { event in
                            if let source = event.source { expressionCard(source) }
                            if let feedback = event.feedback { outcomeCard(feedback, date: event.date) }
                            if let completion = event.completion {
                                VStack(alignment: .leading, spacing: 6) {
                                    Label("完成登记 · " + (focus.tasks.first { $0.actionID == completion.actionID }?.title ?? "任务"), systemImage: "checkmark.circle")
                                    Text("按实际状态记录时间排列；不代表已取得收获。").font(.caption).foregroundStyle(.secondary)
                                    Button("任务与结果") { model.showTask(completion.actionID); dismiss() }
                                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(palette.surface, in: RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
            }
        }.padding(20)
    }
    private func expressionCard(_ source: SourceRecord) -> some View {
        let claims = knowledge(source), actions = tasks(source), connections = updates(source)
        return DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                if let summary = source.contentSummary { Text(summary).font(.callout).textSelection(.enabled) }
                Button(source.kind == "ai_text" ? "查看 AI 交付全文" : source.kind == "user_text" ? "查看表达全文" : "查看录音与全文") { showSource(source.id) }
                if claims.isEmpty && actions.isEmpty { Text("尚无当前有效的整理内容；可以打开全文查看表达。").font(.callout).foregroundStyle(.secondary) }
                ForEach(claims) { claim in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(claim.statement).textSelection(.enabled)
                        HStack {
                            Text(owner(claim)).font(.caption).foregroundStyle(.secondary)
                            Button("讨论这条思考") { discuss(claim) }
                                .disabled(model.discussionSaving || model.discussionSending || model.discussionExtracting || model.dictationActive)
                        }
                    }
                }
                if !connections.isEmpty {
                    Text("这次表达接续了以前的思考").font(.subheadline.bold())
                    ForEach(Array(connections.enumerated()), id: \.offset) { _, update in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(update.understanding).font(.callout).textSelection(.enabled)
                            DisclosureGroup("前后原话") {
                                Text("此前：" + update.historicalQuote).textSelection(.enabled)
                                Text("这次：" + update.currentQuote).textSelection(.enabled)
                            }.font(.caption)
                        }
                    }
                }
                if !actions.isEmpty {
                    Text("任务当前状态").font(.subheadline.bold())
                    Text("这是现在的状态，不代表任务在这一天完成。").font(.caption).foregroundStyle(.secondary)
                    ForEach(actions) { task in
                        HStack(alignment: .top) {
                            Image(systemName: task.state == "completed" ? "checkmark.circle" : task.state == "dismissed" ? "minus.circle" : "circle")
                            Text(task.title).textSelection(.enabled)
                            Spacer()
                            Text(task.state == "completed" ? "已完成" : task.state == "dismissed" ? "已放下" : "待办").font(.caption).foregroundStyle(.secondary)
                            Button("任务与结果") { model.showTask(task.id); dismiss() }
                        }
                    }
                }
            }.padding(.top, 10)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text(source.displayTitle).font(.headline).lineLimit(2)
                Text(source.recordingSubtitle + " · \(claims.count) 条思考 · \(actions.count) 项任务").font(.caption).foregroundStyle(.secondary)
                if source.origin == "ai" { Text("AI 交付物 · 不代表我的观点或实际验证").font(.caption).foregroundStyle(.secondary) }
                else if source.expressedDate == nil { Text("录制时间未知，按导入时间排列").font(.caption).foregroundStyle(.secondary) }
            }
        }.padding(12).background(palette.surface, in: RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
    }
    private func outcomeCard(_ feedback: ActionFeedbackRecord, date: Date?) -> some View {
        let task = action(feedback)
        return DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Text(feedback.text).textSelection(.enabled)
                if let task, task.version != feedback.actionVersion {
                    Text("历史记录 · 第 \(feedback.actionVersion) 版任务的反馈；当前任务为第 \(task.version) 版。").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("任务与全部结果") { model.showTask(feedback.actionID); dismiss() }
                    if let sourceID = feedback.recordingSourceID, model.records.contains(where: { $0.id == sourceID }) {
                        Button("查看来源录音") { showSource(sourceID) }
                    }
                }
            }.padding(.top, 8)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text(feedback.label + " · " + (task?.title ?? "历史任务")).font(.headline).lineLimit(2)
                Text(feedback.text).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                Text(date.map { "记录于 " + $0.formatted(date: .omitted, time: .shortened) } ?? "记录时间待核对").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(12).background(palette.surface, in: RoundedRectangle(cornerRadius: WorkspaceMetrics.panelRadius))
    }
    private func showSource(_ id:String) {
        if let openSource { openSource(id) } else { model.requestWorkspaceSource(id); dismiss() }
    }
    private func owner(_ claim: CandidateClaim) -> String {
        switch claim.ownership {
        case "user_tentative": "我的表达"
        case "external": "外部主张"
        case "ai_candidate": "AI 建议"
        default: "归属待核对"
        }
    }
}

private struct ReflectionTimelineEvent: Identifiable {
    let id: String
    let date: Date?
    let source: SourceRecord?
    let feedback: ActionFeedbackRecord?
    let completion: ReflectionCompletion?
}
private struct ReflectionTimelineDay: Identifiable {
    let date: Date?
    var events: [ReflectionTimelineEvent]
    var id: String { date.map { String($0.timeIntervalSince1970) } ?? "unknown" }
}
