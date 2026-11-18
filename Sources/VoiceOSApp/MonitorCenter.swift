import AppKit
import Foundation
import VoiceOSCore
import VoiceOSPlatform

private enum MonitorDateFormatting {
    static let iso8601 = ISO8601DateFormatter()
}

struct MonitorSettings: Codable, Equatable {
    var hour: Int = 9
    var minute: Int = 0
    var cloudAnalysisAuthorized: Bool = false
    var pushChannel: MonitorPushChannel?
    var scheduleSettings: MonitorScheduleSettings { .init(hour: hour, minute: minute) }
}

enum MonitorSettingsStore {
    private static let key = "voiceos.monitor.settings.v1"
    static func load() -> MonitorSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(MonitorSettings.self, from: data) else {
            return MonitorSettings()
        }
        return settings
    }
    static func save(_ settings: MonitorSettings) {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: key) }
    }
}

/// Paths and the account name are not secrets; the key file content never
/// leaves disk and only its path is stored here.
struct MonitorQQUserSettings: Codable, Equatable {
    var pythonPath: String = ""
    var keyPath: String = ""
    var account: String = ""
    var scriptPathOverride: String = ""
}

enum MonitorQQSettingsStore {
    private static let key = "voiceos.monitor.qq.settings.v1"
    static func load() -> MonitorQQUserSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(MonitorQQUserSettings.self, from: data) else {
            return MonitorQQUserSettings()
        }
        return settings
    }
    static func save(_ settings: MonitorQQUserSettings) {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: key) }
    }
    static func resolvedPythonPath(_ settings: MonitorQQUserSettings) -> String {
        let trimmed = settings.pythonPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        for path in ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        where FileManager.default.isExecutableFile(atPath: path) { return path }
        return "/usr/bin/python3"
    }
    static func resolvedScriptPath(_ settings: MonitorQQUserSettings) -> String {
        let override = settings.scriptPathOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty { return override }
        let fileManager = FileManager.default
        if let resource = Bundle.main.resourceURL?.appendingPathComponent("qqmonitor/qq_read_range.py").path,
           fileManager.fileExists(atPath: resource) { return resource }
        var directory = Bundle.main.bundleURL
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent("scripts/qqmonitor/qq_read_range.py").path
            if fileManager.fileExists(atPath: candidate) { return candidate }
            directory.deleteLastPathComponent()
        }
        let current = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("scripts/qqmonitor/qq_read_range.py").path
        if fileManager.fileExists(atPath: current) { return current }
        return Bundle.main.resourceURL?.appendingPathComponent("qqmonitor/qq_read_range.py").path
            ?? "scripts/qqmonitor/qq_read_range.py"
    }
    static func cacheDirectory() -> String {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("VoiceOS/MonitorQQ", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return directory.path
    }
    static func qqSettings(_ settings: MonitorQQUserSettings) -> QQMonitorSettings {
        let account = settings.account.trimmingCharacters(in: .whitespacesAndNewlines)
        return QQMonitorSettings(pythonPath: resolvedPythonPath(settings),
                                 scriptPath: resolvedScriptPath(settings),
                                 keyPath: settings.keyPath.trimmingCharacters(in: .whitespacesAndNewlines),
                                 cacheDir: cacheDirectory(),
                                 account: account.isEmpty ? nil : account)
    }
}

struct MonitorSourceStat: Equatable {
    let lastSuccessAt: String?
    let lastError: String?
    let messageCount: Int
    let latestMessageAt: String?
}

struct MonitorItemEvidence: Identifiable, Equatable {
    let id: String
    let sourceName: String
    let sourceKind: MonitorSourceKind?
    let kind: MonitorMessageKind?
    let sender: String?
    let sentAt: String?
    let url: String?
    let title: String?
    let excerpt: String
    let replyQuote: String?
    let missing: Bool

    init(_ record: MonitorEvidenceRecord) {
        id = record.id
        sourceName = record.sourceName
        sourceKind = record.sourceKind
        kind = record.kind
        sender = record.sender
        sentAt = record.sentAt
        url = record.url
        title = record.title
        excerpt = record.excerpt
        replyQuote = record.replyQuote
        missing = record.missing
    }
}

struct MonitorBuiltinWebsite: Identifiable, Equatable {
    let name: String
    let url: String
    var id: String { url }
}

