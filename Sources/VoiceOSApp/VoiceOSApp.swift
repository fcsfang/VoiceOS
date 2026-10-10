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
    @Published var claimHistory: [ClaimReviewVersion] = []
    @Published var reviewingClaim = false
    @Published var actionRecords: [ActionRecord] = []
    @Published var savingAction = false
    @Published var actionVersions: [ActionRevision] = []
    @Published var reminderLinks: [ReminderLink] = []
    @Published var reminderCalendars: [ReminderCalendar] = []
    @Published var reminderCalendarID = ""
    @Published var remindersBusy = false
    @Published var choosingReminderCalendar = false
    private let reminders = NativeReminders()
    var reminderCalendarTitle: String { reminderCalendars.first { $0.id == reminderCalendarID }?.title ?? "未选择清单" }
    func reminderSourceAllowed(_ action: ActionRecord) -> Bool {
        guard let claim = claims.first(where: { $0.id == action.claimID }) else { return false }
        return !claim.references.isEmpty && claim.references.allSatisfy { ref in records.contains { $0.id == ref.sourceID && !$0.localOnly } }
    }
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
            actionRecords = try await store?.actions(includeHistory: true) ?? []
            reminderLinks = try await store?.reminderLinks() ?? []
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
    func review(_ claim: CandidateClaim, action: ClaimReviewAction, statement: String? = nil, ownership: CandidateOwnership? = nil, note: String = "") async -> Bool {
        guard let store, !reviewingClaim else { return false }
        reviewingClaim = true; defer { reviewingClaim = false }
        do {
            _ = try await store.reviewClaim(claimID: claim.id, expectedVersion: claim.reviewVersion, action: action, statement: statement, ownership: ownership, note: note)
            await refresh()
            status = action == .correct ? "认知更正已保存 · 重新待核对，原始结果与历史保留" : (action == .endorse ? "已记录明确认可 · 来源与未验证状态保留" : "已记录拒绝 · 保留历史，停止当前使用")
            return true
        } catch { status = error.localizedDescription; await refresh(); return false }
    }
    func createAction(_ claim: CandidateClaim, title: String, kind: ActionKind, note: String, commandID: String) async -> Bool {
        guard let store, !savingAction else { return false }
        savingAction = true; defer { savingAction = false }
        do {
            _ = try await store.createAction(claimID: claim.id, expectedClaimReviewVersion: claim.reviewVersion, title: title, kind: kind, note: note, commandID: commandID)
            await refresh(); status = "意图已保存到 VoiceOS · 尚未写入提醒事项"; return true
        } catch { status = error.localizedDescription; await refresh(); return false }
    }
    func connectReminders() async {
        guard !remindersBusy else { return }
        remindersBusy = true; defer { remindersBusy = false }
        do {
            reminderCalendars = try await reminders.authorize()
            choosingReminderCalendar = true
            status = "请选择明确授权的清单 · 尚未读取或写入任务"
        } catch { status = error.localizedDescription }
    }
    func sendReminder(_ action: ActionRecord) async {
        guard let store, !remindersBusy, !reminderCalendarID.isEmpty else { return }
        remindersBusy = true; defer { remindersBusy = false }
        do {
            try await store.sendTaskToReminders(actionID: action.id, expectedVersion: action.version, calendarID: reminderCalendarID, using: reminders)
            status = "提醒事项尝试已记录 · 以回读状态为准"
        } catch { status = error.localizedDescription }
        await refresh()
    }
    func readReminder(_ link: ReminderLink) async {
        guard let store, !remindersBusy, reminderCalendarID == link.calendarID else { return }
        remindersBusy = true; defer { remindersBusy = false }
        do {
            try await store.readReminder(linkID: link.id, calendarID: reminderCalendarID, using: reminders)
            status = "已回读关联任务 · 外部改名保留，完成反馈独立记录"
        } catch { status = error.localizedDescription }
        await refresh()
    }
    func actionHistory(_ action: ActionRecord) async {
        do { actionVersions = try await store?.actionHistory(actionID: action.id) ?? [] }
        catch { status = error.localizedDescription }
    }
    func changeAction(_ action: ActionRecord, state: LocalActionState) async {
        guard let store, !savingAction else { return }
        savingAction = true; defer { savingAction = false }
        do {
            _ = try await store.setActionState(actionID: action.id, expectedVersion: action.version, state: state)
            status = "行动状态已保存 · 观点仍需独立验证"
        } catch { status = error.localizedDescription }
        await refresh()
    }
    func reviewHistory(_ claim: CandidateClaim) async {
        do { claimHistory = try await store?.claimReviewHistory(claimID: claim.id) ?? [] }
        catch { status = error.localizedDescription }
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
    @State private var correctingClaim: CandidateClaim?
    @State private var showClaimHistory = false
    @State private var actionClaim: CandidateClaim?
    @State private var showActionHistory = false
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
                                        Text("\(claim.ownership == "ai_candidate" ? "AI 候选" : (claim.ownership == "external" ? "外部主张" : "归属待核对")) · 未验证 · \(claim.validity == "frozen" ? "依据或授权已变化，暂停使用" : (claim.reviewState == "rejected" ? "已停止当前使用" : "出处可回溯"))").font(.caption).foregroundStyle(.secondary)
                                        Text(claim.reviewState == "endorsed" ? "明确认可 · 不等于已验证或已经理解" : (claim.reviewState == "rejected" ? "已拒绝 · 保留历史，不用于当前认知" : "尚未认可")).font(.caption).foregroundStyle(.secondary)
                                        HStack {
                                            Button("我认可这个观点") { Task { _ = await model.review(claim, action: .endorse) } }
                                                .disabled(model.reviewingClaim || claim.validity == "frozen" || claim.reviewState == "endorsed")
                                            Button("拒绝候选") { Task { _ = await model.review(claim, action: .reject) } }
                                                .disabled(model.reviewingClaim || claim.validity == "frozen" || claim.reviewState == "rejected")
                                            Button("更正认知") { correctingClaim = claim }.disabled(model.reviewingClaim || claim.validity == "frozen")
                                            Button("审阅历史") { Task { await model.reviewHistory(claim); showClaimHistory = true } }
                                        }
                                        Button("记录行动意图") { actionClaim = claim }.disabled(claim.validity == "frozen" || claim.reviewState == "rejected")
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
                        let relatedActions = model.actionRecords.filter { action in related.contains { $0.id == action.claimID } }
                        if !relatedActions.isEmpty {
                            DisclosureGroup("行动与机会池（\(relatedActions.count)）") {
                                ForEach(relatedActions) { action in
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(action.title).font(.headline)
                                        Text("\(action.kind == "task" ? "明确任务" : (action.kind == "opportunity" ? "探索意图" : "AI 建议")) · \(action.state == "completed" ? "已完成" : (action.state == "dismissed" ? "暂不跟进" : "待跟进")) · 第 \(action.version) 版").font(.caption)
                                        Text(action.validity == "frozen" ? "认知或授权已变化，暂停使用；历史保留" : "本地意图记录 · 外部同步状态见下方").font(.caption).foregroundStyle(.secondary)
                                        Text("认知依据：第 \(action.claimReviewVersion) 版").font(.caption).foregroundStyle(.secondary)
                                        if !action.note.isEmpty { Text(action.note) }
                                        HStack {
                                            if action.state == "open" {
                                                if action.kind == "task" { Button("标记任务完成") { Task { await model.changeAction(action, state: .completed) } } }
                                                Button("暂不跟进") { Task { await model.changeAction(action, state: .dismissed) } }
                                            } else { Button("重新跟进") { Task { await model.changeAction(action, state: .open) } } }
                                        }.disabled(model.savingAction || action.validity == "frozen")
                                        let link = model.reminderLinks.first { $0.actionID == action.id }
                                        if let link {
                                            Text("提醒事项：" + reminderLabel(link.state)).font(.caption).foregroundStyle(.secondary)
                                            if let title = link.remoteTitle { Text("外部标题：" + title).font(.caption) }
                                            if let at = link.lastObservedAt { Text("最近回读记录：" + at).font(.caption).foregroundStyle(.secondary) }
                                            if let done = link.remoteCompleted { Text(done ? "外部回读：已完成" : "外部回读：未完成").font(.caption) }
                                            Button("回读提醒事项") { Task { await model.readReminder(link) } }.disabled(model.remindersBusy || model.reminderCalendarID != link.calendarID)
                                        } else if action.kind == "task" {
                                            Text("目标清单：" + model.reminderCalendarTitle).font(.caption).foregroundStyle(.secondary)
                                            if !model.reminderSourceAllowed(action) { Text("依据包含仅本地资料，不可外发").font(.caption).foregroundStyle(.secondary) }
                                            Button("发送到所选提醒事项清单") { Task { await model.sendReminder(action) } }
                                                .disabled(model.remindersBusy || model.reminderCalendarID.isEmpty || action.validity == "frozen" || action.state != "open" || !model.reminderSourceAllowed(action))
                                        }
                                        Button("行动历史") { Task { await model.actionHistory(action); showActionHistory = true } }
                                        Divider()
                                    }.padding(.vertical, 8)
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
            Button("连接提醒事项…") { Task { await model.connectReminders() } }.disabled(!model.initialized || model.remindersBusy)
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
        .sheet(isPresented: $model.choosingReminderCalendar) {
            VStack(alignment: .leading, spacing: 16) {
                Text("选择提醒事项清单").font(.title2)
                Text("系统权限覆盖全部提醒事项。VoiceOS 只读写你在这里明确选定清单中的关联任务；选择清单不会发送任务。").foregroundStyle(.secondary)
                Picker("授权清单", selection: $model.reminderCalendarID) {
                    Text("请选择清单").tag("")
                    ForEach(model.reminderCalendars) { calendar in Text(calendar.title).tag(calendar.id) }
                }
                Text("重开应用后需重新选择清单；已有尝试只回读，不自动重建。").font(.caption)
                Button("完成") { model.choosingReminderCalendar = false }
            }.padding(24).frame(width: 600)
        }
        .sheet(isPresented: $showActionHistory) {
            VStack(alignment: .leading, spacing: 16) {
                Text("行动状态历史").font(.title2)
                Text("任务完成不等于观点已验证。").foregroundStyle(.secondary)
                ScrollView {
                    ForEach(model.actionVersions) { version in
                        VStack(alignment: .leading) {
                            Text("第 \(version.version) 版 · \(version.state == "completed" ? "已完成" : (version.state == "dismissed" ? "暂不跟进" : "待跟进"))")
                            if !version.note.isEmpty { Text(version.note) }
                            Text(version.actor == "external" ? "来自提醒事项回读" : "明确本地操作").font(.caption)
                            Text(version.createdAt).font(.caption).foregroundStyle(.secondary)
                            Divider()
                        }
                    }
                }
                Button("完成") { showActionHistory = false }
            }.padding(24).frame(width: 600, height: 380)
        }
        .sheet(item: $actionClaim) { claim in
            ActionCreationView(claim: claim, model: model) { actionClaim = nil }
        }
        .sheet(item: $correctingClaim) { claim in
            ClaimCorrectionView(claim: claim, model: model) { correctingClaim = nil }
        }
        .sheet(isPresented: $showClaimHistory) {
            VStack(alignment: .leading, spacing: 12) {
                Text("认知审阅历史").font(.title2)
                Text("认可不等于已验证；更正不代表真实观点变化。").foregroundStyle(.secondary)
                ScrollView {
                    ForEach(model.claimHistory) { revision in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("第 \(revision.version) 版 · \(reviewReason(revision.reason))").font(.headline)
                            Text(revision.statement).textSelection(.enabled)
                            Text("\(ownershipLabel(revision.ownership)) · \(reviewLabel(revision.decision))").font(.caption).foregroundStyle(.secondary)
                            if !revision.note.isEmpty { Text("原因：" + revision.note).font(.callout) }
                            Divider()
                        }
                    }
                }
                HStack { Spacer(); Button("完成") { showClaimHistory = false }.keyboardShortcut(.defaultAction) }
            }.padding(24).frame(width: 660, height: 440)
        }
        .onChange(of: model.selected) { _, _ in model.player?.pause(); model.player = nil }
        .frame(minWidth: 840, minHeight: 540)
        .task { await model.start() }
    }
    private func reminderLabel(_ state: String) -> String {
        switch state {
        case "linked": return "唯一关联已回读"
        case "missing": return "未找到关联项，不自动重建"
        case "conflict": return "关联或状态冲突，保留双方内容"
        default: return "结果待核对，不自动重发"
        }
    }
    private func ownershipLabel(_ value: String) -> String {
        value == "external" ? "外部主张" : (value == "ai_candidate" ? "AI 候选" : "归属待核对")
    }
    private func reviewLabel(_ value: String) -> String {
        value == "endorsed" ? "明确认可" : (value == "rejected" ? "已拒绝" : "待核对")
    }
    private func reviewReason(_ reason: String) -> String {
        switch reason {
        case "explicit_endorsement": return "明确认可"
        case "explicit_rejection": return "拒绝候选"
        case "correction": return "认知更正"
        default: return "模型原始结果"
        }
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
private struct ClaimCorrectionView: View {
    let claim: CandidateClaim
    @ObservedObject var model: ControlCenter
    let dismiss: () -> Void
    @State private var text: String
    @State private var ownership: String
    @State private var note = ""
    @State private var saving = false
    init(claim: CandidateClaim, model: ControlCenter, dismiss: @escaping () -> Void) {
        self.claim = claim; self.model = model; self.dismiss = dismiss
        _text = State(initialValue: claim.statement); _ownership = State(initialValue: claim.ownership)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("更正认知").font(.title2)
            Text("修正 AI 的表述或归属；更正后重新待核对。原始模型结果、出处和历史保留。").foregroundStyle(.secondary)
            TextEditor(text: $text).font(.body).border(.secondary.opacity(0.3))
            Picker("内容归属", selection: $ownership) {
                Text("外部主张").tag("external"); Text("AI 候选").tag("ai_candidate"); Text("归属待核对").tag("unresolved")
            }
            TextField("更正原因（必填）", text: $note)
            HStack {
                Spacer(); Button("取消", action: dismiss).disabled(saving)
                Button("保存更正") {
                    saving = true
                    Task {
                        let saved = await model.review(claim, action: .correct, statement: text, ownership: CandidateOwnership(rawValue: ownership), note: note)
                        saving = false; if saved { dismiss() }
                    }
                }.keyboardShortcut(.defaultAction).disabled(saving || note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (text == claim.statement && ownership == claim.ownership))
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

struct ActionCreationView: View {
    let claim: CandidateClaim
    @ObservedObject var model: ControlCenter
    let close: () -> Void
    @State private var title = ""
    @State private var kind: ActionKind = .opportunity
    @State private var note = ""
    @State private var commandID = UUID().uuidString
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("记录行动意图").font(.title2)
            Text("认可观点不等于承诺任务。选择明确任务，或先放入机会池；尚未写入提醒事项。").foregroundStyle(.secondary)
            Text("依据：" + claim.statement).lineLimit(4)
            Picker("意图", selection: $kind) {
                Text("探索意图 · 机会池").tag(ActionKind.opportunity)
                Text("明确任务").tag(ActionKind.task)
            }.pickerStyle(.segmented)
            TextField("要做什么", text: $title)
            TextField("补充说明（可选）", text: $note)
            Text(model.status).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("取消", action: close).disabled(model.savingAction)
                Spacer()
                Button("保存意图") { Task { if await model.createAction(claim, title: title, kind: kind, note: note, commandID: commandID) { close() } } }
                    .disabled(model.savingAction || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 600)
    }
}
