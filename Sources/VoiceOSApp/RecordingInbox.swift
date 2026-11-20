import SwiftUI
import AppKit
import CryptoKit
import Darwin
import VoiceOSCore
import VoiceOSPlatform

struct RecordingInboxFolder: Codable, Identifiable {
    var id = UUID().uuidString
    var path: String
    var voiceMemos: Bool
    var enabled = true
    var bookmark: Data?
    var baseline: [String: String]
}

struct RecordingInboxInput {
    let url: URL
    let voiceMemos: Bool
    let digest: String
    let inbox: String
}

enum RecordingInboxOutcome {
    case completed
    case retryableFailure(String)
    case needsAttention(String)
}

struct RecordingInboxItem: Codable, Identifiable {
    enum State: String, Codable { case processing, retryScheduled, needsAttention }
    var id: String // Content hash is also the organizer import identity.
    var folderID: String
    var path: String
    var state: State
    var attempts: Int
    var nextAttempt: Date?
    var explanation: String
    var updatedAt: Date
    var fileStamp: String?
}

/// One serial intake while the app is open. Originals are never moved or deleted.
@MainActor
final class RecordingInbox: ObservableObject {
    @Published var folders: [RecordingInboxFolder] = []
    @Published var status = "尚未连接自动入口"
    @Published var folderErrors: [String: String] = [:]
    @Published var activeFolderID: String?
    @Published var voiceMemosNeedsPermission = false
    @Published private(set) var pendingItems: [RecordingInboxItem] = []
    private let key = "voiceos.recordingInbox.v1"
    private let defaults: UserDefaults
    private let retryDelays: [TimeInterval]
    private let now: () -> Date
    private var items: [String: RecordingInboxItem] = [:]
    private var wakeObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var timer: Timer?
    private var started = false
    private var watchers: [String: RecordingInboxDirectoryWatch] = [:]
    private var rescanTask: Task<Void, Never>?
    private var rescanRequested = false
    private var rescanDelay: TimeInterval = 0
    private var scheduledScanDelay: TimeInterval?
    private var observed: [String: String] = [:]
    private var contentDigests: [String: (stamp: String, digest: String)] = [:]
    private var receipts: Set<String> = []
    private var failures: Set<String> = []
    @Published private(set) var scanning = false
    private var scopedURLs: [URL] = []
    private var canProcess: () -> Bool = { false }
    private var resumeSaved: () async -> Void = {}
    private var receive: ([RecordingInboxInput], @escaping ([String:RecordingInboxOutcome]) -> Void) async -> Void = { _, _ in }
    static var defaultInbox: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("01 Projects/个人播客/VoiceOS收件箱") }
    static var voiceMemosFolder: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Group Containers/group.com.apple.VoiceMemos.shared") }

    init(defaults: UserDefaults = .standard, retryDelays: [TimeInterval] = [60, 300], now: @escaping () -> Date = Date.init) {
        self.defaults = defaults; self.retryDelays = retryDelays; self.now = now
    }
    convenience init(libraryRoot:URL?) {
        if let libraryRoot {
            let identity=SHA256.hash(data:Data(libraryRoot.standardizedFileURL.path.utf8)).map { String(format:"%02x",$0) }.joined()
            self.init(defaults:UserDefaults(suiteName:"voiceos.recordingInbox.library."+identity) ?? .standard)
        } else { self.init() }
    }

    func start(canProcess: @escaping () -> Bool, resumeSaved: @escaping () async -> Void, receive: @escaping ([RecordingInboxInput], @escaping ([String:RecordingInboxOutcome]) -> Void) async -> Void) {
        guard !started else { return }
        started = true
        self.canProcess = canProcess; self.resumeSaved = resumeSaved; self.receive = receive
        if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode([RecordingInboxFolder].self, from: data) { folders = saved }
        receipts = Set(defaults.stringArray(forKey: key + ".receipts") ?? [])
        failures = Set(defaults.stringArray(forKey: key + ".failures") ?? [])
        if let data = defaults.data(forKey: key + ".pending"), let saved = try? JSONDecoder().decode([RecordingInboxItem].self, from: data) {
            items = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        }
        for id in Array(items.keys) where items[id]?.state == .processing {
            finish(id, outcome: .retryableFailure("上次整理被中断；将继续同一份素材"))
        }
        for index in folders.indices {
            if let data = folders[index].bookmark {
                var stale = false
                if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) {
                    folders[index].path = url.path
                    if url.startAccessingSecurityScopedResource() { scopedURLs.append(url) }
                }
            }
        }
        publishItems()
        status = folders.isEmpty ? "尚未连接自动入口" : (pendingItems.isEmpty ? "等待新录音 · 有新文件时自动检查" : "已恢复 \(pendingItems.count) 份未完成素材 · 同时接收新录音")
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.scan() }
        }
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.scan() }
        }
        refreshWatchers()
        Task { await scan() }
    }

    func stop() {
        started = false
        timer?.invalidate(); timer = nil
        for watch in watchers.values { watch.cancel() }
        watchers = [:]
        rescanTask?.cancel(); rescanTask = nil; rescanRequested = false; rescanDelay = 0; scheduledScanDelay = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        wakeObserver = nil; activationObserver = nil
        for url in scopedURLs { url.stopAccessingSecurityScopedResource() }
        scopedURLs = []
    }
    private func refreshWatchers() {
        guard started else { return }
        for watch in watchers.values { watch.cancel() }
        watchers = [:]
        var fallbackNeeded = false
        for folder in folders where folder.enabled {
            let directory = Self.watchedDirectory(folder)
            if let watch = RecordingInboxDirectoryWatch(directory: directory, onChange: { [weak self] in self?.requestScan(after: 0.3) }) {
                watchers[folder.id] = watch
            } else {
                fallbackNeeded = true
            }
        }
        if fallbackNeeded { installPollingFallback() } else { removePollingFallback() }
    }
    private static func watchedDirectory(_ folder: RecordingInboxFolder) -> URL {
        let url = URL(fileURLWithPath: folder.path)
        return folder.voiceMemos && url.lastPathComponent != "Recordings" ? url.appendingPathComponent("Recordings") : url
    }
    private func installPollingFallback() {
        guard timer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refreshWatchers()
                await self.scan()
            }
        }
        timer.tolerance = 2
        self.timer = timer
    }
    private func removePollingFallback() {
        timer?.invalidate(); timer = nil
    }
    private func requestScan(after delay: TimeInterval) {
        rescanRequested = true
        scheduleScan(after: delay)
    }
    private func scheduleScan(after delay: TimeInterval) {
        rescanTask?.cancel()
        scheduledScanDelay = delay
        rescanTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.rescanTask = nil
            self.scheduledScanDelay = nil
            await self.scan()
        }
    }
    private func scheduleFollowUp(unstable: Bool, blocked: Bool) {
        if rescanRequested { scheduleScan(after: 0.5); return }
        let followUp = RecordingInboxScanPacing.FollowUp(
            unstable: unstable,
            blocked: blocked,
            nextAttempt: items.values.compactMap(\.nextAttempt).filter { $0 > now() }.min())
        guard let delay = RecordingInboxScanPacing.delay(for: followUp, after: rescanDelay, now: now()) else {
            rescanDelay = 0
            return
        }
        rescanDelay = unstable ? delay : 0
        scheduleScan(after: delay)
    }
    /// finish() sets nextAttempt long after the batch scan already returned, so a retry needs
    /// its own one-shot wake; otherwise the event-driven inbox would stay idle past the due time.
    private func scheduleRetryWake() {
        guard started else { return }
        let next = items.values.compactMap(\.nextAttempt).filter { $0 > now() }.min()
        guard let delay = RecordingInboxScanPacing.retryWakeDelay(nextAttempt: next, pendingScanDelay: scheduledScanDelay, now: now()) else { return }
        scheduleScan(after: delay)
    }

    func addDefaultInbox() {
        Task {
            do {
                try FileManager.default.createDirectory(at: Self.defaultInbox, withIntermediateDirectories: true)
                try await add(Self.defaultInbox, voiceMemos: false)
            } catch { status = error.localizedDescription }
        }
    }
    func chooseFolder(voiceMemos: Bool) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.title = voiceMemos ? "连接 Mac 上同步的语音备忘录" : "选择自动接收录音的文件夹"
        panel.prompt = "连接此文件夹"; panel.directoryURL = voiceMemos ? Self.voiceMemosFolder : Self.defaultInbox
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await add(url, voiceMemos: voiceMemos); voiceMemosNeedsPermission = false
                if voiceMemos, let sample = folders.first(where: { $0.path == url.path })?.baseline.keys.sorted().first {
                    do {
                        _ = try await VoiceOSPlatform.FullRecordingOrganizer.inspect(URL(fileURLWithPath: sample))
                        status = "语音备忘录已连接，完整音轨可读取 · 等待今后新增或更新的录音"
                    } catch {
                        status = "目录已连接，但音轨读取未完成：" + error.localizedDescription
                    }
                }
            } catch { voiceMemosNeedsPermission = voiceMemos; status = "无法读取这个文件夹：" + error.localizedDescription }
        }
    }
    private func add(_ url: URL, voiceMemos: Bool) async throws {
        guard !folders.contains(where: { $0.path == url.path }) else { status = "这个入口已经连接"; return }
        status = "正在读取录音入口，可以继续使用其他页面…"
        let baseline = try await Self.readFiles(in: url, voiceMemos: voiceMemos)
        guard !folders.contains(where: { $0.path == url.path }) else { status = "这个入口已经连接"; return }
        let bookmark = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
        folders.append(.init(path: url.path, voiceMemos: voiceMemos, bookmark: bookmark, baseline: baseline))
        if url.startAccessingSecurityScopedResource() { scopedURLs.append(url) }
        save(); refreshWatchers(); status = "已连接 · 只处理今后新增或更新的录音，已有 \(baseline.count) 份素材留在原处"
        // A file landing between the baseline read and watcher installation would otherwise wait
        // for an external event; one scan right after wiring the watcher closes that gap.
        requestScan(after: 0.3)
    }
    func setEnabled(_ folder: RecordingInboxFolder, _ enabled: Bool) {
        guard let index = folders.firstIndex(where: { $0.id == folder.id }) else { return }
        folders[index].enabled = enabled; save(); refreshWatchers()
        status = enabled ? "已恢复接收新录音" : "已暂停这个入口"
        if enabled { requestScan(after: 0.3) }
    }
    func removeFolder(_ folder: RecordingInboxFolder) {
        guard let index = folders.firstIndex(where: { $0.id == folder.id }) else { return }
        let removed = folders.remove(at: index)
        let removedPath = URL(fileURLWithPath: removed.path).standardizedFileURL.path
        for url in scopedURLs where url.standardizedFileURL.path == removedPath {
            url.stopAccessingSecurityScopedResource()
        }
        scopedURLs.removeAll { $0.standardizedFileURL.path == removedPath }
        items = items.filter { $0.value.folderID != removed.id }
        folderErrors[removed.id] = nil
        if activeFolderID == removed.id { activeFolderID = nil }
        status = "已移除入口：\(removed.voiceMemos ? "语音备忘录" : URL(fileURLWithPath: removed.path).lastPathComponent) · 原文件保留在原处"
        save(); refreshWatchers()
    }
    func retryFailures() {
        failures = []
        for id in Array(items.keys) where items[id]?.state != .processing {
            items[id]?.state = .retryScheduled; items[id]?.attempts = 0
            items[id]?.nextAttempt = now(); items[id]?.explanation = "已请求手动重试"
        }
        save(); status = "将在下一次检查重试未完成的素材"
        Task { await scan() }
    }
    func retry(_ id: String) {
        guard var item = items[id], item.state != .processing else { return }
        failures.remove(id)
        item.state = .retryScheduled; item.attempts = 0
        item.nextAttempt = now(); item.explanation = "已请求重试；复用已保存的音轨和转写进度"
        items[id] = item
        save(); Task { await scan() }
    }
    private func publishItems() {
        pendingItems = items.values.sorted { $0.updatedAt > $1.updatedAt }
    }
    func acknowledgeCompleted(_ id:String) {
        guard let item=items[id],item.state != .processing else { return }
        finish(id,outcome:.completed)
    }
    func ignore(_ id: String) {
        guard let item = items[id], item.state != .processing else { return }
        recordProcessed(item)
        status = "不再处理：\(URL(fileURLWithPath: item.path).lastPathComponent) · 原件保留在原处"
        save()
    }
    private func recordProcessed(_ item: RecordingInboxItem) {
        receipts.insert(item.id); failures.remove(item.id); items[item.id] = nil
        if let stamp = item.fileStamp, let index = folders.firstIndex(where: { $0.id == item.folderID }) {
            folders[index].baseline[item.path] = stamp
        }
    }
    private func finish(_ id: String, outcome: RecordingInboxOutcome) {
        guard var item = items[id] else { return }
        item.updatedAt = now(); item.nextAttempt = nil
        switch outcome {
        case .completed:
            recordProcessed(item)
            status = "已完成：\(URL(fileURLWithPath: item.path).lastPathComponent) · 等待下一份录音"
        case .retryableFailure(let explanation):
            item.explanation = explanation
            if item.attempts > 0, item.attempts <= retryDelays.count {
                item.state = .retryScheduled
                item.nextAttempt = now().addingTimeInterval(retryDelays[item.attempts - 1])
                status = "整理暂未完成，将有限自动重试；原件保留"
            } else {
                item.state = .needsAttention; failures.insert(id)
                status = "自动重试仍未完成；原件保留，请查看原因后手动重试"
            }
            items[id] = item
        case .needsAttention(let explanation):
            item.state = .needsAttention; item.explanation = explanation
            failures.insert(id); items[id] = item
            status = "素材需要处理后再重试；原件保留"
        }
        activeFolderID = nil; save()
        scheduleRetryWake()
    }
    func open(_ folder: RecordingInboxFolder) { NSWorkspace.shared.open(URL(fileURLWithPath: folder.path)) }
    func openPrivacySettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!) }
    private func save() {
        if let data = try? JSONEncoder().encode(folders) { defaults.set(data, forKey: key) }
        defaults.set(Array(receipts), forKey: key + ".receipts")
        defaults.set(Array(failures), forKey: key + ".failures")
        if let data = try? JSONEncoder().encode(Array(items.values)) { defaults.set(data, forKey: key + ".pending") }
        publishItems()
    }
    nonisolated private static func readFiles(in directory: URL, voiceMemos: Bool) async throws -> [String: String] {
        try await Task.detached(priority: .utility) { try files(in: directory, voiceMemos: voiceMemos) }.value
    }
    nonisolated private static func files(in directory: URL, voiceMemos: Bool) throws -> [String: String] {
        let directory = voiceMemos && directory.lastPathComponent != "Recordings" ? directory.appendingPathComponent("Recordings") : directory
        // Explicitly check the protected directory: enumeration must not silently look empty.
        _ = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var result: [String: String] = [:]
        let extensions = voiceMemos ? ["m4a", "wav", "caf", "aac"] : ["m4a", "mp3", "wav", "aiff", "aif", "caf", "aac", "flac", "mp4", "mov", "m4v", "mkv"]
        var failure: Error?
        let iterator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles], errorHandler: { _, error in failure = error; return false })
        while let url = iterator?.nextObject() as? URL {
            // Voice Memos creates composedAsset previews inside subdirectories.
            // Only its original recording files at this level are input material.
            if voiceMemos && url.deletingLastPathComponent().standardizedFileURL != directory.standardizedFileURL { continue }
            guard extensions.contains(url.pathExtension.lowercased()) else { continue }
            let value = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard value.isRegularFile == true, let size = value.fileSize, size > 0, let modified = value.contentModificationDate else { continue }
            result[url.path] = "\(size):\(modified.timeIntervalSince1970)"
        }
        if let failure { throw failure }
        return result
    }
    func scan() async {
        guard !scanning else { rescanRequested = true; return }
        guard activeFolderID == nil else { requestScan(after: 10); return }
        rescanTask?.cancel(); rescanTask = nil
        scheduledScanDelay = nil
        rescanRequested = false
        scanning = true; defer { scanning = false }
        var unstable = false
        var blocked = false
        if canProcess() { await resumeSaved() }
        var nextObserved: [String: String] = [:]
        var batch: [RecordingInboxInput] = []
        for folder in folders where folder.enabled {
            do {
                let found = try await Self.readFiles(in: URL(fileURLWithPath: folder.path), voiceMemos: folder.voiceMemos)
                let canProcessNow = canProcess()
                guard folders.contains(where: { $0.id == folder.id && $0.enabled && $0.path == folder.path }) else { continue }
                if folderErrors[folder.id] != nil { folderErrors[folder.id] = nil }
                for path in found.keys.sorted() {
                    let stamp = found[path]!
                    nextObserved[path] = stamp
                    guard folder.baseline[path] != stamp else { continue }
                    guard observed[path] == stamp else { unstable = true; continue }
                    guard canProcessNow else { blocked = true; continue }
                    let url = URL(fileURLWithPath: path)
                    let digest: String
                    if let pending = items.values.first(where: { $0.folderID == folder.id && $0.path == path && $0.fileStamp == stamp }) {
                        // This file was already hashed when its durable intake was saved.
                        digest = pending.id
                    } else if let cached = contentDigests[path], cached.stamp == stamp { digest = cached.digest }
                    else { digest = try await Task.detached(priority: .utility) {
                        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
                        var hash = SHA256()
                        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
                        return hash.finalize().map { String(format: "%02x", $0) }.joined()
                    }.value
                        contentDigests[path] = (stamp, digest)
                    }
                    let currentFiles = try await Self.readFiles(in: URL(fileURLWithPath: folder.path), voiceMemos: folder.voiceMemos)
                    guard canProcess(), folders.contains(where: { $0.id == folder.id && $0.enabled && $0.path == folder.path }), currentFiles[path] == stamp else { continue }
                    if receipts.contains(digest) {
                        if let index = folders.firstIndex(where: { $0.id == folder.id }) {
                            folders[index].baseline[path] = stamp; save()
                        }
                        continue
                    }
                    if failures.contains(digest) {
                        if items[digest] == nil {
                            items[digest] = .init(id: digest, folderID: folder.id, path: path, state: .needsAttention, attempts: 0, explanation: "上次整理未完成，请手动重试", updatedAt: now())
                            save()
                        }
                        continue
                    }
                    if let pending = items[digest], pending.state == .needsAttention || (pending.nextAttempt ?? .distantPast) > now() { continue }
                    let attempt = (items[digest]?.attempts ?? 0) + 1
                    items[digest] = .init(id: digest, folderID: folder.id, path: path, state: .processing, attempts: attempt, explanation: "正在整理", updatedAt: now(), fileStamp: stamp)
                    batch.append(.init(url:url,voiceMemos:folder.voiceMemos,digest:digest,inbox:folder.path))
                }
            } catch {
                guard folders.contains(where: { $0.id == folder.id && $0.enabled && $0.path == folder.path }) else { continue }
                let message = folder.voiceMemos ? "语音备忘录目录受 macOS 隐私权限保护，尚未接通。请在系统设置中允许 VoiceOS 读取后重试。" : "无法读取文件夹：" + error.localizedDescription
                if folderErrors[folder.id] != message { folderErrors[folder.id] = message }
            }
        }
        observed = nextObserved
        guard !batch.isEmpty else { scheduleFollowUp(unstable: unstable, blocked: blocked); return }
        activeFolderID = items[batch[0].digest]?.folderID
        status = "正在转写并判断 \(batch.count) 段录音的连续表达"
        save()
        let selected = batch
        await receive(selected) { [weak self] outcomes in
            guard let self else { return }
            for entry in selected { self.finish(entry.digest,outcome:outcomes[entry.digest] ?? .needsAttention("本段整理没有完成回执，原件保留")) }
        }
        scheduleFollowUp(unstable: unstable, blocked: blocked)
    }
}