extension ControlCenter {
    static let monitorBuiltinWebsites: [MonitorBuiltinWebsite] = [
        MonitorBuiltinWebsite(name: "计算机学院通知", url: "https://cs.nuaa.edu.cn/10851/list.htm"),
        MonitorBuiltinWebsite(name: "研究生院通知", url: "https://www.graduate.nuaa.edu.cn/2145/list.htm")
    ]

    var monitorLatestReport: MonitorReport? { monitorReports.first }

    /// Every refresh path shares one reload; overlapping calls run one more round
    /// instead of each re-reading the store.
    func reloadMonitorState(forceItems: Bool = false) async {
        monitorReloadPending = true
        monitorReloadForceItems = monitorReloadForceItems || forceItems
        if let monitorReloadWorker { await monitorReloadWorker.value; return }
        let worker = Task { @MainActor [weak self] in
            defer { self?.monitorReloadWorker = nil }
            while self?.monitorReloadPending == true {
                guard let self else { return }
                self.monitorReloadPending = false
                let force = self.monitorReloadForceItems
                self.monitorReloadForceItems = false
                await self.performMonitorReload(forceItems: force)
            }
        }
        monitorReloadWorker = worker
        await worker.value
    }

    private func performMonitorReload(forceItems: Bool) async {
        guard let store else { return }
        do {
            let sources = try await store.monitorSources()
            let reports = try await store.monitorReports(limit: 30)
            var stats: [String: MonitorSourceStat] = [:]
            for source in sources {
                let cursor = try await store.monitorCursor(sourceID: source.id)
                stats[source.id] = MonitorSourceStat(
                    lastSuccessAt: cursor?.lastSuccessAt,
                    lastError: cursor?.lastError,
                    messageCount: try await store.monitorMessageCount(sourceID: source.id),
                    latestMessageAt: try await store.monitorLatestMessageSentAt(sourceID: source.id))
            }
            monitorSources = sources
            monitorReports = reports
            monitorSourceStats = stats
            if forceItems {
                monitorItemsByReport = [:]
                monitorEvidence = [:]
            }
            if let latest = reports.first, monitorItemsByReport[latest.id] == nil {
                _ = await loadMonitorItems(reportID: latest.id)
            }
        } catch {
            monitorStatus = error.localizedDescription
        }
    }

    @discardableResult
    func loadMonitorItems(reportID: String, force: Bool = false) async -> [MonitorItem] {
        guard let store else { return [] }
        if !force, let cached = monitorItemsByReport[reportID] { return cached }
        do {
            if force { monitorEvidence = [:] }
            let items = try await store.monitorItems(reportID: reportID)
            monitorItemsByReport[reportID] = items
            await loadMonitorEvidence(items: items)
            return items
        } catch {
            monitorStatus = error.localizedDescription
            return []
        }
    }

    func loadMonitorEvidence(items: [MonitorItem]) async {
        guard let store else { return }
        let nameBySource = Dictionary(uniqueKeysWithValues: monitorSources.map { ($0.id, $0.displayName) })
        let kindBySource = Dictionary(uniqueKeysWithValues: monitorSources.map { ($0.id, $0.kind) })
        for item in items where monitorEvidence[item.id] == nil {
            let refs = (try? JSONDecoder().decode([NotificationSourceRef].self,
                                                   from: Data(item.sourceRefsJSON.utf8))) ?? []
            var messagesBySource: [String: [MonitorMessage]] = [:]
            for sourceID in Set(refs.map(\.sourceID)) {
                let externalIDs = refs.filter { $0.sourceID == sourceID }.compactMap(\.externalID)
                messagesBySource[sourceID] = (try? await store.monitorMessages(sourceID: sourceID, externalIDs: externalIDs)) ?? []
            }
            monitorEvidence[item.id] = MonitorEvidenceBuilder.build(
                refs: refs, messagesBySource: messagesBySource,
                sourceNames: nameBySource, sourceKinds: kindBySource).map(MonitorItemEvidence.init)
        }
    }

    func setMonitorItemStatus(_ item: MonitorItem, status: MonitorItemStatus) async {
        guard let store else { return }
        do {
            try await store.setMonitorItemStatus(id: item.id, status: status)
            await loadMonitorItems(reportID: item.reportID, force: true)
            await reloadMonitorState()
        } catch {
            monitorStatus = error.localizedDescription
        }
    }

