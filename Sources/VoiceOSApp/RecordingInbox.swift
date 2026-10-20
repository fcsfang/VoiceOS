import SwiftUI
import AppKit
import CryptoKit
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

/// One serial intake while the app is open. Originals are never moved or deleted.
@MainActor
final class RecordingInbox: ObservableObject {
    @Published var folders: [RecordingInboxFolder] = []
    @Published var status = "尚未连接自动入口"
    @Published var folderErrors: [String: String] = [:]
    @Published var activeFolderID: String?
    @Published var voiceMemosNeedsPermission = false
    private let key = "voiceos.recordingInbox.v1"
    private var timer: Timer?
    private var observed: [String: String] = [:]
    private var receipts: Set<String> = []
    private var failures: Set<String> = []
    private var scanning = false
    private var scopedURLs: [URL] = []
    private var canProcess: () -> Bool = { false }
    private var receive: (URL, Bool, String, @escaping (Bool) -> Void) async -> Void = { _, _, _, _ in }
    static var defaultInbox: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("01 Projects/个人播客/VoiceOS收件箱") }
    static var voiceMemosFolder: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Group Containers/group.com.apple.VoiceMemos.shared") }

    func start(canProcess: @escaping () -> Bool, receive: @escaping (URL, Bool, String, @escaping (Bool) -> Void) async -> Void) {
        guard timer == nil else { return }
        self.canProcess = canProcess; self.receive = receive
        if let data = UserDefaults.standard.data(forKey: key), let saved = try? JSONDecoder().decode([RecordingInboxFolder].self, from: data) { folders = saved }
        receipts = Set(UserDefaults.standard.stringArray(forKey: key + ".receipts") ?? [])
        failures = Set(UserDefaults.standard.stringArray(forKey: key + ".failures") ?? [])
        for index in folders.indices {
            if let data = folders[index].bookmark {
                var stale = false
                if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) {
                    folders[index].path = url.path
                    if url.startAccessingSecurityScopedResource() { scopedURLs.append(url) }
                }
            }
        }
        status = folders.isEmpty ? "尚未连接自动入口" : "等待新录音 · 每 10 秒检查一次"
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in Task { await self?.scan() } }
    }
    func addDefaultInbox() {
        do {
            try FileManager.default.createDirectory(at: Self.defaultInbox, withIntermediateDirectories: true)
            try add(Self.defaultInbox, voiceMemos: false)
        } catch { status = error.localizedDescription }
    }
    func chooseFolder(voiceMemos: Bool) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.title = voiceMemos ? "连接 Mac 上同步的语音备忘录" : "选择自动接收录音的文件夹"
        panel.prompt = "连接此文件夹"; panel.directoryURL = voiceMemos ? Self.voiceMemosFolder : Self.defaultInbox
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try add(url, voiceMemos: voiceMemos); voiceMemosNeedsPermission = false
            if voiceMemos, let sample = folders.last?.baseline.keys.sorted().first {
                Task {
                    do {
                        _ = try await VoiceOSPlatform.FullRecordingOrganizer.inspect(URL(fileURLWithPath: sample))
                        status = "语音备忘录已连接，完整音轨可读取 · 等待今后新增或更新的录音"
                    } catch {
                        status = "目录已连接，但音轨读取未完成：" + error.localizedDescription
                    }
                }
            }
        }
        catch { voiceMemosNeedsPermission = voiceMemos; status = "无法读取这个文件夹：" + error.localizedDescription }
    }
    private func add(_ url: URL, voiceMemos: Bool) throws {
        guard !folders.contains(where: { $0.path == url.path }) else { status = "这个入口已经连接"; return }
        let baseline = try files(in: url, voiceMemos: voiceMemos)
        let bookmark = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
        folders.append(.init(path: url.path, voiceMemos: voiceMemos, bookmark: bookmark, baseline: baseline))
        if url.startAccessingSecurityScopedResource() { scopedURLs.append(url) }
        save(); status = "已连接 · 只处理今后新增或更新的录音，已有 \(baseline.count) 份素材留在原处"
    }
    func setEnabled(_ folder: RecordingInboxFolder, _ enabled: Bool) {
        guard let index = folders.firstIndex(where: { $0.id == folder.id }) else { return }
        folders[index].enabled = enabled; save()
        status = enabled ? "已恢复接收新录音" : "已暂停这个入口"
    }
    func retryFailures() { failures = []; save(); status = "将在下一次检查重试未完成的素材" }
    func open(_ folder: RecordingInboxFolder) { NSWorkspace.shared.open(URL(fileURLWithPath: folder.path)) }
    func openPrivacySettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!) }
    private func save() {
        if let data = try? JSONEncoder().encode(folders) { UserDefaults.standard.set(data, forKey: key) }
        UserDefaults.standard.set(Array(receipts), forKey: key + ".receipts")
        UserDefaults.standard.set(Array(failures), forKey: key + ".failures")
    }
    private func files(in directory: URL, voiceMemos: Bool) throws -> [String: String] {
        let directory = voiceMemos && directory.lastPathComponent != "Recordings" ? directory.appendingPathComponent("Recordings") : directory
        // Explicitly check the protected directory: enumeration must not silently look empty.
        _ = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var result: [String: String] = [:]
        let extensions = voiceMemos ? ["m4a", "wav", "caf", "aac"] : ["m4a", "mp3", "wav", "aiff", "aif", "caf", "aac", "flac", "mp4", "mov", "m4v", "mkv"]
        var failure: Error?
        let iterator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles], errorHandler: { _, error in failure = error; return false })
        while let url = iterator?.nextObject() as? URL {
            guard extensions.contains(url.pathExtension.lowercased()) else { continue }
            let value = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard value.isRegularFile == true, let size = value.fileSize, size > 0, let modified = value.contentModificationDate else { continue }
            result[url.path] = "\(size):\(modified.timeIntervalSince1970)"
        }
        if let failure { throw failure }
        return result
    }
    func scan() async {
        guard !scanning, activeFolderID == nil else { return }
        scanning = true; defer { scanning = false }
        var nextObserved: [String: String] = [:]
        for folder in folders where folder.enabled {
            do {
                let found = try files(in: URL(fileURLWithPath: folder.path), voiceMemos: folder.voiceMemos)
                folderErrors[folder.id] = nil
                for path in found.keys.sorted() {
                    let stamp = found[path]!
                    nextObserved[path] = stamp
                    guard folder.baseline[path] != stamp, observed[path] == stamp, canProcess() else { continue }
                    let url = URL(fileURLWithPath: path)
                    let digest = try await Task.detached(priority: .utility) {
                        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
                        var hash = SHA256()
                        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
                        return hash.finalize().map { String(format: "%02x", $0) }.joined()
                    }.value
                    guard canProcess(), folders.first(where: { $0.id == folder.id })?.enabled == true,
                          try files(in: URL(fileURLWithPath: folder.path), voiceMemos: folder.voiceMemos)[path] == stamp else { continue }
                    if receipts.contains(digest) || failures.contains(digest) { continue }
                    activeFolderID = folder.id; status = "正在自动整理：" + url.lastPathComponent
                    observed = nextObserved
                    await receive(url, folder.voiceMemos, digest) { [weak self] success in
                        guard let self else { return }
                        if success { self.receipts.insert(digest) } else { self.failures.insert(digest) }
                        self.activeFolderID = nil; self.save()
                        self.status = success ? "已完成：\(url.lastPathComponent) · 等待下一份录音" : "\(url.lastPathComponent) 未完成；原件保留，可重试"
                    }
                    return
                }
            } catch {
                folderErrors[folder.id] = folder.voiceMemos ? "语音备忘录目录受 macOS 隐私权限保护，尚未接通。请在系统设置中允许 VoiceOS 读取后重试。" : "无法读取文件夹：" + error.localizedDescription
            }
        }
        observed = nextObserved
    }
}

