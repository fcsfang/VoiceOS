import Foundation

public struct QQMonitorSettings: Sendable, Equatable {
    public let pythonPath: String
    public let scriptPath: String
    public let keyPath: String
    public let cacheDir: String
    public let account: String?
    public let timeout: TimeInterval
    public init(pythonPath: String, scriptPath: String, keyPath: String, cacheDir: String, account: String?, timeout: TimeInterval = 300) {
        self.pythonPath = pythonPath; self.scriptPath = scriptPath; self.keyPath = keyPath
        self.cacheDir = cacheDir; self.account = account; self.timeout = timeout
    }
}

public struct QQMonitorReadMessage: Sendable, Equatable {
    public let externalID: String
    public let kind: MonitorMessageKind
    public let senderName: String?
    public let sentAt: Date?
    public let content: String
    public let metaJSON: String?
    public init(externalID: String, kind: MonitorMessageKind, senderName: String?, sentAt: Date?, content: String, metaJSON: String?) {
        self.externalID = externalID; self.kind = kind; self.senderName = senderName
        self.sentAt = sentAt; self.content = content; self.metaJSON = metaJSON
    }
}

public struct QQMonitorReadResult: Sendable, Equatable {
    public let conversationID: String
    public let conversationName: String?
    public let messages: [QQMonitorReadMessage]
    public let truncated: Bool
    public init(conversationID: String, conversationName: String?, messages: [QQMonitorReadMessage], truncated: Bool) {
        self.conversationID = conversationID; self.conversationName = conversationName
        self.messages = messages; self.truncated = truncated
    }
}

public protocol QQMonitorCollecting: Sendable {
    func collect(conversationID: String, start: Date, end: Date, settings: QQMonitorSettings) async throws -> QQMonitorReadResult
}

public struct WebsiteMonitorEntry: Sendable, Equatable {
    public let url: String
    public let title: String
    public let publishedAt: Date?
    public let text: String
    public let note: String?
    public init(url: String, title: String, publishedAt: Date?, text: String, note: String?) {
        self.url = url; self.title = title; self.publishedAt = publishedAt; self.text = text; self.note = note
    }
}

public protocol WebsiteMonitorCollecting: Sendable {
    func collect(columnURL: URL) async throws -> [WebsiteMonitorEntry]
}

public struct MonitorRunResult: Codable, Sendable, Equatable {
    public let reportDate: String
    public let state: MonitorReportState
    public let headline: String
    public let summary: String
    public let itemCount: Int
    public let newMessageCount: Int
    public let sourceStatus: [MonitorSourceStatus]
    public init(reportDate: String, state: MonitorReportState, headline: String, summary: String, itemCount: Int, newMessageCount: Int, sourceStatus: [MonitorSourceStatus]) {
        self.reportDate = reportDate; self.state = state; self.headline = headline; self.summary = summary
        self.itemCount = itemCount; self.newMessageCount = newMessageCount; self.sourceStatus = sourceStatus
    }
}

/// One daily pass: collect every enabled source, persist new messages, advance
/// cursors, then analyze and store the report and its items. Collectors and the
/// model port are injected; scheduling, UI and delivery stay outside this unit.
public struct MessageMonitorRunner: Sendable {
    /// The overlap re-reads half an hour before the last success so messages
    /// written right at the boundary are not lost; dedupe absorbs the repeats.
    public static let cursorOverlap: TimeInterval = 30 * 60
    public static let initialLookback: TimeInterval = 24 * 60 * 60

    private let store: VoiceOSStore
    private let analysis: (any NotificationAnalysisPort)?
    private let qqCollector: (any QQMonitorCollecting)?
    private let websiteCollector: (any WebsiteMonitorCollecting)?
    private let qqSettings: QQMonitorSettings?
    private let now: @Sendable () -> Date

    public init(store: VoiceOSStore, analysis: (any NotificationAnalysisPort)? = nil,
                qqCollector: (any QQMonitorCollecting)? = nil, websiteCollector: (any WebsiteMonitorCollecting)? = nil,
                qqSettings: QQMonitorSettings? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store; self.analysis = analysis; self.qqCollector = qqCollector
        self.websiteCollector = websiteCollector; self.qqSettings = qqSettings; self.now = now
    }