    func updateMonitorSettings(_ change: (inout MonitorSettings) -> Void) {
        var settings = monitorSettings
        change(&settings)
        monitorSettings = settings
        MonitorSettingsStore.save(settings)
    }

    func setMonitorScheduleTime(_ date: Date) {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        updateMonitorSettings {
            $0.hour = components.hour ?? 9
            $0.minute = components.minute ?? 0
        }
    }

    var monitorScheduleDate: Date {
        MonitorSchedule.runTimeToday(now: Date(), settings: monitorSettings.scheduleSettings) ?? Date()
    }

    var monitorNextRunText: String {
        let settings = monitorSettings.scheduleSettings
        if monitorReports.first?.reportDate == MonitorSourceConfigParser.dayString(Date()) {
            return "今天已有报告；自动检查每天最多一次。"
        }
        if let runTime = MonitorSchedule.runTimeToday(now: Date(), settings: settings), Date() < runTime {
            return "下次自动检查：今天 \(settings.timeText)"
        }
        return "下次自动检查：下一次轻量检查时（每 10 分钟比对一次时间）"
    }

    func setMonitorPushChannel(_ channel: MonitorPushChannel?) {
        updateMonitorSettings { $0.pushChannel = channel }
    }

    func ensureBuiltinMonitorSources(restoreMissing: Bool = false) async {
        guard let store else { return }
        let seededKey = "voiceos.monitor.builtinSeeded.v2"
        if !restoreMissing, UserDefaults.standard.bool(forKey: seededKey) { return }
        do {
            let existing = try await store.monitorSources()
            let start = MonitorSourceConfigParser.dayString(Date())
            var added = false
            for item in Self.monitorBuiltinWebsites {
                let present = existing.contains { source in
                    guard source.kind == .websiteColumn,
                          let config = try? MonitorSourceConfigParser.website(source.configJSON) else { return false }
                    return config.columnURL == item.url
                }
                guard !present else { continue }
                let json = try MonitorSourceConfigParser.websiteJSON(columnURL: item.url, startAt: start)
                _ = try await store.addMonitorSource(kind: .websiteColumn, displayName: item.name,
                                                     configJSON: json, enabled: true)
                added = true
            }
            UserDefaults.standard.set(true, forKey: seededKey)
            if added { await reloadMonitorState() }
        } catch {
            monitorStatus = error.localizedDescription
        }
    }

    func monitorSource(forBuiltinURL url: String) -> MonitorSource? {
        monitorSources.first { source in
            guard source.kind == .websiteColumn,
                  let config = try? MonitorSourceConfigParser.website(source.configJSON) else { return false }
            return config.columnURL == url
        }
    }

    func monitorSourceStartDate(_ source: MonitorSource) -> Date? {
        switch source.kind {
        case .qqGroup:
            return MonitorSourceConfigParser.parseStart((try? MonitorSourceConfigParser.qq(source.configJSON))?.startAt)
        case .websiteColumn:
            return MonitorSourceConfigParser.parseStart((try? MonitorSourceConfigParser.website(source.configJSON))?.startAt)
        }
    }

    func setMonitorSourceEnabled(_ source: MonitorSource, enabled: Bool) async {
        guard let store else { return }
        do {
            _ = try await store.updateMonitorSource(id: source.id, displayName: source.displayName,
                                                    configJSON: source.configJSON, enabled: enabled)
            await reloadMonitorState()
        } catch {
            monitorStatus = error.localizedDescription
        }
    }

    func setMonitorWebsiteStart(_ source: MonitorSource, date: Date) async {
        guard let store else { return }
        do {
            var config = try MonitorSourceConfigParser.website(source.configJSON)
            config.startAt = MonitorSourceConfigParser.dayString(date)
            let json = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
            _ = try await store.updateMonitorSource(id: source.id, displayName: source.displayName,
                                                    configJSON: json, enabled: source.enabled)
            await reloadMonitorState()
        } catch {
            monitorStatus = error.localizedDescription
        }
    }

