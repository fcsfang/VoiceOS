import SwiftUI
import AppKit
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
    @Published var initialized = false
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
            await refresh()
            scheduleProcessing()
        } catch { status = error.localizedDescription }
    }
    func refresh() async {
        do { records = try await store?.sources() ?? [] }
        catch { status = error.localizedDescription }
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
                        Text("外部资料 · 说话人待核对 · 仅本机处理").font(.callout).foregroundStyle(.secondary)
                        Text("\(String(format: "%.1f", record.duration ?? 0)) 秒 · \(ByteCountFormatter.string(fromByteCount: record.bytes, countStyle: .file))").font(.caption).foregroundStyle(.secondary)
                        if record.state == "saved" { Button("打开保存的原件", systemImage: "play.circle") { Task { await model.play(record) } } }
                        Divider()
                        Text("逐字稿").font(.headline)
                        if let transcript = record.transcript {
                            if transcript.isEmpty { Text("本次转写没有返回文字。可以播放原件核对；这不代表音轨没有人声。").foregroundStyle(.secondary) }
                            else { Text(transcript).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                            Text("Apple 本地转写 · 中文 · 尚未人工校对").font(.caption).foregroundStyle(.secondary)
                        } else { Text(transcriptStatus(record)).foregroundStyle(.secondary) }
                        if let error = record.error { Text(error).foregroundStyle(.orange) }
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
        .safeAreaInset(edge: .bottom) { HStack { Text(model.status).font(.caption).lineLimit(2); Spacer(); Text("开发预览 · 文件导入与本地转写").font(.caption).foregroundStyle(.secondary) }.padding(10).background(.bar) }
        .frame(minWidth: 840, minHeight: 540)
        .task { await model.start() }
    }
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
