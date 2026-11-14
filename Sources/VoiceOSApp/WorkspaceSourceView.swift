import SwiftUI
import AVFoundation
import VoiceOSCore

private enum SourceHistoryState {
    case idle, loading, loaded([TranscriptVersion]), failed(String)
}
struct WorkspaceSourceView: View {
    @Environment(\.workspacePalette) private var palette
    @ObservedObject var model:ControlCenter
    let source:SourceRecord
    let openTask:(String)->Void
    let openDelivery:(String)->Void
    let openDiscussion:(String)->Void
    var openSource:(String)->Void = { _ in }
    var openInitiation:(String)->Void = { _ in }
    var openFollowups:()->Void = {}
    var scroll: Binding<ScrollPosition>? = nil
    private var expression:RecordingExpression? {
        let catalog=Dictionary(uniqueKeysWithValues:model.records.map { ($0.id,$0) })
        return source.recordingExpression(in:catalog)
    }
    private var expressionIDs:Set<String> { Set(expression?.sourceIDs ?? [source.id]) }
    @State private var loadedContextLinks:[RecordingContextLink]=[]
    @State private var contextIssue=""
    private var programPairs:[RecordingContext] {
        model.records.filter { expressionIDs.contains($0.id) }.compactMap { $0.presentation?.recordingContext }
    }
    private func pairingIsCurrent(_ pair:RecordingContext)->Bool {
        guard let personal=model.records.first(where: { $0.id == pair.personalSourceID }),let external=model.records.first(where: { $0.id == pair.externalSourceID }) else { return false }
        return !personal.localOnly && !external.localOnly && !personal.needsTranscriptionReview && !external.needsTranscriptionReview && personal.transcriptVersionID == pair.personalVersionID && external.transcriptVersionID == pair.externalVersionID && personal.policyVersion == pair.personalPolicyVersion && external.policyVersion == pair.externalPolicyVersion
    }
    private var contextLinks:[RecordingContextLink] {
        loadedContextLinks.filter { link in
            guard pairingIsCurrent(link.pairing),let personal=model.claims.first(where: { $0.id == link.personalClaimID }),let external=model.claims.first(where: { $0.id == link.externalClaimID }) else { return false }
            return personal.validity == "current" && external.validity == "current" && personal.reviewVersion == link.personalReviewVersion && external.reviewVersion == link.externalReviewVersion && personal.reviewState != "rejected" && external.reviewState != "rejected"
        }
    }
    private var contextReadKey:String {
        let pairs = programPairs.map { pair -> String in
            let external = model.records.first { $0.id == pair.externalSourceID }
            return pair.personalVersionID + pair.externalVersionID + String(pair.personalPolicyVersion) + String(pair.externalPolicyVersion)
                + (external?.transcriptVersionID ?? "") + String(external?.policyVersion ?? 0)
        }.joined()
        let filteredRecords = model.records.filter { expressionIDs.contains($0.id) }
        let linkValues = filteredRecords.flatMap { $0.presentation?.contextLinks ?? [] }
        let links = linkValues.map { $0.personalClaimID + $0.externalClaimID + $0.responseIDs.joined() }.joined()
        return source.id + pairs + links
    }
    @State private var editing:SourceRecord?
    @State private var naming:SourceRecord?
    @State private var claimEditor:CandidateClaim?
    @State private var actionClaim:CandidateClaim?
    @State private var showingSegmentation=false
    @State private var showAllThoughts=false
    @State private var historyState = SourceHistoryState.idle
    @State private var historyTask: Task<Void, Never>?
    @State private var historyClaimID: String?
    @State private var loadedClaimHistory: [ClaimReviewVersion] = []
    @State private var loadedDiscussions: [ConversationRecord] = []
    @State private var pauseExplanation = "正在读取具体原因…"
    @State private var showingOriginal = false
    @State private var pendingRejection: CandidateClaim?
    @State private var confirmingRejection = false
    @State private var error=""
    @State private var claimNotes:[String:ClaimNote]=[:]
    @State private var captureInfo:CaptureMetadata?
    @State private var playbackMS:Int?
    private var sourceStatus: String {
        if source.transcript == nil { return source.jobState == "failed" ? "转写失败 · 原件已保存" : "尚未完成转写 · 原件已保存" }
        if source.localOnly { return "仅本机保存" }
        if processing { return "AI 正在整理" }
        return thoughts.isEmpty ? "原文已保存 · 整理尚未完成" : "已整理 · 原话可追溯"
    }
    private var sourceStatusIcon: String {
        if source.transcript == nil { return "exclamationmark.circle" }
        return source.localOnly ? "internaldrive" : processing ? "sparkles" : "checkmark.circle"
    }
    @ViewBuilder private var historyVersions: some View {
        switch historyState {
        case .idle: EmptyView()
        case .loading: ProgressView("正在读取原文版本…")
        case .loaded(let versions):
            if versions.isEmpty { Text("尚无原文版本。请先完成转写；原始录音仍已保存。").foregroundStyle(.secondary) }
            ForEach(versions) { version in
                DisclosureGroup("第 \(version.number) 版 · " + (ConversationReflectionFocus.date(version.createdAt)?.formatted(date:.abbreviated,time:.shortened) ?? "时间未知")) { Text(version.text).textSelection(.enabled) }
            }
        case .failed(let message): WorkspaceNoticeText(message:"原文版本读取失败：" + message,severity:.danger)
        }
    }
    @ViewBuilder private func relatedActionRow(_ action: ActionRecord, in list: [ActionRecord]) -> some View {
        if let delivery=model.assistantExecutions.first(where: { $0.actionID == action.id && $0.validity == "current" && $0.state == "completed" }) {
            WorkspaceRow(title:action.title,subtitle:"AI 已交付",icon:"doc.text",trailing:"阅读结果") { openDelivery(delivery.id) }
        } else {
            WorkspaceRow(title:action.title,subtitle:model.workspaceExternalCompletionNote(action) ?? model.workspaceActionStatus(action),icon:"circle") { openTask(action.id) }
        }
        if action.id != list.last?.id { Divider() }
    }
    private func loadHistory() {
        historyTask?.cancel()
        guard source.transcript != nil else { historyState = .loaded([]); return }
        guard let store=model.store else { historyState = .failed("资料库尚未打开"); return }
        historyState = .loading
        let id=source.id
        historyTask=Task {
            do {
                let versions=try await store.transcriptHistory(sourceID:id)
                try Task.checkCancellation()
                historyState = .loaded(versions)
            } catch is CancellationError {}
            catch { if !Task.isCancelled { historyState = .failed(error.localizedDescription) } }
        }
    }
    private var thoughts:[CandidateClaim] {
        var seen=Set<String>()
        return expressionIDs.sorted().flatMap { model.currentClaimsBySource[$0] ?? [] }.filter { $0.validity == "current" && $0.reviewState != "rejected" && seen.insert($0.id).inserted }
    }
    private var actions:[ActionRecord] {
        let ids=Set(model.claims.filter { !$0.references.allSatisfy { !expressionIDs.contains($0.sourceID) } }.map(\.id))
        return model.actionRecords.filter { ids.contains($0.claimID) && $0.state != "dismissed" }
    }
    private var review:KnowledgeReviewRecord? { model.knowledgeReviews.filter { $0.sourceID == source.id && $0.validity == "current" }.sorted { $0.createdAt > $1.createdAt }.first }
    private var processing:Bool { model.fullRecordingBusy && model.fullRecordingSourceID.map { expressionIDs.contains($0) } == true || model.understandingSource == source.id || model.processingIntents.contains { $0.sourceID == source.id && [.queued,.running].contains($0.state) } }
    private var organizationStatusText:String {
        if let title=model.workspaceProcessingTitle,model.workspaceProcessingSourceID.map({ expressionIDs.contains($0) }) == true,!title.isEmpty { return title }
        return "正在整理这份材料…"
    }
    private var pendingUnderstanding:Bool {
        model.records.contains { record in
            guard let ids=record.presentation?.correctedSourceIDs else { return false }
            return expressionIDs.contains(record.id) || ids.contains(source.id) || record.presentation?.recordingContext?.externalSourceID == source.id
        }
    }
    private var automaticallyUpdating:Bool { pendingUnderstanding && model.fullRecordingBusy }
    private var pausedThoughts: [CandidateClaim] { (model.currentClaimsBySource[source.id] ?? []).filter { $0.validity != "current" } }
    private var pausedActions: [ActionRecord] { actions.filter { model.workspaceTaskRequiresReview($0) } }
    @ViewBuilder private var readingContent:some View {
        if let scroll { readingScrollView.scrollPosition(scroll) } else { readingScrollView }
    }
    private var readingScrollView: some View {
        ScrollView {
            LazyVStack(alignment:.leading,spacing:30) {
                WorkspaceHeading(eyebrow:(source.origin == "ai" ? "AI 交付物 · 不代表我的观点" : source.origin == "user" ? "我的表达" : "外部资料 · 不代表我的观点") + " · " + source.recordingSubtitle,title:(expression?.sourceIDs.count ?? 0) > 1 ? expression!.title : source.displayTitle)
                if let captureInfo {
                    HStack(spacing:14) {
                        if let link=captureLink(captureInfo.url) { Link(link.host ?? "来源链接", destination: link) }
                        if let date=ConversationReflectionFocus.date(captureInfo.capturedAt) { Text("抓取于 " + date.formatted(date:.abbreviated,time:.shortened)) }
                        else { Text("抓取于 " + captureInfo.capturedAt) }
                    }.font(.caption).foregroundStyle(.secondary)
                }
                if let expression,expression.sourceIDs.count > 1 {
                    WorkspaceSection(title:"整体理解",icon:"waveform.path",count:expression.sourceIDs.count) {
                        WorkspaceExpandableText(text:expression.summary,label:"整体摘要",size:16)
                        if let ledger = model.actionReviewLedgers[expression.id], ledger.canAcknowledge {
                            ActionReviewAcknowledgementControl(model:model,expressionID:expression.id)
                        }
                        DisclosureGroup("本次表达的录音与合并依据") {
                            Text(expression.reason).font(.callout).foregroundStyle(.secondary).padding(.vertical,10)
                            ForEach(Array(expression.sourceIDs.enumerated()),id:\.element) { index,id in
                                if let member=model.records.first(where: { $0.id == id }) {
                                    Button("第 \(index+1) 段 · "+member.name+(id == source.id ? "（当前原文）" : "")) { openSource(id) }.padding(.vertical,5).disabled(id == source.id)
                                }
                            }
                        }.padding(.top,12)
                    }
                }
                if !programPairs.isEmpty {
                    WorkspaceSection(title:"节目与我的思考",icon:"waveform",count:contextLinks.count) {
                        ForEach(programPairs,id:\.externalSourceID) { pair in
                            if let external=model.records.first(where: { $0.id == pair.externalSourceID }) {
                                WorkspaceRow(title:external.displayTitle,subtitle:pairingIsCurrent(pair) ? "同次录制的完整节目原文 · 可单独回听" : "节目原话或处理许可已变化，关联等待更新",icon:"headphones",trailing:"节目原文") { openSource(external.id) }
                            }
                        }
                        if !contextLinks.isEmpty {
                            DisclosureGroup("节目原话与我的回应（\(contextLinks.count)）") {
                                ForEach(Array(contextLinks.enumerated()),id:\.offset) { _,link in
                                    VStack(alignment:.leading,spacing:12) {
                                        Text(contextRelation(link.relation)).font(.headline)
                                        Text("节目原话").font(.caption).foregroundStyle(.secondary)
                                        Text(link.externalQuote).textSelection(.enabled)
                                        Button(contextPlaybackLabel(link.externalClaimID,role:"节目")) { Task { await playContextClaim(link.externalClaimID) } }
                                        Text("我的表达").font(.caption).foregroundStyle(.secondary)
                                        Text(link.personalQuote).textSelection(.enabled)
                                        Button(contextPlaybackLabel(link.personalClaimID,role:"我的")) { Task { await playContextClaim(link.personalClaimID) } }
                                        Text("AI 关联："+link.explanation).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                                    }.padding(.vertical,16)
                                    Divider()
                                }
                            }.padding(.top,12)
                        } else {
                            Text(automaticallyUpdating ? "正在重新核对节目与我的表达。" : programPairs.allSatisfy(pairingIsCurrent) ? "已保留节目背景；还没有已核对的回应关系。" : "已保存的双方原文仍可回看。").font(.callout).foregroundStyle(.secondary).padding(.top,10)
                        }
                        if !contextIssue.isEmpty { Text(contextIssue).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                HStack(spacing:12) {
                    Label(sourceStatus,systemImage:sourceStatusIcon).vosFont(13).foregroundStyle(.secondary)
                    Spacer()
                    Button("从这里启动",systemImage:"arrow.up.forward") { openInitiation(source.id) }
                        .disabled(source.transcript == nil || source.origin != "user" || source.speaker != "user")
                    Button("更正原文",systemImage:"pencil") { editing=source }.disabled(source.transcript == nil)
                    Menu("更多") {
                        Button("修改标题") { naming=source }
                        Button("更正原文") { editing=source }.disabled(source.transcript == nil)
                        Button(source.localOnly ? "允许这份文字用于云端并整理" : "改为仅本地") { Task { await model.changeTextPolicy(source);if source.localOnly { organize() } } }
                        Button("重新整理当前文字",action:organize).disabled(source.transcript == nil || source.localOnly || !model.modelConfigured)
                        if !model.modelConfigured { Button("配置文本模型…") { model.chooseTextModel() } }
                    }
                }
                if source.transcript == nil {
                    Text(source.error ?? "转写尚未完成，理解与待办识别还未开始。").foregroundStyle(.secondary).textSelection(.enabled)
                    if ["failed","blocked"].contains(source.jobState ?? "") {
                        Button("重试本地转写") { Task { await model.retry(source) } }.buttonStyle(.borderedProminent)
                    }
                }
                VStack(alignment:.leading,spacing:10) {
                    MaterialManagementControls(model:model,source:source)
                    Text(source.isArchived ? "已归档：从日常材料列表收起，仍可作为历史依据使用。" : "归档只收起材料；移入回收站会暂停相关理解，原件和历史仍可恢复。").font(.caption).foregroundStyle(.secondary)
                }
                if !pausedThoughts.isEmpty {
                    VStack(alignment:.leading,spacing:12) {
                        Label(automaticallyUpdating ? "正在自动更新理解" : pendingUnderstanding ? "理解尚未更新完成" : "AI 提取需要重新识别",systemImage:automaticallyUpdating ? "arrow.trianglehead.2.clockwise" : "pause.circle").font(.headline)
                        Text(automaticallyUpdating ? "原文已保存，AI 正在结合完整表达与节目背景更新观点、任务和关联。完成后这里会自动更新，无需再次操作。" : pauseExplanation).font(.callout).foregroundStyle(.secondary)
                        if !pausedActions.isEmpty {
                            Text("受影响的任务与问题").font(.subheadline.bold())
                            ForEach(pausedActions) { action in
                                WorkspaceRow(title:action.title,subtitle:model.workspaceExternalCompletionNote(action) ?? model.workspaceActionStatus(action),trailing:"查看任务") { openTask(action.id) }
                                WorkspaceExternalCompletionButton(model:model,action:action).padding(.leading,44).padding(.bottom,6)
                            }
                        }
                        if !automaticallyUpdating {
                            Text(pendingUnderstanding ? "自动更新尚未完成。可查看处理进度或错误，并点击下方按钮重试；已保存的原文和任务完成记录会保留。" : "点击下方按钮，AI 会读取完整文字和转写核对记录，重新提取观点和任务。只有发现文字没记对时，才需要更正转写。").font(.callout).foregroundStyle(.secondary)
                        }
                        if source.localOnly {
                            Text("当前仅本机保存。允许后会将这份完整文字发送给已配置的模型。").font(.callout).foregroundStyle(.secondary)
                            Button("允许这份文字用于云端并重新识别") { Task { await model.changeTextPolicy(source);organize() } }.disabled(!model.modelConfigured || model.fullRecordingBusy || model.understandingSource != nil)
                        } else { Button(automaticallyUpdating ? "正在自动更新…" : processing ? "正在重新识别…" : pendingUnderstanding ? "重试更新理解" : "重新识别观点和任务",action:organize).buttonStyle(.borderedProminent).disabled(processing || model.fullRecordingBusy || model.understandingSource != nil || !model.modelConfigured || source.state == "quarantined") }
                        if !model.modelConfigured {
                            HStack(spacing:8) {
                                Text("重新识别需要先配置文本模型。").font(.caption).foregroundStyle(palette.warning)
                                Button("配置文本模型…") { model.chooseTextModel() }.font(.caption)
                            }
                        }
                        Button("查看完整文字") { showingOriginal = true }.disabled(source.transcript == nil)
                        Text("之前的提取与完成记录会保留为历史。已连接的 Apple 提醒事项可能仍会通知，重新识别不等于已撤销系统提醒。").font(.caption).foregroundStyle(.secondary)
                    }.padding(20).frame(maxWidth:.infinity,alignment:.leading).background(palette.selection,in:RoundedRectangle(cornerRadius:WorkspaceMetrics.panelRadius))
                }
                if processing {
                    HStack(alignment:.top,spacing:10) {
                        ProgressView().controlSize(.small)
                        Text(organizationStatusText).font(.callout).textSelection(.enabled)
                    }
                }
                if let followup = model.recordingFollowups.last(where: { expressionIDs.contains($0.sourceID) }) {
                    RecordingFollowupSummary(receipt: followup, model: model, open: openFollowups)
                }
                if pausedThoughts.isEmpty && !pausedActions.isEmpty {
                    WorkspaceSection(title:"观点已更正，关联待办需要重新确认",icon:"pause.circle",count:pausedActions.count) {
                        ForEach(pausedActions) { action in
                            WorkspaceRow(title:action.title,subtitle:model.workspaceExternalCompletionNote(action) ?? model.workspaceActionStatus(action),trailing:"查看与处理") { openTask(action.id) }
                            WorkspaceExternalCompletionButton(model:model,action:action).padding(.leading,44).padding(.bottom,6)
                        }
                    }
                }
                if (expression?.sourceIDs.count ?? 0) <= 1,let summary=source.contentSummary,!summary.isEmpty {
                    WorkspaceSection(title:"内容摘要",icon:"text.alignleft") {
                        WorkspaceExpandableText(text:summary,label:"完整摘要").padding(.top,10)
                    }
                }
                if !thoughts.isEmpty {
                    WorkspaceSection(title:"核心要点",icon:"lightbulb",count:thoughts.count) {
                        ForEach(Array((showAllThoughts ? thoughts : Array(thoughts.prefix(3))).enumerated()),id:\.element.id) { index,thought in
                            HStack(alignment:.top,spacing:14) {
                                Text(String(format:"%02d",index+1)).vosFont(14, weight: .semibold, design: .monospaced).foregroundStyle(.secondary).padding(.top,3)
                                VStack(alignment:.leading,spacing:12) {
                                    WorkspaceExpandableText(text:thought.statement,label:"完整要点",lines:4,size:16)
                                    Text(thought.ownership == "ai_candidate" ? "AI 分析与建议" : thought.ownership == "external" ? "外部观点" : "从我的表达中提取").vosFont(13).foregroundStyle(.secondary)
                                    HStack {
                                        Button("更正理解或归属",systemImage:"pencil") { claimEditor=thought }
                                        Button("停止使用") { pendingRejection=thought;confirmingRejection=true }
                                        Button("记录行动意图") { actionClaim=thought }.disabled(thought.validity == "frozen" || thought.reviewState == "rejected")
                                    }.font(.caption).disabled(model.reviewingClaim)
                                    ClaimNoteRow(model:model,claimID:thought.id,notes:$claimNotes)
                                    DisclosureGroup("原话依据与调整") {
                                        VStack(alignment:.leading,spacing:10) {
                                            ForEach(Array(thought.references.enumerated()),id:\.offset) { _,ref in
                                                if let member=model.records.first(where: { $0.id == ref.sourceID }),expressionIDs.contains(member.id),ref.transcriptVersionID == member.transcriptVersionID,
                                                   let span=member.spans.first(where: { $0.id == ref.spanID }),let text=member.transcript {
                                                    if expressionIDs.count > 1 {
                                                        QuoteHoverPreview(sourceTitle:member.displayTitle,snippet:quote(span,text:text),open:{ openSource(member.id) }) {
                                                            Text(member.name).font(.caption).foregroundStyle(.secondary)
                                                        }
                                                    }
                                                    Text(quote(span,text:text)).foregroundStyle(.secondary).textSelection(.enabled)
                                                    if let start=span.startMS,let end=span.endMS { Button("回听这段原话",systemImage:"play.circle") { Task { _=await model.playSpan(member,milliseconds:start,endMilliseconds:end) } } }
                                                }
                                            }
                                            HStack {
                                                Button("审阅历史") { Task { await model.reviewHistory(thought); historyClaimID=thought.id; loadedClaimHistory=model.claimHistory } }
                                            }
                                            if historyClaimID == thought.id {
                                                ForEach(loadedClaimHistory) { revision in Text("第 \(revision.version) 版 · " + revision.statement).font(.caption).textSelection(.enabled) }
                                            }
                                            if let origin=model.claimOrigins.first(where: { $0.claimID == thought.id }) {
                                                Button("查看原讨论") { openDiscussion(origin.conversationID) }
                                            }
                                        }.padding(.top,9)
                                    }.vosFont(13)
                                }
                            }.padding(.vertical,20)
                            if thought.id != (showAllThoughts ? thoughts.last?.id : thoughts.prefix(3).last?.id) { Divider() }
                        }
                        if thoughts.count > 3 {
                            Divider()
                            Button(showAllThoughts ? "收起要点" : "展开全部 \(thoughts.count) 条要点",systemImage:showAllThoughts ? "chevron.up" : "chevron.down") { showAllThoughts.toggle() }.vosFont(14, weight: .medium).buttonStyle(.borderless).padding(.top,18)
                        }
                    }
                } else if source.transcript != nil {
                    if pausedThoughts.isEmpty { Text(source.localOnly ? "完整原文已保存。允许云端后可理解并连接主题。" : processing || model.fullRecordingBusy ? "正在整理完整内容。" : "原文已保留，整理尚未就绪，可在“更多”中重试。").foregroundStyle(.secondary) }
                }
                if let review,!review.issues.isEmpty {
                    WorkspaceSection(title:"理解有需要补充的地方",icon:"lightbulb",count:review.issues.count) {
                        ForEach(review.issues) { issue in WorkspaceExpandableText(text:issue.betterUnderstanding,label:"完整建议",size:16).padding(.vertical,14) }
                    }
                }
                let currentActions = actions.filter { $0.validity == "current" }
                let currentTasks = currentActions.filter { $0.kind == "task" }
                let currentGoals = currentActions.filter { $0.kind != "task" }
                if !currentTasks.isEmpty {
                    WorkspaceSection(title:"待办",icon:"checkmark.circle",count:currentTasks.count) {
                        ForEach(currentTasks) { action in relatedActionRow(action, in: currentTasks) }
                    }
                }
                if !currentGoals.isEmpty {
                    WorkspaceSection(title:"问题与目标",subtitle:"不计为已承诺待办。",icon:"lightbulb",count:currentGoals.count) {
                        ForEach(currentGoals) { action in relatedActionRow(action, in: currentGoals) }
                    }
                }
                let historyActions = actions.filter { $0.validity != "current" && !model.workspaceTaskRequiresReview($0) }
                if !historyActions.isEmpty {
                    DisclosureGroup("之前提取的任务与完成记录（\(historyActions.count)）") {
                        ForEach(historyActions) { action in WorkspaceRow(title:action.title,subtitle:model.workspaceExternalCompletionNote(action) ?? model.workspaceActionStatus(action),trailing:"查看记录") { openTask(action.id) } }
                    }
                }
                WorkspaceSection(title:"原话与依据",icon:"quote.bubble") {
                    DisclosureGroup("原话、来源与回听") {
                        VStack(alignment:.leading,spacing:16) {
                            if let transcript=source.transcript { Text(transcript).vosFont(16).lineSpacing(6).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }
                            else { Text("尚无可用转写 · " + (source.error ?? workspaceStateLabel(source.jobState ?? source.state))).foregroundStyle(.secondary) }
                            if source.state == "saved" { Button("打开保存的原件",systemImage:"play.circle") { Task { await model.play(source) } } }
                            ForEach(source.spans.filter { $0.startMS != nil && $0.endMS != nil }) { span in
                                let active=spanIsPlaying(span)
                                Button { Task { _=await model.playSpan(source,milliseconds:span.startMS!,endMilliseconds:span.endMS!) } } label: {
                                    Text(time(span.startMS!) + "—" + time(span.endMS!) + " · 回听")
                                        .vosFont(13, weight:active ? .semibold : .regular)
                                        .padding(.horizontal,8).padding(.vertical,3)
                                        .background(active ? palette.selection : .clear, in: RoundedRectangle(cornerRadius:WorkspaceMetrics.controlRadius))
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                            if let player=model.player { NativePlayerView(player:player).frame(height:source.kind == "video" ? 240 : 70) }
                            Text("原文件：" + source.name).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }.padding(.top,13)
                    }.padding(.vertical,16)
                    Divider()
                    DisclosureGroup("核对依据与适用边界") { KnowledgeReviewSection(model:model,sourceIDs:[source.id]).padding(.top,12) }.padding(.vertical,16)
                    Divider()
                    DisclosureGroup("文字校正、理解与修订历史") {
                        VStack(alignment:.leading,spacing:13) {
                            if let review=source.transcriptionReview {
                                Text("转写校正已保存，原始版本可追溯。").font(.callout)
                                ForEach(Array((review.unresolved_issues ?? []).enumerated()),id:\.offset) { _,issue in Text(issue.reason).font(.caption).foregroundStyle(palette.warning) }
                            }
                            Button("查看全部原文版本", action:loadHistory)
                            historyVersions
                            if source.transcript != nil { Button("查看原话分段") { Task { showingSegmentation = await model.previewSegmentation(source) } } }
                            ForEach(model.attempts[source.id] ?? []) { attempt in
                                Text((attempt.state == "completed" ? "理解已完成" : "理解：" + workspaceStateLabel(attempt.state)) + (attempt.contextState == "stale" ? " · 历史依据已变化" : "")).font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(Array(loadedDiscussions.enumerated()),id:\.element.id) { index,session in Button("打开讨论 \(index+1)") { openDiscussion(session.id) } }
                        }.padding(.top,12)
                    }.padding(.vertical,16)
                    Divider()
                    DisclosureGroup("主题归属与处理情况") {
                        VStack(alignment:.leading,spacing:13) {
                            ForEach(model.workspaceTopics) { topic in
                                let linked=model.workspaceTopicSources[topic.id]?.contains(source.id) == true
                                Toggle(topic.title,isOn:Binding(get:{linked},set:{ value in Task { do { try await model.linkReflectionQuestionSource(questionID:topic.id,sourceID:source.id,linked:value);await model.refresh() } catch { self.error=error.localizedDescription } } }))
                            }
                            if !source.localOnly { Button("重新整理当前内容",action:organize).disabled(source.transcript == nil || model.fullRecordingBusy || model.understandingSource != nil) }
                            ForEach(model.segmentedBatches.filter { $0.scope.plan.source.sourceID == source.id }) { batch in
                                HStack { Text(workspaceStateLabel(batch.state.rawValue)).font(.caption);if batch.state == .queued { Button("停止后续处理") { model.cancelSegmented(batch.id) } } }
                                if let error=batch.error { Text(error).font(.caption).foregroundStyle(.secondary) }
                            }
                            Text(model.fullRecordingStatus).font(.caption).foregroundStyle(.secondary)
                            Text(model.transcriptReviewStatus).font(.caption).foregroundStyle(.secondary)
                            if let error=source.error { Text(error).font(.caption).foregroundStyle(palette.danger) }
                        }.padding(.top,12)
                    }.padding(.vertical,16)
                }
                if !error.isEmpty { WorkspaceNoticeText(message:error,severity:.danger) }
            }.frame(maxWidth:WorkspaceMetrics.pageWidth,alignment:.leading).padding(WorkspaceMetrics.pagePadding).frame(maxWidth:.infinity,alignment:.top)
        }.onDisappear { historyTask?.cancel() }
    }
    var body:some View {
        readingContent
        .sheet(item:$editing) { source in WorkspaceTranscriptEditor(model:model,source:source) { editing=nil } }
        .sheet(item:$naming) { source in RecordingTitleEditor(record:source,model:model) { naming=nil } }
        .sheet(item:$claimEditor) { claim in ClaimCorrectionView(claim:claim,model:model) { claimEditor=nil } }
        .sheet(item:$actionClaim) { claim in ActionCreationView(claim:claim,model:model) { actionClaim=nil } }
        .sheet(isPresented:$showingSegmentation) { TranscriptSegmentationView(model:model) { showingSegmentation=false } }
        .sheet(isPresented:$showingOriginal) {
            VStack(alignment:.leading,spacing:16) {
                Text("完整文字").font(.title2)
                ScrollView { Text(source.transcript ?? "暂无文字").textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }
                HStack { Spacer();Button("关闭") { showingOriginal=false } }
            }.padding(24).frame(width:650,height:520)
        }
        .alert("停止使用这条理解？", isPresented:$confirmingRejection, presenting:pendingRejection) { claim in
            Button("停止使用", role:.destructive) { Task { _=await model.review(claim, action:.reject) } }
            Button("取消", role:.cancel) {}
        } message: { _ in
            Text("确定后，这份理解将不再用于当前阅读与行动。原文与处理历史会保留。")
        }
        .task(id: source.id + pausedThoughts.map(\.id).joined() + (source.transcriptVersionID ?? "") + String(source.policyVersion) + source.state) {
            historyTask?.cancel(); historyState = .idle
            guard !pausedThoughts.isEmpty,let store=model.store else { return }
            do { pauseExplanation = try await store.understandingPause(sourceID:source.id).summary }
            catch { pauseExplanation = "暂时无法读取暂停原因：" + error.localizedDescription }
        }
        .task(id: source.id + model.discussionList.map { $0.id + String($0.version) + $0.validity }.joined()) {
            guard let store = model.store else { return }
            do {
                let discussions = try await store.conversationsForSource(sourceID: source.id)
                try Task.checkCancellation()
                loadedDiscussions = discussions
            } catch is CancellationError {}
            catch { self.error = error.localizedDescription }
        }
        .task(id:contextReadKey) {
            loadedContextLinks=[];contextIssue=""
            guard let store=model.store else { return }
            do {
                var links:[RecordingContextLink]=[]
                for id in expressionIDs.sorted() { links += try await store.recordingContextLinks(sourceID:id) }
                try Task.checkCancellation();loadedContextLinks=links
            } catch is CancellationError {} catch { contextIssue=error.localizedDescription }
        }
        .task(id: source.id) {
            captureInfo=try? await model.sourceCaptureMetadata(sourceID:source.id)
        }
        .task(id: source.id + thoughts.map(\.id).joined()) {
            guard model.store != nil else { return }
            do {
                let loaded=try await model.claimNoteMap()
                try Task.checkCancellation()
                claimNotes=loaded
            } catch is CancellationError {}
            catch { self.error="旁注读取失败：" + error.localizedDescription }
        }
        .onChange(of:source.id) { _,_ in showingOriginal=false }
        .task {
            while !Task.isCancelled {
                refreshPlaybackPosition()
                do { try await Task.sleep(for:.milliseconds(300)) } catch { return }
            }
        }
    }
    private func captureLink(_ value:String?)->URL? {
        guard let value,let url=URL(string:value),let scheme=url.scheme?.lowercased(),scheme=="http" || scheme=="https" else { return nil }
        return url
    }
    private func contextRelation(_ relation:String)->String {
        ["summary":"复述或总结 · 不代表赞同","agreement":"表达赞同","disagreement":"提出不同看法","qualification":"补充适用条件","application":"联系实际情境","question":"由节目引出的疑问","uncertain":"AI 推测的联系 · 尚不确定"][relation] ?? "AI 关联分析"
    }
    private func contextPlaybackLabel(_ id:String,role:String) -> String {
        guard let claim=model.claims.first(where: { $0.id == id }) else { return "回听"+role+"原话" }
        let hasTime=claim.references.contains { ref in
            model.records.first(where: { $0.id == ref.sourceID })?.spans.contains(where: { $0.id == ref.spanID && $0.startMS != nil && $0.endMS != nil }) == true
        }
        return hasTime ? "回听"+role+"原话" : "回听"+role+"完整录音（更正稿未精确定位）"
    }
    private func playContextClaim(_ id:String) async {
        guard let claim=model.claims.first(where: { $0.id == id }) else { return }
        for ref in claim.references {
            if let member=model.records.first(where: { $0.id == ref.sourceID && $0.transcriptVersionID == ref.transcriptVersionID }),let span=member.spans.first(where: { $0.id == ref.spanID }),let start=span.startMS,let end=span.endMS {
                _=await model.playSpan(member,milliseconds:start,endMilliseconds:end);return
            }
        }
        if let ref=claim.references.first,let member=model.records.first(where: { $0.id == ref.sourceID && $0.transcriptVersionID == ref.transcriptVersionID }) {
            _=await model.playSpan(member,milliseconds:0)
        }
    }
    private func organize() {
        guard let current=model.records.first(where: { $0.id == source.id }),!current.localOnly else { return }
        model.reidentify(current)
    }
    private func quote(_ span:TranscriptSpan,text:String) -> String { let s=Array(text.unicodeScalars);guard span.textStart>=0,span.textEnd<=s.count else { return "原文范围已变化" };return String(String.UnicodeScalarView(s[span.textStart..<span.textEnd])) }
    private func time(_ ms:Int)->String { String(format:"%02d:%02d",ms/60000,ms/1000%60) }
    private func spanIsPlaying(_ span:TranscriptSpan)->Bool {
        guard let ms=playbackMS,let start=span.startMS,let end=span.endMS else { return false }
        return ms>=start && ms<end
    }
    private func refreshPlaybackPosition() {
        guard let player=model.player,player.timeControlStatus == .playing else { playbackMS=nil; return }
        let seconds=player.currentTime().seconds
        playbackMS=seconds.isFinite ? Int((seconds*1000).rounded()) : nil
    }
}
struct WorkspaceTranscriptEditor:View {
    @ObservedObject var model:ControlCenter
    let source:SourceRecord
    let close:()->Void
    @State private var text=""
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("更正原文").font(.title2)
            Text(source.localOnly ? "这份材料仅本机保存。更正后保留原话历史，旧理解暂停使用；允许云端处理后可重新整理。" : "保存后自动更新完整理解；原话历史、真实完成与结果保留。不能确定的关联会单独说明。").font(.callout).foregroundStyle(.secondary)
            TextEditor(text:$text).frame(minHeight:300).workspaceEditorSurface()
            Text(model.status).font(.caption).foregroundStyle(.secondary)
            HStack { Button("取消",action:close);Spacer();Button("保存更正") { Task { if await model.correct(source,text:text) { close() } } }.disabled(text == source.transcript || text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty) }
        }.padding(24).frame(width:650).onAppear { text=source.transcript ?? "" }
    }
}
struct ClaimCorrectionView:View {
    let claim:CandidateClaim
    @ObservedObject var model:ControlCenter
    let dismiss:()->Void
    @State private var text:String
    @State private var ownership:String
    @State private var note=""
    init(claim:CandidateClaim,model:ControlCenter,dismiss:@escaping()->Void) {
        self.claim=claim;self.model=model;self.dismiss=dismiss
        _text=State(initialValue:claim.statement);_ownership=State(initialValue:claim.ownership)
    }
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("更正当前理解").font(.title2)
            Text("更正不会改写原话，历史与相关行动依据会分别保留。").font(.callout).foregroundStyle(.secondary)
            TextEditor(text:$text).frame(minHeight:180).workspaceEditorSurface()
            Picker("内容归属",selection:$ownership) {
                Text("我的暂定表达").tag("user_tentative");Text("外部观点").tag("external");Text("AI 建议").tag("ai_candidate");Text("归属待核对").tag("unresolved")
            }
            TextField("更正原因",text:$note)
            Text(model.status).font(.caption).foregroundStyle(.secondary)
            HStack { Button("取消",action:dismiss);Spacer();Button("更新理解") { Task { if await model.review(claim,action:.correct,statement:text,ownership:CandidateOwnership(rawValue:ownership),note:note) { dismiss() } } }.disabled(model.reviewingClaim || (text == claim.statement && ownership == claim.ownership) || text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || note.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty) }
        }.padding(24).frame(width:620)
    }
}
