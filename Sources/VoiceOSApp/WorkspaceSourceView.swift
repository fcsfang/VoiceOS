import AppKit
import SwiftUI
import Combine
import AVFoundation
import VoiceOSCore
import VoiceOSPlatform

extension SourceRecord {
    var hasProvisionalRecordingTranscript: Bool {
        ["audio", "video"].contains(kind) && transcript != nil
            && transcriptionReview?.isCompleteFullTextReview != true
            && transcriptVersionReason != "transcription_error"
    }
}

private enum SourceReadingTab: String, CaseIterable, Identifiable {
    case original = "原文"
    case note = "笔记"
    case results = "提取结果"

    var id: Self { self }
}

private enum SourceDetailPanel: String, Identifiable {
    case history = "处理记录"
    case actions = "历史待办"
    case entities = "人名与术语"
    case provisional = "待校正转写"

    var id: Self { self }
}

private enum SourceHistoryState {
    case idle, loading, loaded([TranscriptVersion]), failed(String)
}
private struct SourceEntityGroup:Identifiable {
    let kind:String
    let title:String
    let entities:[SourceEntity]
    var id:String { kind }
}
private struct TranscriptParagraph: Identifiable {
    let id: String
    var spanIDs: Set<String>
    let startMS: Int
    var endMS: Int
    var text: String
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
private struct SourcePageReadKey: Hashable {
    let pause:SourcePauseReadKey
    let discussions:SourceDiscussionReadKey
    let context:SourceContextReadKey
    let sourceID:String
    let transcript:SourceTranscriptReadKey
    let chapters:SourceChapterReadKey
    let extraction:SourceExtractionReadKey
}
private enum SourceReadSlot:String {
    case pause,discussions,context,attachment,entities,chapters,claimNotes,extraction
}
private func sourceTime(_ ms:Int)->String { String(format:"%02d:%02d",ms/60000,ms/1000%60) }
/// Thin wrapper kept for the playback key handler; stepping lives in
/// `WorkspaceKeyboardSelection` so every list shares one rule.
private func stepSourcePlaybackSelection(_ selection:inout String?,up:Bool,over ids:[String])->Bool {
    var state = WorkspaceKeyboardSelection(id: selection)
    let moved = state.step(up: up, over: ids)
    selection = state.id
    return moved
}
struct SourceFoldState: Equatable {
    var originalTarget: String?
    var tools = false
    var fullText = false
    var timedSpans = false
    var thoughts = false
    var overall = false
    var digest = false
    var outline = false
    var chapters = false
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
/// A collapsible group on the page canvas: heading, count, chevron, hairline.
/// No card shell, so a `SourceSection` nested inside reads as a subgroup
/// rather than a box inside a box.
private struct SourceFold<Content: View>: View {
    @Environment(\.workspacePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title:String
    var icon=""
    var count:Int?=nil
    @Binding var isExpanded:Bool
    var spacing:CGFloat=0
    @ViewBuilder let content:()->Content
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            Button { isExpanded.toggle() } label: {
                HStack(alignment:.firstTextBaseline,spacing:10) {
                    Image(systemName:"chevron.right").vosFont(WorkspaceText.caption.size, weight:.semibold)
                        .foregroundStyle(palette.tertiaryText)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(reduceMotion ? nil : WorkspaceMotion.expand, value: isExpanded)
                        .accessibilityHidden(true)
                    Text(title).vosFont(WorkspaceText.sectionTitle).foregroundStyle(palette.text).accessibilityAddTraits(.isHeader)
                    Spacer(minLength:8)
                    if let count {
                        Text(String(count)).vosFont(WorkspaceText.meta.size, weight: WorkspaceText.meta.weight, monospacedDigit: true)
                            .foregroundStyle(palette.tertiaryText)
                    }
                }.padding(.vertical,10).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .workspaceHoverHighlight(cornerRadius: WorkspaceMetrics.controlRadius)
                .accessibilityValue(isExpanded ? "已展开" : "已收起")
            WorkspaceListDivider()
            if isExpanded {
                LazyVStack(alignment:.leading,spacing:spacing,content:content).padding(.top,8)
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
                        Label("转写备注（\(issues.count)）",systemImage:"waveform")
                            .vosFont(WorkspaceText.meta.size, weight:.semibold)
                            .foregroundStyle(palette.secondaryText)
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
    @Environment(\.workspacePalette) private var palette
    let title:String
    var count:Int? = nil
    /// Inside a `SourceFold` the heading steps down to a list group header.
    var nested = false
    @ViewBuilder let content:()->Content
    var body: some View {
        if nested {
            VStack(alignment:.leading,spacing:0) {
                WorkspaceListGroupHeader(title: count.map { title + " · \($0)" } ?? title)
                LazyVStack(alignment:.leading,spacing:0,content:content)
            }
        } else {
            sectionBody
        }
    }
    private var sectionBody: some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(alignment:.firstTextBaseline,spacing:10) {
                Text(title).vosFont(WorkspaceText.sectionTitle).foregroundStyle(palette.text).accessibilityAddTraits(.isHeader)
                Spacer(minLength:8)
                if let count {
                    Text(String(count)).vosFont(WorkspaceText.meta.size, weight: WorkspaceText.meta.weight, monospacedDigit: true)
                        .foregroundStyle(palette.tertiaryText)
                }
            }.padding(.vertical,10)
            WorkspaceListDivider()
            LazyVStack(alignment:.leading,spacing:0,content:content).padding(.top,8)
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
    var openProcessing:()->Void = {}
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
    @State private var appliedReadKeys:[SourceReadSlot:String]=[:]
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
    @State private var showSlowLoad=false
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
    // 页面体不读 milliseconds，回听标签与播放条各自 @ObservedObject 订阅；@State 持有避免每 tick 重算整页
    @State private var playback=SourcePlaybackClock()
    @State private var playbackSelection:String?
    @State private var autoScrolledSpanID:String?
    @State private var selectedText=""
    @State private var selectedRange=NSRange(location:0,length:0)
    private func foldExpanded(_ keyPath:WritableKeyPath<SourceFoldState,Bool>) -> Binding<Bool> {
        Binding(get: { folds[keyPath:keyPath] }, set: { folds[keyPath:keyPath]=$0 })
    }
    @State private var toast: String? = nil
    @State private var readingTab = SourceReadingTab.original
    @State private var auxiliaryScroll = ScrollPosition(edge: .top)
    @State private var detailPanel: SourceDetailPanel?
    @State private var extractionFlag: SourceExtractionFlag? = nil
    @State private var correctionsExpanded=false
    @State private var correctionJustSaved=false
    @State private var showingCorrectionImpacts=false
    @State private var entities:[SourceEntity]=[]
    @State private var chapters:[SourceChapter]=[]
    /// 已排队但本机转写模型没配置：如实显示「等待」，不再假装正在转写。
    private var waitingForSpeech: Bool {
        transcriptionRunning && source.jobState == "queued" && !model.speechConfigured
    }
    private var transcriptionRunning: Bool {
        source.transcript == nil && ["queued","running"].contains(source.jobState ?? "")
    }
    private var transcriptionFailed: Bool {
        source.transcript == nil && ["failed","blocked"].contains(source.jobState ?? "")
    }
    private var historyLoading:Bool {
        if case .loading=historyState { return true }
        return false
    }
    @ViewBuilder private var historyVersions: some View {
        switch historyState {
        case .idle: EmptyView()
        case .loading:
            if showSlowLoad { ProgressView("正在读取原文版本…") }
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
            WorkspaceRow(title:action.title,subtitle:actionSubtitle("AI 已交付",reminder:reminder),materialIcon:.delivery,trailing:"阅读结果") { openDelivery(delivery.id) }
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
    private var processing: Bool {
        let visibleWork = model.workspaceProcessingTitle != nil
            && model.workspaceProcessingSourceID.map(expressionIDs.contains) == true
        return visibleWork || model.processingIntents.contains {
            expressionIDs.contains($0.sourceID) && [.queued, .running].contains($0.state)
        }
    }

    private var processingFailure: ExpressionProcessingIntentRecord? {
        guard !processing else { return nil }
        return model.processingIntents.first { expressionIDs.contains($0.sourceID) && $0.needsAttention }
    }

    private var pendingUnderstanding:Bool {
        model.records.contains { record in
            guard let ids=record.presentation?.correctedSourceIDs else { return false }
            return expressionIDs.contains(record.id) || ids.contains(source.id) || record.presentation?.recordingContext?.externalSourceID == source.id
        }
    }
    private var automaticallyUpdating:Bool { pendingUnderstanding && model.fullRecordingBusy }
    /// The failed-transcription retry is the surface's one primary when shown;
    /// re-understanding cannot run on a transcript that does not exist yet.
    private var retryOffersPrimary: Bool {
        source.transcript == nil && !source.dictationRecoveryPending && ["failed","blocked"].contains(source.jobState ?? "")
    }
    private var pausedThoughts: [CandidateClaim] { (model.currentClaimsBySource[source.id] ?? []).filter { $0.validity != "current" } }
    private var pausedActions: [ActionRecord] { actions.filter { model.sourcePageIndex.requiresReview($0.id) } }
    private var selectedSpan:TranscriptSpan? {
        guard !selectedText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,let transcript=source.transcript,
              let offset=SelectableText.scalarOffset(ofUTF16Offset:selectedRange.location,in:transcript) else { return nil }
        return source.spans.first { $0.textStart <= offset && offset < $0.textEnd && $0.startMS != nil && $0.endMS != nil }
    }
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
                ForEach(showAllThoughts ? thoughts : Array(thoughts.prefix(3))) { thought in
                    let commands = ClaimActionsMenu(edit: { claimEditor=thought }, delete: { pendingRejection=thought;confirmingRejection=true }, createAction: { actionClaim=thought })
                    VStack(alignment:.leading,spacing:8) {
                        WorkspaceExpandableText(text:thought.statement,label:"完整要点",lines:4,size:WorkspaceText.body.size)
                        HStack {
                            Text(thought.ownership == "ai_candidate" ? "AI 分析与建议" : thought.ownership == "external" ? "外部观点" : thought.ownership == "unresolved" ? "归属待确认" : "我的观点").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                            Spacer()
                            Button("编辑", systemImage:"pencil", action:commands.edit).labelStyle(.titleAndIcon)
                                .buttonStyle(.borderless).disabled(model.reviewingClaim)
                            commands.disabled(model.reviewingClaim)
                        }
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
                            Text("原话与旁注").vosFont(WorkspaceText.caption).foregroundStyle(palette.secondaryText)
                        }
                    }.padding(.vertical,8)
                        .contextMenu { commands.actions.disabled(model.reviewingClaim) }
                    if thought.id != (showAllThoughts ? thoughts.last?.id : thoughts.prefix(3).last?.id) { WorkspaceListDivider() }
                }
                if thoughts.count > 3 {
                    WorkspaceListDivider()
                    Button(showAllThoughts ? "收起要点" : "展开全部 \(thoughts.count) 条要点",systemImage:showAllThoughts ? "chevron.up" : "chevron.down") { showAllThoughts.toggle() }.buttonStyle(.workspaceQuiet).padding(.top,18)
                }
            }
        }
    }
    private var readingContent: some View {
        VStack(spacing: 0) {
            readingControls
            WorkspaceListDivider()
            ScrollViewReader { reader in
                readingScrollView
                    .scrollPosition(readingTab == .original ? scroll ?? $auxiliaryScroll : $auxiliaryScroll)
                    .id(readingTab)
                    .task(id: folds.originalTarget) {
                        guard readingTab == .original, let anchor = folds.originalTarget else { return }
                        reader.scrollTo("source-original", anchor: .top)
                        try? await Task.sleep(for: .milliseconds(120))
                        guard !Task.isCancelled, folds.originalTarget == anchor else { return }
                        let paragraph = transcriptParagraphs.first { paragraph in
                            anchor.hasPrefix("source-span-") && paragraph.spanIDs.contains(String(anchor.dropFirst("source-span-".count)))
                        }
                        reader.scrollTo(paragraph.map { "source-span-" + $0.id } ?? anchor, anchor: .center)
                        folds.originalTarget = nil
                    }
            }
        }
    }

    private var readingControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                readingPicker
                Spacer(minLength: 8)
                sourceActions
            }
            VStack(alignment: .leading, spacing: 8) {
                readingPicker
                sourceActions
            }
        }
        .frame(maxWidth: readingWidth, alignment: .leading)
        .padding(.horizontal, WorkspaceMetrics.pagePadding)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(palette.canvas)
    }

