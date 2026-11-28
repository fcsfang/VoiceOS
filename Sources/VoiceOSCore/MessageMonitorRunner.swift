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
                    let start = MonitorSourceConfigParser.parseStart(config.startAt)
                    let collected = try await websiteCollector.collect(columnURL: config.columnURL)
                    let entries = collected.filter { entry in
                        guard let start, let published = entry.publishedAt else { return true }
                        return published >= start
                    }
                    drafts = entries.map { entry in
                        var meta: [String: Any] = ["url": entry.url, "title": entry.title]
                        if let note = entry.note { meta["error"] = note }
                        if entry.publishedAt == nil { meta["date_missing"] = true }
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
        let pending = try await store.unanalyzedMonitorMessages(sourceIDs: sources.map(\.id))
        if pending.isEmpty {
            let existing = try await store.monitorReport(date: key)
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
        let input = try await analysisInput(messages: pending, statuses: statuses)
        let state: MonitorReportState = anyFailure ? .incomplete : .complete
        do {
            let result = try await analysis.analyze(input)
            let reportID = try await store.upsertMonitorReport(date: key, state: state, headline: result.headline,
                                                               summary: result.summary, sourceStatus: statuses)
            let itemCount = try await store.applyMonitorAnalysis(reportID: reportID, date: key, items: result.items,
                                                                 analyzedMessageIDs: pending.map(\.id))
            return MonitorRunResult(reportDate: key, state: state, headline: result.headline, summary: result.summary,
                                    itemCount: itemCount, newMessageCount: newMessages.count, sourceStatus: statuses)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let headline = "分析未完成"
            let summary = "已保存 \(pending.count) 条未分析原文，但模型分析失败：" + error.localizedDescription
                + "。可稍后重试分析，不需要重新采集。"
            _ = try await store.upsertMonitorReport(date: key, state: .failed, headline: headline,
                                                    summary: summary, sourceStatus: statuses)
            return MonitorRunResult(reportDate: key, state: .failed, headline: headline, summary: summary,
                                    itemCount: 0, newMessageCount: newMessages.count, sourceStatus: statuses)
        }
    }

    /// Retries only the model step over every message no stored analysis has
    /// consumed yet. The cursor's last_run_message_ids stays written for old
    /// readers but no longer decides the input.
    public func retryAnalysis(reportDate: Date) async throws -> MonitorRunResult {
        let key = Self.dateKey(reportDate)
        let report = try await store.monitorReport(date: key)
        let sources = try await store.enabledMonitorSources()
        let messages = try await store.unanalyzedMonitorMessages(sourceIDs: sources.map(\.id))
        guard !messages.isEmpty else {
            if let report, report.state != .failed {
                return MonitorRunResult(reportDate: key, state: report.state, headline: report.headline,
                                        summary: report.summary, itemCount: report.itemCount,
                                        newMessageCount: 0, sourceStatus: report.sourceStatus)
            }
            let headline = "检查完成，无新增待办"
            let summary = "检查完成，无新增待办。"
            let statuses = report?.sourceStatus ?? []
            _ = try await store.upsertMonitorReport(date: key, state: .complete, headline: headline,
                                                    summary: summary, sourceStatus: statuses)
            return MonitorRunResult(reportDate: key, state: .complete, headline: headline, summary: summary,
                                    itemCount: 0, newMessageCount: 0, sourceStatus: statuses)
        }
        guard let analysis else { throw VoiceOSError("未配置分析模型端口，无法重试分析") }
        let statuses = report?.sourceStatus ?? []
        let state: MonitorReportState = statuses.contains { !$0.ok } ? .incomplete : .complete
        let input = try await analysisInput(messages: messages, statuses: statuses)
        let result = try await analysis.analyze(input)
        let reportID = try await store.upsertMonitorReport(date: key, state: state, headline: result.headline,
                                                           summary: result.summary, sourceStatus: statuses)
        let itemCount = try await store.applyMonitorAnalysis(reportID: reportID, date: key, items: result.items,
                                                             analyzedMessageIDs: messages.map(\.id))
        return MonitorRunResult(reportDate: key, state: state, headline: result.headline, summary: result.summary,
                                itemCount: itemCount, newMessageCount: 0, sourceStatus: statuses)
    }

    private func analysisInput(messages: [MonitorMessage], statuses: [MonitorSourceStatus]) async throws -> NotificationAnalysisInput {
        let sources = try await store.monitorSources()
        let descriptors = sources.map { NotificationSourceDescriptor(sourceID: $0.id, displayName: $0.displayName, kind: $0.kind) }
        let existing = try await store.openMonitorItems().map {
            NotificationExistingItem(id: $0.id, title: $0.title, deadlineDate: $0.deadlineDate, category: $0.category)
        }
        let inputs = messages.map { Self.notificationInput(for: $0) }
        let states = statuses.map { NotificationSourceState(sourceID: $0.sourceID, ok: $0.ok, error: $0.error) }
        let digest = VoiceOSStore.relevanceHash(Data((inputs.map { $0.sourceID + "\u{0}" + $0.externalID } + existing.map(\.id))
            .joined(separator: "\n").utf8))
        return NotificationAnalysisInput(sources: descriptors, messages: inputs, existingItems: existing,
                                         sourceStatus: states, digest: digest)
    }

    /// The quoted text and type marker ride inside the message text because
    /// both stay fixed-length; batch slicing already budgets text by scalars.
    static func notificationInput(for message: MonitorMessage) -> NotificationMessageInput {
        let markers = analysisMarkers(kind: message.kind, metaJSON: message.metaJSON)
        let text = markers.isEmpty ? message.content : message.content + " " + markers.joined(separator: " ")
        return NotificationMessageInput(sourceID: message.sourceID, externalID: message.externalID, kind: message.kind,
                                        senderName: message.senderName, sentAt: message.sentAt, text: text,
                                        needsReview: message.kind != .text && message.kind != .article)
    }

    static func analysisMarkers(kind: MonitorMessageKind, metaJSON: String?) -> [String] {
        var markers: [String] = []
        switch kind {
        case .image, .file, .forward, .other:
            markers.append("（类型：\(MonitorEvidenceBuilder.kindLabel(kind))）")
        case .text, .article:
            break
        }
        if let reply = MonitorMessageMeta.replyContext(metaJSON) {
            markers.append("（回复：\(MonitorEvidenceBuilder.truncated(reply.content, limit: 80))）")
        }
        return markers
    }

    private struct QQSourceConfiguration: Decodable {
        let conversationID: String
        enum CodingKeys: String, CodingKey { case conversationID = "conversation_id" }
    }

    private struct WebsiteSourceConfiguration: Decodable {
        let columnURL: URL
        let startAt: String?
        enum CodingKeys: String, CodingKey {
            case columnURL = "column_url"
            case startAt = "start_at"
        }
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

    static func dateKey(_ date: Date) -> String { TimestampFormatting.dayString(date) }

    static func isoString(_ date: Date) -> String { TimestampFormatting.iso.string(from: date) }

    static func isoDate(_ text: String) -> Date? { TimestampFormatting.iso.date(from: text) }
}

/// The quoted message as qq_read_range.py forwards it inside meta.replyContext.
struct MonitorReplyContext: Equatable {
    let accountName: String?
    let content: String
}

enum MonitorMessageMeta {
    static func replyContext(_ metaJSON: String?) -> MonitorReplyContext? {
        guard let object = object(metaJSON),
              let reply = object["replyContext"] as? [String: Any],
              let content = (reply["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else { return nil }
        let name = (reply["accountName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return MonitorReplyContext(accountName: name?.isEmpty == false ? name : nil, content: content)
    }

    private static func object(_ json: String?) -> [String: Any]? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

/// Presentation data for one evidence row: what kind of message it is, what it
/// said, and what it quoted. Rows survive deleted messages as a source-name
/// fallback so an item never loses its provenance.
public struct MonitorEvidenceRecord: Identifiable, Sendable, Equatable {
    public let id: String
    public let sourceID: String
    public let sourceName: String
    public let sourceKind: MonitorSourceKind?
    public let kind: MonitorMessageKind?
    public let sender: String?
    public let sentAt: String?
    public let url: String?
    public let title: String?
    public let excerpt: String
    public let replyQuote: String?
    public let missing: Bool
}

public enum MonitorEvidenceBuilder {
    public static let excerptLimit = 120

    public static func kindLabel(_ kind: MonitorMessageKind?) -> String {
        switch kind {
        case .text?: return "文本"
        case .image?: return "图片"
        case .file?: return "文件"
        case .forward?: return "合并转发"
        case .other?: return "语音"
        case .article?: return "网页"
        case nil: return ""
        }
    }

    public static func truncated(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }

    public static func build(refs: [NotificationSourceRef], messagesBySource: [String: [MonitorMessage]],
                             sourceNames: [String: String],
                             sourceKinds: [String: MonitorSourceKind]) -> [MonitorEvidenceRecord] {
        var orderedSources: [String] = []
        var expectedBySource: [String: [String]] = [:]
        for ref in refs {
            if expectedBySource[ref.sourceID] == nil { orderedSources.append(ref.sourceID) }
            if let externalID = ref.externalID,
               expectedBySource[ref.sourceID, default: []].contains(externalID) == false {
                expectedBySource[ref.sourceID, default: []].append(externalID)
            }
        }
        var records: [MonitorEvidenceRecord] = []
        for sourceID in orderedSources {
            let name = sourceNames[sourceID] ?? "监测来源"
            let sourceKind = sourceKinds[sourceID]
            let expected = expectedBySource[sourceID] ?? []
            let messages = messagesBySource[sourceID] ?? []
            let foundIDs = Set(messages.map(\.externalID))
            for message in messages {
                let meta = metaObject(message.metaJSON)
                records.append(MonitorEvidenceRecord(
                    id: message.id, sourceID: sourceID, sourceName: name, sourceKind: sourceKind,
                    kind: message.kind, sender: message.senderName, sentAt: message.sentAt,
                    url: meta["url"] as? String, title: meta["title"] as? String,
                    excerpt: truncated(message.content, limit: excerptLimit),
                    replyQuote: replyQuote(message.metaJSON), missing: false))
            }
            if expected.isEmpty {
                records.append(MonitorEvidenceRecord(
                    id: "source:" + sourceID, sourceID: sourceID, sourceName: name, sourceKind: sourceKind,
                    kind: nil, sender: nil, sentAt: nil, url: nil, title: nil,
                    excerpt: "", replyQuote: nil, missing: false))
            } else if expected.contains(where: { !foundIDs.contains($0) }) {
                records.append(MonitorEvidenceRecord(
                    id: "missing:" + sourceID, sourceID: sourceID, sourceName: name, sourceKind: sourceKind,
                    kind: nil, sender: nil, sentAt: nil, url: nil, title: nil,
                    excerpt: "", replyQuote: nil, missing: true))
            }
        }
        return records
    }

    static func replyQuote(_ metaJSON: String?) -> String? {
        guard let reply = MonitorMessageMeta.replyContext(metaJSON) else { return nil }
        let content = truncated(reply.content, limit: excerptLimit)
        guard !content.isEmpty else { return nil }
        if let name = reply.accountName, !name.isEmpty { return "引用：" + name + "：" + content }
        return "引用：" + content
    }

    private static func metaObject(_ json: String?) -> [String: Any] {
        guard let json, let data = json.data(using: .utf8) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