    /// The start control is the cursor itself: moving it later skips the
    /// history the user chose to skip, and moving it earlier re-reads from
    /// that moment; dedupe absorbs the overlap.
    func setMonitorQQStart(_ source: MonitorSource, date: Date) async {
        guard let store else { return }
        do {
            var config = try MonitorSourceConfigParser.qq(source.configJSON)
            config.startAt = MonitorSourceConfigParser.timestampString(date)
            let json = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
            _ = try await store.updateMonitorSource(id: source.id, displayName: source.displayName,
                                                    configJSON: json, enabled: source.enabled)
            try await store.alignMonitorCursorToStart(sourceID: source.id, start: date)
            await reloadMonitorState()
        } catch {
            monitorStatus = error.localizedDescription
        }
    }

    @discardableResult
    func addQQMonitorSource(_ conversation: QQMonitorConversation, start: Date) async -> Bool {
        guard let store else { return false }
        do {
            let json = try MonitorSourceConfigParser.qqJSON(
                conversationID: conversation.id,
                conversationName: conversation.name,
                startAt: MonitorSourceConfigParser.timestampString(start))
            let source = try await store.addMonitorSource(kind: .qqGroup, displayName: conversation.name,
                                                          configJSON: json, enabled: true)
            try await store.advanceMonitorCursor(sourceID: source.id, lastSuccessEnd: start, newMessageIDs: [])
            await reloadMonitorState()
            monitorStatus = "已添加群来源「\(conversation.name)」，从 \(start.formatted(date: .abbreviated, time: .shortened)) 开始读取"
            return true
        } catch {
            monitorStatus = error.localizedDescription
            return false
        }
    }

    func removeMonitorSource(_ source: MonitorSource) async {
        guard let store else { return }
        do {
            try await store.removeMonitorSource(id: source.id)
            await reloadMonitorState()
        } catch {
            monitorStatus = error.localizedDescription
        }
    }

    @discardableResult
    func loadQQMonitorConversations() async -> String? {
        monitorQQConversationStatus = "正在读取 QQ 群列表…"
        monitorQQConversations = []
        let settings = MonitorQQSettingsStore.qqSettings(MonitorQQSettingsStore.load())
        do {
            let list = try await QQMonitorHelper().conversationList(settings: settings)
            monitorQQConversations = list.conversations
            monitorQQConversationStatus = list.conversations.isEmpty
                ? "没有读到群会话；请先确认 QQ 已登录并完成诊断"
                : "已读取 \(list.conversations.count) 个群"
            return list.account
        } catch {
            monitorQQConversationStatus = error.localizedDescription
            return nil
        }
    }

    func diagnoseMonitorQQ() async {
        monitorQQDiagnosisStatus = "正在检查 QQ 依赖…"
        let settings = MonitorQQSettingsStore.qqSettings(MonitorQQSettingsStore.load())
        let items = await QQMonitorHelper().diagnoseItems(settings: settings)
        monitorQQDiagnostics = items
        monitorQQDiagnosisStatus = items.allSatisfy(\.ok) ? "QQ 读取环境可用" : "有 \(items.filter { !$0.ok }.count) 项需要处理"
    }

    func saveMonitorQQSettings(_ settings: MonitorQQUserSettings) {
        MonitorQQSettingsStore.save(settings)
        monitorStatus = "QQ 读取设置已保存（只保存路径与账号，不保存密钥内容）"
    }

    var monitorWebhookTail: String { MonitorCredentialStore.tail(MonitorCredentialStore.loadWebhookURL()) }

