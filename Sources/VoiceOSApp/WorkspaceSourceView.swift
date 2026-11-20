import AppKit
import SwiftUI
import Combine
import AVFoundation
import VoiceOSCore
import VoiceOSPlatform

private enum SourceHistoryState {
    case idle, loading, loaded([TranscriptVersion]), failed(String)
}
private struct SourceEntityGroup:Identifiable {
    let kind:String
    let title:String
    let entities:[SourceEntity]
    var id:String { kind }
}
private struct TranscriptParagraph:Identifiable {
    let span:TranscriptSpan
    let text:String
    var id:String { span.id }
}
private final class SourcePlaybackClock: ObservableObject {
    @Published var milliseconds:Int?
}
private struct SourcePauseReadKey: Hashable {
    let sourceID:String
    let pausedThoughtIDs:[String]
    let transcriptVersionID:String?
    let policyVersion:Int
    let state:String
}
private struct SourceDiscussionReadKey: Hashable {
    struct Item: Hashable {
        let id:String
        let version:Int
        let validity:String
    }
    let sourceID:String
    let items:[Item]
    let retry:Int
}
private struct SourceContextReadKey: Hashable {
    struct Pair: Hashable {
        let personalVersion:String
        let externalVersion:String
        let personalPolicy:Int
        let externalPolicy:Int
        let externalTranscriptVersion:String
        let externalPolicyVersion:Int
    }
    struct Link: Hashable {
        let personalClaimID:String
        let externalClaimID:String
        let responseIDs:[String]
    }
    let sourceID:String
    let expressionID:String?
    let transcriptVersionID:String?
    let policyVersion:Int
    let pairs:[Pair]
    let links:[Link]
    let retry:Int
}
private struct SourceTranscriptReadKey: Hashable {
    let sourceID:String
    let transcriptVersionID:String?
    let retry:Int
}
private struct SourceChapterReadKey: Hashable {
    let sourceID:String
    let kind:String
    let retry:Int
}
private struct SourceExtractionReadKey: Hashable {
    let sourceID:String
    let transcriptVersionID:String?
    let expressionState:String
    let thoughtsCount:Int
}
private func sourceTime(_ ms:Int)->String { String(format:"%02d:%02d",ms/60000,ms/1000%60) }
struct SourceFoldState: Equatable {
    var original = false
    var fullText = false
    var thoughts = true
    var overall = false
    var digest = false
    var outline = false
    var chapters = false
    var entities = false
    var extras = false
    var records = false
    static func initial(transcript:String?) -> SourceFoldState {
        SourceFoldState()
    }
}
private enum SourceLoadPhase: Equatable {
    case idle, loading, failed(String)
    var isLoading:Bool {
        if case .loading=self { return true }
        return false
    }
    var failure:String? {
        if case .failed(let message)=self { return message }
        return nil
    }
}
private struct SourceFold<Content: View>: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(\.vosTextScale) private var textScale
    let title:String
    var icon=""
    var count:Int?=nil
    @Binding var isExpanded:Bool
    var spacing:CGFloat=0
    @ViewBuilder let content:()->Content
    var body: some View {
        WorkspaceCard() {
            VStack(alignment:.leading,spacing:0) {
                Button { isExpanded.toggle() } label: {
                    HStack(alignment:.top,spacing:12) {
                        if !icon.isEmpty {
                            Image(systemName:icon).vosFont(19, weight:.medium).foregroundStyle(palette.accent).frame(minWidth: 26 * vosLayoutScale(textScale), minHeight: 28 * vosLayoutScale(textScale)).accessibilityHidden(true)
                        }
                        WorkspaceSectionHeading(title:title,count:count.map { String($0) }) {
                            Image(systemName:isExpanded ? "chevron.up" : "chevron.down").vosFont(WorkspaceText.caption).foregroundStyle(palette.secondaryText).accessibilityHidden(true)
                        }
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityValue(isExpanded ? "已展开" : "已收起")
                WorkspaceListDivider().padding(.top,18)
                if isExpanded {
                    LazyVStack(alignment:.leading,spacing:spacing,content:content).padding(.top,8)
                }
            }
        }
    }
}
private struct SourceLoadingRow: View {
    @Environment(\.workspacePalette) private var palette
    let title:String
    var body:some View {
        HStack(spacing:10) {
            ProgressView().controlSize(.small).accessibilityHidden(true)
            Text(title).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
        }.accessibilityElement(children:.combine)
    }
}
private struct SourceLoadFailureRow: View {
    @Environment(\.workspacePalette) private var palette
    let operation:String
    let reason:String
    let retry:()->Void
    var body:some View {
        HStack(alignment:.firstTextBaseline,spacing:12) {
            Label(InlineFailurePresentation.message(operation:operation,reason:reason),systemImage:"exclamationmark.triangle")
                .vosFont(WorkspaceText.meta).foregroundStyle(palette.warning)
                .fixedSize(horizontal:false,vertical:true)
            Spacer(minLength:8)
            Button("重试",systemImage:"arrow.clockwise",action:retry)
                .buttonStyle(.workspaceQuietCompact)
                .help("重新读取")
        }.padding(.vertical,6)
    }
}
private struct UnresolvedIssuesBlock: View {
    @Environment(\.workspacePalette) private var palette
    let issues:[TranscriptionReview.Issue]
    let playbackAvailable:Bool
    let playbackLabel:(TranscriptionReview.Issue)->String
    let play:(TranscriptionReview.Issue)->Void
    let jump:(String)->Void
    @State private var isExpanded=false
    var body: some View {
        WorkspaceCard() {
            VStack(alignment:.leading,spacing:12) {
                Button { isExpanded.toggle() } label: {
                    HStack(spacing:9) {
                        Label("疑点 \(issues.count) · 核对未完成",systemImage:"exclamationmark.triangle")
                            .vosFont(WorkspaceText.meta.size, weight:.semibold)
                            .foregroundStyle(palette.warning)
                            .accessibilityAddTraits(.isHeader)
                        Spacer(minLength:0)
                        Image(systemName:isExpanded ? "chevron.up" : "chevron.down")
                            .vosFont(WorkspaceText.caption)
                            .foregroundStyle(palette.warning)
                            .accessibilityHidden(true)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityValue(isExpanded ? "已展开" : "已收起")
                if isExpanded {
                    ForEach(Array(issues.enumerated()),id:\.offset) { _,issue in
                        VStack(alignment:.leading,spacing:8) {
                            Text(issue.reason).vosFont(WorkspaceText.meta).foregroundStyle(palette.warning)
                            HStack(spacing:14) {
                                Button(playbackLabel(issue),systemImage:"play.circle") { play(issue) }
                                    .buttonStyle(.workspaceQuietCompact)
                                    .disabled(!playbackAvailable)
                                    .help(playbackAvailable ? "播放这条核对项对应的原话" : "这份材料当前没有可播放的录音")
                                Button("跳到原文",systemImage:"text.magnifyingglass") { jump(issue.span_id) }
                                    .buttonStyle(.workspaceQuietCompact)
                            }
                        }.padding(.vertical,4)
                    }
                }
            }
        }
    }
}
private struct SourceSection<Content: View>: View {
    let title:String
    var count:Int? = nil
    @ViewBuilder let content:()->Content
    var body: some View {
        WorkspaceCard() {
            VStack(alignment:.leading,spacing:0) {
                WorkspaceSectionHeading(title,count:count.map { String($0) })
                WorkspaceListDivider().padding(.top,18)
                LazyVStack(alignment:.leading,spacing:0,content:content).padding(.top,8)
            }
        }
    }
}
private struct SourceFollowupCard: View {
    @Environment(\.workspacePalette) private var palette
    let receipt:RecordingFollowupReceipt
    @ObservedObject var model:ControlCenter
    let open:()->Void
    var body: some View {
        WorkspaceCard(padding:16) {
            HStack(alignment:.center,spacing:10) {
                VStack(alignment:.leading,spacing:6) {
                    if let result=receipt.result {
                        HStack(spacing:6) {
                            WorkspaceBadge(text:"旧思想关联 \(result.thoughtUpdates.count)")
                            WorkspaceBadge(text:"目标下一步 \(result.goalPlans.count)")
                            if result.english.isPractice { WorkspaceBadge(text:"英语反馈已接续",tone:.accent) }
                        }
                        if model.followupValidity[receipt.id]?.sourceCurrent != true {
                            Text("录音依据已变化，历史结果保留；可重新生成跟进").vosFont(WorkspaceText.caption).foregroundStyle(palette.secondaryText)
                        }
                    } else {
                        Text(receipt.state == "running" ? "正在后台生成思想关联与下一步" : receipt.state == "queued" ? "思想关联与下一步已排队，录音和任务已保存" : "自动跟进待完成，可重试")
                            .vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                    }
                }
                Spacer(minLength:8)
                Button("查看思想与下一步",action:open).buttonStyle(.workspaceQuietCompact)
            }
        }
    }
}
struct WorkspaceSourceView: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(\.vosTextScale) private var textScale
    @ObservedObject var model:ControlCenter
    let source:SourceRecord
    let openTask:(String)->Void
    let openDelivery:(String)->Void
    let openDiscussion:(String)->Void
    var openSource:(String)->Void = { _ in }
    var openInitiation:(String)->Void = { _ in }
    var openFollowups:()->Void = {}
    var scroll: Binding<ScrollPosition>? = nil
    @Binding var folds:SourceFoldState
    private var catalog:[String:SourceRecord] { model.sourcePageIndex.recordsByID }
    private var expression:RecordingExpression? {
        model.sourcePageIndex.expression(for:source.id)
    }
    private var expressionIDs:Set<String> { Set(expression?.sourceIDs ?? [source.id]) }
    @State private var programPairs:[RecordingContext]=[]
    @State private var contextLinks:[RecordingContextLink]=[]
    @State private var contextPhase=SourceLoadPhase.idle
    @State private var discussionsPhase=SourceLoadPhase.idle
    @State private var entitiesPhase=SourceLoadPhase.idle
    @State private var chaptersPhase=SourceLoadPhase.idle
    @State private var contextRetry=0
    @State private var discussionsRetry=0
    @State private var entitiesRetry=0
    @State private var chaptersRetry=0
    private func pairingIsCurrent(_ pair:RecordingContext)->Bool {
        guard let personal=catalog[pair.personalSourceID],let external=catalog[pair.externalSourceID] else { return false }
        return !personal.localOnly && !external.localOnly && !personal.needsTranscriptionReview && !external.needsTranscriptionReview && personal.transcriptVersionID == pair.personalVersionID && external.transcriptVersionID == pair.externalVersionID && personal.policyVersion == pair.personalPolicyVersion && external.policyVersion == pair.externalPolicyVersion
    }
    private var contextReadKey:SourceContextReadKey {
        let memberIDs = expression?.sourceIDs ?? [source.id]
        var pairs:[SourceContextReadKey.Pair]=[]
        var links:[SourceContextReadKey.Link]=[]
        for id in memberIDs {
            guard let record=catalog[id] else { continue }
            if let pair=record.presentation?.recordingContext {
                let external=catalog[pair.externalSourceID]
                pairs.append(.init(personalVersion:pair.personalVersionID,externalVersion:pair.externalVersionID,
                                   personalPolicy:pair.personalPolicyVersion,externalPolicy:pair.externalPolicyVersion,
                                   externalTranscriptVersion:external?.transcriptVersionID ?? "",
                                   externalPolicyVersion:external?.policyVersion ?? 0))
            }
            for link in record.presentation?.contextLinks ?? [] {
                links.append(.init(personalClaimID:link.personalClaimID,externalClaimID:link.externalClaimID,responseIDs:link.responseIDs))
            }
        }
        return .init(sourceID:source.id,expressionID:expression?.id,transcriptVersionID:source.transcriptVersionID,
                     policyVersion:source.policyVersion,pairs:pairs,links:links,retry:contextRetry)
    }
    @State private var editing:SourceRecord?
    @State private var naming:SourceRecord?
    @State private var claimEditor:CandidateClaim?
    @State private var actionClaim:CandidateClaim?
    @State private var showingSegmentation=false
    @State private var showingBilingual=false
    @State private var bilingualExcerpt=BilingualExcerpt(paragraphs:[],truncated:false)
    @State private var bilingualTranslations:[String?]=[]
    @State private var bilingualPhase=BilingualPhase.idle
    @State private var bilingualTask: Task<Void, Never>?
    @State private var bilingualConsumed=0
    @State private var retryingTranscription=false
    @State private var showAllThoughts=false
    @State private var historyState = SourceHistoryState.idle
    @State private var historyTask: Task<Void, Never>?
    @State private var savingQuestion = false
    @State private var historyClaimID: String?
    @State private var loadedClaimHistory: [ClaimReviewVersion] = []
    @State private var loadedDiscussions: [ConversationRecord] = []
    @State private var pauseExplanation = "正在读取具体原因…"
    @State private var showingIncrementalReading = false
    @State private var pendingRejection: CandidateClaim?
    @State private var confirmingRejection = false
    @State private var error=""
    @State private var claimNotes:[String:ClaimNote]=[:]
    @State private var captureInfo:CaptureMetadata?
    @State private var attachmentURL:URL?
    @State private var attachmentMime:String?
    @StateObject private var playback=SourcePlaybackClock()
    @State private var autoScrolledSpanID:String?
    @State private var selectedText=""
    @State private var selectedRange=NSRange(location:0,length:0)
    private func foldExpanded(_ keyPath:WritableKeyPath<SourceFoldState,Bool>) -> Binding<Bool> {
        Binding(get: { folds[keyPath:keyPath] }, set: { folds[keyPath:keyPath]=$0 })
    }
    @State private var toast: String? = nil
    @State private var extractionFlag: SourceExtractionFlag? = nil
    @State private var correctionsExpanded=false
    @State private var correctionJustSaved=false
    @State private var showingCorrectionImpacts=false
    @State private var entities:[SourceEntity]=[]
    @State private var chapters:[SourceChapter]=[]
    private var sourceStatus: String {
        if source.transcript == nil {
            if transcriptionRunning { return "正在转写…" }
            return transcriptionFailed ? "转写失败 · 原件已保存" : "尚未完成转写 · 原件已保存"
        }
        if source.localOnly { return "仅本机保存" }
        if processing { return "AI 正在整理" }
        return thoughts.isEmpty ? "原文已保存 · 整理尚未完成" : "已整理 · 原话可追溯"
    }
    private var sourceStatusIcon: String {
        if source.transcript == nil { return "exclamationmark.circle" }
        return source.localOnly ? "internaldrive" : processing ? "sparkles" : "checkmark.circle"
    }
    private var transcriptionRunning: Bool {
        source.transcript == nil && ["queued","running"].contains(source.jobState ?? "")
    }
    private var transcriptionFailed: Bool {
        source.transcript == nil && ["failed","blocked"].contains(source.jobState ?? "")
    }
    @ViewBuilder private var historyVersions: some View {
        switch historyState {
        case .idle: EmptyView()
        case .loading: ProgressView("正在读取原文版本…")
        case .loaded(let versions):
            if versions.isEmpty { Text("尚无原文版本。请先完成转写；原始录音仍已保存。").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText) }
            ForEach(versions) { version in
                DisclosureGroup("第 \(version.number) 版 · " + (ConversationReflectionFocus.date(version.createdAt)?.formatted(date:.abbreviated,time:.shortened) ?? "时间未知")) { Text(version.text).vosFont(WorkspaceText.body).textSelection(.enabled) }
            }
        case .failed(let message): SourceLoadFailureRow(operation:"读取原文版本",reason:message,retry:loadHistory)
        }
    }
    @ViewBuilder private func relatedActionRow(_ action: ActionRecord, in list: [ActionRecord], reads: ActionRowReads) -> some View {
        let reminder=actionReminderMeta(action,reads:reads)
        if let delivery=model.assistantExecutions.first(where: { $0.actionID == action.id && $0.validity == "current" && $0.state == "completed" }) {
            WorkspaceRow(title:action.title,subtitle:actionSubtitle("AI 已交付",reminder:reminder),icon:"doc.text",trailing:"阅读结果") { openDelivery(delivery.id) }
        } else {
            WorkspaceRow(title:action.title,subtitle:actionSubtitle(model.workspaceExternalCompletionNote(action) ?? model.workspaceActionStatus(action),reminder:reminder),icon:"circle") { openTask(action.id) }
        }
        if action.id != list.last?.id { WorkspaceListDivider() }
    }
    private func actionReminderMeta(_ action: ActionRecord, reads: ActionRowReads) -> String {
        ActionRowLayout.reminderSummary(linkState:reads.reminderLinkStateByActionID[action.id],due:reads.reminderDueByActionID[action.id]) ?? ""
    }
    private func actionSubtitle(_ base: String, reminder: String) -> String {
        reminder.isEmpty ? base : base + " · " + reminder
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
    private var entityGroups:[SourceEntityGroup] {
        let kinds:[(SourceEntityKind,String)] = [(.person,"人物"),(.organization,"机构"),(.term,"术语")]
        var groups:[SourceEntityGroup] = []
        for (kind,title) in kinds {
            var items = entities.filter { $0.kind == kind }
            items.sort { lhs, rhs in
                if lhs.mentionCount != rhs.mentionCount { return lhs.mentionCount > rhs.mentionCount }
                return lhs.name < rhs.name
            }
            if !items.isEmpty { groups.append(SourceEntityGroup(kind:kind.rawValue,title:title,entities:Array(items.prefix(8)))) }
        }
        return groups
    }
    private var actions:[ActionRecord] {
        model.sourcePageIndex.actions(for:expressionIDs)
    }
    private var outlineSections:[SourceOutlineSection] {
        guard let transcript=source.transcript else { return [] }
        return SourceOutline.sections(spans:source.spans,transcript:transcript)
    }
    private var historyActions:[ActionRecord] {
        actions.filter { $0.validity != "current" && !model.sourcePageIndex.requiresReview($0.id) }
    }
    private var extraSectionCount:Int {
        (programPairs.isEmpty ? 0 : 1) + (historyActions.isEmpty ? 0 : 1) + (outlineSections.isEmpty ? 0 : 1) + (chapters.isEmpty ? 0 : 1) + (entities.isEmpty ? 0 : 1)
    }
    private var readingDigest:ReadingDigest {
        ReadingLayers.digest(transcript:source.transcript,thoughts:thoughts,summary:overallSummaryText)
    }
    private var overallSummaryText:String? {
        if let expression,expression.sourceIDs.count > 1,!expression.summary.isEmpty { return expression.summary }
        if let summary=source.contentSummary,!summary.isEmpty { return summary }
        if let summary=expression?.summary,!summary.isEmpty { return summary }
        return nil
    }
    private var readingWidth: CGFloat { min(760, max(640, WorkspaceMetrics.readerWidth)) }
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
    private var pausedActions: [ActionRecord] { actions.filter { model.sourcePageIndex.requiresReview($0.id) } }
    private var selectedSpan:TranscriptSpan? {
        guard !selectedText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,let transcript=source.transcript,
              let offset=SelectableText.scalarOffset(ofUTF16Offset:selectedRange.location,in:transcript) else { return nil }
        return source.spans.first { $0.textStart <= offset && offset < $0.textEnd && $0.startMS != nil && $0.endMS != nil }
    }
    /// Reading order: conclusions first, the verbatim transcript on demand.
    @ViewBuilder private var digestSections: some View {
        if let expression,expression.sourceIDs.count > 1 {
            SourceFold(title:"整体理解",icon:"waveform.path",count:expression.sourceIDs.count,isExpanded:foldExpanded(\.overall)) {
                WorkspaceExpandableText(text:expression.summary,label:"整体摘要",size:WorkspaceText.body.size)
                if let ledger = model.actionReviewLedgers[expression.id], ledger.canAcknowledge {
                    ActionReviewAcknowledgementControl(model:model,expressionID:expression.id)
                }
                DisclosureGroup("本次表达的录音与合并依据") {
                    Text(expression.reason).vosFont(WorkspaceText.body).foregroundStyle(palette.secondaryText).padding(.vertical,10)
                    ForEach(Array(expression.sourceIDs.enumerated()),id:\.element) { index,id in
                        if let member=catalog[id] {
                            Button("第 \(index+1) 段 · "+MaterialNaming.displayName(member.name)+(id == source.id ? "（当前原文）" : "")) { openSource(id) }
                                .buttonStyle(.workspaceQuietCompact)
                                .padding(.vertical,5)
                                .disabled(id == source.id)
                        }
                    }
                }.padding(.top,12)
            }
        }
        if (expression?.sourceIDs.count ?? 0) <= 1,let summary=source.contentSummary,!summary.isEmpty {
            SourceFold(title:"内容摘要",icon:"text.alignleft",isExpanded:foldExpanded(\.digest)) {
                WorkspaceExpandableText(text:summary,label:"完整摘要",size:WorkspaceText.body.size).padding(.top,10)
            }
        }
        if !thoughts.isEmpty {
            SourceFold(title:"核心要点",icon:"lightbulb",count:thoughts.count,isExpanded:foldExpanded(\.thoughts)) {
                let digest=readingDigest
                if !digest.isEmpty {
                    DisclosureGroup("逐层读") {
                        VStack(alignment:.leading,spacing:16) {
                            if let excerpt=digest.excerpt { readingLayerRow("原文摘录",excerpt) }
                            if !digest.points.isEmpty {
                                VStack(alignment:.leading,spacing:8) {
                                    Text("要点").vosFont(WorkspaceText.meta.size, weight: .semibold).foregroundStyle(palette.secondaryText)
                                    ForEach(Array(digest.points.enumerated()),id:\.offset) { _,point in
                                        HStack(alignment:.top,spacing:8) {
                                            Text("·").vosFont(WorkspaceText.body).foregroundStyle(palette.secondaryText)
                                            Text(point).vosFont(WorkspaceText.body).lineSpacing(4).fixedSize(horizontal:false,vertical:true).textSelection(.enabled)
                                        }
                                    }
                                }
                            }
                            if let sentence=digest.sentence { readingLayerRow("一句话",sentence) }
                        }.padding(.top,12)
                    }.padding(.bottom,14)
                    WorkspaceListDivider()
                }
                ForEach(Array((showAllThoughts ? thoughts : Array(thoughts.prefix(3))).enumerated()),id:\.element.id) { index,thought in
                    HStack(alignment:.top,spacing:14) {
                        Text(String(format:"%02d",index+1)).vosFont(WorkspaceText.caption.size, weight: .semibold, design: .monospaced).foregroundStyle(palette.secondaryText).padding(.top,3)
                        VStack(alignment:.leading,spacing:8) {
                            WorkspaceExpandableText(text:thought.statement,label:"完整要点",lines:4,size:WorkspaceText.body.size)
                            Text(thought.ownership == "ai_candidate" ? "AI 分析与建议" : thought.ownership == "external" ? "外部观点" : "从我的表达中提取").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                            HStack(spacing:8) {
                                Button("记录行动意图") { actionClaim=thought }
                                    .buttonStyle(.workspaceSecondaryCompact)
                                    .disabled(thought.validity == "frozen" || thought.reviewState == "rejected")
                                Spacer(minLength:0)
                                Menu {
                                    Button("更正理解或归属",systemImage:"pencil") { claimEditor=thought }
                                    Button("停止使用") { pendingRejection=thought;confirmingRejection=true }
                                } label: { Image(systemName:"ellipsis.circle") }
                                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                                .help("更多操作").accessibilityLabel("更多操作")
                            }.vosFont(WorkspaceText.meta).disabled(model.reviewingClaim)
                            DisclosureGroup {
                                VStack(alignment:.leading,spacing:10) {
                                    ForEach(Array(thought.references.enumerated()),id:\.offset) { _,ref in
                                        if let member=catalog[ref.sourceID],expressionIDs.contains(member.id),ref.transcriptVersionID == member.transcriptVersionID,
                                           let span=member.spans.first(where: { $0.id == ref.spanID }),let text=member.transcript {
                                            if expressionIDs.count > 1 {
                                                QuoteHoverPreview(sourceTitle:member.displayTitle,snippet:quote(span,text:text),open:{ openSource(member.id) }) {
                                                    Text(MaterialNaming.displayName(member.name)).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                                                }
                                            }
                                            if let start=span.startMS,let end=span.endMS {
                                                Button { Task { _=await model.playSpan(member,milliseconds:start,endMilliseconds:end) } } label: {
                                                    Text(quote(span,text:text)).vosFont(WorkspaceText.body).foregroundStyle(palette.secondaryText).multilineTextAlignment(.leading).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
                                                }.buttonStyle(.plain)
                                            } else {
                                                Text(quote(span,text:text)).vosFont(WorkspaceText.body).foregroundStyle(palette.secondaryText).textSelection(.enabled)
                                            }
                                            if let start=span.startMS,let end=span.endMS { Button("回听这段原话",systemImage:"play.circle") { Task { _=await model.playSpan(member,milliseconds:start,endMilliseconds:end) } }.buttonStyle(.workspaceQuietCompact) }
                                        }
                                    }
                                    ClaimNoteRow(model:model,claimID:thought.id,notes:$claimNotes)
                                    HStack {
                                        Button("审阅历史") { Task { await model.reviewHistory(thought); historyClaimID=thought.id; loadedClaimHistory=model.claimHistory } }.buttonStyle(.workspaceQuietCompact)
                                    }
                                    if historyClaimID == thought.id {
                                        ForEach(loadedClaimHistory) { revision in Text("第 \(revision.version) 版 · " + revision.statement).vosFont(WorkspaceText.meta).textSelection(.enabled) }
                                    }
                                    if let origin=model.claimOrigins.first(where: { $0.claimID == thought.id }) {
                                        Button("查看原讨论") { openDiscussion(origin.conversationID) }.buttonStyle(.workspaceQuietCompact)
                                    }
                                }.padding(.top,9)
                            } label: {
                                Text("原话依据、旁注与调整").vosFont(WorkspaceText.caption).foregroundStyle(palette.secondaryText)
                            }
                        }
                    }.padding(.vertical,8)
                    if thought.id != (showAllThoughts ? thoughts.last?.id : thoughts.prefix(3).last?.id) { WorkspaceListDivider() }
                }
                if thoughts.count > 3 {
                    WorkspaceListDivider()
                    Button(showAllThoughts ? "收起要点" : "展开全部 \(thoughts.count) 条要点",systemImage:showAllThoughts ? "chevron.up" : "chevron.down") { showAllThoughts.toggle() }.buttonStyle(.workspaceQuiet).padding(.top,18)
                }
            }
        } else if source.transcript != nil, pausedThoughts.isEmpty {
            VStack(alignment:.leading,spacing:10) {
                Text("这份材料还没有整理出观点。").vosFont(WorkspaceText.body).foregroundStyle(palette.secondaryText)
                Button("重新整理",systemImage:"arrow.clockwise",action:organize)
                    .buttonStyle(.workspaceSecondary)
                    .disabled(source.transcript == nil || source.localOnly || !model.modelConfigured)
                    .help(source.transcript == nil ? "转写完成后才能重新整理" : source.localOnly ? "仅本机保存的文字不能交给模型整理" : !model.modelConfigured ? "先配置文本模型才能重新整理" : "用当前文字重新提取理解")
            }
        }
    }
    @ViewBuilder private var readingContent:some View {
        if let scroll { readingScrollView.scrollPosition(scroll) } else { readingScrollView }
    }
    private var readingTitle: String {
        if let expression, expression.sourceIDs.count > 1 { return expression.displayTitle(in:catalog) }
        return source.displayTitle
    }
    private var sourceActions: some View {
        HStack(spacing:8) {
            if ["audio","video"].contains(source.kind) {
                Button("回听",systemImage:"play.circle") { Task { _=await model.playSpan(source,milliseconds:0) } }
                    .buttonStyle(.workspaceSecondaryCompact)
                    .disabled(source.state != "saved")
                    .help(source.state == "saved" ? "在页内从开头回听" : "录音尚未就绪，暂时无法回听")
            } else {
                Button("开始按天读",systemImage:"book") { showingIncrementalReading=true }
                    .buttonStyle(.workspaceSecondaryCompact)
                    .disabled(source.transcript == nil)
                    .help(source.transcript == nil ? "转写完成后才能按天读" : "按天分段阅读这份文字")
            }
            Menu {
                Button(expression.map { $0.sourceIDs.count > 1 } == true ? "修改分组标题" : "修改标题") { naming=source }
                Button("更正文字") { editing=source }.disabled(source.transcript == nil)
                    .help(source.transcript == nil ? "转写完成后才能更正文字" : "更正这段原文")
                if let saved=source.presentation?.expression, saved.sourceIDs.count > 1 {
                    Divider()
                    Button("拆为独立录音") { splitExpression(saved.sourceIDs) }
                        .disabled(model.fullRecordingBusy || model.understandingSource != nil)
                    Button("重新判断连续表达") { rejudgeExpression(saved.sourceIDs) }
                        .disabled(model.fullRecordingBusy || model.understandingSource != nil)
                        .help("重新让 AI 判断这些分段是否属于同一段连续表达")
                }
                Divider()
                Button("按天读") { showingIncrementalReading=true }.disabled(source.transcript == nil)
                    .help(source.transcript == nil ? "转写完成后才能按天读" : "按天分段阅读这份文字")
                Button("译文对照") { showingBilingual=true }.disabled(source.transcript == nil)
                    .help(source.transcript == nil ? "转写完成后才能译文对照" : "逐段查看译文")
                Button("从这里启动") { openInitiation(source.id) }
                    .disabled(source.transcript == nil || source.origin != "user" || source.speaker != "user")
                    .help(source.transcript == nil ? "转写完成后才能从这里启动" : source.origin != "user" ? "只有自己的记录才能从这里启动任务" : source.speaker != "user" ? "只有自己的表达才能从这里启动任务" : "从这条表达启动任务")
                Divider()
                Button(source.localOnly ? "允许这份文字用于云端并整理" : "改为仅本地") { Task { await model.changeTextPolicy(source);if source.localOnly { organize() } } }
                Button("重新整理当前文字",action:organize)
                    .disabled(source.transcript == nil || source.localOnly || !model.modelConfigured)
                    .help(source.transcript == nil ? "转写完成后才能重新整理" : source.localOnly ? "仅本机保存的文字不能交给模型整理" : !model.modelConfigured ? "先配置文本模型才能重新整理" : "用当前文字重新提取理解")
                if !model.modelConfigured { Button("配置文本模型…") { model.chooseTextModel() } }
            } label: {
                Label("更多",systemImage:"ellipsis.circle")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.workspaceSecondaryCompact)
        }
        .fixedSize()
    }
    private var readingScrollView: some View {
        ScrollView {
            LazyVStack(alignment:.leading,spacing:WorkspaceMetrics.sectionGap) {
                let reminderReads=ActionRowReads(reminderLinks:model.reminderLinks,executions:model.assistantExecutions)
                let titleFit=WorkspaceTitleFit.present(readingTitle)
                VStack(alignment:.leading,spacing:10) {
                    HStack(alignment:.top,spacing:16) {
                        VStack(alignment:.leading,spacing:6) {
                            Text((source.origin == "ai" ? "AI 交付物 · 不代表我的观点" : source.origin == "user" ? "我的表达" : "外部资料 · 不代表我的观点") + " · " + source.recordingSubtitle)
                                .vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                            Text(titleFit.title).vosFont(WorkspaceText.pageTitle).fixedSize(horizontal:false,vertical:true).textSelection(.enabled).accessibilityAddTraits(.isHeader)
                            if let origin=titleFit.source {
                                Text(origin).vosFont(WorkspaceText.caption).foregroundStyle(palette.tertiaryText).textSelection(.enabled)
                            }
                        }
                        Spacer(minLength:12)
                        sourceActions
                    }
                    if let captureInfo {
                        HStack(spacing:14) {
                            if let context=captureInfo.context,!context.isEmpty { Text("来自 " + context) }
                            if let link=captureLink(captureInfo.url) { Link(link.host ?? "来源链接", destination: link) }
                            if let date=ConversationReflectionFocus.date(captureInfo.capturedAt) { Text("抓取于 " + date.formatted(date:.abbreviated,time:.shortened)) }
                            else { Text("抓取于 " + captureInfo.capturedAt) }
                        }.vosFont(WorkspaceText.caption).foregroundStyle(palette.secondaryText).padding(.top,8)
                    }
                    HStack(spacing:12) {
                        if transcriptionRunning {
                            HStack(spacing:6) {
                                ProgressView().controlSize(.small).accessibilityHidden(true)
                                Text("正在转写…").vosFont(WorkspaceText.caption).foregroundStyle(palette.secondaryText)
                            }.accessibilityElement(children:.combine).accessibilityLabel("正在转写")
                        } else {
                            Label(sourceStatus,systemImage:sourceStatusIcon).vosFont(WorkspaceText.caption).foregroundStyle(transcriptionFailed ? palette.warning : palette.secondaryText)
                        }
                        let issueCount=source.unresolvedTranscriptionIssues.count
                        if issueCount > 0 { WorkspaceBadge(text:"转写疑点 \(issueCount)",tone:.warning) }
                        if let attachmentURL {
                            Button(attachmentMime == "application/pdf" ? "查看原件" : "查看原图",systemImage:attachmentMime == "application/pdf" ? "doc.richtext" : "photo") { if !NSWorkspace.shared.open(attachmentURL) { error="无法打开原件" } }
                                .buttonStyle(.workspaceQuietCompact)
                        }
                        Spacer(minLength:0)
                    }
                    .padding(.top,8)
                }
                if extractionFlag == .empty {
                    WorkspaceCard(padding:16) {
                        VStack(alignment:.leading,spacing:10) {
                            Label("这段没有提取到想法",systemImage:"circle.dashed")
                                .vosFont(WorkspaceText.meta.size, weight:.semibold)
                                .foregroundStyle(palette.warning)
                                .accessibilityAddTraits(.isHeader)
                            HStack(spacing:14) {
                                Button("重新整理这段",systemImage:"arrow.clockwise") { organize() }
                                    .buttonStyle(.workspaceSecondaryCompact)
                                    .disabled(source.transcript == nil || source.localOnly || !model.modelConfigured)
                                    .help(source.localOnly ? "仅本机保存的文字不能交给模型整理" : !model.modelConfigured ? "先配置文本模型才能重新整理" : "会重做整段表达：这段和同一表达的其他分段都会重新整理")
                                Button("视为无观点",systemImage:"checkmark.circle") { Task { await markExtractionAcknowledged() } }
                                    .buttonStyle(.workspaceQuietCompact)
                                    .help("确认这段没有可归属的观点；这条提示不会再出现")
                            }
                        }
                    }
                }
                let issues=source.unresolvedTranscriptionIssues
                if !issues.isEmpty {
                    UnresolvedIssuesBlock(issues:issues,playbackAvailable:playbackAvailable,playbackLabel:{ unresolvedIssuePlaybackLabel($0) },play:{ playUnresolvedIssue($0) },jump:{ jumpToOriginal(spanID:$0) })
                }
                if let issue=source.recordingExpressionIssue(in:catalog) {
                    WorkspaceCard(padding:16) {
                        HStack(alignment:.firstTextBaseline,spacing:12) {
                            Label("连续表达分组暂不可用 · \(issue)。",systemImage:"exclamationmark.triangle")
                                .vosFont(WorkspaceText.meta).foregroundStyle(palette.warning)
                            Spacer(minLength:8)
                            Button("重新判断连续表达") { rejudgeExpression(source.presentation?.expression?.sourceIDs ?? [source.id]) }
                                .buttonStyle(.workspaceSecondaryCompact)
                                .disabled(model.fullRecordingBusy || model.understandingSource != nil)
                            Button("拆为独立录音") { splitExpression(source.presentation?.expression?.sourceIDs ?? [source.id]) }
                                .buttonStyle(.workspaceSecondaryCompact)
                                .disabled(model.fullRecordingBusy || model.understandingSource != nil)
                        }
                    }
                }
                if correctionJustSaved,!model.correctionImpacts.isEmpty {
                    WorkspaceCard(padding:16) {
                        HStack(alignment:.firstTextBaseline,spacing:12) {
                            Label("\(model.correctionImpacts.count) 项任务受影响",systemImage:"exclamationmark.triangle")
                                .vosFont(WorkspaceText.meta.size, weight:.semibold)
                            Text("这些任务依赖更正前的内容；完成记录与已写入的外部提醒不会被自动删除。").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                            Spacer(minLength:8)
                            Button("查看纠错影响") { showingCorrectionImpacts=true }
                                .buttonStyle(.workspaceSecondaryCompact)
                            Button("知道了") { correctionJustSaved=false }
                                .buttonStyle(.workspaceQuietCompact)
                        }
                    }
                }
                if source.transcript == nil {
                    Text(source.error ?? "转写尚未完成，理解与待办识别还未开始。").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).textSelection(.enabled)
                    if source.dictationRecoveryPending {
                        Text("这段录音在结束前被中断，还没有完整原件。").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                        DictationRecoveryControls(model:model,source:source)
                    } else if ["failed","blocked"].contains(source.jobState ?? "") {
                        Button {
                            guard !retryingTranscription else { return }
                            retryingTranscription = true
                            Task {
                                await model.retry(source)
                                retryingTranscription = false
                            }
                        } label: {
                            HStack(spacing: 6) {
                                if retryingTranscription { ProgressView().controlSize(.small) }
                                Text(retryingTranscription ? "正在重试…" : "重试本地转写")
                            }
                        }
                        .buttonStyle(.workspacePrimary)
                        .disabled(retryingTranscription || model.dictationBusy || model.fullRecordingBusy || model.processingActivity != nil)
                    }
                }
                digestSections
                if !pausedThoughts.isEmpty {
                    WorkspaceCard() {
                        VStack(alignment:.leading,spacing:12) {
                        Label(automaticallyUpdating ? "正在自动更新理解" : pendingUnderstanding ? "理解尚未更新完成" : "AI 提取需要重新识别",systemImage:automaticallyUpdating ? "arrow.trianglehead.2.clockwise" : "pause.circle").vosFont(WorkspaceText.meta.size, weight: .semibold)
                        Text(automaticallyUpdating ? "原文已保存；正在结合完整表达与节目背景更新观点、任务和关联，完成后会自动更新。" : pauseExplanation).vosFont(WorkspaceText.body).foregroundStyle(palette.secondaryText)
                        if !pausedActions.isEmpty {
                            Text("受影响的任务与问题").vosFont(WorkspaceText.rowTitle)
                            ForEach(pausedActions) { action in
                                WorkspaceRow(title:action.title,subtitle:actionSubtitle(model.workspaceExternalCompletionNote(action) ?? model.workspaceActionStatus(action),reminder:actionReminderMeta(action,reads:reminderReads)),trailing:"查看任务") { openTask(action.id) }
                                WorkspaceExternalCompletionButton(model:model,action:action).padding(.leading,44).padding(.bottom,6)
                            }
                        }
                        if pendingUnderstanding && !automaticallyUpdating {
                            Text("自动更新尚未完成；原文与任务完成记录会保留。").vosFont(WorkspaceText.body).foregroundStyle(palette.secondaryText)
                        }
                        if source.localOnly {
                            Text("当前仅本机保存。允许后会将这份完整文字发送给已配置的模型。").vosFont(WorkspaceText.body).foregroundStyle(palette.secondaryText)
                            Button("允许这份文字用于云端并重新识别") { Task { await model.changeTextPolicy(source);organize() } }
                                .buttonStyle(.workspacePrimary)
                                .disabled(!model.modelConfigured || model.fullRecordingBusy || model.understandingSource != nil)
                        } else {
                            Button(automaticallyUpdating ? "正在自动更新…" : processing ? "正在重新识别…" : pendingUnderstanding ? "重试更新理解" : "重新识别观点和任务",action:organize)
                                .buttonStyle(.workspacePrimary)
                                .disabled(processing || model.fullRecordingBusy || model.understandingSource != nil || !model.modelConfigured || source.state == "quarantined")
                                .help(automaticallyUpdating || processing ? "正在处理，完成后这里会自动更新" : pendingUnderstanding ? "查看处理进度或错误后，点此重试自动更新" : "AI 会读取完整文字和转写核对记录，重新提取观点和任务；只有文字记错时才需要更正转写")
                        }
                        if !model.modelConfigured {
                            HStack(spacing:8) {
                                Text("重新识别需要先配置文本模型。").vosFont(WorkspaceText.meta).foregroundStyle(palette.warning)
                                Button("配置文本模型…") { model.chooseTextModel() }.buttonStyle(.workspaceQuietCompact)
                            }
                        }
                        Text("旧提取保留为历史；已连接的提醒事项不受影响。").vosFont(WorkspaceText.caption).foregroundStyle(palette.secondaryText)
                        }
                    }
                }
                if processing {
                    HStack(alignment:.top,spacing:10) {
                        ProgressView().controlSize(.small)
                        Text(organizationStatusText).vosFont(WorkspaceText.meta).textSelection(.enabled)
                    }
                }
                if let followup = model.recordingFollowups.last(where: { expressionIDs.contains($0.sourceID) }) {
                    SourceFollowupCard(receipt: followup, model: model, open: openFollowups)
                }
                if pausedThoughts.isEmpty && !pausedActions.isEmpty {
                    SourceSection(title:"观点已更正，关联待办需要重新确认",count:pausedActions.count) {
                        ForEach(pausedActions) { action in
                            WorkspaceRow(title:action.title,subtitle:actionSubtitle(model.workspaceExternalCompletionNote(action) ?? model.workspaceActionStatus(action),reminder:actionReminderMeta(action,reads:reminderReads)),trailing:"查看与处理") { openTask(action.id) }
                            WorkspaceExternalCompletionButton(model:model,action:action).padding(.leading,44).padding(.bottom,6)
                        }
                    }
                }
                let currentActions = actions.filter { $0.validity == "current" }
                let currentTasks = currentActions.filter { $0.kind == "task" }
                let currentGoals = currentActions.filter { $0.kind != "task" }
                if !currentTasks.isEmpty {
                    SourceSection(title:"待办",count:currentTasks.count) {
                        ForEach(currentTasks) { action in relatedActionRow(action, in: currentTasks, reads: reminderReads) }
                    }
                }
                if !currentGoals.isEmpty {
                    SourceSection(title:"问题与目标",count:currentGoals.count) {
                        ForEach(currentGoals) { action in relatedActionRow(action, in: currentGoals, reads: reminderReads) }
                    }
                }
                if let review {
                    let open = review.openIssues(from: review.issues)
                    if !open.isEmpty {
                        SourceSection(title:"理解有需要补充的地方",count:open.count) {
                            ForEach(open) { issue in
                                VStack(alignment:.leading,spacing:8) {
                                    WorkspaceExpandableText(text:issue.betterUnderstanding,label:"完整建议",size:WorkspaceText.body.size)
                                    KnowledgeReviewIssueStatusControls(model:model,record:review,issue:issue)
                                }.padding(.vertical,8)
                            }
                        }
                    }
                }
                SourceFold(title:"原文与回听",icon:"waveform",isExpanded:foldExpanded(\.original)) {
                    VStack(alignment:.leading,spacing:16) {
                        transcriptBody
                        if source.state == "saved" { Button("打开保存的原件",systemImage:"play.circle") { Task { await model.play(source) } }.buttonStyle(.workspaceSecondaryCompact) }
                        SourceSpanPlaybackList(model:model,source:source,
                                               spans:source.spans.filter { $0.startMS != nil && $0.endMS != nil },
                                               clock:playback)
                        Text("原文件：" + MaterialNaming.displayName(source.name)).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).textSelection(.enabled)
                        if source.transcript != nil {
                            WorkspaceListDivider()
                            DisclosureGroup("全文选读",isExpanded:foldExpanded(\.fullText)) {
                                VStack(alignment:.leading,spacing:12) {
                                    SelectionActions(selection:selectedText,canPlay:selectedSpan != nil,onSave:saveSelectionAsQuestion,onCopy:copySelectedText,onPlay:playSelectedSpan)
                                    SelectableText(text:source.transcript!) { text, range in
                                        selectedText=text
                                        selectedRange=range
                                    }.frame(minHeight:240)
                                }.padding(.top,12)
                            }
                        }
                    }
                }.id("source-original-fold")
                SourceFold(title:"更多资料",icon:"archivebox",count:extraSectionCount == 0 ? nil : extraSectionCount,isExpanded:foldExpanded(\.extras),spacing:WorkspaceMetrics.groupGap) {
                    if programPairs.isEmpty && contextPhase.isLoading { SourceLoadingRow(title:"正在读取节目关联…") }
                    if !programPairs.isEmpty {
                        SourceSection(title:"节目与我的思考",count:contextLinks.count) {
                            ForEach(programPairs,id:\.externalSourceID) { pair in
                                if let external=catalog[pair.externalSourceID] {
                                    WorkspaceRow(title:external.displayTitle,subtitle:pairingIsCurrent(pair) ? "同次录制的完整节目原文" : "节目原话或处理许可已变化，关联等待更新",icon:"headphones",trailing:"节目原文") { openSource(external.id) }
                                }
                            }
                            if !contextLinks.isEmpty {
                                DisclosureGroup("节目原话与我的回应（\(contextLinks.count)）") {
                                    ForEach(Array(contextLinks.enumerated()),id:\.offset) { _,link in
                                        VStack(alignment:.leading,spacing:12) {
                                            Text(contextRelation(link.relation)).vosFont(WorkspaceText.rowTitle)
                                            Text("节目原话").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                                            Text(link.externalQuote).vosFont(WorkspaceText.body).textSelection(.enabled)
                                            Button(contextPlaybackLabel(link.externalClaimID,role:"节目")) { Task { await playContextClaim(link.externalClaimID) } }.buttonStyle(.workspaceQuietCompact)
                                            Text("我的表达").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                                            Text(link.personalQuote).vosFont(WorkspaceText.body).textSelection(.enabled)
                                            Button(contextPlaybackLabel(link.personalClaimID,role:"我的")) { Task { await playContextClaim(link.personalClaimID) } }.buttonStyle(.workspaceQuietCompact)
                                            Text("AI 关联："+link.explanation).vosFont(WorkspaceText.body).foregroundStyle(palette.secondaryText).textSelection(.enabled)
                                        }.padding(.vertical,8)
                                        WorkspaceListDivider()
                                    }
                                }.padding(.top,12)
                            } else {
                                Text(automaticallyUpdating ? "正在重新核对节目与我的表达。" : programPairs.allSatisfy(pairingIsCurrent) ? "已保留节目背景；还没有已核对的回应关系。" : "已保存的双方原文仍可回看。").vosFont(WorkspaceText.body).foregroundStyle(palette.secondaryText).padding(.top,10)
                            }
                        }
                    }
                    if let failure=contextPhase.failure { SourceLoadFailureRow(operation:"读取节目关联",reason:failure) { contextRetry+=1 } }
                    if !historyActions.isEmpty {
                        DisclosureGroup("之前提取的任务与完成记录（\(historyActions.count)）") {
                            ForEach(historyActions) { action in WorkspaceRow(title:action.title,subtitle:actionSubtitle(model.workspaceExternalCompletionNote(action) ?? model.workspaceActionStatus(action),reminder:actionReminderMeta(action,reads:reminderReads)),trailing:"查看记录") { openTask(action.id) } }
                        }
                    }
                    if !outlineSections.isEmpty {
                        SourceFold(title:"逐字稿大纲",icon:"list.bullet",count:outlineSections.count,isExpanded:foldExpanded(\.outline)) {
                            SourceOutlinePlaybackList(sections:outlineSections,clock:playback) { playOutlineSection($0) }
                        }
                    }
                    if chapters.isEmpty && chaptersPhase.isLoading { SourceLoadingRow(title:"正在读取章节…") }
                    if let failure=chaptersPhase.failure, chapters.isEmpty { SourceLoadFailureRow(operation:"读取章节",reason:failure) { chaptersRetry+=1 } }
                    if !chapters.isEmpty {
                        SourceFold(title:"章节",icon:"list.number",count:chapters.count,isExpanded:foldExpanded(\.chapters)) {
                            SourceChapterPlaybackList(chapters:chapters,clock:playback) { playChapter($0) }
                        }
                    }
                    if entities.isEmpty && entitiesPhase.isLoading { SourceLoadingRow(title:"正在读取人名与术语…") }
                    if let failure=entitiesPhase.failure, entities.isEmpty { SourceLoadFailureRow(operation:"读取人名与术语",reason:failure) { entitiesRetry+=1 } }
                    if !entities.isEmpty {
                        SourceFold(title:"人名与术语",icon:"person.2",count:entities.count,isExpanded:foldExpanded(\.entities)) {
                            ForEach(entityGroups) { group in
                                Text(group.title).vosFont(WorkspaceText.meta.size, weight: .semibold).foregroundStyle(palette.secondaryText).padding(.top,12)
                                ForEach(group.entities,id:\.name) { entity in
                                    Button { openEntity(entity) } label: {
                                        HStack(spacing:8) {
                                            Text(entity.name + " · " + String(entity.mentionCount) + " 次").vosFont(WorkspaceText.rowTitle).multilineTextAlignment(.leading)
                                            Spacer(minLength:0)
                                        }.padding(.horizontal,8).padding(.vertical,6).contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                SourceFold(title:"处理记录",icon:"tray",isExpanded:foldExpanded(\.records),spacing:WorkspaceMetrics.groupGap) {
                    SourceSection(title:"依据、修订与处理记录") {
                        DisclosureGroup("核对依据与适用边界") { KnowledgeReviewSection(model:model,sourceIDs:[source.id],carded:false).padding(.top,12) }.padding(.vertical,16)
                        WorkspaceListDivider()
                        DisclosureGroup("文字校正、理解与修订历史") {
                            VStack(alignment:.leading,spacing:WorkspaceMetrics.rowGap) {
                                if source.transcriptionReview != nil {
                                    Text("转写校正已保存，原始版本可追溯。").vosFont(WorkspaceText.meta)
                                    let issues=source.unresolvedTranscriptionIssues
                                    if !issues.isEmpty {
                                        UnresolvedIssuesBlock(issues:issues,playbackAvailable:playbackAvailable,playbackLabel:{ unresolvedIssuePlaybackLabel($0) },play:{ playUnresolvedIssue($0) },jump:{ jumpToOriginal(spanID:$0) })
                                    }
                                }
                                Button("查看全部原文版本", action:loadHistory).buttonStyle(.workspaceQuietCompact)
                                historyVersions
                                if source.transcript != nil { Button("查看原话分段") { Task { showingSegmentation = await model.previewSegmentation(source) } }.buttonStyle(.workspaceQuietCompact) }
                                ForEach(model.attempts[source.id] ?? []) { attempt in
                                    Text((attempt.state == "completed" ? "理解已完成" : "理解：" + workspaceStateLabel(attempt.state)) + (attempt.contextState == "stale" ? " · 历史依据已变化" : "")).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                                }
                                if discussionsPhase.isLoading { SourceLoadingRow(title:"正在读取讨论…") }
                                else if let failure=discussionsPhase.failure { SourceLoadFailureRow(operation:"读取讨论",reason:failure) { discussionsRetry+=1 } }
                                ForEach(Array(loadedDiscussions.enumerated()),id:\.element.id) { index,session in Button("打开讨论 \(index+1)") { openDiscussion(session.id) }.buttonStyle(.workspaceQuietCompact) }
                            }.padding(.top,12)
                        }.padding(.vertical,16)
                        if let corrections=source.transcriptionReview?.corrections,!corrections.isEmpty {
                            WorkspaceListDivider()
                            DisclosureGroup("转写改写 \(corrections.count) 处",isExpanded:$correctionsExpanded) {
                                VStack(alignment:.leading,spacing:12) {
                                    ForEach(Array(corrections.enumerated()),id:\.offset) { _,correction in
                                        VStack(alignment:.leading,spacing:6) {
                                            HStack(alignment:.firstTextBaseline,spacing:8) {
                                                Text(correction.before).strikethrough().foregroundStyle(palette.secondaryText)
                                                Image(systemName:"arrow.right").vosFont(WorkspaceText.caption).foregroundStyle(palette.tertiaryText).accessibilityHidden(true)
                                                Text(correction.after)
                                            }.vosFont(WorkspaceText.body).fixedSize(horizontal:false,vertical:true)
                                            if let context=correction.context_quote?.trimmingCharacters(in:.whitespacesAndNewlines),!context.isEmpty {
                                                Text("上下文：" + truncatedQuote(context)).vosFont(WorkspaceText.caption).foregroundStyle(palette.tertiaryText).textSelection(.enabled)
                                            }
                                        }.padding(.vertical,4)
                                    }
                                }.padding(.top,12)
                            }.padding(.vertical,16)
                        }
                        WorkspaceListDivider()
                        DisclosureGroup("主题归属与处理情况") {
                            VStack(alignment:.leading,spacing:WorkspaceMetrics.rowGap) {
                                ForEach(model.workspaceTopics) { topic in
                                    let linked=model.workspaceTopicSources[topic.id]?.contains(source.id) == true
                                    Toggle(topic.title,isOn:Binding(get:{linked},set:{ value in Task { do { try await model.linkReflectionQuestionSource(questionID:topic.id,sourceID:source.id,linked:value);await model.refresh() } catch { self.error=error.localizedDescription } } }))
                                }
                                if !source.localOnly { Button("重新整理当前内容",action:organize).buttonStyle(.workspaceSecondaryCompact).disabled(source.transcript == nil || model.fullRecordingBusy || model.understandingSource != nil) }
                                ForEach(model.segmentedBatches.filter { $0.scope.plan.source.sourceID == source.id }) { batch in
                                    HStack { Text(workspaceStateLabel(batch.state.rawValue)).vosFont(WorkspaceText.meta);if batch.state == .queued { Button("停止后续处理") { model.cancelSegmented(batch.id) }.buttonStyle(.workspaceQuietCompact) } }
                                    if let error=batch.error { Text(error).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText) }
                                }
                                Text(model.fullRecordingStatus).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                                Text(model.transcriptReviewStatus).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                                if let error=source.error { Text(error).vosFont(WorkspaceText.meta).foregroundStyle(palette.danger) }
                            }.padding(.top,12)
                        }.padding(.vertical,16)
                    }
                    if !source.dictationRecoveryPending {
                        VStack(alignment:.leading,spacing:10) {
                            MaterialManagementControls(model:model,source:source)
                            Text(source.isArchived ? "已归档：从日常材料列表收起，仍可作为历史依据使用。" : "归档只收起材料；移入回收站会暂停相关理解，但可恢复。").vosFont(WorkspaceText.caption).foregroundStyle(palette.secondaryText)
                        }
                    }
                    if !error.isEmpty { WorkspaceNoticeText(message:error,severity:.danger) }
                }
            }.frame(maxWidth:readingWidth,alignment:.leading)
                .padding(.horizontal,WorkspaceMetrics.pagePadding)
                .padding(.top,16)
                .padding(.bottom,WorkspaceMetrics.pagePadding)
                .frame(maxWidth:.infinity,alignment:.top)
        }
        .onDisappear { historyTask?.cancel();bilingualTask?.cancel() }
    }
    var body:some View {
        readingContent
        .safeAreaInset(edge:.bottom,spacing:0) { playbackBar }
        .workspaceToast($toast)
        .sheet(item:$editing) { source in WorkspaceTranscriptEditor(model:model,source:source,onSaved:{ toast="原文已更正";correctionJustSaved=true }) { editing=nil } }
        .sheet(isPresented:$showingCorrectionImpacts) {
            CorrectionImpactView(model:model,dismiss:{ showingCorrectionImpacts=false;if let id=model.selected,id != source.id { openSource(id) } })
        }
        .sheet(item:$naming) { target in
            if let expression=model.sourcePageIndex.expression(for:target.id), expression.sourceIDs.count > 1 {
                RecordingExpressionTitleEditor(record:target,expression:expression,model:model) { naming=nil }
            } else {
                RecordingTitleEditor(record:target,model:model) { naming=nil }
            }
        }
        .sheet(item:$claimEditor) { claim in ClaimCorrectionView(claim:claim,model:model,onSaved:{ toast="理解已更新" }) { claimEditor=nil } }
        .sheet(item:$actionClaim) { claim in ActionCreationView(claim:claim,model:model) { actionClaim=nil } }
        .sheet(isPresented:$showingSegmentation) { TranscriptSegmentationView(model:model) { showingSegmentation=false } }
        .sheet(isPresented:$showingBilingual) {
            BilingualView(model:model,source:source,excerpt:bilingualExcerpt,translations:bilingualTranslations,phase:bilingualPhase,generate:generateBilingual,continueBatch:continueBilingual,retryParagraph:retryBilingualParagraph,allowCloud:allowBilingualCloud,correctTranscript:correctBilingualTranscript,dismiss:{ showingBilingual=false })
        }
        .sheet(isPresented:$showingIncrementalReading) {
            IncrementalReadingView(model:model,source:source) { showingIncrementalReading=false }
        }
        .alert("停止使用这条理解？", isPresented:$confirmingRejection, presenting:pendingRejection) { claim in
            Button("停止使用", role:.destructive) { Task { _=await model.review(claim, action:.reject) } }
            Button("取消", role:.cancel) {}
        } message: { _ in
            Text("确定后，这份理解将不再用于当前阅读与行动。原文与处理历史会保留。")
        }
        .task(id: pauseReadKey) {
            guard !pausedThoughts.isEmpty,let store=model.store else { return }
            do { pauseExplanation = try await store.understandingPause(sourceID:source.id).summary }
            catch { pauseExplanation = "暂时无法读取暂停原因：" + error.localizedDescription }
        }
        .task(id: discussionReadKey) {
            discussionsPhase = .loading
            guard let store = model.store else { discussionsPhase = .idle; return }
            do {
                let discussions = try await store.conversationsForSource(sourceID: source.id)
                try Task.checkCancellation()
                loadedDiscussions = discussions
                discussionsPhase = .idle
            } catch is CancellationError { discussionsPhase = .idle }
            catch {
                self.error = error.localizedDescription
                discussionsPhase = .failed(error.localizedDescription)
            }
        }
        .task(id:contextReadKey) {
            programPairs=[]
            contextLinks=[]
            contextPhase = .loading
            guard let store=model.store else { contextPhase = .idle; return }
            let ids=expressionIDs
            programPairs=model.records.filter { ids.contains($0.id) }.compactMap { $0.presentation?.recordingContext }
            do {
                let links=try await store.recordingContextLinks(sourceIDs:ids.sorted(),catalog:catalog)
                try Task.checkCancellation()
                contextLinks=links.filter { pairingIsCurrent($0.pairing) }
                contextPhase = .idle
            } catch is CancellationError { contextPhase = .idle }
            catch { contextPhase = .failed(error.localizedDescription) }
        }
        .task(id: source.id) {
            attachmentURL=nil;attachmentMime=nil
            captureInfo=try? await model.sourceCaptureMetadata(sourceID:source.id)
            do {
                let attachment=try await model.sourceAttachmentURL(sourceID:source.id)
                attachmentURL=attachment?.url;attachmentMime=attachment?.mime
            }
            catch { self.error="原件读取失败：" + error.localizedDescription }
        }
        .task(id: SourceTranscriptReadKey(sourceID:source.id,transcriptVersionID:source.transcriptVersionID,retry:entitiesRetry)) {
            entities=[]
            entitiesPhase = .loading
            guard source.transcript != nil,let store=model.store else { entitiesPhase = .idle; return }
            do {
                let loaded=try await store.entities(sourceID:source.id)
                entities=loaded
                let spanIDs=Set(source.spans.map(\.id))
                let stale = !loaded.isEmpty && loaded.allSatisfy { $0.sentenceIDs.allSatisfy { !spanIDs.contains($0) } }
                if loaded.isEmpty || stale {
                    _=try? await store.refreshEntities(sourceID:source.id)
                    if !Task.isCancelled { entities=(try? await store.entities(sourceID:source.id)) ?? [] }
                }
                entitiesPhase = .idle
            } catch {
                entitiesPhase = .failed(error.localizedDescription)
            }
        }
        .task(id: SourceChapterReadKey(sourceID:source.id,kind:source.kind,retry:chaptersRetry)) {
            chapters=[]
            chaptersPhase = .loading
            guard ["audio","video"].contains(source.kind),let store=model.store else { chaptersPhase = .idle; return }
            do {
                chapters=try await store.chapters(sourceID:source.id)
                if chapters.isEmpty,let url=try? await store.playableURL(sourceID:source.id) {
                    let found=await MediaChapters.read(url)
                    if !found.isEmpty {
                        try await store.replaceChapters(sourceID:source.id,entries:found.map { (title:$0.title,startMS:$0.startMS) })
                        chapters=try await store.chapters(sourceID:source.id)
                    }
                }
                chaptersPhase = .idle
            } catch {
                chapters=[]
                chaptersPhase = .failed(error.localizedDescription)
            }
        }
        .task(id: source.id) {
            guard let store=model.store else { return }
            do {
                let loaded=try await store.claimNotes(claimIDs:thoughts.map(\.id))
                try Task.checkCancellation()
                claimNotes=loaded
            } catch is CancellationError {}
            catch { self.error="旁注读取失败：" + error.localizedDescription }
        }
        .task(id: extractionFlagRefreshKey) {
            extractionFlag=nil
            guard let store=model.store else { return }
            extractionFlag=try? await store.sourceExtractionFlag(sourceID:source.id)
        }
        .onChange(of:folds.fullText) { _,_ in if !folds.fullText { clearSelection() } }
        .onChange(of:source.transcript) { _,_ in clearSelection();resetBilingual();folds.original=SourceFoldState.initial(transcript:source.transcript).original }
        .onReceive(playback.$milliseconds) { followPlaybackHighlight($0) }
        .task {
            while !Task.isCancelled {
                refreshPlaybackPosition()
                do { try await Task.sleep(for:.milliseconds(300)) } catch { return }
            }
        }
    }
    private var playbackAvailable:Bool { ["audio","video"].contains(source.kind) && source.state == "saved" }
    private var pauseReadKey:SourcePauseReadKey {
        .init(sourceID:source.id,pausedThoughtIDs:pausedThoughts.map(\.id),
              transcriptVersionID:source.transcriptVersionID,policyVersion:source.policyVersion,state:source.state)
    }
    private var discussionReadKey:SourceDiscussionReadKey {
        .init(sourceID:source.id,items:model.discussionList.map { .init(id:$0.id,version:$0.version,validity:$0.validity) },retry:discussionsRetry)
    }
    private var extractionFlagRefreshKey:SourceExtractionReadKey {
        .init(sourceID:source.id,transcriptVersionID:source.transcriptVersionID,
              expressionState:expression?.state ?? "",thoughtsCount:thoughts.count)
    }
    @ViewBuilder private var playbackBar:some View {
        if playbackAvailable { SourcePlaybackBar(model:model,source:source,clock:playback) }
    }
    @ViewBuilder private var transcriptBody:some View {
        if let transcript=source.transcript {
            if transcriptParagraphs.isEmpty {
                MarkdownText(transcript)
            } else {
                SourceTranscriptBody(paragraphs:transcriptParagraphs,clock:playback)
            }
        } else if transcriptionRunning {
            HStack(spacing:10) {
                ProgressView().controlSize(.small).accessibilityHidden(true)
                Text("正在转写… 原件已保存").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
            }.accessibilityElement(children:.combine)
        } else if transcriptionFailed {
            Text("转写失败 · 原件已保存").vosFont(WorkspaceText.meta).foregroundStyle(palette.warning)
        } else {
            Text("尚无可用转写 · " + (source.error ?? workspaceStateLabel(source.jobState ?? source.state))).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
        }
    }
    private var timedTranscriptSpans:[TranscriptSpan] {
        guard ["audio","video"].contains(source.kind),source.transcript != nil,!source.spans.isEmpty,
              source.spans.allSatisfy({ $0.startMS != nil && $0.endMS != nil }) else { return [] }
        return source.spans
    }
    private var transcriptParagraphs:[TranscriptParagraph] {
        guard let transcript=source.transcript else { return [] }
        return timedTranscriptSpans.compactMap { span in
            let text=SourceText.quote(span,in:transcript)
            return text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? nil : TranscriptParagraph(span:span,text:text)
        }
    }
    private func followPlaybackHighlight(_ milliseconds:Int?) {
        guard let ms=milliseconds else { autoScrolledSpanID=nil;return }
        guard folds.original,let scroll else { return }
        guard let paragraph=transcriptParagraphs.first(where: { paragraph in
            guard let start=paragraph.span.startMS,let end=paragraph.span.endMS else { return false }
            return ms>=start && ms<end
        }),paragraph.id != autoScrolledSpanID else { return }
        autoScrolledSpanID=paragraph.id
        let anchor="source-para-"+paragraph.id
        Task { @MainActor in
            await Task.yield()
            scroll.wrappedValue.scrollTo(id:anchor,anchor:.center)
        }
    }
    private func jumpToOriginal(spanID:String) {
        folds.original=true
        guard let scroll else { return }
        let anchor:String
        if transcriptParagraphs.contains(where: { $0.id == spanID }) { anchor="source-para-"+spanID }
        else if source.spans.contains(where: { $0.id == spanID }) { anchor="source-span-"+spanID }
        else { anchor="source-original-fold" }
        Task { @MainActor in
            await Task.yield()
            scroll.wrappedValue.scrollTo(id:anchor,anchor:.center)
        }
    }
    private func unresolvedIssuePlaybackLabel(_ issue:TranscriptionReview.Issue)->String {
        guard let span=source.spans.first(where: { $0.id == issue.span_id }),span.startMS != nil,span.endMS != nil else { return "回听整段" }
        return "回听"
    }
    private func playUnresolvedIssue(_ issue:TranscriptionReview.Issue) {
        guard playbackAvailable else { return }
        if let span=source.spans.first(where: { $0.id == issue.span_id }),let start=span.startMS,let end=span.endMS {
            Task { _=await model.playSpan(source,milliseconds:start,endMilliseconds:end) }
        } else {
            Task { _=await model.playSpan(source,milliseconds:0) }
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
            catalog[ref.sourceID]?.spans.contains(where: { $0.id == ref.spanID && $0.startMS != nil && $0.endMS != nil }) == true
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
    private func markExtractionAcknowledged() async {
        guard let store=model.store else { return }
        do {
            try await store.acknowledgeEmptyExtraction(sourceID:source.id)
            extractionFlag=try await store.sourceExtractionFlag(sourceID:source.id)
        } catch { self.error=error.localizedDescription }
    }
    private func generateBilingual() {
        guard bilingualPhase != .loading,let transcript=source.transcript else { return }
        guard !source.localOnly,!source.needsTranscriptionReview else { return }
        let excerpt=Bilingual.paragraphs(from:transcript,spans:source.spans)
        guard !excerpt.isEmpty else { bilingualPhase = .failed("这份材料没有可对照的文字。");return }
        bilingualConsumed=0
        translateBilingual(excerpt)
    }
    private func continueBilingual() {
        guard bilingualPhase == .ready,let transcript=source.transcript else { return }
        let next=Bilingual.nextBatch(from:transcript,spans:source.spans,consumed:bilingualConsumed)
        guard !next.isEmpty else { return }
        translateBilingual(next)
    }
    private func translateBilingual(_ excerpt:BilingualExcerpt) {
        bilingualExcerpt=excerpt
        bilingualConsumed+=excerpt.paragraphs.reduce(0) { $0+$1.text.unicodeScalars.count }
        bilingualTranslations=Array(repeating:nil,count:excerpt.paragraphs.count)
        bilingualPhase = .loading
        let paragraphs=excerpt.paragraphs
        bilingualTask?.cancel()
        bilingualTask=Task {
            do {
                let client=try BilingualClient()
                let lines=try await client.translate(paragraphs)
                try Task.checkCancellation()
                bilingualTranslations=lines
                bilingualPhase = .ready
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { bilingualPhase = .failed(error.localizedDescription) }
            }
        }
    }
    private func retryBilingualParagraph(_ paragraph:BilingualParagraph) async -> Bool {
        guard bilingualTranslations.indices.contains(paragraph.id) else { return false }
        do {
            let lines=try await BilingualClient().translate([paragraph])
            guard let text=lines.first ?? nil else { return false }
            bilingualTranslations[paragraph.id]=text
            return true
        } catch { return false }
    }
    private func allowBilingualCloud() {
        guard let current=model.records.first(where: { $0.id == source.id }) else { return }
        Task { await model.changeTextPolicy(current) }
    }
    private func correctBilingualTranscript() {
        showingBilingual=false
        Task {
            try? await Task.sleep(for:.milliseconds(250))
            editing=source
        }
    }
    private func resetBilingual() {
        bilingualTask?.cancel()
        bilingualConsumed=0
        bilingualExcerpt=BilingualExcerpt(paragraphs:[],truncated:false)
        bilingualTranslations=[]
        bilingualPhase = .idle
    }
    private func saveSelectionAsQuestion() {
        let text=selectedText
        guard !savingQuestion, !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return }
        savingQuestion = true
        Task { @MainActor in
            defer { savingQuestion = false }
            if let id=await model.saveCapturedText(text,title:selectionQuestionTitle(text),ownership:.personal,allowCloud:false,commandID:UUID().uuidString) {
                clearSelection()
                openSource(id)
            } else {
                error=model.status.isEmpty ? "保存失败，请稍后重试" : model.status
            }
        }
    }
    private func selectionQuestionTitle(_ text:String)->String {
        let firstLine=text.split(whereSeparator:{ $0.isNewline }).map { $0.trimmingCharacters(in:.whitespaces) }.first { !$0.isEmpty }
        return "问题 · " + String((firstLine ?? text.trimmingCharacters(in:.whitespacesAndNewlines)).prefix(60))
    }
    private func copySelectedText() {
        let board=NSPasteboard.general
        board.clearContents()
        if !board.setString(selectedText,forType:.string) { error="复制失败，请重试" }
    }
    private func playSelectedSpan() {
        guard let span=selectedSpan,let start=span.startMS,let end=span.endMS else { return }
        Task { @MainActor in
            if !(await model.playSpan(source,milliseconds:start,endMilliseconds:end)) {
                error=model.status.isEmpty ? "无法回听这段原话" : model.status
            }
        }
    }
    private func clearSelection() {
        selectedText=""
        selectedRange=NSRange(location:0,length:0)
    }
    private func splitExpression(_ ids:[String]) {
        guard !ids.isEmpty else { return }
        Task { @MainActor in
            do {
                let count=try await model.splitRecordingExpression(sourceIDs:Set(ids))
                toast="已拆成 \(count) 段独立录音"
            } catch { self.error=error.localizedDescription }
        }
    }
    private func rejudgeExpression(_ ids:[String]) {
        guard !ids.isEmpty else { return }
        Task { @MainActor in
            do {
                let groups=try await model.rejudgeRecordingExpressions(sourceIDs:Set(ids))
                toast="已重新判断连续表达 · \(groups) 组"
            } catch { self.error=error.localizedDescription }
        }
    }
    private func quote(_ span:TranscriptSpan,text:String) -> String { SourceText.quote(span,in:text) }
    private func truncatedQuote(_ text:String,limit:Int=60)->String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }
    private func playOutlineSection(_ section:SourceOutlineSection) {
        Task { @MainActor in
            if !(await model.playSpan(source,milliseconds:section.startMS,endMilliseconds:section.endMS)) {
                error=model.status.isEmpty ? "无法回听这一节" : model.status
            }
        }
    }
    private func playChapter(_ chapter:SourceChapter) {
        Task { @MainActor in
            if !(await model.playSpan(source,milliseconds:chapter.startMS)) {
                error=model.status.isEmpty ? "无法回听这一章" : model.status
            }
        }
    }
    private func openEntity(_ entity:SourceEntity) {
        let timed=entity.sentenceIDs.compactMap { id in source.spans.first { $0.id == id && $0.startMS != nil && $0.endMS != nil } }.first
        if let span=timed {
            folds.original=true
            if ["audio","video"].contains(source.kind),let start=span.startMS { Task { _=await model.playSpan(source,milliseconds:start) } }
            let anchor="source-span-"+span.id
            Task { @MainActor in
                await Task.yield()
                if let scroll { scroll.wrappedValue.scrollTo(id:anchor,anchor:.center) }
            }
            return
        }
        folds.original=true
        if let scroll { scroll.wrappedValue.scrollTo(edge:.top) }
    }
    private func readingLayerRow(_ title:String,_ text:String) -> some View {
        VStack(alignment:.leading,spacing:8) {
            Text(title).vosFont(WorkspaceText.meta.size, weight: .semibold).foregroundStyle(palette.secondaryText)
            Text(text).vosFont(WorkspaceText.body).lineSpacing(4).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
        }
    }
    private func refreshPlaybackPosition() {
        var next: Int?
        if let player=model.player,player.timeControlStatus == .playing {
            let seconds=player.currentTime().seconds
            next = seconds.isFinite ? Int((seconds*1000).rounded()) : nil
        }
        if next != playback.milliseconds { playback.milliseconds = next }
    }
}
private struct SourcePlaybackBar: View {
    @Environment(\.workspacePalette) private var palette
    let model:ControlCenter
    let source:SourceRecord
    @ObservedObject var clock:SourcePlaybackClock
    private var playing:Bool { model.player?.timeControlStatus == .playing }
    private var displayedMS:Int {
        if let milliseconds=clock.milliseconds { return milliseconds }
        guard let player=model.player else { return 0 }
        let seconds=player.currentTime().seconds
        return seconds.isFinite ? Int((seconds*1000).rounded()) : 0
    }
    var body:some View {
        VStack(spacing:0) {
            HStack(spacing:12) {
                Button {
                    if let player=model.player {
                        if player.timeControlStatus == .playing { player.pause() } else { player.play() }
                    } else { Task { _=await model.playSpan(source,milliseconds:0) } }
                } label: {
                    Image(systemName:playing ? "pause.fill" : "play.fill").vosFont(WorkspaceText.rowTitle).accessibilityHidden(true)
                }
                .buttonStyle(.plain).frame(width:WorkspaceMetrics.iconButtonSize,height:WorkspaceMetrics.iconButtonSize)
                .background(palette.selection,in:RoundedRectangle(cornerRadius:WorkspaceMetrics.controlRadius))
                .accessibilityLabel(playing ? "暂停回听" : "开始或继续回听")
                Text(sourceTime(displayedMS)).vosFont(WorkspaceText.meta.size,monospacedDigit:true).foregroundStyle(palette.secondaryText)
                if let duration=source.duration,duration>0 {
                    ProgressView(value:min(Double(displayedMS)/1000,duration),total:duration).progressViewStyle(.linear).frame(maxWidth:280)
                    Text(sourceTime(Int(duration*1000))).vosFont(WorkspaceText.meta.size,monospacedDigit:true).foregroundStyle(palette.tertiaryText)
                }
                Spacer(minLength:8)
                Text(source.displayTitle).vosFont(WorkspaceText.caption).foregroundStyle(palette.tertiaryText).lineLimit(1)
            }.padding(.horizontal,20).padding(.vertical,10)
            if let player=model.player {
                NativePlayerView(player:player).frame(height:source.kind == "video" ? 200 : 56)
            }
        }
        .background(palette.surface)
        .overlay(alignment:.top) { Rectangle().fill(palette.border).frame(height:1) }
        .accessibilityElement(children:.contain)
        .accessibilityLabel("页内回听")
    }
}
private struct SourceTranscriptBody: View {
    @Environment(\.vosTextScale) private var textScale
    let paragraphs:[TranscriptParagraph]
    @ObservedObject var clock:SourcePlaybackClock
    private let window:SourceParagraphWindow
    init(paragraphs:[TranscriptParagraph],clock:SourcePlaybackClock) {
        self.paragraphs=paragraphs
        _clock=ObservedObject(wrappedValue:clock)
        window=SourceParagraphWindow(paragraphs:paragraphs.map {
            .init(id:$0.id,startMS:$0.span.startMS ?? 0,endMS:$0.span.endMS ?? 0)
        })
    }
    var body:some View {
        let active=window.activeID(at:clock.milliseconds)
        VStack(alignment:.leading,spacing:WorkspaceText.body.size * textScale * 1.125) {
            ForEach(paragraphs) { paragraph in
                TranscriptParagraphRow(id:paragraph.id,text:paragraph.text,active:paragraph.id == active).equatable()
            }
        }.textSelection(.enabled)
    }
}
private struct TranscriptParagraphRow: View, Equatable {
    @Environment(\.workspacePalette) private var palette
    @Environment(\.vosTextScale) private var textScale
    let id:String
    let text:String
    let active:Bool
    static func == (lhs:TranscriptParagraphRow,rhs:TranscriptParagraphRow)->Bool {
        lhs.id == rhs.id && lhs.text == rhs.text && lhs.active == rhs.active
    }
    var body:some View {
        Text(text)
            .vosFont(WorkspaceText.body)
            .foregroundStyle(palette.text)
            .lineSpacing(WorkspaceText.body.size * textScale * 0.5)
            .fixedSize(horizontal:false,vertical:true)
            .padding(.horizontal,8).padding(.vertical,4)
            .background(active ? palette.selection : Color.clear,in:RoundedRectangle(cornerRadius:WorkspaceMetrics.controlRadius))
            .id("source-para-"+id)
            .accessibilityElement(children:.ignore)
            .accessibilityLabel(text)
    }
}
private struct SourceSpanPlaybackList: View {
    let model:ControlCenter
    let source:SourceRecord
    let spans:[TranscriptSpan]
    @ObservedObject var clock:SourcePlaybackClock
    var body:some View {
        ForEach(spans) { span in
            let active=isPlaying(span)
            Button { Task { _=await model.playSpan(source,milliseconds:span.startMS!,endMilliseconds:span.endMS!) } } label: {
                SourceSpanPlaybackLabel(startMS:span.startMS!,endMS:span.endMS!,active:active).equatable()
            }.buttonStyle(.plain).id("source-span-"+span.id)
                .accessibilityElement(children:.ignore)
                .accessibilityLabel(sourceTime(span.startMS!) + "—" + sourceTime(span.endMS!) + "，回听这段")
        }
    }
    private func isPlaying(_ span:TranscriptSpan)->Bool {
        guard let milliseconds=clock.milliseconds,let start=span.startMS,let end=span.endMS else { return false }
        return milliseconds >= start && milliseconds < end
    }
}
private struct SourceSpanPlaybackLabel: View, Equatable {
    @Environment(\.workspacePalette) private var palette
    let startMS:Int
    let endMS:Int
    let active:Bool
    static func == (lhs:SourceSpanPlaybackLabel,rhs:SourceSpanPlaybackLabel)->Bool {
        lhs.startMS == rhs.startMS && lhs.endMS == rhs.endMS && lhs.active == rhs.active
    }
    var body:some View {
        Text(sourceTime(startMS) + "—" + sourceTime(endMS) + " · 回听")
            .vosFont(WorkspaceText.meta.size, weight: active ? .semibold : .regular)
            .padding(.horizontal,8).padding(.vertical,3)
            .background(active ? palette.selection : .clear, in: RoundedRectangle(cornerRadius:WorkspaceMetrics.controlRadius))
            .contentShape(Rectangle())
    }
}
private struct SourceOutlinePlaybackList: View {
    let sections:[SourceOutlineSection]
    @ObservedObject var clock:SourcePlaybackClock
    let play:(SourceOutlineSection)->Void
    var body:some View {
        VStack(alignment:.leading,spacing:4) {
            ForEach(sections) { section in
                let active=isPlaying(section)
                Button { play(section) } label: {
                    SourceTimedPlaybackLabel(startMS:section.startMS,title:section.title,active:active).equatable()
                }.buttonStyle(.plain)
                    .accessibilityElement(children:.ignore)
                    .accessibilityLabel(sourceTime(section.startMS) + "，" + section.title)
            }
        }
    }
    private func isPlaying(_ section:SourceOutlineSection)->Bool {
        guard let milliseconds=clock.milliseconds else { return false }
        return milliseconds >= section.startMS && milliseconds < section.endMS
    }
}
private struct SourceChapterPlaybackList: View {
    let chapters:[SourceChapter]
    @ObservedObject var clock:SourcePlaybackClock
    let play:(SourceChapter)->Void
    var body:some View {
        ForEach(chapters,id:\.ordinal) { chapter in
            let active=isPlaying(chapter)
            Button { play(chapter) } label: {
                SourceTimedPlaybackLabel(startMS:chapter.startMS,title:chapter.title,active:active).equatable()
            }.buttonStyle(.plain)
                .accessibilityElement(children:.ignore)
                .accessibilityLabel(sourceTime(chapter.startMS) + "，" + chapter.title)
        }
    }
    private func isPlaying(_ chapter:SourceChapter)->Bool {
        guard let milliseconds=clock.milliseconds else { return false }
        let next=chapters.first { $0.ordinal == chapter.ordinal + 1 }?.startMS ?? Int.max
        return milliseconds >= chapter.startMS && milliseconds < next
    }
}
private struct SourceTimedPlaybackLabel: View, Equatable {
    @Environment(\.workspacePalette) private var palette
    let startMS:Int
    let title:String
    let active:Bool
    static func == (lhs:SourceTimedPlaybackLabel,rhs:SourceTimedPlaybackLabel)->Bool {
        lhs.startMS == rhs.startMS && lhs.title == rhs.title && lhs.active == rhs.active
    }
    var body:some View {
        HStack(alignment:.top,spacing:10) {
            Text(sourceTime(startMS)).vosFont(WorkspaceText.meta.size, weight: .medium, design: .monospaced).foregroundStyle(palette.secondaryText)
            Text(title).vosFont(WorkspaceText.rowTitle.size, weight: active ? .semibold : .regular).multilineTextAlignment(.leading)
            Spacer(minLength:0)
        }.padding(.horizontal,8).padding(.vertical,6)
            .background(active ? palette.selection : .clear,in:RoundedRectangle(cornerRadius:WorkspaceMetrics.controlRadius))
            .contentShape(Rectangle())
    }
}
struct WorkspaceTranscriptEditor:View {
    @Environment(\.workspacePalette) private var palette
    @ObservedObject var model:ControlCenter
    let source:SourceRecord
    var onSaved:()->Void = {}
    let close:()->Void
    @State private var text=""
    @State private var failure=""
    @State private var saving=false
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("更正原文").vosFont(WorkspaceText.sectionTitle)
            Text(source.localOnly ? "这份材料仅本机保存。更正后保留原话历史，旧理解暂停使用；允许云端处理后可重新整理。" : "保存后会自动更新完整理解；原话历史、真实完成与结果保留。").vosFont(WorkspaceText.body).foregroundStyle(palette.secondaryText)
            TextEditor(text:$text).frame(minHeight:300).workspaceEditorSurface()
            if !failure.isEmpty { Text(failure).vosFont(WorkspaceText.meta).foregroundStyle(palette.danger) }
            HStack {
                Button("取消",action:close).buttonStyle(.workspaceSecondary).keyboardShortcut(.cancelAction)
                Spacer()
                Button(saving ? "正在保存…" : "保存更正") { save() }
                    .buttonStyle(.workspacePrimary)
                    .disabled(saving || text == source.transcript || text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width:650).onAppear { text=source.transcript ?? "" }
            .workspaceModalSurface()
    }
    private func save() {
        guard !saving else { return }
        saving=true
        failure=""
        Task { @MainActor in
            let saved=await model.correct(source,text:text)
            saving=false
            if saved { onSaved();close() } else { failure="保存失败，请重试。" }
        }
    }
}
struct ClaimCorrectionView:View {
    @Environment(\.workspacePalette) private var palette
    let claim:CandidateClaim
    @ObservedObject var model:ControlCenter
    var onSaved:()->Void = {}
    let dismiss:()->Void
    @State private var text:String
    @State private var ownership:String
    @State private var note=""
    @State private var failure=""
    @State private var saving=false
    init(claim:CandidateClaim,model:ControlCenter,onSaved:@escaping()->Void = {},dismiss:@escaping()->Void) {
        self.claim=claim;self.model=model;self.onSaved=onSaved;self.dismiss=dismiss
        _text=State(initialValue:claim.statement);_ownership=State(initialValue:claim.ownership)
    }
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("更正当前理解").vosFont(WorkspaceText.sectionTitle)
            Text("更正不会改写原话，历史与相关行动依据会分别保留。").vosFont(WorkspaceText.body).foregroundStyle(palette.secondaryText)
            TextEditor(text:$text).frame(minHeight:180).workspaceEditorSurface()
            Picker("内容归属",selection:$ownership) {
                Text("我的暂定表达").tag("user_tentative");Text("外部观点").tag("external");Text("AI 建议").tag("ai_candidate");Text("归属待核对").tag("unresolved")
            }
            TextField("更正原因",text:$note)
            if !failure.isEmpty { Text(failure).vosFont(WorkspaceText.meta).foregroundStyle(palette.danger) }
            HStack {
                Button("取消",action:dismiss).buttonStyle(.workspaceSecondary).keyboardShortcut(.cancelAction)
                Spacer()
                Button(saving ? "正在更新…" : "更新理解") { save() }
                    .buttonStyle(.workspacePrimary)
                    .disabled(saving || model.reviewingClaim || (text == claim.statement && ownership == claim.ownership) || text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || note.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width:WorkspaceMetrics.modalSmall)
            .workspaceModalSurface()
    }
    private func save() {
        guard !saving else { return }
        saving=true
        failure=""
        Task { @MainActor in
            let updated=await model.review(claim,action:.correct,statement:text,ownership:CandidateOwnership(rawValue:ownership),note:note)
            saving=false
            if updated { onSaved();dismiss() } else { failure="更新失败，请重试。" }
        }
    }
}

struct RecordingExpressionTitleEditor:View {
    @Environment(\.workspacePalette) private var palette
    let record:SourceRecord
    let expression:RecordingExpression
    @ObservedObject var model:ControlCenter
    let dismiss:()->Void
    @State private var title:String
    @State private var saving=false
    init(record:SourceRecord,expression:RecordingExpression,model:ControlCenter,dismiss:@escaping()->Void) {
        self.record=record;self.expression=expression;self.model=model;self.dismiss=dismiss
        _title=State(initialValue:expression.manualTitle ?? expression.title)
    }
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("修改分组标题").vosFont(WorkspaceText.sectionTitle)
            TextField("分组标题",text:$title)
            Text("\(expression.sourceIDs.count) 段录音同属一段连续表达。").vosFont(WorkspaceText.caption).foregroundStyle(palette.secondaryText)
            if !model.recordingTitleStatus.isEmpty { Text(model.recordingTitleStatus).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText) }
            HStack {
                if expression.manualTitle != nil { Button("恢复自动标题") { save(nil) }.buttonStyle(.workspaceQuiet).disabled(saving) }
                Spacer()
                Button("取消",action:dismiss).buttonStyle(.workspaceSecondary).keyboardShortcut(.cancelAction)
                Button("保存") { save(title) }.buttonStyle(.workspacePrimary).keyboardShortcut(.defaultAction)
                    .disabled(saving || title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || title.count > 100)
            }
        }.padding(24).frame(width:600)
            .workspaceModalSurface()
    }
    private func save(_ value:String?) {
        guard !saving else { return }
        saving=true
        Task { @MainActor in
            if await model.renameRecording(record,title:value) { dismiss() }
            saving=false
        }
    }
}

extension ControlCenter {
    func sourceAttachmentURL(sourceID:String) async throws -> (url:URL,mime:String)? {
        guard let store else { throw VoiceOSError("资料库尚未打开") }
        guard let attachment=try await store.sourceAttachment(sourceID:sourceID) else { return nil }
        let root=await store.root
        return (root.appendingPathComponent(attachment.relativePath),attachment.mime)
    }
}