    private var readingPicker: some View {
        Picker("材料内容", selection: $readingTab) {
            ForEach(SourceReadingTab.allCases) { tab in
                Text(tab == .original && source.transcriptionReview?.isCompleteFullTextReview == true ? "校正稿" : tab.rawValue)
                    .tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityIdentifier("material.reader.mode")
    }

    private var noteRequestKey: [String] {
        model.materialNoteMemberIDs(sourceID: source.id).map { id in
            guard let record = catalog[id] else { return id }
            return [id, record.transcriptVersionID ?? "", String(record.policyVersion),
                    String(record.hasProvisionalRecordingTranscript)].joined(separator: "|")
        }
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
            }
            Menu {
                if source.hasProvisionalRecordingTranscript {
                    Button("查看待校正转写") { detailPanel = .provisional }
                }
                if playbackAvailable {
                    Button("打开录音原件") { Task { await model.play(source) } }
                }
                if let url = captureInfo.flatMap({ captureLink($0.url) }) {
                    Link("打开来源", destination: url)
                }
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
                    .disabled(source.transcript == nil || source.localOnly || !model.modelConfigured || processing)
                    .help(source.transcript == nil ? "转写完成后才能重新整理" : source.localOnly ? "仅本机保存的文字不能交给模型整理" : !model.modelConfigured ? "先配置文本模型才能重新整理" : "用当前文字重新提取理解")
                if !model.modelConfigured { Button("配置文本模型…") { model.chooseTextModel() } }
                Divider()
                if !historyActions.isEmpty { Button("历史待办") { detailPanel = .actions } }
                if !entities.isEmpty || entitiesPhase.failure != nil { Button("人名与术语") { detailPanel = .entities } }
                Button("处理记录") { detailPanel = .history }
                if processing { Button("查看处理情况", action: openProcessing) }
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
                if !error.isEmpty { WorkspaceNoticeText(message:error,severity:.danger) }
                switch readingTab {
                case .original:
                    originalSection
                case .note:
                    MaterialNoteReadingView(model: model, source: source, openSource: openSource, openTask: openTask,
                                            openDiscussion: openDiscussion, hasNote: .constant(false), materialReader: true)
                case .results:
                    extractionResults
                }
            }.frame(maxWidth:readingWidth,alignment:.leading)
                .padding(.horizontal,WorkspaceMetrics.pagePadding)
                .padding(.top,16)
                .padding(.bottom,WorkspaceMetrics.pagePadding)
                .frame(maxWidth:.infinity,alignment:.top)
        }
    }

