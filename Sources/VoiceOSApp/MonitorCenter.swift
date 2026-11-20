import AppKit
import Combine
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

struct MonitorSettingsLoad {
    let settings: MonitorSettings
    let decodeFailed: Bool
}

enum MonitorSettingsStore {
    private static let key = "voiceos.monitor.settings.v1"
    static func loadResult() -> MonitorSettingsLoad {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            return MonitorSettingsLoad(settings: MonitorSettings(), decodeFailed: false)
        }
        do {
            return MonitorSettingsLoad(settings: try JSONDecoder().decode(MonitorSettings.self, from: data),
                                       decodeFailed: false)
        } catch {
            return MonitorSettingsLoad(settings: MonitorSettings(), decodeFailed: true)
        }
    }
    static func load() -> MonitorSettings { loadResult().settings }
    @discardableResult
    static func save(_ settings: MonitorSettings) -> Bool {
        guard let data = try? JSONEncoder().encode(settings) else { return false }
        UserDefaults.standard.set(data, forKey: key)
        return true
    }
}

enum MonitorSettingsBootstrap {
    static let loaded = MonitorSettingsStore.loadResult()
}

/// Paths and the account name are not secrets; the key file content never
/// leaves disk and only its path is stored here.
struct MonitorQQUserSettings: Codable, Equatable {
    var pythonPath: String = ""
    var keyPath: String = ""
    var account: String = ""
    var scriptPathOverride: String = ""
}

struct MonitorQQSettingsLoad {
    let settings: MonitorQQUserSettings
    let decodeFailed: Bool
}