@MainActor
private final class RecordingInboxDirectoryWatch {
    private var source: DispatchSourceFileSystemObject?
    private var onChange: (() -> Void)?

    init?(directory: URL, onChange: @escaping () -> Void) {
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        self.onChange = onChange
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .extend], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.onChange?() }
        }
        source.setCancelHandler { _ = close(descriptor) }
        self.source = source
        source.resume()
    }

    func cancel() {
        source?.cancel()
        source = nil
        onChange = nil
    }
}

struct RecordingInboxView: View {
    @Environment(\.workspacePalette) private var palette
    @ObservedObject var inbox: RecordingInbox
    @ObservedObject var model: ControlCenter
    var embedded = false
    let dismiss: () -> Void
    @State private var folderPendingRemoval: RecordingInboxFolder?
    @State private var itemPendingIgnore: RecordingInboxItem?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WorkspaceHeading(eyebrow: "工具 · 收件箱", title: "自动接收录音",
                             subtitle: "将自己的录音放入收件箱，或连接已同步到 Mac 的语音备忘录。")
            Text("VoiceOS 打开且 Mac 唤醒时，自动完成 Qwen 全长转写，由 AI 识别连续表达并合并理解，再整理观点、任务和提醒事项。").vosFont(WorkspaceText.body)
            Text("只接收连接后新增或更新的素材；原文件保留。有变化时立即检查，文件连续两次检查不变后自动处理。同批录音先转写再判断分组；稍后到达的补录自动接续。音频在本机处理，文字使用已配置文本模型。")
                .vosFont(WorkspaceText.body).foregroundStyle(palette.secondaryText)
            Text(RecordingMediaInfo.personalRecordingLayout).vosFont(WorkspaceText.body).foregroundStyle(palette.secondaryText)
            HStack {
                Button("启用 VoiceOS收件箱") { inbox.addDefaultInbox() }.buttonStyle(.workspacePrimary)
                Button("其他文件夹…") { inbox.chooseFolder(voiceMemos: false) }.buttonStyle(.workspaceSecondary)
                Button("连接语音备忘录…") { inbox.chooseFolder(voiceMemos: true) }.buttonStyle(.workspaceSecondary)
            }
            if !inbox.folders.isEmpty && (!model.speechConfigured || !model.textModelConfigured) {
                Text("已连接；配置模型后开始处理新录音").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                HStack {
                    if !model.speechConfigured { Button("配置本地 Qwen 转写…") { model.chooseLocalSpeech() }.buttonStyle(.workspaceSecondaryCompact) }
                    if !model.textModelConfigured { Button("配置文本模型…") { model.chooseTextModel() }.buttonStyle(.workspaceSecondaryCompact) }
                }
            }
            ForEach(inbox.folders) { folder in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Toggle(folder.voiceMemos ? "语音备忘录" : URL(fileURLWithPath: folder.path).lastPathComponent,
                               isOn: Binding(get: { inbox.folders.first(where: { $0.id == folder.id })?.enabled ?? false }, set: { inbox.setEnabled(folder, $0) }))
                        Spacer()
                        Button("打开文件夹") { inbox.open(folder) }.buttonStyle(.workspaceSecondaryCompact)
                        Button("移除入口", role: .destructive) { folderPendingRemoval = folder }.buttonStyle(.workspaceDestructive)
                    }
                    Text(folder.path).vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText).textSelection(.enabled)
                    if let error = inbox.folderErrors[folder.id] { WorkspaceNoticeText(message: error) }
                }
            }
            .alert("移除这个自动入口？", isPresented: Binding(get: { folderPendingRemoval != nil }, set: { if !$0 { folderPendingRemoval = nil } }), presenting: folderPendingRemoval) { folder in
                Button("移除入口", role: .destructive) { inbox.removeFolder(folder); folderPendingRemoval = nil }
                Button("保留", role: .cancel) { folderPendingRemoval = nil }
            } message: { _ in
                Text("移除入口不会删除原文件，只是不再自动接收这个文件夹的新录音。")
            }
            Text(inbox.status).vosFont(WorkspaceText.meta).textSelection(.enabled)
            if !inbox.pendingItems.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(inbox.pendingItems) { item in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(URL(fileURLWithPath: item.path).lastPathComponent).vosFont(WorkspaceText.rowTitle).lineLimit(1)
                                if item.state == .processing {
                                    WorkspaceBadge(text: "正在整理 · 第 \(item.attempts) 次尝试", tone: .accent)
                                } else if let next = item.nextAttempt {
                                    WorkspaceBadge(text: "将在 \(next.formatted(date: .abbreviated, time: .standard)) 自动重试 · 已尝试 \(item.attempts) 次")
                                } else {
                                    WorkspaceBadge(text: "等待手动重试 · 已尝试 \(item.attempts) 次", tone: .warning)
                                }
                                Text(item.explanation).foregroundStyle(palette.secondaryText).textSelection(.enabled)
                                if item.state != .processing {
                                    HStack(spacing: 8) {
                                        Button("重试这份素材") { inbox.retry(item.id) }.buttonStyle(.workspaceSecondaryCompact)
                                        Button("不再处理这份素材", role: .destructive) { itemPendingIgnore = item }.buttonStyle(.workspaceDestructive)
                                    }
                                }
                                if inbox.folders.first(where: { $0.id == item.folderID })?.enabled == false {
                                    Text("入口已暂停，恢复前不会自动重试").foregroundStyle(palette.secondaryText)
                                }
                            }.vosFont(WorkspaceText.meta)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .alert("不再处理这份素材？", isPresented: Binding(get: { itemPendingIgnore != nil }, set: { if !$0 { itemPendingIgnore = nil } }), presenting: itemPendingIgnore) { item in
                    Button("不再处理", role: .destructive) { inbox.ignore(item.id); itemPendingIgnore = nil }
                    Button("保留", role: .cancel) { itemPendingIgnore = nil }
                } message: { item in
                    Text("“\(URL(fileURLWithPath: item.path).lastPathComponent)”不会再自动处理；原件保留在原处。")
                }
                .frame(maxHeight: 150)
            }
            if model.fullRecordingBusy { ProgressView(model.fullRecordingStatus).vosFont(WorkspaceText.meta) }
            HStack {
                Button("检查新素材") { Task { await inbox.scan() } }.buttonStyle(.workspaceSecondary).disabled(inbox.scanning)
                Button("重试未完成素材") { inbox.retryFailures() }.buttonStyle(.workspaceSecondary).disabled(inbox.scanning)
                if inbox.scanning {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("正在检查新素材…").vosFont(WorkspaceText.meta).foregroundStyle(palette.secondaryText)
                    }
                }
                if inbox.voiceMemosNeedsPermission || inbox.folderErrors.values.contains(where: { $0.contains("隐私") }) { Button("打开系统隐私设置") { inbox.openPrivacySettings() }.buttonStyle(.workspaceSecondary) }
                Spacer(); if !embedded { Button("完成", action: dismiss).buttonStyle(.workspaceSecondary).keyboardShortcut(.cancelAction) }
            }
        }.padding(24).frame(width: embedded ? nil : 700)
    }
}
