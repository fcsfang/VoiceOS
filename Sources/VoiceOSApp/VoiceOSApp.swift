import SwiftUI
import AppKit
import AVKit
import UniformTypeIdentifiers
import VoiceOSCore
import VoiceOSPlatform

@MainActor
final class ControlCenter: ObservableObject {
    @Published var records: [SourceRecord] = []
    @Published var selected: String?
    @Published var query = ""
    var filtered: [SourceRecord] {
        query.isEmpty ? records : records.filter { $0.name.localizedCaseInsensitiveContains(query) || ($0.transcript?.localizedCaseInsensitiveContains(query) ?? false) }
    }
    @Published var status = "正在检查资料库…"
    @Published var importing = false
    @Published var changingPolicy = false
    @Published var understandingSource: String?
    @Published var modelConfigured = false
    @Published var modelSummary = "尚未配置文本模型"
    @Published var attempts: [String: [ModelAttemptRecord]] = [:]
    private var textModel: ResponsesModelPort?
    private var understandingWorker: Task<Void, Never>?
    @Published var initialized = false
    @Published var player: AVPlayer?
    @Published var history: [TranscriptVersion] = []
    @Published var claims: [CandidateClaim] = []
    private var store: VoiceOSStore?
    private var worker: Task<Void, Never>?
    func start() async {
        guard store == nil else { return }
        do {
            let root: URL
            if let path = ProcessInfo.processInfo.environment["VOICEOS_DATA_DIR"] { root = URL(fileURLWithPath: path, isDirectory: true) }
            else { root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("VoiceOS", isDirectory: true) }
            let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
            self.store = store
            try await store.recover()
            initialized = true; status = "准备就绪 · 媒体只在本机处理"
            if let path = ProcessInfo.processInfo.environment["VOICEOS_MODEL_CONFIG_FILE"] {
                configureTextModel(URL(fileURLWithPath: path))
            }
            await refresh()
            scheduleProcessing()
        } catch { status = error.localizedDescription }
    }
    func refresh() async {
        do {
            claims = try await store?.candidateClaims(includeFrozen: true) ?? []
            records = try await store?.sources() ?? []
            if let store {
                var loaded: [String: [ModelAttemptRecord]] = [:]
                for record in records { loaded[record.id] = try await store.modelAttempts(sourceID: record.id) }
                attempts = loaded
            }
        }
        catch { status = error.localizedDescription }
    }
    func chooseTextModel() {
        let panel = NSOpenPanel()
        panel.title = "选择本地文本模型配置"; panel.prompt = "使用配置"
        panel.showsHiddenFiles = true; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.begin { response in
            if response == .OK, let url = panel.url { self.configureTextModel(url) }
        }
    }
    private func configureTextModel(_ file: URL) {
        do {
            let port = try LocalTextModel.load(from: file)
            textModel = port; modelConfigured = true
            modelSummary = "gpt-6.1-sol · " + port.configuration.provider.replacingOccurrences(of: "responses:", with: "")
            status = "文本模型已就绪 · 只处理你选择并授权的文字"
        } catch { status = error.localizedDescription }
    }
    func understand(_ record: SourceRecord) {
        guard let store, let port = textModel, understandingWorker == nil, !record.localOnly,
              !(record.transcript ?? "").isEmpty else { return }
        understandingSource = record.id
        status = "正在理解所选文字 · 原始音视频仍在本机"
        // Application-owned: changing selection or closing the window does not resend/cancel.
        understandingWorker = Task {
            do {
                let ids = try await store.understandSource(sourceID: record.id, using: port)
                status = ids.isEmpty ? "理解完成 · 没有提取到陈述" : "理解完成 · \(ids.count) 条陈述待核对"
            } catch { status = error.localizedDescription }
            await refresh()
            understandingSource = nil; understandingWorker = nil
        }
    }
    func export(includeMedia: Bool) {
        let panel = NSSavePanel()
        panel.title = includeMedia ? "导出资料与原件" : "导出结构化资料"
        panel.nameFieldStringValue = "VoiceOS-导出-" + ISO8601DateFormatter().string(from: Date()).prefix(10)
        panel.prompt = "导出"
        panel.begin { response in
            guard response == .OK, let url = panel.url, let store = self.store else { return }
            Task {
                do { try await store.exportPackage(to: url, includeMedia: includeMedia); self.status = "已导出资料" + (includeMedia ? "和完整原件" : "；原件未包含，可另选打包") }
                catch { self.status = error.localizedDescription }
            }
        }
    }
    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.title = "导入音频或视频"; panel.prompt = "导入"
        panel.allowedContentTypes = [.audio, .movie]; panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { await self.importFiles(urls) }
        }
    }
    private func importFiles(_ urls: [URL]) async {
        guard let store, !importing else { return }
        importing = true
        defer { importing = false }
        var failures = 0
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            status = "正在保存：\(url.lastPathComponent)"
            do { selected = try await store.importFile(url) }
            catch { failures += 1; status = error.localizedDescription }
            if access { url.stopAccessingSecurityScopedResource() }
            await refresh()
        }
        if failures == 0 { status = "已可靠保存 \(urls.count) 个原件 · 正在本地转写" }
        scheduleProcessing()
        if failures == 0 { status = "导入完成 · 可查看原件和转写状态" }
    }
    private func scheduleProcessing() {
        guard worker == nil else { return }
        // Owned by the application model, not the SwiftUI view task/window lifetime.
        worker = Task {
            await process()
            worker = nil
            if let store, let pending = try? await store.sources(), pending.contains(where: { $0.jobState == "queued" }) {
                scheduleProcessing()
            }
        }
    }
    private func process() async {
        guard let store else { return }
        // Refresh while the durable worker runs; closing the window does not cancel it.
        let refreshTask = Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        defer { refreshTask.cancel() }
        do { try await store.processTranscriptions(using: NativeSpeechPort()) }
        catch { status = error.localizedDescription }
        await refresh()
    }
    func playSpan(_ record: SourceRecord, milliseconds: Int) async {
        do {
            guard let url = try await store?.playableURL(sourceID: record.id) else { return }
            player?.pause()
            let playback = AVPlayer(url: url)
            player = playback
            await playback.seek(to: CMTime(value: Int64(milliseconds), timescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
            playback.play()
        } catch { status = error.localizedDescription; await refresh() }
    }
    func historyFor(_ record: SourceRecord) async {
        do { history = try await store?.transcriptHistory(sourceID: record.id) ?? [] }
        catch { status = error.localizedDescription }
    }
    func correct(_ record: SourceRecord, text: String) async -> Bool {
        guard let store, let version = record.transcriptVersionID else { return false }
        do {
            _ = try await store.correctTranscript(sourceID: record.id, expectedVersionID: version, text: text)
            await refresh(); status = "更正已保存 · 原件和旧逐字稿保留"; return true
        } catch { status = error.localizedDescription; return false }
    }
    func changeTextPolicy(_ record: SourceRecord) async {
        guard let store, !changingPolicy else { return }
        changingPolicy = true
        defer { changingPolicy = false }
        do {
            _ = try await store.setSourceLocalOnly(sourceID: record.id, expectedVersion: record.policyVersion, localOnly: !record.localOnly)
            await refresh(); status = "文本处理权限已更新 · 原始音频仍仅本机"
        } catch { status = error.localizedDescription }
    }
    func play(_ record: SourceRecord) async {
        do { if let url = try await store?.playableURL(sourceID: record.id) { NSWorkspace.shared.open(url) } }
        catch { status = error.localizedDescription; await refresh() }
    }
    func retry(_ record: SourceRecord) async {
        do { try await store?.retryTranscription(sourceID: record.id); await refresh(); scheduleProcessing() }
        catch { status = error.localizedDescription }
    }
}
struct CenterView: View {
    @ObservedObject var model: ControlCenter
    @State private var editing: SourceRecord?
    @State private var showHistory = false
    var body: some View {
        NavigationSplitView {
            List(model.filtered, selection: $model.selected) { record in
                VStack(alignment: .leading, spacing: 5) {
                    Text(record.name).lineLimit(2)
                    Text(label(record)).font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 5).tag(record.id)
            }
            .navigationTitle("资料库")
            .searchable(text: $model.query, prompt: "搜索文件名或逐字稿")
            .overlay { if model.records.isEmpty { ContentUnavailableView("从一段表达开始", systemImage: "waveform", description: Text("导入音频或视频，保存原件并生成本地逐字稿。")) } }
        } detail: {
            if let record = model.records.first(where: { $0.id == model.selected }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(record.name).font(.title2).textSelection(.enabled)
                        HStack { Label(label(record), systemImage: record.state == "saved" ? "checkmark.circle" : "exclamationmark.circle"); Spacer(); Text(record.kind == "video" ? "视频" : "音频") }
                        Text("外部资料 · 说话人待核对 · \(record.localOnly ? "仅本机处理" : "文本可用于云端")").font(.callout).foregroundStyle(.secondary)
                        Button(record.localOnly ? "允许这份资料的文本用于云端" : "将这份资料限制为仅本地") { Task { await model.changeTextPolicy(record) } }.disabled(model.changingPolicy)
                        Text("此选项仅授权文本；点击“理解这份文字”才发送所选文字，原始音频和视频仍仅本机。").font(.caption).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Button(model.understandingSource == record.id ? "正在理解…" : "理解这份文字", systemImage: "sparkles") { model.understand(record) }
                                    .disabled(!model.modelConfigured || record.localOnly || (record.transcript ?? "").isEmpty || model.understandingSource != nil)
                                if model.understandingSource == record.id { ProgressView().controlSize(.small) }
                                Button("配置文本模型…") { model.chooseTextModel() }.disabled(model.understandingSource != nil)
                            }
                            Text(model.modelSummary).font(.caption).foregroundStyle(.secondary)
                            if record.localOnly { Text("允许这份资料的文本用于云端后，可以理解文字。").font(.caption).foregroundStyle(.secondary) }
                            if let attempts = model.attempts[record.id], !attempts.isEmpty {
                                DisclosureGroup("理解调用记录（\(attempts.count)）") {
                                    ForEach(attempts) { attempt in
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(attemptLabel(attempt)).font(.callout)
                                            Text("\(attempt.model) · \(attempt.provider.replacingOccurrences(of: "responses:", with: ""))").font(.caption).foregroundStyle(.secondary)
                                            Text("输入 \(attempt.usage?["input_tokens"].map(String.init) ?? "未知") / 输出 \(attempt.usage?["output_tokens"].map(String.init) ?? "未知") tokens · 实际费用未知").font(.caption).foregroundStyle(.secondary)
                                        }.padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                        }
                        Text("\(String(format: "%.1f", record.duration ?? 0)) 秒 · \(ByteCountFormatter.string(fromByteCount: record.bytes, countStyle: .file))").font(.caption).foregroundStyle(.secondary)
                        if record.state == "saved" { Button("打开保存的原件", systemImage: "play.circle") { Task { await model.play(record) } } }
                        Divider()
                        HStack {
                            Text("逐字稿").font(.headline)
                            Spacer()
                            if record.transcript != nil {
                                Button("更正文字") { editing = record }
                                Button("版本历史") { Task { await model.historyFor(record); showHistory = true } }
                            }
                        }
                        if let transcript = record.transcript {
                            if transcript.isEmpty { Text("本次转写没有返回文字。可以播放原件核对；这不代表音轨没有人声。").foregroundStyle(.secondary) }
                            else { Text(transcript).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                            Text(record.spans.contains(where: { $0.startMS != nil }) ? "Apple 本地转写 · 中文 · 识别时间定位待核对" : "中文逐字稿 · 时间定位未确认").font(.caption).foregroundStyle(.secondary)
                            if !record.spans.isEmpty {
                                DisclosureGroup("来源片段") {
                                    ForEach(record.spans) { span in
                                        VStack(alignment: .leading, spacing: 6) {
                                            if let start = span.startMS, let end = span.endMS, record.state == "saved" {
                                                Button("\(timeLabel(start))—\(timeLabel(end)) · 播放核对", systemImage: "play.circle") { Task { await model.playSpan(record, milliseconds: start) } }
                                            } else { Text("时间未确认").font(.caption).foregroundStyle(.secondary) }
                                            Text(quote(span, text: transcript)).textSelection(.enabled)
                                        }.padding(.vertical, 6)
                                    }
                                }
                            }
                            if let player = model.player { VideoPlayer(player: player).frame(height: record.kind == "video" ? 260 : 80) }
                        } else { Text(transcriptStatus(record)).foregroundStyle(.secondary) }
                        if let error = record.error { Text(error).foregroundStyle(.orange) }
                        let related = model.claims.filter { $0.references.contains(where: { $0.sourceID == record.id }) }
                        if !related.isEmpty {
                            Divider()
                            DisclosureGroup("认知候选与历史（\(related.count)）") {
                                ForEach(related) { claim in
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(claim.statement).textSelection(.enabled)
                                        Text("\(claim.ownership == "ai_candidate" ? "AI 候选" : (claim.ownership == "external" ? "外部主张" : "归属待核对")) · 未验证 · \(claim.validity == "frozen" ? "依据或授权已变化，暂停使用" : "待核对")").font(.caption).foregroundStyle(.secondary)
                                        ForEach(Array(claim.references.enumerated()), id: \.offset) { _, ref in
                                            if ref.sourceID == record.id, ref.transcriptVersionID == record.transcriptVersionID,
                                               let span = record.spans.first(where: { $0.id == ref.spanID }), let text = record.transcript {
                                                Text("依据：" + quote(span, text: text)).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                                            } else if ref.sourceID == record.id {
                                                Button("查看历史逐字稿依据") { Task { await model.historyFor(record); showHistory = true } }
                                            }
                                        }
                                    }.padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        if ["failed", "blocked"].contains(record.jobState ?? ""), record.state == "saved" {
                            Button("重试本地转写") { Task { await model.retry(record) } }
                        }
                        Spacer()
                    }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
                }
            } else { ContentUnavailableView("选择一份资料", systemImage: "doc.text.magnifyingglass", description: Text("原件和逐字稿保存在 VoiceOS 自己的资料库中。")) }
        }
        .toolbar {
            Button("导入文件", systemImage: "square.and.arrow.down") { model.chooseFiles() }.disabled(!model.initialized || model.importing)
            Menu {
                Button("导出结构化资料…") { model.export(includeMedia: false) }
                Button("导出资料与原件…") { model.export(includeMedia: true) }
            } label: { Label("导出资料", systemImage: "square.and.arrow.up") }.disabled(!model.initialized || model.importing)
        }
        .safeAreaInset(edge: .bottom) { HStack { Text(model.status).font(.caption).lineLimit(2); Spacer(); Text("开发预览 · 文本理解与来源核对").font(.caption).foregroundStyle(.secondary) }.padding(10).background(.bar) }
        .sheet(item: $editing) { record in
            TranscriptCorrectionView(record: record, model: model) { editing = nil }
        }
        .sheet(isPresented: $showHistory) {
            VStack(alignment: .leading, spacing: 12) {
                Text("逐字稿版本历史").font(.title2)
                ScrollView {
                    ForEach(model.history) { version in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("第 \(version.number) 版 · \(version.reason == "original" ? "本地识别原稿" : "识别文字更正")\(version.isCurrent ? " · 当前" : " · 历史")").font(.headline)
                            Text(version.text.isEmpty ? "（空文字）" : version.text).textSelection(.enabled)
                            Divider()
                        }
                    }
                }
                HStack { Spacer(); Button("完成") { showHistory = false }.keyboardShortcut(.defaultAction) }
            }.padding(24).frame(width: 660, height: 440)
        }
        .onChange(of: model.selected) { _, _ in model.player?.pause(); model.player = nil }
        .frame(minWidth: 840, minHeight: 540)
        .task { await model.start() }
    }
    private func attemptLabel(_ attempt: ModelAttemptRecord) -> String {
        switch attempt.state {
        case "completed": return attempt.contextState == "stale" ? "已完成 · 依据或授权已变化，保留历史" : "已完成 · 结果待核对"
        case "reserved": return "正在处理；重启后结果可能未知，不自动重发"
        case "unknown": return "结果未知 · 不自动重发"
        default: return "未接纳结果 · 不自动重发"
        }
    }
    private func quote(_ span: TranscriptSpan, text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        guard span.textStart >= 0, span.textEnd >= span.textStart, span.textEnd <= scalars.count else { return "片段定位无效，请检查资料" }
        return String(String.UnicodeScalarView(scalars[span.textStart..<span.textEnd]))
    }
    private func timeLabel(_ ms: Int) -> String { String(format: "%02d:%02d", ms / 60000, (ms / 1000) % 60) }
    private func label(_ record: SourceRecord) -> String {
        switch record.state {
        case "saved": return "原件已保存"
        case "quarantined": return "原件需要检查"
        case "reference_only": return "原件未随包附带"
        case "interrupted": return "保存未完成"
        default: return "正在保存"
        }
    }
    private func transcriptStatus(_ record: SourceRecord) -> String {
        switch record.jobState {
        case "queued": return "等待本地转写"
        case "running": return "正在本地转写…"
        case "failed", "blocked": return "转写暂未完成"
        default: return "完整保存后开始转写"
        }
    }
}
private struct TranscriptCorrectionView: View {
    let record: SourceRecord
    @ObservedObject var model: ControlCenter
    let dismiss: () -> Void
    @State private var text: String
    @State private var saving = false
    init(record: SourceRecord, model: ControlCenter, dismiss: @escaping () -> Void) {
        self.record = record; self.model = model; self.dismiss = dismiss
        _text = State(initialValue: record.transcript ?? "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("更正逐字稿").font(.title2)
            Text("仅更正识别文字；原件和旧逐字稿保留。新文字的时间定位会标为未确认。").foregroundStyle(.secondary)
            TextEditor(text: $text).font(.body).border(.secondary.opacity(0.3))
            HStack {
                Spacer()
                Button("取消", action: dismiss).disabled(saving)
                Button("保存更正") {
                    saving = true
                    Task { let saved = await model.correct(record, text: text); saving = false; if saved { dismiss() } }
                }.keyboardShortcut(.defaultAction).disabled(saving || text == record.transcript)
            }
            Text(model.status).font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 660, height: 440)
    }
}
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
@main
struct VoiceOSApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) var delegate
    @StateObject private var model = ControlCenter()
    var body: some Scene {
        Window("VoiceOS", id: "control-center") { CenterView(model: model) }
        .commands { CommandGroup(after: .newItem) { Button("导入音频或视频…") { model.chooseFiles() }.keyboardShortcut("i").disabled(!model.initialized || model.importing) } }
    }
}