enum MonitorQQSettingsStore {
    private static let key = "voiceos.monitor.qq.settings.v1"
    static func loadResult() -> MonitorQQSettingsLoad {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            return MonitorQQSettingsLoad(settings: MonitorQQUserSettings(), decodeFailed: false)
        }
        do {
            return MonitorQQSettingsLoad(settings: try JSONDecoder().decode(MonitorQQUserSettings.self, from: data),
                                         decodeFailed: false)
        } catch {
            return MonitorQQSettingsLoad(settings: MonitorQQUserSettings(), decodeFailed: true)
        }
    }
    static func load() -> MonitorQQUserSettings { loadResult().settings }
    @discardableResult
    static func save(_ settings: MonitorQQUserSettings) -> Bool {
        guard let data = try? JSONEncoder().encode(settings) else { return false }
        UserDefaults.standard.set(data, forKey: key)
        return true
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

enum MonitorSourceStart: Equatable {
    case unset
    case invalid
    case date(Date)
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

/// One in-flight operation per external channel: the push webhook and the
/// read-only QQ child process. Automatic delivery takes the same push slot as
/// the manual buttons, so one report leaves at most once. The gate is static
/// because ControlCenter's stored properties live in VoiceOSApp.swift; views
/// observe it directly for busy labels.
@MainActor
final class MonitorOperationGate: ObservableObject {
    enum Push: Equatable { case report, test }
    enum QQ: Equatable { case diagnose, list, add }

    @Published private(set) var push: Push?
    @Published private(set) var qq: QQ?

    func beginPush(_ operation: Push) -> Bool {
        guard push == nil else { return false }
        push = operation
        return true
    }

    func endPush(_ operation: Push) {
        if push == operation { push = nil }
    }

    func beginQQ(_ operation: QQ) -> Bool {
        guard qq == nil else { return false }
        qq = operation
        return true
    }

    func endQQ(_ operation: QQ) {
        if qq == operation { qq = nil }
    }
}

extension ControlCenter {
    static let monitorBuiltinWebsites: [MonitorBuiltinWebsite] = [
        MonitorBuiltinWebsite(name: "计算机学院通知", url: "https://cs.nuaa.edu.cn/10851/list.htm"),
        MonitorBuiltinWebsite(name: "研究生院通知", url: "https://www.graduate.nuaa.edu.cn/2145/list.htm")
    ]

    var monitorLatestReport: MonitorReport? { monitorReports.first }

    /// Reports load in pages so the daily page stays fast. Static because
    /// ControlCenter keeps its stored properties in VoiceOSApp.swift; paging
    /// state lives beside the paging code. Reads are internal, writes file-private.
    private(set) static var monitorReportLimit = 30
    static let monitorReportLimitCap = 960
    static let monitorOperations = MonitorOperationGate()

    /// Widen the report window one page; loaded item caches stay.
    func loadMoreMonitorReports() async {
        guard Self.monitorReportLimit < Self.monitorReportLimitCap else { return }
        Self.monitorReportLimit = min(Self.monitorReportLimit * 2, Self.monitorReportLimitCap)
        await reloadMonitorState()
    }

    /// Every refresh path shares one reload; overlapping calls run one more round
    /// instead of each re-reading the store. Returns whether the last round
    /// succeeded, so callers can tell a failed read from an empty result.
    @discardableResult
    func reloadMonitorState(forceItems: Bool = false) async -> Bool {
        monitorReloadPending = true
        monitorReloadForceItems = monitorReloadForceItems || forceItems
        if let monitorReloadWorker {
            await monitorReloadWorker.value
            return Self.monitorLastReloadSucceeded
        }
        let worker = Task { @MainActor [weak self] in
            defer { self?.monitorReloadWorker = nil }
            while self?.monitorReloadPending == true {
                guard let self else { return }
                self.monitorReloadPending = false
                let force = self.monitorReloadForceItems
                self.monitorReloadForceItems = false
                Self.monitorLastReloadSucceeded = await self.performMonitorReload(forceItems: force)
            }
        }
        monitorReloadWorker = worker
        await worker.value
        return Self.monitorLastReloadSucceeded
    }

    /// The worker task outlives the call that started it, so coalesced callers
    /// read the outcome here after waiting on the same run.
    private static var monitorLastReloadSucceeded = true

    private func performMonitorReload(forceItems: Bool) async -> Bool {
        guard let store else { return false }
        do {
            let sources = try await store.monitorSources()
            let reports = try await store.monitorReports(limit: Self.monitorReportLimit)
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
            return true
        } catch {
            monitorStatus = error.localizedDescription
            return false
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
        recordMonitorSettingsSave(success: MonitorSettingsStore.save(settings))
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
        if case .date(let date) = monitorSourceStart(source) { return date }
        return nil
    }

    /// Parses the stored start config explicitly so a corrupt source shows
    /// "配置无效" instead of pretending no start was ever set.
    func monitorSourceStart(_ source: MonitorSource) -> MonitorSourceStart {
        let startAt: String?
        do {
            switch source.kind {
            case .qqGroup:
                startAt = try MonitorSourceConfigParser.qq(source.configJSON).startAt
            case .websiteColumn:
                startAt = try MonitorSourceConfigParser.website(source.configJSON).startAt
            }
        } catch {
            return .invalid
        }
        guard let raw = startAt?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return .unset }
        guard let date = MonitorSourceConfigParser.parseStart(raw) else { return .invalid }
        return .date(date)
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
        guard Self.monitorOperations.beginQQ(.add) else { return false }
        defer { Self.monitorOperations.endQQ(.add) }
        do {
            let sources = try await store.monitorSources()
            let existing = sources.first { source in
                guard source.kind == .qqGroup,
                      let config = try? MonitorSourceConfigParser.qq(source.configJSON) else { return false }
                return config.conversationID == conversation.id
            }
            if let existing {
                monitorStatus = "「\(existing.displayName)」已在监测来源中；如需调整起点，请在「来源状态」里改起始时间"
                return true
            }
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
        guard Self.monitorOperations.beginQQ(.list) else { return nil }
        defer { Self.monitorOperations.endQQ(.list) }
        monitorQQConversationStatus = "正在读取 QQ 群列表…"
        monitorQQConversations = []
        let loaded = MonitorQQSettingsStore.loadResult()
        recordMonitorQQSettingsLoad(decodeFailed: loaded.decodeFailed)
        let settings = MonitorQQSettingsStore.qqSettings(loaded.settings)
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
        guard Self.monitorOperations.beginQQ(.diagnose) else { return }
        defer { Self.monitorOperations.endQQ(.diagnose) }
        monitorQQDiagnosisStatus = "正在检查 QQ 依赖…"
        let loaded = MonitorQQSettingsStore.loadResult()
        recordMonitorQQSettingsLoad(decodeFailed: loaded.decodeFailed)
        let settings = MonitorQQSettingsStore.qqSettings(loaded.settings)
        let items = await QQMonitorHelper().diagnoseItems(settings: settings)
        monitorQQDiagnostics = items
        monitorQQDiagnosisStatus = items.allSatisfy(\.ok) ? "QQ 读取环境可用" : "有 \(items.filter { !$0.ok }.count) 项需要处理"
    }

    @discardableResult
    func saveMonitorQQSettings(_ settings: MonitorQQUserSettings) -> Bool {
        guard MonitorQQSettingsStore.save(settings) else {
            monitorStatus = "QQ 读取设置保存失败，请重试；若仍失败请重启应用后再试"
            return false
        }
        clearMonitorQQSettingsDecodeFailure()
        monitorStatus = "QQ 读取设置已保存（只保存路径与账号，不保存密钥内容）"
        return true
    }

    /// Push is usable only when both the channel and the keychain address exist.
    var monitorPushConfigured: Bool {
        monitorSettings.pushChannel != nil && MonitorCredentialStore.loadWebhookURL() != nil
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
        guard Self.monitorOperations.beginPush(.report) else {
            monitorPushStatus = "正在推送，请稍候…"
            return false
        }
        defer { Self.monitorOperations.endPush(.report) }
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
        guard Self.monitorOperations.beginPush(.test) else {
            monitorTestPushStatus = "正在发送测试，请稍候…"
            return
        }
        defer { Self.monitorOperations.endPush(.test) }
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
        let loaded = MonitorQQSettingsStore.loadResult()
        recordMonitorQQSettingsLoad(decodeFailed: loaded.decodeFailed)
        let user = loaded.settings
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

    /// Open items can outlive the report that shows them. The today section
    /// sums every open item so work stranded on earlier reports stays visible.
    func monitorOpenItemsSummary(todayKey: String) async -> MonitorOpenItemsSummary {
        guard let store, let openItems = try? await store.openMonitorItems() else {
            return MonitorOpenItemsSummary()
        }
        return MonitorOpenItemsSummary(openItems: openItems, reports: monitorReports, todayKey: todayKey)
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

    static func monitorGeneratedText(_ report: MonitorReport) -> String? {
        guard let date = MonitorDateFormatting.iso8601.date(from: report.createdAt) else { return nil }
        return "生成于 " + date.formatted(date: .omitted, time: .shortened)
    }
}
