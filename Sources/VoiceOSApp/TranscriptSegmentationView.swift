import SwiftUI
import VoiceOSCore

struct TranscriptSegmentationView: View {
    @ObservedObject var model: ControlCenter
    let dismiss: () -> Void
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("原话分段").font(.title2)
            if let plan = model.segmentationPlan {
                Text("\(plan.source.origin == "user" && plan.source.speaker == "user" ? "我的表达" : "外部资料 · 说话人待核对") · \(plan.segments.count) 段 · 每段最多 \(plan.scalarBudget) 字符")
                Text("仅在本机预览，保留全部原话；尚未排队发送模型。").font(.callout).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:14) {
                        ForEach(plan.segments) { segment in
                            VStack(alignment:.leading,spacing:6) {
                                Text("第 \(segment.ordinal) 段 · 原文字符 \(segment.textStart+1)—\(segment.textEnd)").font(.headline)
                                Text(segment.text).textSelection(.enabled)
                                DisclosureGroup("原片段引用（\(segment.references.count)）") {
                                    ForEach(segment.references.indices,id:\.self) { index in
                                        let reference = segment.references[index]
                                        VStack(alignment:.leading,spacing:4) {
                                            Text("原文字符 \(reference.textStart+1)—\(reference.textEnd)").font(.caption)
                                            if let start = reference.containingSpanStartMS, let end = reference.containingSpanEndMS {
                                                Text(String(format:"原片段 %.1f—%.1f 秒；不是当前分段的精确起止",Double(start)/1000,Double(end)/1000)).font(.caption).foregroundStyle(.secondary)
                                                Button("从原片段开始播放核对") { Task { await model.playSegmentationReference(plan,reference:reference) } }
                                            } else { Text("时间未确认；文字更正后不沿用原时间。").font(.caption).foregroundStyle(.secondary) }
                                        }
                                    }
                                }
                                Divider()
                            }
                        }
                    }
                }
            } else { Text("原话或授权已变化，请关闭后重新查看分段。").foregroundStyle(.secondary) }
            if !model.segmentationStatus.isEmpty { Text(model.segmentationStatus).foregroundStyle(.orange) }
            HStack { Spacer(); Button("完成",action:dismiss).keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width:680,height:560)
    }
}
