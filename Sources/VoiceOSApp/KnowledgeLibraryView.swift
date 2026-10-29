import SwiftUI
import VoiceOSCore

struct KnowledgeLibraryView: View {
    @ObservedObject var model: ControlCenter
    let dismiss: () -> Void
    let discuss: (CandidateClaim) -> Void
    @State private var query = ""
    @State private var ownership = "all"
    @State private var sourceID = "all"
    @State private var selectedID: String?
    @State private var mode = "knowledge"
    @State private var selectedOutcomeID: String?
    @State private var correctingClaim: CandidateClaim?
    @State private var historyClaim: CandidateClaim?

    private var knowledge: [CandidateClaim] {
        let actions = Set(model.actionRecords.filter { $0.kind == "task" }.map(\.claimID))
        var seen = Set<String>()
        return model.records.flatMap { model.currentClaimsBySource[$0.id] ?? [] }.filter {
            seen.insert($0.id).inserted && $0.validity == "current" && $0.reviewState != "rejected" && !actions.contains($0.id)
        }
    }
    private func sources(_ claim: CandidateClaim) -> [SourceRecord] {
        model.records.filter { source in claim.references.contains { $0.sourceID == source.id } }
    }
    private func title(_ claim: CandidateClaim) -> String {
        let first = claim.statement.components(separatedBy: "\n说明：")[0]
        if first.hasPrefix("【"), let end = first.firstIndex(of: "】") { return String(first[first.index(after: end)...]) }
        return first
    }
    private func owner(_ claim: CandidateClaim) -> String {
        switch claim.ownership {
        case "user_tentative": return "我的表达"
        case "external": return "外部主张"
        case "ai_candidate": return "AI 建议"
        default: return "归属待核对"
        }
    }
    private var visible: [CandidateClaim] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return knowledge.filter { claim in
            (ownership == "all" || claim.ownership == ownership) &&
            (sourceID == "all" || claim.references.contains { $0.sourceID == sourceID }) &&
            words.allSatisfy { word in
                claim.statement.localizedCaseInsensitiveContains(word) || sources(claim).contains { $0.displayTitle.localizedCaseInsensitiveContains(word) }
            }
        }
    }
    private var selected: CandidateClaim? { visible.first { $0.id == selectedID } ?? visible.first }
    private var availableSources: [SourceRecord] {
        let ids = mode == "outcomes" ? Set(model.recentOutcomes.flatMap { outcomeSources($0).map(\.id) }) : Set(knowledge.flatMap { $0.references.map(\.sourceID) })
        return model.records.filter { ids.contains($0.id) }
    }
    private func outcomeAction(_ feedback: ActionFeedbackRecord) -> ActionRecord? {
        model.actionRecords.first { $0.id == feedback.actionID }
    }
    private func outcomeSources(_ feedback: ActionFeedbackRecord) -> [SourceRecord] {
        let claimID = outcomeAction(feedback)?.claimID
        let claim = model.claims.first { $0.id == claimID }
        let ids = Set((claim?.references.map(\.sourceID) ?? []) + [feedback.recordingSourceID ?? feedback.sourceID])
        return model.records.filter { ids.contains($0.id) }
    }
    private var visibleOutcomes: [ActionFeedbackRecord] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return model.recentOutcomes.filter { feedback in
            let sources = outcomeSources(feedback)
            return (sourceID == "all" || sources.contains { $0.id == sourceID }) && words.allSatisfy { word in
                feedback.text.localizedCaseInsensitiveContains(word) ||
                (outcomeAction(feedback)?.title.localizedCaseInsensitiveContains(word) ?? false) ||
                sources.contains { $0.displayTitle.localizedCaseInsensitiveContains(word) }
            }
        }
    }
    private var selectedOutcome: ActionFeedbackRecord? { visibleOutcomes.first { $0.id == selectedOutcomeID } ?? visibleOutcomes.first }
    private func outcomeDate(_ feedback: ActionFeedbackRecord) -> String {
        guard let date = ISO8601DateFormatter().date(from: feedback.createdAt) else { return feedback.createdAt }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
    private func excerpt(_ claim: CandidateClaim, source: SourceRecord) -> String {
        guard let text = source.transcript else { return "" }
        let scalars = Array(text.unicodeScalars)
        return source.spans.filter { span in
            claim.references.contains { $0.sourceID == source.id && $0.transcriptVersionID == source.transcriptVersionID && $0.spanID == span.id }
        }.compactMap { span in
            guard span.textStart >= 0, span.textEnd <= scalars.count else { return nil }
            return String(String.UnicodeScalarView(scalars[span.textStart..<span.textEnd]))
        }.joined(separator: "\n")
    }
    private func tasks(_ claim: CandidateClaim) -> [ActionRecord] {
        let nearby = Set(model.claims.filter { other in
            other.references.contains { ref in claim.references.contains { $0.sourceID == ref.sourceID && $0.transcriptVersionID == ref.transcriptVersionID && $0.spanID == ref.spanID } }
        }.map(\.id))
        let feedbackActions = Set(sources(claim).compactMap(\.feedbackActionID))
        return model.actionRecords.filter { $0.kind == "task" && $0.validity == "current" && $0.state != "dismissed" && (nearby.contains($0.claimID) || feedbackActions.contains($0.id)) }
    }
    private func coversQuote(_ quote: String, claim: CandidateClaim, sourceID: String) -> Bool {
        guard !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              claim.references.contains(where: { $0.sourceID == sourceID }),
              let source = model.records.first(where: { $0.id == sourceID }),
              let text = source.transcript else { return false }
        let scalars = Array(text.unicodeScalars)
        let ranges = source.spans.filter { span in
            span.textStart >= 0 && span.textEnd > span.textStart && span.textEnd <= scalars.count &&
            claim.references.contains { $0.sourceID == source.id && $0.transcriptVersionID == source.transcriptVersionID && $0.spanID == span.id }
        }.map { $0.textStart..<$0.textEnd }.sorted { $0.lowerBound < $1.lowerBound }
        var contiguous: [Range<Int>] = []
        for range in ranges {
            if let last = contiguous.last, range.lowerBound <= last.upperBound {
                contiguous[contiguous.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                contiguous.append(range)
            }
        }
        // Only actual continuous evidence may establish this expression's link.
        return contiguous.contains { String(String.UnicodeScalarView(scalars[$0])).contains(quote) }
    }
    private func links(_ claim: CandidateClaim) -> [(RecordingFollowupReceipt, ThoughtUpdate)] {
        var seen = Set<String>()
        return model.recordingFollowups.reversed().flatMap { receipt in
            (receipt.result?.thoughtUpdates ?? []).compactMap { update in
                guard model.followupValidity[receipt.id]?.thoughtIsCurrent(update.claimID) == true else { return nil }
                // Several thoughts may share a coarse transcript span. A quote
                // that fits all of them establishes only a recording-level link.
                if update.claimID != claim.id {
                    guard coversQuote(update.currentQuote, claim: claim, sourceID: receipt.sourceID),
                          !knowledge.contains(where: { $0.id != claim.id && coversQuote(update.currentQuote, claim: $0, sourceID: receipt.sourceID) }) else { return nil }
                }
                let key = receipt.sourceID + ":" + update.claimID + ":" + update.currentQuote
                guard seen.insert(key).inserted else { return nil }
                return (receipt, update)
            }
        }.reversed()
    }
    private func reviewQuotes(_ claim: CandidateClaim) -> [String: [String]] {
        var matches: [String: [String]] = [:]
        for record in model.knowledgeReviews where claim.references.contains(where: { $0.sourceID == record.sourceID }) {
            for issue in record.issues {
                guard coversQuote(issue.quote, claim: claim, sourceID: record.sourceID),
                      !knowledge.contains(where: { $0.id != claim.id && coversQuote(issue.quote, claim: $0, sourceID: record.sourceID) }) else { continue }
                if !(matches[record.sourceID] ?? []).contains(issue.quote) { matches[record.sourceID, default: []].append(issue.quote) }
            }
        }
        return matches
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("知识与思考").font(.title2)
                    Text("找回观点、问题与实际结果，接着以前的思考继续。").foregroundStyle(.secondary)
                }
                Spacer(); Button("完成", action: dismiss).keyboardShortcut(.cancelAction)
            }
            Picker("内容", selection: $mode) {
                Text("观点与思考").tag("knowledge")
                Text("行动结果").tag("outcomes")
            }.pickerStyle(.segmented)
            HStack {
                TextField(mode == "outcomes" ? "查找任务、结果或录音标题" : "查找观点、收获或录音标题", text: $query)
                Picker("来源", selection: $sourceID) {
                    Text("全部录音与表达").tag("all")
                    ForEach(availableSources) { Text($0.displayTitle).tag($0.id) }
                }.frame(maxWidth: 330)
            }
            if mode == "knowledge" {
                Picker("内容归属", selection: $ownership) {
                    Text("全部").tag("all"); Text("我的表达").tag("user_tentative")
                    Text("外部主张").tag("external"); Text("AI 建议").tag("ai_candidate")
                    Text("归属待核对").tag("unresolved")
                }.pickerStyle(.segmented)
                knowledgeBrowser
            } else {
                outcomeBrowser
            }
        }.padding(24).frame(width: 1040, height: 740)
        .onChange(of: mode) { _, _ in sourceID = "all" }
        .onDisappear { model.stopPlayback() }
        .sheet(item: $correctingClaim) { claim in
            ClaimCorrectionView(claim: claim, model: model) { correctingClaim = nil }
        }
        .sheet(item: $historyClaim) { _ in
            ClaimReviewHistoryView(revisions: model.claimHistory) { historyClaim = nil }
        }
    }
    private var knowledgeBrowser: some View {
        HSplitView {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(visible.count) 条内容").font(.caption).foregroundStyle(.secondary)
                    List(visible, selection: $selectedID) { claim in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(title(claim)).lineLimit(3)
                            Text(sources(claim).first?.recordingDateLabel ?? "历史表达").font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 4).tag(claim.id)
                    }.listStyle(.inset)
                }.frame(minWidth: 260, idealWidth: 300, maxWidth: 360)
                ScrollView {
                    if let claim = selected {
                        detail(claim).padding(.leading, 16)
                    } else {
                        ContentUnavailableView(query.isEmpty ? "整理后的知识会汇入这里" : "没有找到这条思考", systemImage: "books.vertical", description: Text(query.isEmpty ? "完整整理录音后，观点与任务会分别保存。" : "可以换个关键词，或切换来源。"))
                    }
                }.frame(minWidth: 450, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
    private var outcomeBrowser: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(visibleOutcomes.count) 条实际结果").font(.caption).foregroundStyle(.secondary)
                List(visibleOutcomes, selection: $selectedOutcomeID) { feedback in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(outcomeAction(feedback)?.title ?? "行动结果").lineLimit(2)
                        Text(feedback.text).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                        Text(outcomeDate(feedback)).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4).tag(feedback.id)
                }.listStyle(.inset)
            }.frame(minWidth: 260, idealWidth: 300, maxWidth: 360)
            ScrollView {
                if let feedback = selectedOutcome {
                    outcomeDetail(feedback).padding(.leading, 16)
                } else {
                    ContentUnavailableView(query.isEmpty ? "实际结果会保存在这里" : "没有找到这条结果", systemImage: "checkmark.bubble", description: Text(query.isEmpty ? "在任务中记录收获与结果，或在后续录音中讲述实际结果。完成任务本身不会生成结果。" : "可以换个关键词，或切换来源。"))
                }
            }.frame(minWidth: 450, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
    private func outcomeDetail(_ feedback: ActionFeedbackRecord) -> some View {
        let action = outcomeAction(feedback)
        return VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text(feedback.label + " · " + outcomeDate(feedback)).font(.caption).foregroundStyle(.secondary)
                Text(action?.title ?? "行动结果").font(.title3.bold()).textSelection(.enabled)
                if let action, feedback.actionVersion != action.version {
                    Text("历史记录 · 第 \(feedback.actionVersion) 版任务的结果；当前任务为第 \(action.version) 版。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Button("查看任务与全部结果") { model.showTask(feedback.actionID); dismiss() }
            }
            Text(feedback.text).textSelection(.enabled)
            let thoughts = knowledge.filter { $0.references.contains { $0.sourceID == feedback.sourceID } }
            if !thoughts.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("从这次结果整理的思考").font(.headline)
                    ForEach(thoughts) { claim in
                        Button(title(claim)) {
                            query = ""; ownership = "all"; mode = "knowledge"; selectedID = claim.id
                        }.buttonStyle(.link)
                    }
                }
            }
            ForEach(outcomeSources(feedback)) { source in
                VStack(alignment: .leading, spacing: 8) {
                    Text(source.displayTitle).font(.headline)
                    Text(source.recordingSubtitle).font(.caption).foregroundStyle(.secondary)
                    Button(source.kind == "user_text" ? "查看表达全文" : "查看录音与全文") { model.selected = source.id; dismiss() }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func detail(_ claim: CandidateClaim) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text(owner(claim) + (claim.reviewState == "endorsed" ? " · 已认可" : " · 暂未认可") + " · 未验证").font(.caption).foregroundStyle(.secondary)
                Text(title(claim)).font(.title3.bold()).textSelection(.enabled)
                if let explanation = claim.statement.components(separatedBy: "\n说明：").dropFirst().first {
                    DisclosureGroup("整理说明") { Text(explanation).textSelection(.enabled) }.font(.callout)
                }
                HStack {
                    Button(claim.reviewState == "endorsed" ? "已认可" : "认可这段整理") { Task { _ = await model.review(claim, action: .endorse) } }
                        .disabled(model.reviewingClaim || claim.reviewState == "endorsed")
                    Button("更正表述或归属") { correctingClaim = claim }.disabled(model.reviewingClaim)
                    Button("停止使用") { Task { _ = await model.review(claim, action: .reject) } }.disabled(model.reviewingClaim)
                    Button("审阅历史") { Task { await model.reviewHistory(claim); historyClaim = claim } }
                }
                Text("认可表示这段整理可以保留；事实是否成立仍需证据。").font(.caption).foregroundStyle(.secondary)
                Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            ForEach(sources(claim)) { source in
                VStack(alignment: .leading, spacing: 8) {
                    Text(source.displayTitle).font(.headline)
                    Text(source.recordingSubtitle).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(source.kind == "user_text" ? "查看表达全文" : "查看录音与全文") { model.selected = source.id; dismiss() }
                        Button("讨论这条思考") { discuss(claim) }.disabled(model.discussionSaving || model.discussionSending || model.discussionExtracting || model.dictationActive)
                        if source.kind != "user_text" && source.state == "saved" {
                            Button("回听原话") { Task { await model.playFollowupQuote(sourceID: source.id, quote: excerpt(claim, source: source)) } }
                        }
                    }
                    DisclosureGroup("原话") { Text(excerpt(claim, source: source)).textSelection(.enabled) }
                }
            }
            KnowledgeReviewSection(model: model, sourceIDs: sources(claim).map(\.id), matchingQuotesBySource: reviewQuotes(claim))
            let related = links(claim)
            VStack(alignment: .leading, spacing: 10) {
                Text("前后思考").font(.headline)
                if related.isEmpty { Text("还没有明确对应这条思考的前后关联。录音整体的关联可在“思想与下一步”查看。").font(.callout).foregroundStyle(.secondary) }
                ForEach(Array(related.enumerated()), id: \.offset) { _, pair in
                    let receipt = pair.0, update = pair.1
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.records.first(where: { $0.id == receipt.sourceID })?.recordingDateLabel ?? receipt.createdAt).font(.caption).foregroundStyle(.secondary)
                        Text(update.understanding).font(.callout.bold()).textSelection(.enabled)
                        Text(update.claimID == claim.id ? "这条思考的后续表达" : "这份录音与历史思考的关联").font(.caption).foregroundStyle(.secondary)
                        DisclosureGroup("前后原话与依据") {
                            Text("此前：" + update.historicalQuote).textSelection(.enabled)
                            if let target = receipt.input.thoughts.first(where: { $0.id == update.claimID }), let old = target.evidence.first(where: { $0.quote.contains(update.historicalQuote) }) {
                                Button("查看此前出处") { model.selected = old.reference.sourceID; dismiss() }
                            }
                            Text("这次：" + update.currentQuote).textSelection(.enabled)
                            Text(update.reason).font(.caption).foregroundStyle(.secondary)
                            Button("查看后续录音") { model.selected = receipt.sourceID; dismiss() }
                        }
                    }.padding(12).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            let actions = tasks(claim)
            if !actions.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(sources(claim).contains(where: { $0.feedbackActionID != nil }) ? "这次结果对应的行动" : "同段录音中的行动").font(.headline)
                    Text("任务完成状态与实际结果分别保留，具体关系以原话为准。").font(.caption).foregroundStyle(.secondary)
                    ForEach(actions) { action in
                        HStack {
                            Image(systemName: action.state == "completed" ? "checkmark.circle" : "circle")
                            Text(action.title).lineLimit(2)
                            Spacer()
                            Button("任务与结果") { model.showTask(action.id); dismiss() }
                        }
                    }
                }
            }
            if let player = model.player { NativePlayerView(player: player).frame(height: 64) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
