import SwiftUI
import VoiceOSCore

struct DiscussionView: View {
    @ObservedObject var model:ControlCenter
    let dismiss:()->Void
    @State private var text=""
    @State private var allowCloud=true
    private struct ReferencePreview:Identifiable { let id=UUID();let text:String;let version:String }
    @State private var referencePreview:ReferencePreview?
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text("继续讨论").font(.title2)
                Spacer()
                Button("关闭",action:dismiss)
            }
            Picker("讨论历史",selection:Binding(get:{ model.discussionSession?.id ?? "" },set:{ id in text="";Task { await model.openDiscussion(id) } })) {
                Text("请选择讨论，或从资料进入").tag("")
                ForEach(model.discussionList) { session in
                    Text(String(session.id.prefix(8))+" · "+(session.state == "ended" ? "已结束" : "进行中")+(session.validity == "frozen" ? " · 只读历史" : "")).tag(session.id)
                }
            }.disabled(model.discussionSending || model.discussionSaving || model.discussionExtracting || model.dictationActive)
            if let session=model.discussionSession {
                ScrollView {
                    VStack(alignment:.leading,spacing:16) {
                        DisclosureGroup("入口原文与来源") {
                            ForEach(model.discussionHistory,id:\.sourceID) { source in
                                VStack(alignment:.leading,spacing:6) {
                                    Text(source.origin == "user" ? "我的历史表达" : "外部资料 · 不代表我的观点").font(.headline)
                                    Text(source.text).textSelection(.enabled)
                                    Text(source.localOnly ? "当时仅本地" : "当时允许云端文本").font(.caption).foregroundStyle(.secondary)
                                }.padding(.vertical,8)
                            }
                        }
                        if model.discussionTurns.isEmpty { Text("先口述或输入本轮发言；保存后再发送。") }
                        ForEach(model.discussionTurns) { turn in
                            VStack(alignment:.leading,spacing:8) {
                                Text("我 · 第\(turn.ordinal)轮").font(.headline)
                                Text(turn.text).textSelection(.enabled)
                                HStack {
                                    Button("查看个人原文") { model.selected=turn.sourceID;dismiss() }
                                    Button("整理我的这轮表达") { model.understandDiscussionTurn(turn);dismiss() }.disabled(!model.canUnderstandDiscussionTurn(turn))
                                }
                                Text("整理会发送本轮个人原话，提取待核对观点与明确行动；行动遵循已保存的提醒清单授权。").font(.caption).foregroundStyle(.secondary)
                                ForEach(model.discussionReplies.filter { $0.replyToTurnID == turn.id }) { reply in
                                    VStack(alignment:.leading,spacing:8) {
                                        Text(replyLabel(reply)).font(.headline)
                                        ForEach(Array(reply.parts.enumerated()),id:\.offset) { index,part in
                                            VStack(alignment:.leading,spacing:6) {
                                                Text(part.kind == .quotation ? "原文引用" : "AI分析与建议").font(.caption).foregroundStyle(.secondary)
                                                Text(part.text).textSelection(.enabled)
                                                if part.kind == .aiSuggestion {
                                                    let kept=model.discussionDerivations.first { $0.discussionAttemptID == reply.id && $0.partIndex == index }
                                                    if let claimID=kept?.claimID ?? outcomeParagraphClaim(reply,index:index,part:part),let claim=model.claims.first(where: { $0.id == claimID }) {
                                                        Button("已保留 · 查看 AI 候选") { model.selected=claim.references.first?.sourceID;dismiss() }
                                                    } else {
                                                        Button("保留为 AI 候选") { Task { if await model.retainDiscussionCandidate(reply,index:index) { dismiss() } } }
                                                            .disabled(reply.validity != "current" || session.validity != "current" || model.discussionSaving || model.discussionSending || model.dictationActive)
                                                    }
                                                    Text("待核对、未验证；保留不表示认可，也不创建行动。").font(.caption).foregroundStyle(.secondary)
                                                }
                                                ForEach(Array(part.references.enumerated()),id:\.offset) { _,ref in
                                                    Button("查看引用原文 · "+String(ref.sourceID.prefix(8))) { inspectReference(ref) }
                                                }
                                            }.padding(10).frame(maxWidth:.infinity,alignment:.leading).background(.quaternary,in:RoundedRectangle(cornerRadius:8))
                                        }
                                        Text("输入 \(reply.usage?["input_tokens"].map(String.init) ?? "未知") / 输出 \(reply.usage?["output_tokens"].map(String.init) ?? "未知") tokens · 实际费用未知").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Divider()
                            }
                        }
                        ForEach(model.discussionOutcomes) { outcome in
                            Divider()
                            Text(outcomeTitle(outcome.state)).font(.headline)
                            if outcome.validity == "frozen" { Text("历史成果已冻结，身份与出处保留。").font(.caption).foregroundStyle(.secondary) }
                            if !outcome.priorClaimIDs.isEmpty {
                                Text("沿用已有成果，保留原审阅与行动记录").font(.subheadline)
                                ForEach(outcome.priorClaimIDs,id:\.self) { id in
                                    if let claim=model.claims.first(where: { $0.id == id }) {
                                        Text(claim.statement).textSelection(.enabled)
                                        Text((claim.ownership == "ai_candidate" ? "已有 AI 候选" : "已有个人/来源候选")+" · "+(claim.reviewState == "rejected" ? "已拒绝" : (claim.reviewState == "endorsed" ? "已认可" : "待核对"))).font(.caption).foregroundStyle(.secondary)
                                        Button("查看原候选与行动") { model.selected=claim.references.first?.sourceID;dismiss() }
                                    }
                                }
                            }
                            ForEach(Array(outcome.proposals.enumerated()),id:\.offset) { index,proposal in
                                VStack(alignment:.leading,spacing:6) {
                                    Text(proposal.ownership == .aiCandidate ? "AI 候选" : (proposal.ownership == .userTentative ? "我的暂定表达" : "归属待核对")).font(.caption)
                                    Text(proposal.contentKind?.displayName ?? "内容类型未分类").font(.caption).foregroundStyle(.secondary)
                                    Text(proposal.statement).textSelection(.enabled)
                                    if outcome.claimIDs.indices.contains(index),let claim=model.claims.first(where: { $0.id == outcome.claimIDs[index] }) {
                                        if let question=model.questionRecords.first(where: { $0.seed.claimID == claim.id }) {
                                            QuestionStateView(question: question, model: model)
                                        }
                                        Button("查看成果候选与行动") { model.selected=claim.references.first?.sourceID;dismiss() }
                                    }
                                    if let action=proposal.action,proposal.ownership == .aiCandidate { Text("AI 行动建议（未创建个人任务）："+action.title).font(.caption).foregroundStyle(.secondary) }
                                    ForEach(Array(proposal.sourceEvidence.enumerated()),id:\.offset) { _,evidence in
                                        Text("来源原话："+evidence.quote).textSelection(.enabled)
                                        Button("查看当时来源版本") { inspectReference(evidence.reference) }
                                    }
                                    ForEach(Array(proposal.replyEvidence.enumerated()),id:\.offset) { _,evidence in
                                        Text("当时 AI 原话："+evidence.quote).textSelection(.enabled)
                                        Button("查看原 AI 段落") { inspectReplyEvidence(evidence) }
                                    }
                                }.padding(.vertical,8)
                            }
                            Text("输入 \(outcome.usage?["input_tokens"].map(String.init) ?? "未知") / 输出 \(outcome.usage?["output_tokens"].map(String.init) ?? "未知") tokens · 实际费用未知").font(.caption).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,6)
                }.frame(minHeight:180)
                if model.discussionWritable {
                    HStack {
                        if model.dictationActive {
                            Button("停止并保存本轮口述") { model.stopDictation() }.disabled(model.dictationBusy)
                        } else {
                            Button("口述这一轮",systemImage:"mic") { Task { await model.startDiscussionDictation() } }.disabled(model.discussionSending || model.discussionSaving || model.dictationBusy)
                        }
                        Text("逐轮录音 · 本地转写 · 文字回复").font(.caption).foregroundStyle(.secondary)
                    }
                    if let id=model.discussionRecordingID,let record=model.records.first(where: { $0.id == id }) {
                        Text(recordingLabel(record)).font(.callout).lineLimit(3)
                    }
                    Picker("已有个人录音",selection:Binding(get:{ model.discussionRecordingID ?? "" },set:{ model.discussionRecordingID=$0.isEmpty ? nil : $0 })) {
                        Text("可选已转写的个人口述").tag("")
                        ForEach(model.discussionRecordings) { record in Text(record.name).tag(record.id) }
                    }.disabled(model.dictationActive || model.discussionSending || model.discussionSaving)
                    TextEditor(text:$text).frame(height:72).border(.secondary.opacity(0.3)).disabled(model.discussionSaving || model.discussionSending || model.dictationActive)
                    Toggle("允许本轮文字用于云端讨论；音频保留本机",isOn:$allowCloud).font(.caption).disabled(model.discussionSaving || model.discussionSending || model.dictationActive)
                    HStack {
                        Button("保存文字发言") { Task { if await model.saveDiscussionText(text,allowCloud:allowCloud) { text="" } } }.disabled(text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || text.unicodeScalars.count > 4000 || model.discussionSaving || model.discussionSending || model.dictationActive)
                        Button("关联核对后的口述") { Task { _=await model.attachDiscussionRecording(allowCloud:allowCloud) } }.disabled(!model.discussionRecordings.contains(where: { $0.id == model.discussionRecordingID }) || model.discussionSaving || model.discussionSending || model.dictationActive || model.dictationBusy)
                        Spacer()
                        Button(model.discussionSending ? "正在回复…" : "发送本轮文字") { Task { await model.sendDiscussion() } }.disabled(!model.discussionCanSend || model.discussionSaving || model.discussionSending || model.dictationActive)
                    }
                    if !model.discussionCanSend { Text("发送需已保存的新发言、文本模型配置及全部实际来源的云端文本许可；同一轮已有调用不会重发。").font(.caption).foregroundStyle(.secondary) }
                } else {
                    Text(session.state == "ended" ? "这段讨论已结束，历史可回溯。新的讨论请从资料明确进入。" : "资料迁移或来源/权限变化使这段讨论冻结，旧讨论保留历史；请核对后从资料另开讨论。").font(.callout)
                }
                if session.state == "ended",session.validity == "current",model.discussionOutcomes.isEmpty {
                    HStack {
                        Button(model.discussionExtracting ? "正在整理整段成果…" : "整理整段讨论成果") { model.extractDiscussionOutcome() }.disabled(!model.discussionCanExtract)
                        Spacer()
                    }
                    Text("整理会使用本段已授权的原文与 AI 回复，沿用已有成果；明确普通任务遵循已有清单授权，AI 建议保持待核对。").font(.caption).foregroundStyle(.secondary)
                    if !model.discussionCanExtract,!model.discussionExtracting { Text("请先配置文本模型、在来源详情允许本段文字用于云端，并等待在途回复完成。").font(.caption).foregroundStyle(.secondary) }
                }
                HStack {
                    Text(model.discussionStatus).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    Spacer()
                    if session.state == "active" { Button("结束讨论") { Task { await model.endDiscussion() } }.disabled(model.discussionSaving || model.dictationActive) }
                }
            } else {
                ContentUnavailableView("还没有选择讨论",systemImage:"bubble.left.and.bubble.right",description:Text("在资料详情点击“继续讨论”建立新的讨论，或选择已保存历史。"))
            }
        }.padding(24).frame(width:760,height:780)
        .onAppear {
            if !model.discussionDraft.isEmpty { text = model.discussionDraft; model.discussionDraft = "" }
        }
        .sheet(item:$referencePreview) { preview in
            VStack(alignment:.leading,spacing:12) {
                Text("当时引用的原文版本").font(.title2)
                Text(preview.version).font(.caption).foregroundStyle(.secondary)
                ScrollView { Text(preview.text).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }
                HStack { Spacer();Button("完成") { referencePreview=nil } }
            }.padding(24).frame(width:640,height:420)
        }
    }
    private func outcomeTitle(_ state:String)->String {
        switch state {
        case "reserved":return "正在整理讨论成果 · 等待结果"
        case "completed":return "讨论成果 · 待核对"
        case "unknown":return "成果提取结果未知 · 不自动重发"
        default:return "成果未接纳 · 不自动重发"
        }
    }
    private func recordingLabel(_ record:SourceRecord)->String {
        if model.dictationActive { return "正在录制本轮口述；停止后再转写与核对。" }
        if ["queued","running"].contains(record.jobState ?? "") { return "原件已保存，正在等待本地转写。" }
        if ["failed","blocked"].contains(record.jobState ?? "") { return "本地转写未完成，口述原件保留；可回到资料库重试。" }
        if !(record.transcript ?? "").unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) { return "没有识别到可用的发言；不会关联或发送。可重新口述，或输入文字。" }
        return "本轮口述待核对："+(record.transcript ?? "")
    }
    private func inspectReference(_ ref:ClaimReference) {
        let text:String
        if let source=model.discussionHistory.first(where: { $0.sourceID == ref.sourceID && $0.transcriptVersionID == ref.transcriptVersionID }) {
            text=source.text
        } else if let turn=model.discussionTurns.first(where: { $0.sourceID == ref.sourceID && $0.transcriptVersionID == ref.transcriptVersionID }) {
            text=turn.text
        } else { text="此引用没有对应的历史原文；请核对资料，不以当前版本替代。" }
        referencePreview=ReferencePreview(text:text,version:"来源 "+ref.sourceID+" · 逐字稿版本 "+ref.transcriptVersionID)
    }
    private func outcomeParagraphClaim(_ reply:DiscussionAttemptRecord,index:Int,part:DiscussionPart)->String? {
        for outcome in model.discussionOutcomes where outcome.state == "completed" {
            for (ordinal,proposal) in outcome.proposals.enumerated() where outcome.claimIDs.indices.contains(ordinal) {
                if proposal.ownership == .aiCandidate,proposal.statement == part.text,proposal.replyEvidence.contains(where: { $0.attemptID == reply.id && $0.partIndex == index && $0.quote == part.text }) { return outcome.claimIDs[ordinal] }
            }
        }
        return nil
    }
    private func inspectReplyEvidence(_ evidence:OutcomeReplyEvidence) {
        guard let reply=model.discussionReplies.first(where: { $0.id == evidence.attemptID }),reply.parts.indices.contains(evidence.partIndex) else { return }
        referencePreview=ReferencePreview(text:reply.parts[evidence.partIndex].text,version:"AI 调用 "+evidence.attemptID+" · 段落 "+String(evidence.partIndex+1))
    }
    private func replyLabel(_ reply:DiscussionAttemptRecord)->String {
        let state=reply.state == "completed" ? "AI回复" : (reply.state == "unknown" ? "调用结果未知 · 不自动重发" : (reply.state == "reserved" ? "正在等待结果" : "结果未接纳 · 不自动重发"))
        return state+(reply.validity == "frozen" ? " · 历史依据已冻结" : "")
    }
}