    public func runDailyCheck(date: Date = Date()) async throws -> MonitorRunResult {
        let key = Self.dateKey(date)
        let end = now()
        let sources = try await store.enabledMonitorSources()
        guard !sources.isEmpty else {
            let status: [MonitorSourceStatus] = []
            _ = try await store.upsertMonitorReport(date: key, state: .incomplete, headline: "未启用监测来源",
                                                    summary: "没有启用任何监测来源，无法检查。请在消息监测设置中添加 QQ 群或官网栏目。",
                                                    sourceStatus: status)
            return MonitorRunResult(reportDate: key, state: .incomplete, headline: "未启用监测来源",
                                    summary: "没有启用任何监测来源，无法检查。请在消息监测设置中添加 QQ 群或官网栏目。",
                                    itemCount: 0, newMessageCount: 0, sourceStatus: status)
        }
        var statuses: [MonitorSourceStatus] = []
        var newMessages: [MonitorMessage] = []
        for source in sources {
            do {
                let cursor = try await store.monitorCursor(sourceID: source.id)
                let lastSuccess = cursor?.lastSuccessAt.flatMap(Self.isoDate)
                let start = lastSuccess.map { $0.addingTimeInterval(-Self.cursorOverlap) }
                    ?? end.addingTimeInterval(-Self.initialLookback)
                let drafts: [MonitorMessageDraft]
                switch source.kind {
                case .qqGroup:
                    guard let qqCollector, let qqSettings else {
                        throw VoiceOSError("QQ 读取器未配置，无法检查「\(source.displayName)」")
                    }
                    let config = try Self.qqConfiguration(source.configJSON)
                    let result = try await qqCollector.collect(conversationID: config.conversationID, start: start, end: end, settings: qqSettings)
                    drafts = result.messages.map {
                        MonitorMessageDraft(sourceID: source.id, externalID: $0.externalID, kind: $0.kind,
                                            senderName: $0.senderName, sentAt: $0.sentAt.map(Self.isoString),
                                            content: $0.content, metaJSON: $0.metaJSON)
                    }
                case .websiteColumn:
                    guard let websiteCollector else {
                        throw VoiceOSError("官网抓取器未配置，无法检查「\(source.displayName)」")
                    }
                    let config = try Self.websiteConfiguration(source.configJSON)
                    let entries = try await websiteCollector.collect(columnURL: config.columnURL)
                    drafts = entries.map { entry in
                        var meta: [String: Any] = ["url": entry.url, "title": entry.title]
                        if let note = entry.note { meta["error"] = note }
                        let metaJSON = (try? JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys]))
                            .map { String(decoding: $0, as: UTF8.self) }
                        return MonitorMessageDraft(sourceID: source.id, externalID: entry.url, kind: .article,
                                                   senderName: config.columnURL.host,
                                                   sentAt: entry.publishedAt.map(Self.isoString),
                                                   content: entry.title + "\n\n" + entry.text, metaJSON: metaJSON)
                    }
                }
                let inserted = try await store.insertMonitorMessages(drafts)
                try await store.advanceMonitorCursor(sourceID: source.id, lastSuccessEnd: end,
                                                     newMessageIDs: inserted.map(\.id))
                newMessages += inserted
                statuses.append(MonitorSourceStatus(sourceID: source.id, displayName: source.displayName,
                                                    ok: true, newMessageCount: inserted.count, error: nil))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try? await store.failMonitorCursor(sourceID: source.id, error: error.localizedDescription)
                statuses.append(MonitorSourceStatus(sourceID: source.id, displayName: source.displayName,
                                                    ok: false, newMessageCount: 0, error: error.localizedDescription))
            }
        }
        let anyFailure = statuses.contains { !$0.ok }
        let existing = try await store.monitorReport(date: key)
        if newMessages.isEmpty {
            if let existing, existing.state == .failed {
                return try await retryAnalysis(reportDate: date)
            }
            if let existing, existing.state == .complete, !anyFailure {
                return MonitorRunResult(reportDate: key, state: existing.state, headline: existing.headline,
                                        summary: existing.summary, itemCount: existing.itemCount,
                                        newMessageCount: 0, sourceStatus: existing.sourceStatus)
            }
            let headline = anyFailure ? "部分来源检查失败" : "检查完成，无新增待办"
            let failures = statuses.filter { !$0.ok }
                .map { $0.displayName + "（" + ($0.error ?? "原因未知") + "）" }
                .joined(separator: "；")
            let summary = anyFailure
                ? "以下来源本次未能检查：" + failures + "；已采集内容不受影响，可稍后手动检查。"
                : "检查完成，无新增待办。"
            let state: MonitorReportState = anyFailure ? .incomplete : .complete
            _ = try await store.upsertMonitorReport(date: key, state: state, headline: headline,
                                                    summary: summary, sourceStatus: statuses)
            return MonitorRunResult(reportDate: key, state: state, headline: headline, summary: summary,
                                    itemCount: 0, newMessageCount: 0, sourceStatus: statuses)
        }
        guard let analysis else { throw VoiceOSError("未配置分析模型端口，无法处理新增消息") }
        let input = try await analysisInput(messages: newMessages, statuses: statuses)
        let state: MonitorReportState = anyFailure ? .incomplete : .complete
        do {
            let result = try await analysis.analyze(input)
            let reportID = try await store.upsertMonitorReport(date: key, state: state, headline: result.headline,
                                                               summary: result.summary, sourceStatus: statuses)
            let itemCount = try await store.applyMonitorAnalysis(reportID: reportID, date: key, items: result.items)
            return MonitorRunResult(reportDate: key, state: state, headline: result.headline, summary: result.summary,
                                    itemCount: itemCount, newMessageCount: newMessages.count, sourceStatus: statuses)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let headline = "分析未完成"
            let summary = "已保存 \(newMessages.count) 条新增原文，但模型分析失败：" + error.localizedDescription
                + "。可稍后重试分析，不需要重新采集。"
            _ = try await store.upsertMonitorReport(date: key, state: .failed, headline: headline,
                                                    summary: summary, sourceStatus: statuses)
            return MonitorRunResult(reportDate: key, state: .failed, headline: headline, summary: summary,
                                    itemCount: 0, newMessageCount: newMessages.count, sourceStatus: statuses)
        }
    }

    /// Retries only the model step for a failed day, using the messages the
    /// last successful collection persisted.
    public func retryAnalysis(reportDate: Date) async throws -> MonitorRunResult {
        let key = Self.dateKey(reportDate)
        guard let report = try await store.monitorReport(date: key) else { throw VoiceOSError("没有 \(key) 的报告，无法只重分析") }
        guard report.state == .failed else {
            return MonitorRunResult(reportDate: key, state: report.state, headline: report.headline,
                                    summary: report.summary, itemCount: report.itemCount,
                                    newMessageCount: 0, sourceStatus: report.sourceStatus)
        }
        guard let analysis else { throw VoiceOSError("未配置分析模型端口，无法重试分析") }
        var ids: [String] = []
        for source in try await store.monitorSources() {
            guard let cursor = try await store.monitorCursor(sourceID: source.id),
                  let data = cursor.cursorJSON.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let stored = object["last_run_message_ids"] as? [String] else { continue }
            ids += stored
        }
        let messages = try await store.monitorMessages(ids: Array(Set(ids)).sorted())
        guard !messages.isEmpty else {
            throw VoiceOSError("上次检查的原文标识已被新的采集覆盖，无法只重分析；请等待下一次每日检查")
        }
        let statuses = report.sourceStatus
        let input = try await analysisInput(messages: messages, statuses: statuses)
        let result = try await analysis.analyze(input)
        let state: MonitorReportState = statuses.contains { !$0.ok } ? .incomplete : .complete
        let reportID = try await store.upsertMonitorReport(date: key, state: state, headline: result.headline,
                                                           summary: result.summary, sourceStatus: statuses)
        let itemCount = try await store.applyMonitorAnalysis(reportID: reportID, date: key, items: result.items)
        return MonitorRunResult(reportDate: key, state: state, headline: result.headline, summary: result.summary,
                                itemCount: itemCount, newMessageCount: messages.count, sourceStatus: statuses)
    }

    private func analysisInput(messages: [MonitorMessage], statuses: [MonitorSourceStatus]) async throws -> NotificationAnalysisInput {
        let sources = try await store.monitorSources()
        let descriptors = sources.map { NotificationSourceDescriptor(sourceID: $0.id, displayName: $0.displayName, kind: $0.kind) }
        let existing = try await store.openMonitorItems().map {
            NotificationExistingItem(id: $0.id, title: $0.title, deadlineDate: $0.deadlineDate, category: $0.category)
        }
        let inputs = messages.map {
            NotificationMessageInput(sourceID: $0.sourceID, externalID: $0.externalID, kind: $0.kind,
                                     senderName: $0.senderName, sentAt: $0.sentAt, text: $0.content,
                                     needsReview: $0.kind != .text && $0.kind != .article)
        }
        let states = statuses.map { NotificationSourceState(sourceID: $0.sourceID, ok: $0.ok, error: $0.error) }
        let digest = VoiceOSStore.relevanceHash(Data((inputs.map { $0.sourceID + "\u{0}" + $0.externalID } + existing.map(\.id))
            .joined(separator: "\n").utf8))
        return NotificationAnalysisInput(sources: descriptors, messages: inputs, existingItems: existing,
                                         sourceStatus: states, digest: digest)
    }

    private struct QQSourceConfiguration: Decodable {
        let conversationID: String
        enum CodingKeys: String, CodingKey { case conversationID = "conversation_id" }
    }

    private struct WebsiteSourceConfiguration: Decodable {
        let columnURL: URL
        enum CodingKeys: String, CodingKey { case columnURL = "column_url" }
    }

    private static func qqConfiguration(_ json: String) throws -> QQSourceConfiguration {
        guard let data = json.data(using: .utf8), let config = try? JSONDecoder().decode(QQSourceConfiguration.self, from: data),
              config.conversationID.hasPrefix("group:"), config.conversationID.count > "group:".count else {
            throw VoiceOSError("QQ 来源配置无效：需要 conversation_id（形如 group:群号）")
        }
        return config
    }

    private static func websiteConfiguration(_ json: String) throws -> WebsiteSourceConfiguration {
        guard let data = json.data(using: .utf8), let config = try? JSONDecoder().decode(WebsiteSourceConfiguration.self, from: data),
              ["http", "https"].contains(config.columnURL.scheme?.lowercased() ?? ""), config.columnURL.host != nil else {
            throw VoiceOSError("官网来源配置无效：需要 column_url（http 或 https 栏目地址）")
        }
        return config
    }

    static func dateKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func isoString(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    static func isoDate(_ text: String) -> Date? { ISO8601DateFormatter().date(from: text) }
}