    @ViewBuilder private var originalSection: some View {
        let titleFit = WorkspaceTitleFit.present(readingTitle)
        Text(titleFit.title).vosFont(WorkspaceText.pageTitle)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled).accessibilityAddTraits(.isHeader)
        if let attachmentURL {
            Button(attachmentMime == "application/pdf" ? "查看原件" : "查看原图", systemImage: "arrow.up.right.square") {
                if !NSWorkspace.shared.open(attachmentURL) { error = "无法打开原件" }
            }.buttonStyle(.workspaceQuietCompact)
        }
        if source.hasProvisionalRecordingTranscript {
            VStack(alignment: .leading, spacing: 12) {
                Text(model.transcriptReviewSourceID == source.id ? "正在校正逐字稿…" : "逐字稿待校正")
                    .vosFont(WorkspaceText.body)
                if source.needsTranscriptionReview && !source.localOnly && model.transcriptReviewSourceID != source.id {
                    Button(source.transcriptionReviewFailure == nil ? "校正逐字稿" : "重试校正") {
                        Task { await model.reviewTranscription(sourceID: source.id) }
                    }
                    .buttonStyle(.workspaceSecondaryCompact)
                    .disabled(!model.modelConfigured || model.fullRecordingBusy || model.transcriptReviewSourceID != nil)
                }
            }
        } else if source.transcript != nil {
            originalReading.id("source-original")
        } else {
            transcriptUnavailable
        }
    }

    @ViewBuilder private var transcriptUnavailable: some View {
        if source.dictationRecoveryPending {
            DictationRecoveryControls(model:model,source:source)
        } else if transcriptionFailed {
            Text(source.error ?? "转写失败").vosFont(WorkspaceText.body).foregroundStyle(palette.warning)
            Button(retryingTranscription ? "正在重试…" : "重试本地转写") {
                retryingTranscription = true
                Task {
                    await model.retry(source)
                    retryingTranscription = false
                }
            }
            .buttonStyle(.workspaceSecondaryCompact)
            .disabled(retryingTranscription || model.dictationBusy || model.fullRecordingBusy || model.processingActivity != nil)
        } else if transcriptionRunning {
            SourceLoadingRow(title: waitingForSpeech ? "等待本地转写模型" : "正在转写…")
            if waitingForSpeech {
                Button("配置本地转写…") { model.chooseLocalSpeech() }.buttonStyle(.workspaceQuietCompact)
            }
        }
    }

    @ViewBuilder private var extractionResults: some View {
        let reminderReads = ActionRowReads(reminderLinks: model.reminderLinks, executions: model.assistantExecutions)
        if let failure = processingFailure, pausedThoughts.isEmpty {
            HStack(spacing: 12) {
                Text(failure.error ?? "整理未完成").vosFont(WorkspaceText.body).foregroundStyle(palette.warning)
                Button("查看处理情况", action: openProcessing).buttonStyle(.workspaceQuietCompact)
            }
        }
        if extractionFlag == .empty && !processing {
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
        digestSections
        if !pausedThoughts.isEmpty {
            WorkspaceCard() {
                VStack(alignment:.leading,spacing:12) {
                Label(automaticallyUpdating ? "正在自动更新理解" : pendingUnderstanding ? "理解尚未更新完成" : "AI 提取需要重新识别",systemImage:automaticallyUpdating ? "arrow.trianglehead.2.clockwise" : "pause.circle").vosFont(WorkspaceText.meta.size, weight: .semibold)
                if !automaticallyUpdating { Text(pauseExplanation).vosFont(WorkspaceText.body).foregroundStyle(palette.secondaryText) }
                if !pausedActions.isEmpty {
                    Text("受影响的任务与问题").vosFont(WorkspaceText.rowTitle)
                    ForEach(pausedActions) { action in
                        WorkspaceRow(title:action.title,subtitle:actionSubtitle(model.workspaceExternalCompletionNote(action) ?? model.workspaceActionStatus(action),reminder:actionReminderMeta(action,reads:reminderReads)),trailing:"查看任务") { openTask(action.id) }
                        WorkspaceExternalCompletionButton(model:model,action:action).padding(.leading,44).padding(.bottom,6)
                    }
                }
                if source.localOnly {
                    Text("当前仅本机保存。允许后会将这份完整文字发送给已配置的模型。").vosFont(WorkspaceText.body).foregroundStyle(palette.secondaryText)
                    Button("允许这份文字用于云端并重新识别") { Task { await model.changeTextPolicy(source);organize() } }
                        .buttonStyle(retryOffersPrimary ? .workspaceSecondary : .workspacePrimary)
                        .disabled(!model.modelConfigured || model.fullRecordingBusy || model.understandingSource != nil)
                } else {
                    Button(automaticallyUpdating ? "正在自动更新…" : processing ? "正在重新识别…" : pendingUnderstanding ? "重试更新理解" : "重新识别观点和任务",action:organize)
                        .buttonStyle(retryOffersPrimary ? .workspaceSecondary : .workspacePrimary)
                        .disabled(processing || model.fullRecordingBusy || model.understandingSource != nil || !model.modelConfigured || source.state == "quarantined")
                        .help(automaticallyUpdating || processing ? "正在处理，完成后这里会自动更新" : pendingUnderstanding ? "查看处理进度或错误后，点此重试自动更新" : "AI 会读取完整文字和转写核对记录，重新提取观点和任务；只有文字记错时才需要更正转写")
                }
                if !model.modelConfigured {
                    HStack(spacing:8) {
                        Text("重新识别需要先配置文本模型。").vosFont(WorkspaceText.meta).foregroundStyle(palette.warning)
                        Button("配置文本模型…") { model.chooseTextModel() }.buttonStyle(.workspaceQuietCompact)
                    }
                }
                }
            }
        }
        if model.recordingFollowups.contains(where: { expressionIDs.contains($0.sourceID) }) {
            Button("查看思想与下一步", action: openFollowups).buttonStyle(.workspaceQuietCompact)
        }
        if pausedThoughts.isEmpty && !pausedActions.isEmpty {
            SourceSection(title:"观点已更正，关联待办需要重新确认",count:pausedActions.count) {
                ForEach(pausedActions) { action in
                    WorkspaceRow(title:action.title,subtitle:actionSubtitle(model.workspaceExternalCompletionNote(action) ?? model.workspaceActionStatus(action),reminder:actionReminderMeta(action,reads:reminderReads)),trailing:"查看与处理") { openTask(action.id) }
                    WorkspaceExternalCompletionButton(model:model,action:action).padding(.leading,44).padding(.bottom,6)
                }
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
        relatedMaterials
        if thoughts.isEmpty && actions.isEmpty && extractionFlag != .empty && pausedThoughts.isEmpty && processingFailure == nil {
            if processing { SourceLoadingRow(title: "正在提取…") }
            else { Text("暂无提取结果").vosFont(WorkspaceText.body).foregroundStyle(palette.secondaryText) }
        }
    }

    private var originalReading: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let transcript = source.transcript {
                if transcriptParagraphs.isEmpty {
                    MarkdownText(transcript).textSelection(.enabled)
                } else {
                    SourceTranscriptBody(paragraphs: transcriptParagraphs, clock: playback)
                }
                DisclosureGroup("原文工具", isExpanded: foldExpanded(\.tools)) {
                    VStack(alignment: .leading, spacing: 12) {
                        originalNavigation
                        DisclosureGroup("选择原文片段", isExpanded: foldExpanded(\.fullText)) {
                            SelectionActions(selection: selectedText, canPlay: selectedSpan != nil, onSave: saveSelectionAsQuestion,
                                             onCopy: copySelectedText, onPlay: playSelectedSpan)
                            SelectableText(text: transcript, textColor: palette.textNSColor) { text, range in
                                selectedText = text
                                selectedRange = range
                            }.frame(minHeight: 180)
                        }
                        let timedSpans = source.spans.filter { $0.startMS != nil && $0.endMS != nil }
                        if playbackAvailable && !timedSpans.isEmpty {
                            DisclosureGroup("按时间回听", isExpanded: foldExpanded(\.timedSpans)) {
                                SourceSpanPlaybackList(model: model, source: source, spans: timedSpans, clock: playback, selection: $playbackSelection)
                            }
                        }
                    }.padding(.top, 8)
                }
            }
        }
    }

    @ViewBuilder private var originalNavigation: some View {
        if outlineSections.count > 1 {
            DisclosureGroup("逐字稿大纲", isExpanded: foldExpanded(\.outline)) {
                SourceOutlinePlaybackList(sections:outlineSections,clock:playback,selection:$playbackSelection) { playOutlineSection($0) }
            }
        }
        if chapters.isEmpty && chaptersPhase.isLoading { SourceLoadingRow(title:"正在读取章节…") }
        if let failure=chaptersPhase.failure, chapters.isEmpty { SourceLoadFailureRow(operation:"读取章节",reason:failure) { chaptersRetry+=1 } }
        if !chapters.isEmpty {
            DisclosureGroup("章节", isExpanded: foldExpanded(\.chapters)) {
                SourceChapterPlaybackList(chapters:chapters,clock:playback,selection:$playbackSelection) { playChapter($0) }
            }
        }
    }

    @ViewBuilder private var relatedMaterials: some View {
        if !programPairs.isEmpty {
            SourceSection(title:"相关材料",nested:true) {
                ForEach(programPairs,id:\.externalSourceID) { pair in
                    if let external=catalog[pair.externalSourceID] {
                        WorkspaceRow(title:external.displayTitle,subtitle:pairingIsCurrent(pair) ? "同次录制的完整节目原文" : "节目原话或处理许可已变化，关联等待更新",materialIcon: MaterialRowIconKind(external),trailing:"节目原文") { openSource(external.id) }
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
                }
            }
        }
        if let failure=contextPhase.failure { SourceLoadFailureRow(operation:"读取节目关联",reason:failure) { contextRetry+=1 } }
    }

    @ViewBuilder private var entityPanel: some View {
        if entities.isEmpty && entitiesPhase.isLoading { SourceLoadingRow(title:"正在读取人名与术语…") }
        if let failure=entitiesPhase.failure, entities.isEmpty { SourceLoadFailureRow(operation:"读取人名与术语",reason:failure) { entitiesRetry+=1 } }
        if !entities.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(entityGroups) { group in
                    Text(group.title).vosFont(WorkspaceText.meta.size, weight: .semibold).foregroundStyle(palette.secondaryText).padding(.top,12)
                    ForEach(group.entities,id:\.name) { entity in
                        Button { openEntity(entity) } label: {
                            HStack(spacing:8) {
                                Text(entity.name + " · " + String(entity.mentionCount) + " 次").vosFont(WorkspaceText.rowTitle).multilineTextAlignment(.leading)
                                Spacer(minLength:0)
                            }.padding(.horizontal,8).padding(.vertical,6).frame(minHeight: WorkspaceMetrics.rowActionMinHeight).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .workspaceHoverHighlight(cornerRadius: WorkspaceMetrics.controlRadius)
                    }
                }
            }
        }
    }

    private var processingHistory: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(MaterialNaming.displayName(source.name))
                .vosFont(WorkspaceText.body).textSelection(.enabled)
            Text(source.recordingSubtitle).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
            if let info = captureInfo, let url = captureLink(info.url) {
                Link(info.context ?? url.host ?? "来源", destination: url)
            }
            if source.transcriptionReview?.isCompleteFullTextReview == true {
                Text("当前原文已校正").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
            }
            VStack(alignment: .leading, spacing: 0) {
                DisclosureGroup("核对依据与适用边界") { KnowledgeReviewSection(model:model,sourceIDs:[source.id],carded:false).padding(.top,12) }.padding(.vertical,16)
                WorkspaceListDivider()
                DisclosureGroup("文字校正、理解与修订历史") {
                    VStack(alignment:.leading,spacing:WorkspaceMetrics.rowGap) {
                        if source.transcriptionReview != nil {
                            Text("转写校正已保存，原始版本可追溯。").vosFont(WorkspaceText.meta)
                            let issues=source.unresolvedTranscriptionIssues
                            if !issues.isEmpty {
                                UnresolvedIssuesBlock(issues:issues,playbackAvailable:playbackAvailable,playbackLabel:{ unresolvedIssuePlaybackLabel($0) },play:{ playUnresolvedIssue($0) },jump:{ spanID in detailPanel = nil; revealOriginal(spanID: spanID) })
                            }
                        }
                        Button("查看全部原文版本", action:loadHistory).buttonStyle(.workspaceQuietCompact)
                        historyVersions
                            .workspaceSlowLoading(historyLoading, into: $showSlowLoad)
                        if source.transcript != nil { Button("查看原话分段") { detailPanel = nil; Task { showingSegmentation = await model.previewSegmentation(source) } }.buttonStyle(.workspaceQuietCompact) }
                        ForEach(model.attempts[source.id] ?? []) { attempt in
                            Text((attempt.state == "completed" ? "理解已完成" : "理解：" + workspaceStateLabel(attempt.state)) + (attempt.contextState == "stale" ? " · 历史依据已变化" : "")).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                        }
                        if discussionsPhase.isLoading { SourceLoadingRow(title:"正在读取讨论…") }
                        else if let failure=discussionsPhase.failure { SourceLoadFailureRow(operation:"读取讨论",reason:failure) { discussionsRetry+=1 } }
                        ForEach(Array(loadedDiscussions.enumerated()),id:\.element.id) { index,session in Button("打开讨论 \(index+1)") { detailPanel = nil; openDiscussion(session.id) }.buttonStyle(.workspaceQuietCompact) }
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
                        ForEach(model.segmentedBatches.filter { $0.scope.plan.source.sourceID == source.id }) { batch in
                            HStack { Text(workspaceStateLabel(batch.state.rawValue)).vosFont(WorkspaceText.meta);if batch.state == .queued { Button("停止后续处理") { model.cancelSegmented(batch.id) }.buttonStyle(.workspaceQuietCompact) } }
                            if let error=batch.error { Text(error).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText) }
                        }
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
    }

    private func detailSheet(_ panel: SourceDetailPanel) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(panel.rawValue).vosFont(WorkspaceText.sectionTitle).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("完成") { detailPanel = nil }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch panel {
                    case .history:
                        processingHistory
                    case .actions:
                        let reads = ActionRowReads(reminderLinks:model.reminderLinks,executions:model.assistantExecutions)
                        ForEach(historyActions) { action in
                            WorkspaceRow(title:action.title,subtitle:actionSubtitle(model.workspaceExternalCompletionNote(action) ?? model.workspaceActionStatus(action),reminder:actionReminderMeta(action,reads:reads)),trailing:"查看记录") {
                                detailPanel = nil
                                openTask(action.id)
                            }
                        }
                    case .entities:
                        entityPanel
                    case .provisional:
                        if let text = source.transcript { MarkdownText(text).textSelection(.enabled) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            }
        }.frame(width: 570, height: 480)
            .background(palette.canvas)
    }

    var body:some View {
        readingContent
        .safeAreaInset(edge:.bottom,spacing:0) { playbackBar }
        .task(id: noteRequestKey) {
            let members = model.materialNoteMemberIDs(sourceID: source.id)
            if !members.contains(where: { catalog[$0]?.hasProvisionalRecordingTranscript == true }) {
                await model.requestMaterialNote(sourceID: source.id)
            }
        }
        .onChange(of: readingTab) { _, _ in auxiliaryScroll = ScrollPosition(edge: .top) }
        .onDisappear { historyTask?.cancel(); bilingualTask?.cancel() }
        .workspaceToast($toast)
        .sheet(item: $detailPanel, content: detailSheet)
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
        .alert("删除这条观点？", isPresented:$confirmingRejection, presenting:pendingRejection) { claim in
            Button("删除", role:.destructive) { Task { _=await model.review(claim, action:.reject) } }
            Button("取消", role:.cancel) {}
        } message: { _ in
            Text("原录音、逐字稿和历史记录会保留。依赖这条观点的行动将暂停。")
        }
        .task(id: combinedReadKey) {
            let key=combinedReadKey
            async let pauseRead = await readSourcePause(key:key)
            async let discussionsRead = await readSourceDiscussions(key:key)
            async let contextRead = await readSourceContext(key:key)
            async let attachmentRead = await readSourceAttachment(key:key)
            async let entitiesRead = await readSourceEntities(key:key)
            async let chaptersRead = await readSourceChapters(key:key)
            async let claimNotesRead = await readSourceClaimNotes(key:key)
            async let extractionRead = await readSourceExtractionFlag(key:key)
            _=await (pauseRead,discussionsRead,contextRead,attachmentRead,entitiesRead,chaptersRead,claimNotesRead,extractionRead)
        }
        .onChange(of:folds.fullText) { _,_ in if !folds.fullText { clearSelection() } }
        .onChange(of:source.transcript) { _,_ in clearSelection();resetBilingual() }
        .onChange(of:playbackSelection) { _,id in guard let id,let scroll else { return };scroll.wrappedValue.scrollTo(id:id,anchor:.center) }
        .onReceive(playback.$milliseconds) { followPlaybackHighlight($0) }
        .task {
            while !Task.isCancelled {
                refreshPlaybackPosition()
                let interval=model.player?.timeControlStatus == .playing ? 300 : 1500
                do { try await Task.sleep(for:.milliseconds(interval)) } catch { return }
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
    private var combinedReadKey:SourcePageReadKey {
        .init(pause:pauseReadKey,discussions:discussionReadKey,context:contextReadKey,sourceID:source.id,
              transcript:.init(sourceID:source.id,transcriptVersionID:source.transcriptVersionID,retry:entitiesRetry),
              chapters:.init(sourceID:source.id,kind:source.kind,retry:chaptersRetry),
              extraction:extractionFlagRefreshKey)
    }
    // 只有发起时的 key 仍是当前 key 且任务未被取消，才允许写回状态，避免旧结果串到新 key。
    private func readKeyIsCurrent(_ key:SourcePageReadKey)->Bool { !Task.isCancelled && key == combinedReadKey }
    // 每个读取只看自己的子键：子键未变时跳过读取且不清空状态；读取前先记录子键，失败重试由用户重试 token 改变子键触发。
    private func readSlotNeedsRun(_ slot:SourceReadSlot,_ subkey:AnyHashable)->Bool {
        let value=String(describing:subkey)
        guard appliedReadKeys[slot] != value else { return false }
        appliedReadKeys[slot]=value
        return true
    }
    @MainActor private func readSourcePause(key:SourcePageReadKey) async {
        guard readKeyIsCurrent(key),readSlotNeedsRun(.pause,key.pause),!pausedThoughts.isEmpty,let store=model.store else { return }
        do {
            let summary=try await store.understandingPause(sourceID:source.id).summary
            guard readKeyIsCurrent(key) else { return }
            pauseExplanation=summary
        } catch {
            guard readKeyIsCurrent(key) else { return }
            pauseExplanation = "暂时无法读取暂停原因：" + error.localizedDescription
        }
    }
    @MainActor private func readSourceDiscussions(key:SourcePageReadKey) async {
        guard readKeyIsCurrent(key),readSlotNeedsRun(.discussions,key.discussions) else { return }
        discussionsPhase = .loading
        guard let store = model.store else { discussionsPhase = .idle; return }
        do {
            let discussions = try await store.conversationsForSource(sourceID: source.id)
            try Task.checkCancellation()
            guard readKeyIsCurrent(key) else { return }
            loadedDiscussions = discussions
            discussionsPhase = .idle
        } catch is CancellationError {
            guard readKeyIsCurrent(key) else { return }
            discussionsPhase = .idle
        } catch {
            guard readKeyIsCurrent(key) else { return }
            self.error = error.localizedDescription
            discussionsPhase = .failed(error.localizedDescription)
        }
    }
    @MainActor private func readSourceContext(key:SourcePageReadKey) async {
        guard readKeyIsCurrent(key),readSlotNeedsRun(.context,key.context) else { return }
        programPairs=[]
        contextLinks=[]
        contextPhase = .loading
        guard let store=model.store else { contextPhase = .idle; return }
        let ids=expressionIDs
        programPairs=model.records.filter { ids.contains($0.id) }.compactMap { $0.presentation?.recordingContext }
        do {
            let links=try await store.recordingContextLinks(sourceIDs:ids.sorted(),catalog:catalog)
            try Task.checkCancellation()
            guard readKeyIsCurrent(key) else { return }
            contextLinks=links.filter { pairingIsCurrent($0.pairing) }
            contextPhase = .idle
        } catch is CancellationError {
            guard readKeyIsCurrent(key) else { return }
            contextPhase = .idle
        } catch {
            guard readKeyIsCurrent(key) else { return }
            contextPhase = .failed(error.localizedDescription)
        }
    }
    @MainActor private func readSourceAttachment(key:SourcePageReadKey) async {
        guard readKeyIsCurrent(key),readSlotNeedsRun(.attachment,key.sourceID) else { return }
        attachmentURL=nil;attachmentMime=nil
        let captured=try? await model.sourceCaptureMetadata(sourceID:source.id)
        guard readKeyIsCurrent(key) else { return }
        captureInfo=captured
        do {
            let attachment=try await model.sourceAttachmentURL(sourceID:source.id)
            guard readKeyIsCurrent(key) else { return }
            attachmentURL=attachment?.url;attachmentMime=attachment?.mime
        }
        catch {
            guard readKeyIsCurrent(key) else { return }
            self.error="原件读取失败：" + error.localizedDescription
        }
    }
    @MainActor private func readSourceEntities(key:SourcePageReadKey) async {
        guard readKeyIsCurrent(key),readSlotNeedsRun(.entities,key.transcript) else { return }
        entities=[]
        entitiesPhase = .loading
        guard source.transcript != nil,let store=model.store else { entitiesPhase = .idle; return }
        do {
            let loaded=try await store.entities(sourceID:source.id)
            guard readKeyIsCurrent(key) else { return }
            entities=loaded
            let spanIDs=Set(source.spans.map(\.id))
            let stale = !loaded.isEmpty && loaded.allSatisfy { $0.sentenceIDs.allSatisfy { !spanIDs.contains($0) } }
            if loaded.isEmpty || stale {
                _=try? await store.refreshEntities(sourceID:source.id)
                if !Task.isCancelled {
                    let refreshed=try? await store.entities(sourceID:source.id)
                    guard readKeyIsCurrent(key) else { return }
                    entities=refreshed ?? []
                }
            }
            guard readKeyIsCurrent(key) else { return }
            entitiesPhase = .idle
        } catch {
            guard readKeyIsCurrent(key) else { return }
            entitiesPhase = .failed(error.localizedDescription)
        }
    }
    @MainActor private func readSourceChapters(key:SourcePageReadKey) async {
        guard readKeyIsCurrent(key),readSlotNeedsRun(.chapters,key.chapters) else { return }
        chapters=[]
        chaptersPhase = .loading
        guard ["audio","video"].contains(source.kind),let store=model.store else { chaptersPhase = .idle; return }
        do {
            let loaded=try await store.chapters(sourceID:source.id)
            guard readKeyIsCurrent(key) else { return }
            chapters=loaded
            if chapters.isEmpty,let url=try? await store.playableURL(sourceID:source.id) {
                let found=await MediaChapters.read(url)
                guard readKeyIsCurrent(key) else { return }
                if !found.isEmpty {
                    try await store.replaceChapters(sourceID:source.id,entries:found.map { (title:$0.title,startMS:$0.startMS) })
                    let reloaded=try await store.chapters(sourceID:source.id)
                    guard readKeyIsCurrent(key) else { return }
                    chapters=reloaded
                }
            }
            guard readKeyIsCurrent(key) else { return }
            chaptersPhase = .idle
        } catch {
            guard readKeyIsCurrent(key) else { return }
            chapters=[]
            chaptersPhase = .failed(error.localizedDescription)
        }
    }
    @MainActor private func readSourceClaimNotes(key:SourcePageReadKey) async {
        guard readKeyIsCurrent(key),readSlotNeedsRun(.claimNotes,key.sourceID) else { return }
        guard let store=model.store else { return }
        do {
            let loaded=try await store.claimNotes(claimIDs:thoughts.map(\.id))
            try Task.checkCancellation()
            guard readKeyIsCurrent(key) else { return }
            claimNotes=loaded
        } catch is CancellationError {}
        catch {
            guard readKeyIsCurrent(key) else { return }
            self.error="旁注读取失败：" + error.localizedDescription
        }
    }
    @MainActor private func readSourceExtractionFlag(key:SourcePageReadKey) async {
        guard readKeyIsCurrent(key),readSlotNeedsRun(.extraction,key.extraction) else { return }
        extractionFlag=nil
        guard let store=model.store else { return }
        let flag=try? await store.sourceExtractionFlag(sourceID:source.id)
        guard readKeyIsCurrent(key) else { return }
        extractionFlag=flag
    }
    @ViewBuilder private var playbackBar: some View {
        if let player = model.player, let playbackID = model.playbackSourceID, let playingSource = catalog[playbackID] {
            VStack(spacing: 0) {
                if playingSource.kind == "audio", let duration = playingSource.duration, duration.isFinite, duration > 0 {
                    RecordingPlaybackTimeline(player: player, duration: duration, timelineIdentifier: "material.playback.timeline")
                        .id(ObjectIdentifier(player))
                        .frame(maxWidth: 500)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                } else {
                    NativePlayerView(player: player).frame(height: playingSource.kind == "video" ? 200 : 56)
                }
            }
            .frame(maxWidth: .infinity)
            .background(palette.surface)
            .overlay(alignment: .top) { WorkspaceListDivider() }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("页内回听")
        }
    }
    private var timedTranscriptSpans:[TranscriptSpan] {
        guard ["audio","video"].contains(source.kind),source.transcript != nil,!source.spans.isEmpty,
              source.spans.allSatisfy({ $0.startMS != nil && $0.endMS != nil }) else { return [] }
        return source.spans
    }
    private var transcriptParagraphs: [TranscriptParagraph] {
        guard let transcript = source.transcript else { return [] }
        var paragraphs: [TranscriptParagraph] = []
        let sentenceEnd = "。！？.!?…"
        for span in timedTranscriptSpans {
            guard let start = span.startMS, let end = span.endMS else { continue }
            let text = SourceText.quote(span, in: transcript)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let last = paragraphs.indices.last {
                let previous = paragraphs[last].text.trimmingCharacters(in: .whitespacesAndNewlines)
                let previousEndsSentence = previous.last.map(sentenceEnd.contains) == true
                if (!previousEndsSentence && !paragraphs[last].text.hasSuffix("\n")) || trimmed.count <= 4 {
                    paragraphs[last].spanIDs.insert(span.id)
                    paragraphs[last].endMS = end
                    paragraphs[last].text += text
                    continue
                }
            }
            paragraphs.append(.init(id: span.id, spanIDs: [span.id], startMS: start, endMS: end, text: text))
        }
        return paragraphs
    }
    private func followPlaybackHighlight(_ milliseconds:Int?) {
        guard let ms=milliseconds else { autoScrolledSpanID=nil;return }
        guard readingTab == .original, !source.hasProvisionalRecordingTranscript, let scroll else { return }
        guard let paragraph=transcriptParagraphs.first(where: { paragraph in
            ms >= paragraph.startMS && ms < paragraph.endMS
        }),paragraph.id != autoScrolledSpanID else { return }
        autoScrolledSpanID=paragraph.id
        let anchor="source-span-"+paragraph.id
        Task { @MainActor in
            await Task.yield()
            scroll.wrappedValue.scrollTo(id:anchor,anchor:.center)
        }
    }
    private func revealOriginal(spanID: String? = nil) {
        guard !source.hasProvisionalRecordingTranscript else {
            detailPanel = .provisional
            return
        }
        readingTab = .original
        var state = folds
        if let spanID {
            if transcriptParagraphs.contains(where: { $0.spanIDs.contains(spanID) }) {
                state.originalTarget = "source-span-" + spanID
            } else if playbackAvailable && source.spans.contains(where: {
                $0.id == spanID && $0.startMS != nil && $0.endMS != nil
            }) {
                state.tools = true
                state.timedSpans = true
                state.originalTarget = "source-time-" + spanID
            }
        }
        folds = state
        if let scroll { scroll.wrappedValue.scrollTo(id: "source-original", anchor: .top) }
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
        detailPanel = nil
        if let span = timed, let start = span.startMS {
            if playbackAvailable { Task { _ = await model.playSpan(source, milliseconds: start) } }
            revealOriginal(spanID: span.id)
        } else {
            revealOriginal()
        }
    }
    private func readingLayerRow(_ title:String,_ text:String) -> some View {
        VStack(alignment:.leading,spacing:8) {
            Text(title).vosFont(WorkspaceText.meta.size, weight: .semibold).foregroundStyle(palette.secondaryText)
            Text(text).vosFont(WorkspaceText.body).lineSpacing(4).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
        }
    }
    private func refreshPlaybackPosition() {
        var next: Int?
        if model.playbackSourceID == source.id, let player=model.player,player.timeControlStatus == .playing {
            let seconds=player.currentTime().seconds
            next = seconds.isFinite ? Int((seconds*1000).rounded()) : nil
        }
        if next != playback.milliseconds { playback.milliseconds = next }
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
            .init(id: $0.id, startMS: $0.startMS, endMS: $0.endMS)
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
            .id("source-span-"+id)
            .accessibilityElement(children:.ignore)
            .accessibilityLabel(text)
    }
}
private struct SourcePlaybackKeyList<Content:View>: View {
    @Binding var selection:String?
    let ids:[String]
    let play:(String)->Void
    @ViewBuilder let content:()->Content
    @FocusState private var focused:Bool
    var body:some View {
        content()
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress { handle($0) }
            .onAppear { requestFocus() }
    }
    private func requestFocus() {
        guard !ids.isEmpty else { return }
        Task {
            try? await Task.sleep(for:.milliseconds(100))
            // Expanding a fold must not pull focus away from an open text editor.
            guard !(NSApp.keyWindow?.firstResponder is NSTextView) else { return }
            focused=true
        }
    }
    private func handle(_ press:KeyPress)->KeyPress.Result {
        guard focused, !ids.isEmpty, press.modifiers.isDisjoint(with:[.command,.option,.control]) else { return .ignored }
        if press.phase == .repeat, press.key != .upArrow, press.key != .downArrow { return .ignored }
        switch press.key {
        case .downArrow, .upArrow:
            guard stepSourcePlaybackSelection(&selection,up:press.key == .upArrow,over:ids) else { return .ignored }
            return .handled
        case .return:
            guard let id=selection, ids.contains(id) else { return .ignored }
            play(id)
            return .handled
        default:
            return .ignored
        }
    }
}
private struct SourceSpanPlaybackList: View {
    let model:ControlCenter
    let source:SourceRecord
    let spans:[TranscriptSpan]
    @ObservedObject var clock:SourcePlaybackClock
    @Binding var selection:String?
    var body:some View {
        SourcePlaybackKeyList(selection:$selection,ids:spans.map { rowID($0) },play:playRow) {
            ForEach(spans) { span in
                let active=isPlaying(span)
                Button { play(span) } label: {
                    SourceSpanPlaybackLabel(startMS:span.startMS!,endMS:span.endMS!,active:active,highlighted:selection == rowID(span)).equatable()
                }.buttonStyle(.plain).id(rowID(span))
                    .workspaceFocusRing(selection == rowID(span) && !active,radius:WorkspaceMetrics.controlRadius)
                    .accessibilityElement(children:.ignore)
                    .accessibilityLabel(sourceTime(span.startMS!) + "—" + sourceTime(span.endMS!) + "，回听这段")
            }
        }
    }
    private func rowID(_ span:TranscriptSpan)->String { "source-time-"+span.id }
    private func play(_ span:TranscriptSpan) {
        Task { _=await model.playSpan(source,milliseconds:span.startMS!,endMilliseconds:span.endMS!) }
    }
    private func playRow(_ id:String) {
        guard let span=spans.first(where: { rowID($0) == id }) else { return }
        play(span)
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
    let highlighted:Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    static func == (lhs:SourceSpanPlaybackLabel,rhs:SourceSpanPlaybackLabel)->Bool {
        lhs.startMS == rhs.startMS && lhs.endMS == rhs.endMS && lhs.active == rhs.active && lhs.highlighted == rhs.highlighted
    }
    var body:some View {
        Text(sourceTime(startMS) + "—" + sourceTime(endMS) + " · 回听")
            .vosFont(WorkspaceText.meta.size, weight: active ? .semibold : .regular)
            .padding(.horizontal,8).padding(.vertical,3)
            .frame(minHeight: WorkspaceMetrics.rowActionMinHeight)
            .background(active || highlighted ? palette.selection : hovered ? palette.hover : .clear, in: RoundedRectangle(cornerRadius:WorkspaceMetrics.controlRadius))
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : WorkspaceMotion.hover, value: hovered)
            .animation(reduceMotion ? nil : WorkspaceMotion.selection, value: highlighted)
    }
}
private struct SourceOutlinePlaybackList: View {
    let sections:[SourceOutlineSection]
    @ObservedObject var clock:SourcePlaybackClock
    @Binding var selection:String?
    let play:(SourceOutlineSection)->Void
    var body:some View {
        SourcePlaybackKeyList(selection:$selection,ids:sections.map { rowID($0) },play:playRow) {
            VStack(alignment:.leading,spacing:4) {
                ForEach(sections) { section in
                    let active=isPlaying(section)
                    Button { play(section) } label: {
                        SourceTimedPlaybackLabel(startMS:section.startMS,title:section.title,active:active,highlighted:selection == rowID(section)).equatable()
                    }.buttonStyle(.plain).id(rowID(section))
                        .workspaceFocusRing(selection == rowID(section) && !active,radius:WorkspaceMetrics.controlRadius)
                        .accessibilityElement(children:.ignore)
                        .accessibilityLabel(sourceTime(section.startMS) + "，" + section.title)
                }
            }
        }
    }
    private func rowID(_ section:SourceOutlineSection)->String { "outline:"+String(section.id) }
    private func playRow(_ id:String) {
        guard let section=sections.first(where: { rowID($0) == id }) else { return }
        play(section)
    }
    private func isPlaying(_ section:SourceOutlineSection)->Bool {
        guard let milliseconds=clock.milliseconds else { return false }
        return milliseconds >= section.startMS && milliseconds < section.endMS
    }
}
private struct SourceChapterPlaybackList: View {
    let chapters:[SourceChapter]
    @ObservedObject var clock:SourcePlaybackClock
    @Binding var selection:String?
    let play:(SourceChapter)->Void
    var body:some View {
        SourcePlaybackKeyList(selection:$selection,ids:chapters.map { rowID($0) },play:playRow) {
            ForEach(chapters,id:\.ordinal) { chapter in
                let active=isPlaying(chapter)
                Button { play(chapter) } label: {
                    SourceTimedPlaybackLabel(startMS:chapter.startMS,title:chapter.title,active:active,highlighted:selection == rowID(chapter)).equatable()
                }.buttonStyle(.plain).id(rowID(chapter))
                    .workspaceFocusRing(selection == rowID(chapter) && !active,radius:WorkspaceMetrics.controlRadius)
                    .accessibilityElement(children:.ignore)
                    .accessibilityLabel(sourceTime(chapter.startMS) + "，" + chapter.title)
            }
        }
    }
    private func rowID(_ chapter:SourceChapter)->String { "chapter:"+String(chapter.ordinal) }
    private func playRow(_ id:String) {
        guard let chapter=chapters.first(where: { rowID($0) == id }) else { return }
        play(chapter)
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
    let highlighted:Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    static func == (lhs:SourceTimedPlaybackLabel,rhs:SourceTimedPlaybackLabel)->Bool {
        lhs.startMS == rhs.startMS && lhs.title == rhs.title && lhs.active == rhs.active && lhs.highlighted == rhs.highlighted
    }
    var body:some View {
        HStack(alignment:.top,spacing:10) {
            Text(sourceTime(startMS)).vosFont(WorkspaceText.meta.size, weight: .medium, design: .monospaced).foregroundStyle(palette.secondaryText)
            Text(title).vosFont(WorkspaceText.rowTitle.size, weight: active ? .semibold : .regular).multilineTextAlignment(.leading)
            Spacer(minLength:0)
        }.padding(.horizontal,8).padding(.vertical,6)
            .frame(minHeight: WorkspaceMetrics.rowActionMinHeight)
            .background(active || highlighted ? palette.selection : hovered ? palette.hover : .clear,in:RoundedRectangle(cornerRadius:WorkspaceMetrics.controlRadius))
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : WorkspaceMotion.hover, value: hovered)
            .animation(reduceMotion ? nil : WorkspaceMotion.selection, value: highlighted)
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
    @FocusState private var textFocused:Bool
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("更正原文").vosFont(WorkspaceText.sectionTitle).accessibilityAddTraits(.isHeader)
            Text(source.localOnly ? "这份材料仅本机保存。更正后保留原话历史，旧理解暂停使用；允许云端处理后可重新整理。" : "保存后会自动更新完整理解；原话历史、真实完成与结果保留。").vosFont(WorkspaceText.body).foregroundStyle(palette.secondaryText)
            TextEditor(text:$text).frame(minHeight:300).workspaceEditorSurface().focused($textFocused)
            if !failure.isEmpty { Text(failure).vosFont(WorkspaceText.meta).foregroundStyle(palette.danger) }
            HStack {
                Button("取消",action:close).buttonStyle(.workspaceSecondary).keyboardShortcut(.cancelAction)
                Spacer()
                Button(saving ? "正在保存…" : "保存更正") { save() }
                    .buttonStyle(.workspacePrimary).keyboardShortcut(.defaultAction)
                    .disabled(saving || text == source.transcript || text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width:WorkspaceMetrics.modalSmall).onAppear { text=source.transcript ?? "" }
            .workspaceModalSurface()
            .task { try? await Task.sleep(for:.milliseconds(100)); textFocused=true }
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
struct ClaimActionsMenu: View {
    let edit: () -> Void
    let delete: () -> Void
    var createAction: (() -> Void)? = nil
    var body: some View {
        Menu { actions } label: { Image(systemName:"ellipsis.circle") }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("观点操作").accessibilityLabel("观点操作")
    }
    @ViewBuilder var actions: some View {
        Button("编辑", systemImage: "pencil", action: edit)
        if let createAction { Button("创建行动", systemImage: "plus", action: createAction) }
        Button("删除", systemImage: "trash", role: .destructive, action: delete)
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
    @FocusState private var textFocused:Bool
    init(claim:CandidateClaim,model:ControlCenter,onSaved:@escaping()->Void = {},dismiss:@escaping()->Void) {
        self.claim=claim;self.model=model;self.onSaved=onSaved;self.dismiss=dismiss
        _text=State(initialValue:claim.statement);_ownership=State(initialValue:claim.ownership)
    }
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("编辑观点").vosFont(WorkspaceText.sectionTitle).accessibilityAddTraits(.isHeader)
            Text("原话会保留。依赖旧观点的行动将暂停。").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
            TextEditor(text:$text).frame(minHeight:180).workspaceEditorSurface().focused($textFocused)
            Picker("内容归属",selection:$ownership) {
                Text("我的表达").tag("user_tentative");Text("他人观点").tag("external");Text("AI 建议").tag("ai_candidate");Text("尚不确定").tag("unresolved")
            }
            TextField("备注（选填）",text:$note)
            if !failure.isEmpty { Text(failure).vosFont(WorkspaceText.meta).foregroundStyle(palette.danger) }
            HStack {
                Button("取消",action:dismiss).buttonStyle(.workspaceSecondary).keyboardShortcut(.cancelAction)
                Spacer()
                Button(saving ? "正在保存…" : "保存") { save() }
                    .buttonStyle(.workspacePrimary).keyboardShortcut(.defaultAction)
                    .disabled(saving || model.reviewingClaim || (text == claim.statement && ownership == claim.ownership) || text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width:WorkspaceMetrics.modalSmall)
            .workspaceModalSurface()
            .task { try? await Task.sleep(for:.milliseconds(100)); textFocused=true }
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
    @FocusState private var titleFocused:Bool
    init(record:SourceRecord,expression:RecordingExpression,model:ControlCenter,dismiss:@escaping()->Void) {
        self.record=record;self.expression=expression;self.model=model;self.dismiss=dismiss
        _title=State(initialValue:expression.manualTitle ?? expression.title)
    }
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("修改分组标题").vosFont(WorkspaceText.sectionTitle).accessibilityAddTraits(.isHeader)
            TextField("分组标题",text:$title).focused($titleFocused)
            Text("\(expression.sourceIDs.count) 段录音同属一段连续表达。").vosFont(WorkspaceText.caption).foregroundStyle(palette.secondaryText)
            if !model.recordingTitleStatus.isEmpty { Text(model.recordingTitleStatus).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText) }
            HStack {
                if expression.manualTitle != nil { Button("恢复自动标题") { save(nil) }.buttonStyle(.workspaceQuiet).disabled(saving) }
                Button("取消",action:dismiss).buttonStyle(.workspaceSecondary).keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存") { save(title) }.buttonStyle(.workspacePrimary).keyboardShortcut(.defaultAction)
                    .disabled(saving || title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || title.count > 100)
            }
        }.padding(24).frame(width:WorkspaceMetrics.modalSmall)
            .workspaceModalSurface()
            .task { try? await Task.sleep(for:.milliseconds(100)); titleFocused=true }
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
