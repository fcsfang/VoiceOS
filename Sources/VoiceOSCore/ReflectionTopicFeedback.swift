import Foundation

public struct ReflectionTopicFeedback: Identifiable, Sendable {
    public let id: String
    public let mode: CognitiveFeedbackMode
    public let snoozedUntil: String?
    public let reviewedAt: String?
}

public struct ReflectionTopicResurfacing: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let sourceID: String
    public let quote: String
    public let reason: String
    public let idleDays: Int
}

extension VoiceOSStore {
    public func reflectionTopicFeedback() throws -> [ReflectionTopicFeedback] {
        guard ready else { throw VoiceOSError("资料库尚未完成恢复") }
        return try db.query("SELECT * FROM reflection_topic_feedback ORDER BY question_id").map {
            .init(id: $0["question_id"]!, mode: CognitiveFeedbackMode(rawValue: $0["mode"]!)!, snoozedUntil: $0["snoozed_until"], reviewedAt: $0["reviewed_at"])
        }
    }

    /// Feedback controls only quiet resurfacing, never the user's interest or
    /// whether a question is resolved. It does not invalidate topic evidence.
    public func saveTopicFeedback(questionID: String, mode: CognitiveFeedbackMode, snooze: Bool, now: Date = Date()) throws {
        guard try reflectionQuestions().contains(where: { $0.id == questionID }) else { throw VoiceOSError("找不到这个主题") }
        let existing = try reflectionTopicFeedback().first { $0.id == questionID }
        let effectiveMode = snooze ? existing?.mode ?? mode : mode
        let until = snooze ? ISO8601DateFormatter().string(from: now.addingTimeInterval(7 * 86_400)) : nil
        let reviewedAt = !snooze && mode == .reduced ? ISO8601DateFormatter().string(from: now) : existing?.reviewedAt
        try db.execute("""
        INSERT INTO reflection_topic_feedback(id,question_id,mode,snoozed_until,reviewed_at) VALUES(?,?,?,?,?)
        ON CONFLICT(question_id) DO UPDATE SET mode=excluded.mode,snoozed_until=excluded.snoozed_until,reviewed_at=excluded.reviewed_at
        """, [UUID().uuidString,questionID,effectiveMode.rawValue,until,reviewedAt])
    }

    public func markTopicReviewed(questionID: String, now: Date = Date()) throws {
        guard try reflectionQuestions().contains(where: { $0.id == questionID }) else { throw VoiceOSError("找不到这个主题") }
        try db.execute("""
        INSERT INTO reflection_topic_feedback(id,question_id,mode,reviewed_at) VALUES(?,?,'normal',?)
        ON CONFLICT(question_id) DO UPDATE SET reviewed_at=excluded.reviewed_at
        """, [UUID().uuidString,questionID,ISO8601DateFormatter().string(from: now)])
    }

    /// A local, explainable candidate. Age alone never resurfaces arbitrary
    /// notes; only a still-available personal question or an unattached trial
    /// is shown. No AI reassessment, notification, or task commitment occurs.
    public func topicResurfacing(now: Date = Date()) throws -> [ReflectionTopicResurfacing] {
        let globalMode = try cognitiveFeedbackPreference().mode
        guard globalMode != .paused else { return [] }
        let feedback = Dictionary(uniqueKeysWithValues: try reflectionTopicFeedback().map { ($0.id,$0) })
        let catalog = Dictionary(uniqueKeysWithValues: try sources().map { ($0.id,$0) })
        func usable(_ id: String) -> Bool {
            guard let source = catalog[id] else { return false }
            return ["saved","reference_only"].contains(source.state) && source.transcript?.isEmpty == false
        }
        var result: [ReflectionTopicResurfacing] = []
        for question in try reflectionQuestions() {
            let preference = feedback[question.id]
            guard preference?.mode != .paused,
                  preference?.snoozedUntil.flatMap(ConversationReflectionFocus.date).map({ $0 <= now }) ?? true,
                  usable(question.sourceID), catalog[question.sourceID]?.transcript == question.title,
                  let updated = ConversationReflectionFocus.date(question.updatedAt) else { continue }
            let lastVisit = preference?.reviewedAt.flatMap(ConversationReflectionFocus.date) ?? updated
            let days = Int(now.timeIntervalSince(max(updated,lastVisit)) / 86_400)
            let reduced = preference?.mode == .reduced || globalMode == .reduced
            guard days >= (reduced ? 30 : 14) else { continue }
            let entries = try reflectionQuestionEntries(questionID: question.id).filter { $0.unavailableSourceIDs.isEmpty && usable($0.sourceID) }
            if let experiment = entries.reversed().first(where: { entry in
                entry.kind == .experiment && !entries.contains { $0.kind == .result && $0.sourceIDs.contains(entry.sourceID) }
            }) {
                result.append(.init(id: question.id, title: question.title, sourceID: experiment.sourceID, quote: experiment.text,
                    reason: "这个主题已有 \(days) 天没有新增或重访记录；这条小验证还没有附上对应结果。可以继续看，也可以稍后再说。", idleDays: days))
            } else if let entry = entries.reversed().first(where: { $0.kind != .result && Self.isExplicitTopicQuestion($0.text) }) {
                result.append(.init(id: question.id, title: question.title, sourceID: entry.sourceID, quote: entry.text,
                    reason: "这个主题已有 \(days) 天没有新增或重访记录；你曾留下这段疑问。现在是否还有价值，由你决定。", idleDays: days))
            } else if Self.isExplicitTopicQuestion(question.title) {
                result.append(.init(id: question.id, title: question.title, sourceID: question.sourceID, quote: question.title,
                    reason: "这个问题已有 \(days) 天没有新增或重访记录。可以接着探索；这不代表它仍未解决，也不要求你回应。", idleDays: days))
            }
        }
        return result.sorted { $0.idleDays == $1.idleDays ? $0.id < $1.id : $0.idleDays > $1.idleDays }
    }

    private static func isExplicitTopicQuestion(_ text: String) -> Bool {
        text.contains("？") || text.contains("?") || ["如何", "怎样", "为什么", "是否"].contains { text.hasPrefix($0) }
    }

    static func validateStoredTopicFeedback(_ database: Database) throws {
        for row in try database.query("SELECT * FROM reflection_topic_feedback") {
            guard CognitiveFeedbackMode(rawValue: row["mode"] ?? "") != nil,
                  try !database.query("SELECT id FROM reflection_questions WHERE id=?", [row["question_id"]]).isEmpty,
                  row["snoozed_until"].map({ ConversationReflectionFocus.date($0) != nil }) ?? true,
                  row["reviewed_at"].map({ ConversationReflectionFocus.date($0) != nil }) ?? true else { throw VoiceOSError("主题静默反馈设置无效") }
        }
    }
}
