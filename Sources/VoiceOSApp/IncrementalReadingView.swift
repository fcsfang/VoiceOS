import SwiftUI
import VoiceOSCore

struct IncrementalReadingView: View {
    @ObservedObject var model: ControlCenter
    let source: SourceRecord
    let dismiss: () -> Void
    @State private var plan: IncrementalPlan?
    @State private var chunkSize = 1200
    @State private var loaded = false
    @State private var busy = false
    @State private var notice = ""
    @State private var error = ""
    private let sizes = [400, 800, 1200, 2000, 4000]
    private var chunks: [ReadingChunk] {
        guard let plan, let transcript = source.transcript else { return [] }
        return ReadingChunks.split(text: transcript, spans: source.spans, targetSize: plan.chunkSize)
    }
    private var index: Int { min(plan?.currentChunk ?? 0, max(chunks.count - 1, 0)) }
    private var text: String {
        guard let transcript = source.transcript, chunks.indices.contains(index) else { return "" }
        return slice(transcript, start: chunks[index].start, end: chunks[index].end)
    }
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            Text("按天读").vosFont(WorkspaceText.sectionTitle)
            if !loaded {
                ProgressView("正在读取阅读进度…")
            } else if let plan {
                Text("第 \(index + 1)/\(chunks.count) 块 · 每块约 \(plan.chunkSize) 字").vosFont(WorkspaceText.meta)
                if chunks.isEmpty {
                    Text(source.transcript == nil ? "转写尚未完成，完成后可以开始按天读。" : "当前转写没有可读文字。").foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        Text(text).vosFont(WorkspaceText.body).lineSpacing(6).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
                    }
                    HStack(spacing:10) {
                        Button("上一块") { move(to:index - 1) }.disabled(busy || index <= 0)
                        Button("下一块") { move(to:index + 1) }.disabled(busy || index >= chunks.count - 1)
                        Button("读完了，明天继续") { advance() }.disabled(busy)
                        Spacer()
                        Button("结束按天读") { stop() }.disabled(busy)
                    }
                }
            } else {
                Text(source.transcript == nil ? "转写尚未完成，完成后可以开始按天读。" : "把这份材料切成小块，每天读一块。进度只记当前位置，原文变化后按最新转写重算。").vosFont(WorkspaceText.body).foregroundStyle(.secondary)
                Picker("每块字数", selection:$chunkSize) { ForEach(sizes,id:\.self) { Text(String($0)).tag($0) } }.pickerStyle(.segmented)
                Button("开始按天读") { start() }.buttonStyle(.workspacePrimary).disabled(busy || source.transcript == nil)
            }
            if !notice.isEmpty { Text(notice).vosFont(WorkspaceText.meta).foregroundStyle(.secondary) }
            if !error.isEmpty { WorkspaceNoticeText(message:error,severity:.danger) }
            HStack { Spacer(); Button("关闭",action:dismiss).keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width:680,height:560)
        .task(id:source.id) { await reload() }
    }
    private func slice(_ text:String,start:Int,end:Int) -> String {
        let scalars = Array(text.unicodeScalars)
        guard start >= 0, end <= scalars.count, start < end else { return "" }
        return String(String.UnicodeScalarView(scalars[start..<end]))
    }
    private func reload() async {
        guard let store = model.store else { loaded = true; error = "资料库尚未打开"; return }
        do {
            plan = try await store.incrementalPlan(sourceID:source.id)
            error = ""
        } catch { self.error = error.localizedDescription }
        loaded = true
    }
    private func start() {
        guard !busy else { return }
        busy = true
        let size = chunkSize
        Task {
            defer { busy = false }
            guard let store = model.store else { error = "资料库尚未打开"; return }
            do {
                try await store.startIncrementalReading(sourceID:source.id,chunkSize:size)
                await reload()
                notice = "已开始按天读"
            } catch { self.error = error.localizedDescription }
        }
    }
    private func move(to next:Int) {
        guard !busy, chunks.indices.contains(next) else { return }
        busy = true
        Task {
            defer { busy = false }
            guard let store = model.store else { error = "资料库尚未打开"; return }
            do {
                try await store.setIncrementalChunk(sourceID:source.id,index:next)
                await reload()
                notice = ""
            } catch { self.error = error.localizedDescription }
        }
    }
    private func advance() {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            guard let store = model.store else { error = "资料库尚未打开"; return }
            do {
                let moved = try await store.advanceIncrementalChunk(sourceID:source.id)
                await reload()
                notice = moved ? "已翻到第 \(index + 1) 块，明天继续" : "读完了"
            } catch { self.error = error.localizedDescription }
        }
    }
    private func stop() {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            guard let store = model.store else { error = "资料库尚未打开"; return }
            do {
                try await store.stopIncrementalReading(sourceID:source.id)
                await reload()
                notice = "已结束按天读"
            } catch { self.error = error.localizedDescription }
        }
    }
}