    @discardableResult
    func saveMonitorWebhook(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            monitorPushStatus = "请先输入推送地址"
            return false
        }
        do {
            try MonitorCredentialStore.saveWebhookURL(value)
            monitorPushStatus = "推送地址已保存到钥匙串（尾号 " + String(value.suffix(4)) + "）"
            return true
        } catch {
            monitorPushStatus = error.localizedDescription
            return false
        }
    }

    func monitorPushContent(for report: MonitorReport) async -> MonitorPushContent {
        let items = await loadMonitorItems(reportID: report.id)
        let nameBySource = Dictionary(uniqueKeysWithValues: monitorSources.map { ($0.id, $0.displayName) })
        let pushItems = items.map { item -> MonitorPushItem in
            let refs = (try? JSONDecoder().decode([NotificationSourceRef].self,
                                                   from: Data(item.sourceRefsJSON.utf8))) ?? []
            let sourceName = refs.compactMap { nameBySource[$0.sourceID] }.first ?? "监测来源"
            return MonitorPushItem(title: item.title, deadline: item.deadlineText ?? item.deadlineDate,
                                   whyRelevant: item.whyRelevant, sourceName: sourceName,
                                   category: item.category, status: item.status)
        }
        return MonitorPushContent(date: report.reportDate, headline: report.headline,
                                  summary: report.summary, items: pushItems)
    }

    @discardableResult
    func pushMonitorReport(_ report: MonitorReport) async -> Bool {
        guard let store else { return false }
        guard let channel = monitorSettings.pushChannel else {
            monitorPushStatus = "尚未选择推送通道；请在设置中选择企业微信或 Server酱式"
            return false
        }
        guard let raw = MonitorCredentialStore.loadWebhookURL(),
              let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else {
            monitorPushStatus = "尚未保存有效的推送地址；请在设置中填写并保存"
            return false
        }
        monitorPushStatus = "正在推送…"
        let content = await monitorPushContent(for: report)
        let outcome = await MonitorPushService(store: store)
            .deliver(reportID: report.id, date: report.reportDate, content: content, channel: channel, webhookURL: url)
        monitorPushStatus = outcome.success
            ? "已推送 · " + (outcome.deliveredAt.map(Self.monitorTimeText) ?? "刚刚")
            : (outcome.error ?? "推送失败")
        await reloadMonitorState()
        return outcome.success
    }

    func pushLatestMonitorReport() async {
        guard let report = monitorReports.first else {
            monitorPushStatus = "还没有可推送的报告"
            return
        }
        _ = await pushMonitorReport(report)
    }

    func sendMonitorPushTest() async {
        guard let store else { monitorTestPushStatus = "资料库尚未打开"; return }
        guard let channel = monitorSettings.pushChannel else {
            monitorTestPushStatus = "先选择推送通道"
            return
        }
        guard let raw = MonitorCredentialStore.loadWebhookURL(), let url = URL(string: raw) else {
            monitorTestPushStatus = "先保存推送地址"
            return
        }
        let sample = MonitorPushContent(
            date: MonitorSourceConfigParser.dayString(Date()),
            headline: "推送通道测试",
            summary: "这是一条固定样例。收到说明通道可用；今日报告内容不会因此发送。",
            items: [MonitorPushItem(title: "示例事项", deadline: "明天", whyRelevant: "验证推送格式",
                                    sourceName: "VoiceOS", category: .applicable)])
        monitorTestPushStatus = "正在发送测试…"
        let outcome = await MonitorPushService(store: store).sendTest(sample, channel: channel, webhookURL: url)
        monitorTestPushStatus = outcome.success
            ? "测试已发送 · " + (outcome.deliveredAt.map(Self.monitorTimeText) ?? "刚刚")
            : (outcome.error ?? "测试发送失败")
    }

    func runMonitorCheck(automatic: Bool = false) async {
        if let monitorWorker {
            await monitorWorker.value
            return
        }
        let worker = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.performMonitorCheck(automatic: automatic)
        }
        monitorWorker = worker
        await worker.value
        monitorWorker = nil
    }

    private func performMonitorCheck(automatic: Bool) async {
        guard initialized, let store else {
            monitorStatus = "资料库尚未打开，无法检查"
            return
        }
        monitorChecking = true
        monitorPhase = "采集与分析"
        monitorStatus = automatic ? "自动检查开始…" : "正在检查…"
        defer { monitorChecking = false; monitorPhase = "" }
        await ensureBuiltinMonitorSources()
        let user = MonitorQQSettingsStore.load()
        let analysis: (any NotificationAnalysisPort)? = monitorSettings.cloudAnalysisAuthorized ? monitorAnalysisModel : nil
        let runner = MessageMonitorRunner(
            store: store, analysis: analysis,
            qqCollector: QQMonitorHelper(),
            websiteCollector: WebsiteMonitor(),
            qqSettings: MonitorQQSettingsStore.qqSettings(user))
        let today = MonitorSourceConfigParser.dayString(Date())
        do {
            let result = try await runner.runDailyCheck(date: Date())
            await reloadMonitorState(forceItems: true)
            monitorStatus = Self.monitorRunSummary(result)
            await deliverLatestMonitorIfNeeded()
        } catch is CancellationError {
            monitorStatus = "检查已取消"
        } catch {
            let message = error.localizedDescription
            let summary: String
            let headline: String
            if message.contains("分析模型端口") {
                headline = monitorSettings.cloudAnalysisAuthorized ? "未配置文本模型" : "等待云端分析授权"
                summary = monitorSettings.cloudAnalysisAuthorized
                    ? "已采集新增原文，但尚未配置文本模型，内容没有发送。配置后点击「立即检查」完成分析。"
                    : "已采集新增原文，但云端分析授权未开启，内容没有发送给模型。开启授权后点击「立即检查」完成分析。"
            } else {
                headline = "检查未完成"
                summary = "检查未完成：" + message
            }
            _ = try? await store.upsertMonitorReport(date: today, state: .failed, headline: headline,
                                                     summary: summary, sourceStatus: [])
            monitorStatus = summary
            await reloadMonitorState(forceItems: true)
        }
    }

    private func deliverLatestMonitorIfNeeded() async {
        guard let report = monitorReports.first,
              report.reportDate == MonitorSourceConfigParser.dayString(Date()),
              report.state != .failed,
              report.deliveryState != "delivered",
              monitorSettings.pushChannel != nil,
              MonitorCredentialStore.loadWebhookURL() != nil else { return }
        monitorPhase = "推送"
        _ = await pushMonitorReport(report)
    }

    func installMonitorSchedule() {
        guard monitorObservers.isEmpty else { return }
        monitorObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.monitorTick(trigger: .activation) }
            })
        monitorObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.monitorTick(trigger: .wake) }
            })
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.monitorTick(trigger: .timer) }
        }
        Task { await self.monitorTick(trigger: .launch) }
    }

    func monitorTick(trigger: MonitorTrigger) async {
        guard initialized, let store, !monitorChecking else { return }
        // Decide from one report row; the full monitor reload runs only when
        // the daily gate says this tick needs a check.
        let latestReportDate = (try? await store.monitorReports(limit: 1))?.first?.reportDate
        let decision = MonitorSchedule.decide(trigger: trigger, now: Date(),
                                              settings: monitorSettings.scheduleSettings,
                                              latestReportDate: latestReportDate)
        guard decision.shouldRun else { return }
        await reloadMonitorState()
        await runMonitorCheck(automatic: true)
    }

    var monitorNeedsAttention: Bool {
        MonitorAttention.needsAttention(monitorReports.first)
    }

    var monitorOpenItemCount: Int {
        guard let report = monitorLatestReport else { return 0 }
        return MonitorItemTally(items: monitorItemsByReport[report.id] ?? []).open
    }

    var monitorAttentionText: String? {
        guard monitorNeedsAttention, let report = monitorReports.first else { return nil }
        if report.state == .failed {
            return "\(report.reportDate) 的检查未完成：" + (report.summary.isEmpty ? "原因未知" : report.summary)
        }
        if report.state == .incomplete {
            return "\(report.reportDate) 的检查不完整：" + (report.summary.isEmpty ? "部分来源未检查" : report.summary)
        }
        if report.deliveryState == "failed" {
            return "\(report.reportDate) 的微信推送失败：" + (report.deliveryError ?? "原因未知") + "，可重试推送"
        }
        return nil
    }

    func markMonitorAttentionSeen() {
        guard let signature = MonitorAttention.seenSignatureWhenOpened(for: monitorReports.first) else { return }
        UserDefaults.standard.set(signature, forKey: MonitorAttention.seenKey)
        monitorAttentionRevision += 1
    }

    static func monitorRunSummary(_ result: MonitorRunResult) -> String {
        let state: String
        switch result.state {
        case .complete: state = "完整"
        case .incomplete: state = "不完整"
        case .failed: state = "失败"
        }
        return "检查结束 · \(state) · 新增 \(result.newMessageCount) 条消息 · \(result.itemCount) 条事项"
    }

    static func monitorStateText(_ state: MonitorReportState) -> String {
        switch state {
        case .complete: "完整"
        case .incomplete: "不完整"
        case .failed: "失败"
        }
    }

    static func monitorDeliveryText(_ report: MonitorReport) -> String {
        switch report.deliveryState {
        case "delivered": return "已推送" + (report.deliveredAt.map { " · " + monitorTimeText($0) } ?? "")
        case "failed": return "推送失败" + (report.deliveryError.map { "：" + $0 } ?? "") + "（可重试）"
        default: return "尚未推送"
        }
    }

    static func monitorTimeText(_ iso: String?) -> String {
        guard let iso, let date = MonitorDateFormatting.iso8601.date(from: iso) else { return iso ?? "时间未知" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
