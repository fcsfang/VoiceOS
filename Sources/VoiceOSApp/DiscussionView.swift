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
            }.disabled(model.discussionSending || model.discussionSaving || model.dictationActive)
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
                                        ForEach(Array(reply.parts.enumerated()),id:\.offset) { _,part in
                                            VStack(alignment:.leading,spacing:6) {
                                                Text(part.kind == .quotation ? "原文引用" : "AI分析与建议").font(.caption).foregroundStyle(.secondary)
                                                Text(part.text).textSelection(.enabled)
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
                HStack {
                    Text(model.discussionStatus).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    Spacer()
                    if session.state == "active" { Button("结束讨论") { Task { await model.endDiscussion() } }.disabled(model.discussionSaving || model.dictationActive) }
                }
            } else {
                ContentUnavailableView("还没有选择讨论",systemImage:"bubble.left.and.bubble.right",description:Text("在资料详情点击“继续讨论”建立新的讨论，或选择已保存历史。"))
            }
        }.padding(24).frame(width:760,height:780)
        .sheet(item:$referencePreview) { preview in
            VStack(alignment:.leading,spacing:12) {
                Text("当时引用的原文版本").font(.title2)
                Text(preview.version).font(.caption).foregroundStyle(.secondary)
                ScrollView { Text(preview.text).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }
                HStack { Spacer();Button("完成") { referencePreview=nil } }
            }.padding(24).frame(width:640,height:420)
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
    private func replyLabel(_ reply:DiscussionAttemptRecord)->String {
        let state=reply.state == "completed" ? "AI回复" : (reply.state == "unknown" ? "调用结果未知 · 不自动重发" : (reply.state == "reserved" ? "正在等待结果" : "结果未接纳 · 不自动重发"))
        return state+(reply.validity == "frozen" ? " · 历史依据已冻结" : "")
    }
}
