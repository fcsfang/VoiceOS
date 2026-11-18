import Foundation
import CryptoKit

public enum MonitorSourceKind: String, Codable, Sendable, Equatable {
    case qqGroup = "qq-group"
    case websiteColumn = "website-column"
}

public struct MonitorSource: Identifiable, Sendable, Equatable {
    public let id: String
    public let kind: MonitorSourceKind
    public let displayName: String
    public let configJSON: String
    public let enabled: Bool
    public let createdAt: String
    public let updatedAt: String
    public init(id: String, kind: MonitorSourceKind, displayName: String, configJSON: String, enabled: Bool, createdAt: String, updatedAt: String) {
        self.id = id; self.kind = kind; self.displayName = displayName; self.configJSON = configJSON
        self.enabled = enabled; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

public enum MonitorMessageKind: String, Codable, Sendable, Equatable {
    case text, image, file, forward, article, other
}

public struct MonitorMessageDraft: Sendable, Equatable {
    public let sourceID: String
    public let externalID: String
    public let kind: MonitorMessageKind
    public let senderName: String?
    public let sentAt: String?
    public let content: String
    public let metaJSON: String?
    public init(sourceID: String, externalID: String, kind: MonitorMessageKind, senderName: String?, sentAt: String?, content: String, metaJSON: String?) {
        self.sourceID = sourceID; self.externalID = externalID; self.kind = kind
        self.senderName = senderName; self.sentAt = sentAt; self.content = content; self.metaJSON = metaJSON
    }
}

public struct MonitorMessage: Identifiable, Sendable, Equatable {
    public let id: String
    public let sourceID: String
    public let externalID: String
    public let kind: MonitorMessageKind
    public let senderName: String?
    public let sentAt: String?
    public let collectedAt: String
    public let content: String
    public let metaJSON: String?
    public init(id: String, sourceID: String, externalID: String, kind: MonitorMessageKind, senderName: String?, sentAt: String?, collectedAt: String, content: String, metaJSON: String?) {
        self.id = id; self.sourceID = sourceID; self.externalID = externalID; self.kind = kind
        self.senderName = senderName; self.sentAt = sentAt; self.collectedAt = collectedAt
        self.content = content; self.metaJSON = metaJSON
    }
}

public struct MonitorCursor: Sendable, Equatable {
    public let sourceID: String
    public let cursorJSON: String
    public let lastSuccessAt: String?
    public let lastError: String?
    public let updatedAt: String
    public init(sourceID: String, cursorJSON: String, lastSuccessAt: String?, lastError: String?, updatedAt: String) {
        self.sourceID = sourceID; self.cursorJSON = cursorJSON; self.lastSuccessAt = lastSuccessAt
        self.lastError = lastError; self.updatedAt = updatedAt
    }
}

public enum MonitorReportState: String, Codable, Sendable, Equatable {
    case complete, incomplete, failed
}

public struct MonitorSourceStatus: Codable, Sendable, Equatable {
    public let sourceID: String
    public let displayName: String
    public let ok: Bool
    public let newMessageCount: Int
    public let error: String?
    public init(sourceID: String, displayName: String, ok: Bool, newMessageCount: Int, error: String?) {
        self.sourceID = sourceID; self.displayName = displayName; self.ok = ok
        self.newMessageCount = newMessageCount; self.error = error
    }
}

public struct MonitorReport: Identifiable, Sendable, Equatable {
    public let id: String
    public let reportDate: String
    public let state: MonitorReportState
    public let headline: String
    public let summary: String
    public let sourceStatus: [MonitorSourceStatus]
    public let itemCount: Int
    public let createdAt: String
    public let deliveredAt: String?
    public let deliveryState: String
    public let deliveryError: String?
    public let payloadJSON: String?
    public init(id: String, reportDate: String, state: MonitorReportState, headline: String, summary: String, sourceStatus: [MonitorSourceStatus], itemCount: Int, createdAt: String, deliveredAt: String?, deliveryState: String, deliveryError: String?, payloadJSON: String?) {
        self.id = id; self.reportDate = reportDate; self.state = state; self.headline = headline; self.summary = summary
        self.sourceStatus = sourceStatus; self.itemCount = itemCount; self.createdAt = createdAt
        self.deliveredAt = deliveredAt; self.deliveryState = deliveryState
        self.deliveryError = deliveryError; self.payloadJSON = payloadJSON
    }
}

/// Attention for the daily monitor report. A report is resolved only when the
/// check completed and delivery did not fail; until then the badge stays, no
/// matter how often the monitor page was opened. The page may write a seen
/// signature only after the report resolves.
public enum MonitorAttention {
    public static let seenKey = "voiceos.monitor.attentionSeen.v1"
    public static func isResolved(_ report: MonitorReport) -> Bool {
        report.state == .complete && report.deliveryState != "failed"
    }
    public static func signature(for report: MonitorReport) -> String {
        report.reportDate + "|" + report.state.rawValue + "|" + report.deliveryState
    }
    public static func needsAttention(_ report: MonitorReport?) -> Bool {
        guard let report else { return false }
        return !isResolved(report)
    }
    /// The signature to persist when the monitor page opens, or nil when the
    /// latest report is not resolved and the badge must stay.
    public static func seenSignatureWhenOpened(for report: MonitorReport?) -> String? {
        guard let report, isResolved(report) else { return nil }
        return signature(for: report)
    }
}

public enum MonitorItemCategory: String, Codable, Sendable, Equatable {
    case applicable
    case needsCheck = "needs_check"
}

public enum MonitorItemStatus: String, Codable, Sendable, Equatable {
    case open, done, dismissed
}

public struct MonitorItem: Identifiable, Sendable, Equatable {
    public let id: String
    public let reportID: String
    public let title: String
    public let whyRelevant: String
    public let suggestedAction: String
    public let deadlineText: String?
    public let deadlineDate: String?
    public let conditions: String?
    public let evidenceQuote: String
    public let sourceRefsJSON: String
    public let uncertainty: String?
    public let category: MonitorItemCategory
    public let status: MonitorItemStatus
    public let relatedItemID: String?
    public let firstSeenDate: String
    public let lastUpdatedDate: String
    public let createdAt: String
    public let updatedAt: String
    public init(id: String, reportID: String, title: String, whyRelevant: String, suggestedAction: String, deadlineText: String?, deadlineDate: String?, conditions: String?, evidenceQuote: String, sourceRefsJSON: String, uncertainty: String?, category: MonitorItemCategory, status: MonitorItemStatus, relatedItemID: String?, firstSeenDate: String, lastUpdatedDate: String, createdAt: String, updatedAt: String) {
        self.id = id; self.reportID = reportID; self.title = title; self.whyRelevant = whyRelevant
        self.suggestedAction = suggestedAction; self.deadlineText = deadlineText; self.deadlineDate = deadlineDate
        self.conditions = conditions; self.evidenceQuote = evidenceQuote; self.sourceRefsJSON = sourceRefsJSON
        self.uncertainty = uncertainty; self.category = category; self.status = status
        self.relatedItemID = relatedItemID; self.firstSeenDate = firstSeenDate
        self.lastUpdatedDate = lastUpdatedDate; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

extension VoiceOSStore {
    public func addMonitorSource(kind: MonitorSourceKind, displayName: String, configJSON: String, enabled: Bool = true) throws -> MonitorSource {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw VoiceOSError("监测来源需要名称") }
        try Self.validateMonitorConfigJSON(configJSON)
        let id = UUID().uuidString, now = Self.now()
        try db.execute("INSERT INTO monitor_sources(id,kind,display_name,config_json,enabled,created_at,updated_at) VALUES(?,?,?,?,?,?,?)",
                       [id, kind.rawValue, name, configJSON, enabled ? "1" : "0", now, now])
        return MonitorSource(id: id, kind: kind, displayName: name, configJSON: configJSON, enabled: enabled, createdAt: now, updatedAt: now)
    }

    public func updateMonitorSource(id: String, displayName: String, configJSON: String, enabled: Bool) throws -> MonitorSource {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw VoiceOSError("监测来源需要名称") }
        try Self.validateMonitorConfigJSON(configJSON)
        let now = Self.now()
        try db.execute("UPDATE monitor_sources SET display_name=?,config_json=?,enabled=?,updated_at=? WHERE id=?",
                       [name, configJSON, enabled ? "1" : "0", now, id])
        guard let source = try monitorSources().first(where: { $0.id == id }) else { throw VoiceOSError("监测来源不存在") }
        return source
    }

    public func removeMonitorSource(id: String) throws {
        try db.transaction {
            try db.execute("DELETE FROM monitor_messages WHERE source_id=?", [id])
            try db.execute("DELETE FROM monitor_cursors WHERE source_id=?", [id])
            try db.execute("DELETE FROM monitor_sources WHERE id=?", [id])
        }
    }

    public func monitorSources() throws -> [MonitorSource] {
        try db.query("SELECT * FROM monitor_sources ORDER BY created_at, id").map { row in
            MonitorSource(id: row["id"]!, kind: MonitorSourceKind(rawValue: row["kind"]!) ?? .websiteColumn,
                          displayName: row["display_name"]!, configJSON: row["config_json"]!,
                          enabled: row["enabled"] == "1", createdAt: row["created_at"]!, updatedAt: row["updated_at"]!)
        }
    }

    public func enabledMonitorSources() throws -> [MonitorSource] {
        try monitorSources().filter(\.enabled)
    }

    /// Inserts only messages whose (source, external id) pair is new; the
    /// overlap window may re-read the same rows without duplicating them.
    public func insertMonitorMessages(_ drafts: [MonitorMessageDraft]) throws -> [MonitorMessage] {
        var inserted: [MonitorMessage] = []
        let now = Self.now()
        try db.transaction {
            for draft in drafts {
                let id = UUID().uuidString
                let hash = SHA256.hash(data: Data(draft.content.utf8)).map { String(format: "%02x", $0) }.joined()
                try db.execute("""
                    INSERT OR IGNORE INTO monitor_messages(id,source_id,external_id,kind,sender_name,sent_at,collected_at,content,content_sha256,meta_json)
                    VALUES(?,?,?,?,?,?,?,?,?,?)
                    """, [id, draft.sourceID, draft.externalID, draft.kind.rawValue, draft.senderName,
                          draft.sentAt, now, draft.content, hash, draft.metaJSON])
                guard db.lastChangeCount() == 1 else { continue }
                inserted.append(MonitorMessage(id: id, sourceID: draft.sourceID, externalID: draft.externalID,
                                               kind: draft.kind, senderName: draft.senderName, sentAt: draft.sentAt,
                                               collectedAt: now, content: draft.content, metaJSON: draft.metaJSON))
            }
        }
        return inserted
    }

    public func monitorMessages(ids: [String]) throws -> [MonitorMessage] {
        guard !ids.isEmpty else { return [] }
        var messages: [MonitorMessage] = []
        var start = 0
        while start < ids.count {
            let chunk = Array(ids[start..<min(start + 500, ids.count)])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            for row in try db.query("SELECT * FROM monitor_messages WHERE id IN (\(placeholders)) ORDER BY sent_at, external_id", chunk.map(Optional.some)) {
                messages.append(Self.monitorMessage(row))
            }
            start += 500
        }
        return messages
    }

    public func monitorCursor(sourceID: String) throws -> MonitorCursor? {
        guard let row = try db.query("SELECT * FROM monitor_cursors WHERE source_id=?", [sourceID]).first else { return nil }
        return MonitorCursor(sourceID: row["source_id"]!, cursorJSON: row["cursor_json"]!,
                             lastSuccessAt: row["last_success_at"], lastError: row["last_error"], updatedAt: row["updated_at"]!)
    }

    /// Advances only after the batch's messages are durable. The cursor keeps
    /// the run's message ids so a failed analysis can retry without re-collecting.
    public func advanceMonitorCursor(sourceID: String, lastSuccessEnd: Date, newMessageIDs: [String]) throws {
        struct CursorState: Encodable { let last_success_end: String; let last_run_message_ids: [String] }
        let iso = ISO8601DateFormatter().string(from: lastSuccessEnd)
        let cursor = try Self.relevanceJSON(CursorState(last_success_end: iso, last_run_message_ids: newMessageIDs))
        try db.execute("""
            INSERT INTO monitor_cursors(source_id,cursor_json,last_success_at,last_error,updated_at) VALUES(?,?,?,NULL,?)
            ON CONFLICT(source_id) DO UPDATE SET cursor_json=excluded.cursor_json,last_success_at=excluded.last_success_at,last_error=NULL,updated_at=excluded.updated_at
            """, [sourceID, cursor, iso, Self.now()])
    }

    public func failMonitorCursor(sourceID: String, error: String) throws {
        try db.execute("""
            INSERT INTO monitor_cursors(source_id,cursor_json,last_success_at,last_error,updated_at) VALUES(?,'{}',NULL,?,?)
            ON CONFLICT(source_id) DO UPDATE SET last_error=excluded.last_error,updated_at=excluded.updated_at
            """, [sourceID, error, Self.now()])
    }

    @discardableResult
    public func upsertMonitorReport(date: String, state: MonitorReportState, headline: String, summary: String, sourceStatus: [MonitorSourceStatus], payloadJSON: String? = nil) throws -> String {
        let statusJSON = String(decoding: try JSONEncoder().encode(sourceStatus), as: UTF8.self)
        try db.execute("""
            INSERT INTO monitor_reports(id,report_date,state,headline,summary,source_status_json,item_count,created_at,delivery_state,payload_json)
            VALUES(?,?,?,?,?,?,0,?,'pending',?)
            ON CONFLICT(report_date) DO UPDATE SET state=excluded.state,headline=excluded.headline,summary=excluded.summary,
              source_status_json=excluded.source_status_json,payload_json=COALESCE(excluded.payload_json,monitor_reports.payload_json)
            """, [UUID().uuidString, date, state.rawValue, headline, summary, statusJSON, Self.now(), payloadJSON])
        guard let id = try db.query("SELECT id FROM monitor_reports WHERE report_date=?", [date]).first?["id"] else {
            throw VoiceOSError("报告保存失败")
        }
        return id
    }

    /// Items linked to an existing item update that row in place, keeping the
    /// user's status (including done and dismissed); only an unknown link
    /// creates a new row. The report's item count always reflects every item
    /// currently carried in it.
    /// The analyzed message ids are marked in the same transaction as the
    /// items, so a crash after analysis never strands or double-consumes text.
    public func applyMonitorAnalysis(reportID: String, date: String, items: [NotificationAnalysisItem], analyzedMessageIDs: [String] = []) throws -> Int {
        let now = Self.now()
        return try db.transaction {
            var touchedReports = Set<String>()
            for item in items {
                let refsJSON = try Self.relevanceJSON(item.sourceRefs)
                var updatedOpenItem = false
                if let relatedID = item.relatedExistingItemID,
                   let existing = try db.query("SELECT id,report_id FROM monitor_items WHERE id=?", [relatedID]).first {
                    if let previous = existing["report_id"], previous != reportID { touchedReports.insert(previous) }
                    try db.execute("""
                        UPDATE monitor_items SET report_id=?,title=?,why_relevant=?,suggested_action=?,deadline_text=?,deadline_date=?,
                          conditions=?,evidence_quote=?,source_refs_json=?,uncertainty=?,category=?,last_updated_date=?,updated_at=?
                        WHERE id=?
                        """, [reportID, item.title, item.whyRelevant, item.suggestedAction, item.deadlineText, item.deadlineDate,
                              item.conditions, item.evidenceQuote, refsJSON, item.uncertainty, item.category.rawValue, date, now, relatedID])
                    updatedOpenItem = true
                }
                guard !updatedOpenItem else { continue }
                try db.execute("""
                    INSERT INTO monitor_items(id,report_id,title,why_relevant,suggested_action,deadline_text,deadline_date,conditions,
                      evidence_quote,source_refs_json,uncertainty,category,status,related_item_id,first_seen_date,last_updated_date,created_at,updated_at)
                    VALUES(?,?,?,?,?,?,?,?,?,?,?,?,'open',?,?,?,?,?)
                    """, [UUID().uuidString, reportID, item.title, item.whyRelevant, item.suggestedAction, item.deadlineText,
                          item.deadlineDate, item.conditions, item.evidenceQuote, refsJSON, item.uncertainty,
                          item.category.rawValue, item.relatedExistingItemID, date, date, now, now])
            }
            var start = 0
            while start < analyzedMessageIDs.count {
                let chunk = analyzedMessageIDs[start..<min(start + 500, analyzedMessageIDs.count)]
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                let arguments: [String?] = [reportID] + chunk.map(Optional.some)
                try db.execute("UPDATE monitor_messages SET analyzed_report_id=? WHERE id IN (\(placeholders)) AND analyzed_report_id IS NULL",
                               arguments)
                start += 500
            }
            for touched in touchedReports.union([reportID]) {
                let count = Int(try db.query("SELECT COUNT(*) AS n FROM monitor_items WHERE report_id=?", [touched]).first?["n"] ?? "0") ?? 0
                try db.execute("UPDATE monitor_reports SET item_count=? WHERE id=?", [String(count), touched])
            }
            return Int(try db.query("SELECT COUNT(*) AS n FROM monitor_items WHERE report_id=?", [reportID]).first?["n"] ?? "0") ?? 0
        }
    }

    public func monitorReport(date: String) throws -> MonitorReport? {
        guard let row = try db.query("SELECT * FROM monitor_reports WHERE report_date=?", [date]).first else { return nil }
        return try Self.monitorReport(row)
    }

    public func latestMonitorReport() throws -> MonitorReport? {
        guard let row = try db.query("SELECT * FROM monitor_reports ORDER BY report_date DESC LIMIT 1").first else { return nil }
        return try Self.monitorReport(row)
    }

    public func monitorReports(limit: Int = 30) throws -> [MonitorReport] {
        try db.query("SELECT * FROM monitor_reports ORDER BY report_date DESC LIMIT ?", [String(max(1, limit))]).map { try Self.monitorReport($0) }
    }

    public func monitorItems(reportID: String) throws -> [MonitorItem] {
        try db.query("SELECT * FROM monitor_items WHERE report_id=? ORDER BY COALESCE(deadline_date,'9999-12-31'), created_at, id", [reportID]).map(Self.monitorItem)
    }

    public func openMonitorItems() throws -> [MonitorItem] {
        try db.query("SELECT * FROM monitor_items WHERE status='open' ORDER BY COALESCE(deadline_date,'9999-12-31'), last_updated_date DESC, id").map(Self.monitorItem)
    }

    public func setMonitorItemStatus(id: String, status: MonitorItemStatus) throws {
        try db.execute("UPDATE monitor_items SET status=?,updated_at=? WHERE id=?", [status.rawValue, Self.now(), id])
    }

    public func monitorReport(id: String) throws -> MonitorReport? {
        guard let row = try db.query("SELECT * FROM monitor_reports WHERE id=?", [id]).first else { return nil }
        return try Self.monitorReport(row)
    }

    /// The payload is written before the network call so a failed send keeps
    /// exactly what was attempted and can be retried without rebuilding it.
    public func setMonitorReportPayload(id: String, payloadJSON: String) throws {
        try db.execute("UPDATE monitor_reports SET payload_json=? WHERE id=?", [payloadJSON, id])
    }

    public func markMonitorReportDelivered(id: String, at deliveredAt: String) throws {
        try db.execute("UPDATE monitor_reports SET delivery_state='delivered',delivery_error=NULL,delivered_at=? WHERE id=?",
                       [deliveredAt, id])
    }

    public func markMonitorReportDeliveryFailed(id: String, error: String) throws {
        try db.execute("UPDATE monitor_reports SET delivery_state='failed',delivery_error=? WHERE id=?", [error, id])
    }

    public func monitorMessageCount(sourceID: String) throws -> Int {
        Int(try db.query("SELECT COUNT(*) AS n FROM monitor_messages WHERE source_id=?", [sourceID]).first?["n"] ?? "0") ?? 0
    }

    public func monitorLatestMessageSentAt(sourceID: String) throws -> String? {
        try db.query("SELECT MAX(sent_at) AS latest FROM monitor_messages WHERE source_id=?", [sourceID]).first?["latest"]
    }

    public func monitorMessages(sourceID: String, externalIDs: [String]) throws -> [MonitorMessage] {
        let ids = Array(Set(externalIDs)).sorted()
        guard !ids.isEmpty else { return [] }
        var messages: [MonitorMessage] = []
        var start = 0
        while start < ids.count {
            let chunk = Array(ids[start..<min(start + 500, ids.count)])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let arguments: [String?] = [sourceID] + chunk.map(Optional.some)
            for row in try db.query("SELECT * FROM monitor_messages WHERE source_id=? AND external_id IN (\(placeholders)) ORDER BY sent_at, external_id", arguments) {
                messages.append(Self.monitorMessage(row))
            }
            start += 500
        }
        return messages
    }

    /// Messages from the given sources that no stored analysis has consumed
    /// yet. This is the analysis input, so a failed or unauthorized run never
    /// strands collected text behind a cursor.
    public func unanalyzedMonitorMessages(sourceIDs: [String]) throws -> [MonitorMessage] {
        let ids = Array(Set(sourceIDs)).sorted()
        guard !ids.isEmpty else { return [] }
        var messages: [MonitorMessage] = []
        var start = 0
        while start < ids.count {
            let chunk = Array(ids[start..<min(start + 500, ids.count)])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            for row in try db.query("""
                SELECT * FROM monitor_messages WHERE source_id IN (\(placeholders)) AND analyzed_report_id IS NULL
                ORDER BY COALESCE(sent_at, collected_at), external_id
                """, chunk.map(Optional.some)) {
                messages.append(Self.monitorMessage(row))
            }
            start += 500
        }
        return messages
    }

    private static func validateMonitorConfigJSON(_ configJSON: String) throws {
        guard let data = configJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], !object.isEmpty else {
            throw VoiceOSError("监测来源配置必须是 JSON 对象")
        }
    }

    private static func monitorReport(_ row: [String: String]) throws -> MonitorReport {
        let statuses: [MonitorSourceStatus]
        if let json = row["source_status_json"], !json.isEmpty, let data = json.data(using: .utf8) {
            statuses = (try? JSONDecoder().decode([MonitorSourceStatus].self, from: data)) ?? []
        } else {
            statuses = []
        }
        return MonitorReport(id: row["id"]!, reportDate: row["report_date"]!,
                             state: MonitorReportState(rawValue: row["state"]!) ?? .failed,
                             headline: row["headline"]!, summary: row["summary"]!, sourceStatus: statuses,
                             itemCount: Int(row["item_count"] ?? "0") ?? 0, createdAt: row["created_at"]!,
                             deliveredAt: row["delivered_at"], deliveryState: row["delivery_state"] ?? "pending",
                             deliveryError: row["delivery_error"], payloadJSON: row["payload_json"])
    }

    private static func monitorMessage(_ row: [String: String]) -> MonitorMessage {
        MonitorMessage(id: row["id"]!, sourceID: row["source_id"]!, externalID: row["external_id"]!,
                       kind: MonitorMessageKind(rawValue: row["kind"]!) ?? .other,
                       senderName: row["sender_name"], sentAt: row["sent_at"], collectedAt: row["collected_at"]!,
                       content: row["content"]!, metaJSON: row["meta_json"])
    }

    private static func monitorItem(_ row: [String: String]) -> MonitorItem {
        MonitorItem(id: row["id"]!, reportID: row["report_id"]!, title: row["title"]!,
                    whyRelevant: row["why_relevant"]!, suggestedAction: row["suggested_action"]!,
                    deadlineText: row["deadline_text"], deadlineDate: row["deadline_date"],
                    conditions: row["conditions"], evidenceQuote: row["evidence_quote"]!,
                    sourceRefsJSON: row["source_refs_json"]!, uncertainty: row["uncertainty"],
                    category: MonitorItemCategory(rawValue: row["category"]!) ?? .needsCheck,
                    status: MonitorItemStatus(rawValue: row["status"]!) ?? .open,
                    relatedItemID: row["related_item_id"], firstSeenDate: row["first_seen_date"]!,
                    lastUpdatedDate: row["last_updated_date"]!, createdAt: row["created_at"]!, updatedAt: row["updated_at"]!)
    }
}