struct RecordingInboxView: View {
    @ObservedObject var inbox: RecordingInbox
    @ObservedObject var model: ControlCenter
    let dismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("自动接收录音").font(.title2)
            Text("将自己的录音放入收件箱，或连接已同步到 Mac 的语音备忘录。VoiceOS 打开且 Mac 唤醒时，自动完成 Qwen 全长转写、观点和任务整理、提醒事项同步。")
            Text("只接收连接后新增或更新的素材；原文件保留。音频在本机处理，文字使用已配置文本模型。多音轨视频默认使用本人音轨 2，请把这一音轨留给麦克风。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("启用 VoiceOS收件箱") { inbox.addDefaultInbox() }
                Button("其他文件夹…") { inbox.chooseFolder(voiceMemos: false) }
                Button("连接语音备忘录…") { inbox.chooseFolder(voiceMemos: true) }
            }.disabled(!model.modelConfigured)
            ForEach(inbox.folders) { folder in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Toggle(folder.voiceMemos ? "语音备忘录" : URL(fileURLWithPath: folder.path).lastPathComponent,
                               isOn: Binding(get: { inbox.folders.first(where: { $0.id == folder.id })?.enabled ?? false }, set: { inbox.setEnabled(folder, $0) }))
                        Spacer(); Button("打开文件夹") { inbox.open(folder) }
                    }
                    Text(folder.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if let error = inbox.folderErrors[folder.id] { Text(error).font(.callout).foregroundStyle(.orange) }
                }
            }
            Text(inbox.status).font(.callout).textSelection(.enabled)
            if model.fullRecordingBusy { ProgressView(model.fullRecordingStatus).font(.caption) }
            HStack {
                Button("检查新素材") { Task { await inbox.scan() } }
                Button("重试未完成素材") { inbox.retryFailures() }
                if inbox.voiceMemosNeedsPermission || inbox.folderErrors.values.contains(where: { $0.contains("隐私") }) { Button("打开系统隐私设置") { inbox.openPrivacySettings() } }
                Spacer(); Button("完成", action: dismiss).keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 700)
    }
}
