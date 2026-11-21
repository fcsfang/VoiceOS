import Foundation

public struct RecordingTitleProposal: Codable, Sendable {
    public let sourceID: String
    public let title: String
    public let summary: String
    public let quotes: [String]
}
public struct RecordingTitleInput: Codable, Sendable {
    public let context: LocalTranscriptContext
    public let policies: [String: Int]
}
public struct RecordingPresentation: Codable, Sendable {
    public var archived: Bool?
    public var stateBeforeTrash: String?
    public var manualTitle: String?
    public var automatic: RecordingTitleProposal?
    public var transcriptVersionID: String?
    public var responseIDs: [String] = []
    public var transcriptionReview: TranscriptionReview?
    public var automaticInput: AutomaticRecordingInput?
    public var expression: RecordingExpression?
    public var recordingContext: RecordingContext?
    public var contextLinks: [RecordingContextLink]?
    public var correctedActionIDs: [String]?
    public var correctedSourceIDs: [String]?
    public var recordingUnderstandingIsCorrection: Bool?
    public var transcriptionReviewFailure: TranscriptionReviewFailure?
}
/// Why the last full-transcript review failed, scoped to the transcript and
/// policy version it ran against so a later correction retires it.
public struct TranscriptionReviewFailure: Codable, Sendable, Equatable {
    public let reason: String
    public let transcriptVersionID: String
    public let policyVersion: Int
    public let failedAt: Date
}
public struct TranscriptionReview: Codable, Sendable {
    public struct Correction: Codable, Sendable {
        public let span_id: String
        public let before: String
        public let after: String
        public let context_quote: String?
        public let reason: String
        public let independent_reason: String?
    }
    public struct Issue: Codable, Sendable {
        public let span_id: String
        public let reason: String
    }
    public let completed: Bool
    public let changed: Bool
    public let response_id: String
    public let response_ids: [String]?
    public let context_review_version: Int?
    public var corrections: [Correction]?
    public var correction_count: Int? = nil
    public let unresolved_issues: [Issue]?
    public var transcriptVersionID: String?
    public var scope: String? = nil
    public var full_text_independent_passes: Int? = nil
    public var review_method: String? = nil
    public var isCompleteFullTextReview: Bool {
        let receipts = (response_ids ?? []).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard completed &&
            scope == "complete_expression_knowledge_and_intent" &&
            !response_id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            receipts.contains(response_id) else { return false }
        if context_review_version == 3, review_method == "direct_ai" {
            return full_text_independent_passes == 1
        }
        return context_review_version == 2 && full_text_independent_passes == 2 && Set(receipts).count >= 2
    }
}
public protocol RecordingTitlePort: Sendable {
    func generate(_ input: RecordingTitleInput) async throws -> ([RecordingTitleProposal], [String])
}

/// The one title funnel for library rows and the search index: manual title,
/// version-checked automatic title, recording date, transcript fallback, then
/// the unnamed kind label.
public enum MaterialDisplayTitle {
    public static func title(name: String, kind: String, createdAt: String, timeZone: String,
                             presentation: RecordingPresentation?, transcript: String?,
                             transcriptVersionID: String?) -> String {
        if let manual = presentation?.manualTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !manual.isEmpty { return manual }
        if presentation?.transcriptVersionID == transcriptVersionID,
           let automatic = presentation?.automatic?.title,
           let title = MaterialTitleText.normalizedGenerated(automatic) { return title }
        if ["audio", "video"].contains(kind) { return "录音 · " + recordingDateLabel(name: name, kind: kind, createdAt: createdAt, timeZone: timeZone) }
        if let text = transcript {
            let firstLine = String(text.drop(while: { $0 == "\n" }).prefix(while: { $0 != "\n" }))
                .trimmingCharacters(in: .whitespaces)
            // A capture that is nothing but a link must reach the headline intact;
            // truncating at 48 characters leaves a fragment no title view can read.
            if firstLine.hasPrefix("http://") || firstLine.hasPrefix("https://"), !firstLine.contains(" ") {
                return String(firstLine.prefix(240))
            }
            if let derived = MaterialTitleText.derived(fromTranscript: text) { return derived }
            let line = text.drop(while: { $0 == "\n" }).prefix(49).prefix(while: { $0 != "\n" })
            let cleaned = String(line.prefix(48)).trimmingCharacters(in: .whitespaces)
            if !cleaned.isEmpty { return cleaned + (line.count > 48 ? "…" : "") }
        }
        switch kind {
        case "user_text": return "未命名表达"
        case "external_text": return "未命名外部资料"
        case "ai_text": return "未命名 AI 资料"
        default: return name
        }
    }

    static func expressedDate(name: String, kind: String, createdAt: String, timeZone: String) -> Date? {
        let formats: [(String, Date.FormatString)] = [
            ("^\\d{4}-\\d{2}-\\d{2}_\\d{2}-\\d{2}-\\d{2}", "\(year: .padded(4))-\(month: .twoDigits)-\(day: .twoDigits)_\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))-\(minute: .twoDigits)-\(second: .twoDigits)"),
            ("^\\d{8} \\d{6}", "\(year: .padded(4))\(month: .twoDigits)\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)\(second: .twoDigits)")
        ]
        for (pattern, format) in formats {
            if let range = name.range(of: pattern, options: .regularExpression) {
                return try? Date.ParseStrategy(format: format, locale: Locale(identifier: "en_US_POSIX"),
                    timeZone: TimeZone(identifier: timeZone) ?? .current, isLenient: false).parse(String(name[range]))
            }
        }
        return name.hasPrefix("我的口述") || ["user_text", "external_text", "ai_text"].contains(kind) ? ConversationReflectionFocus.date(createdAt) : nil
    }

    static func recordingDateLabel(name: String, kind: String, createdAt: String, timeZone: String) -> String {
        let expressed = expressedDate(name: name, kind: kind, createdAt: createdAt, timeZone: timeZone)
        let date = expressed ?? ConversationReflectionFocus.date(createdAt)
        guard let date else { return "时间待核对" }
        let style = Date.VerbatimFormatStyle(
            format: "\(month: .defaultDigits)月\(day: .defaultDigits)日 \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
            locale: Locale(identifier: "zh_CN"), timeZone: TimeZone(identifier: timeZone) ?? .current,
            calendar: Calendar(identifier: .gregorian))
        return (expressed == nil ? "导入于 " : "") + date.formatted(style)
    }
}

public extension SourceRecord {
    var recordingExpression: RecordingExpression? {
        guard let value=presentation?.expression,!localOnly,!needsTranscriptionReview,
              value.versions[id] == transcriptVersionID,value.policies[id] == policyVersion else { return nil }
        return value
    }
    var needsTranscriptionReview: Bool {
        ["audio", "video"].contains(kind) && transcriptionBackend?.hasPrefix("Qwen3-ASR") == true &&
        !(transcript ?? "").isEmpty && !spans.isEmpty && spans.allSatisfy { $0.startMS != nil && $0.endMS != nil } &&
        transcriptionReview?.isCompleteFullTextReview != true
    }
    var transcriptionReview: TranscriptionReview? {
        guard presentation?.transcriptionReview?.transcriptVersionID == transcriptVersionID else { return nil }
        return presentation?.transcriptionReview
    }
    var contentTitle: String? {
        if let manual = presentation?.manualTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !manual.isEmpty { return manual }
        guard presentation?.transcriptVersionID == transcriptVersionID else { return nil }
        return presentation?.automatic?.title.flatMap(MaterialTitleText.normalizedGenerated)
    }
    var contentSummary: String? {
        guard !needsTranscriptionReview,presentation?.transcriptVersionID == transcriptVersionID, let summary = presentation?.automatic?.summary else { return nil }
        return (transcriptionReview?.unresolved_issues?.isEmpty == false ? "部分转写待核对。" : "") + summary
    }
    var expressedDate: Date? {
        MaterialDisplayTitle.expressedDate(name: name, kind: kind, createdAt: createdAt, timeZone: timeZone)
    }
    var displayTitle: String {
        MaterialDisplayTitle.title(name: name, kind: kind, createdAt: createdAt, timeZone: timeZone,
                                   presentation: presentation, transcript: transcript,
                                   transcriptVersionID: transcriptVersionID)
    }
    var recordingDateLabel: String {
        MaterialDisplayTitle.recordingDateLabel(name: name, kind: kind, createdAt: createdAt, timeZone: timeZone)
    }
    var recordingSubtitle: String {
        guard let duration, duration > 0 else { return recordingDateLabel }
        let seconds = Int(duration.rounded()), minutes = seconds / 60, hours = minutes / 60
        let length = hours > 0 ? "\(hours)小时\(minutes % 60)分钟" : (minutes > 0 ? "\(minutes)分\(seconds % 60)秒" : "\(seconds)秒")
        return recordingDateLabel + " · " + length
    }
    var needsContentTitle: Bool {
        ["audio", "video"].contains(kind) && ["saved", "reference_only"].contains(state) && !localOnly &&
        !(transcript ?? "").isEmpty && contentTitle == nil
    }
}
extension VoiceOSStore {
    func saveTranscriptionReview(_ review: TranscriptionReview, sourceID: String) throws {
        guard let source = try sources().first(where: { $0.id == sourceID }), let version = source.transcriptVersionID,
              review.completed, !review.response_id.isEmpty else { throw VoiceOSError("转写核对缺少当前版本或回执") }
        var saved = source.presentation ?? RecordingPresentation(), current = review
        current.transcriptVersionID = version
        current.correction_count = current.correction_count ?? current.corrections?.count
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        if let previous = saved.transcriptionReview, try encoder.encode(previous) == encoder.encode(current) { return }
        let affected = current.changed || current.unresolved_issues?.isEmpty == false ||
            saved.transcriptionReview?.corrections?.isEmpty == false || saved.transcriptionReview?.unresolved_issues?.isEmpty == false
        saved.transcriptionReview = current
        if affected { saved.automatic = nil; saved.transcriptVersionID = nil }
        try savePresentation(saved, sourceID: sourceID)
    }
    public func renameRecording(sourceID: String, title: String?) throws {
        let catalog = try sources()
        guard let source = catalog.first(where: { $0.id == sourceID }) else { throw VoiceOSError("录音不存在") }
        let clean = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean == nil || (!clean!.isEmpty && clean!.count <= 100 && !clean!.contains(where: \.isNewline)) else { throw VoiceOSError("请输入一行、不超过100字的标题") }
        if let expression = source.recordingExpression, expression.sourceIDs.count > 1 {
            var updated = expression
            updated.manualTitle = clean
            try db.transaction {
                for id in expression.sourceIDs {
                    guard let member = catalog.first(where: { $0.id == id }), var presentation = member.presentation,
                          presentation.expression?.id == expression.id else { throw VoiceOSError("分组里的录音已变化，标题未保存") }
                    presentation.expression = updated
                    try saveExpressionPresentation(presentation, sourceID: id)
                }
            }
            return
        }
        var saved = source.presentation ?? RecordingPresentation()
        saved.manualTitle = clean
        try savePresentation(saved, sourceID: sourceID)
    }
    func savePresentation(_ value: RecordingPresentation, sourceID: String) throws {
        try db.execute("UPDATE sources SET presentation_json=? WHERE id=?", [String(decoding: try JSONEncoder().encode(value), as: UTF8.self), sourceID])
    }
    public func prepareRecordingTitles(sourceIDs: Set<String>? = nil) throws -> RecordingTitleInput? {
        let chosen = try sources().filter { !$0.needsTranscriptionReview && $0.needsContentTitle && (sourceIDs?.contains($0.id) ?? true) }
        guard !chosen.isEmpty else { return nil }
        let context = try prepareLocalTranscriptContext(sourceIDs: chosen.map(\.id), scalarBudget: max(1, chosen.reduce(0) { $0 + ($1.transcript?.unicodeScalars.count ?? 0) }))
        return .init(context: context, policies: Dictionary(uniqueKeysWithValues: chosen.map { ($0.id, $0.policyVersion) }))
    }
    public static func validateRecordingTitles(_ proposals: [RecordingTitleProposal], input: RecordingTitleInput) throws {
        guard proposals.count == input.context.sources.count, Set(proposals.map(\.sourceID)) == Set(input.context.sources.map(\.sourceID)) else { throw VoiceOSError("内容命名未覆盖全部录音") }
        for proposal in proposals {
            guard let source = input.context.sources.first(where: { $0.sourceID == proposal.sourceID }),
                  !proposal.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, proposal.title.count <= 40,
                  !proposal.title.contains(where: \.isNewline), !proposal.summary.isEmpty, proposal.summary.count <= 240,
                  !proposal.quotes.isEmpty, proposal.quotes.allSatisfy({ !$0.isEmpty && source.text.contains($0) }) else { throw VoiceOSError("内容标题、摘要或原话依据无效") }
        }
    }
    @discardableResult
    public func generateRecordingTitles(using model: any RecordingTitlePort, sourceIDs: Set<String>? = nil) async throws -> Int {
        guard let input = try prepareRecordingTitles(sourceIDs: sourceIDs) else { return 0 }
        let (proposals, ids) = try await model.generate(input)
        guard !ids.isEmpty, ids.allSatisfy({ !$0.isEmpty }) else { throw VoiceOSError("内容命名缺少模型回执") }
        try Self.validateRecordingTitles(proposals, input: input)
        try requireReviewedTranscriptions(sourceIDs:input.context.sources.map(\.sourceID),destination:.cloud)
        try validateLocalTranscriptContext(input.context)
        let catalog = Dictionary(uniqueKeysWithValues: try sources().map { ($0.id, $0) })
        var savedCount = 0
        try db.transaction {
            for proposal in proposals {
                guard let source = catalog[proposal.sourceID], !source.localOnly, source.policyVersion == input.policies[source.id] else { throw VoiceOSError("命名期间录音授权已变化") }
                guard let title = MaterialTitleText.normalizedGenerated(proposal.title) else { continue }
                var saved = source.presentation ?? RecordingPresentation()
                saved.automatic = RecordingTitleProposal(sourceID: proposal.sourceID, title: title, summary: proposal.summary, quotes: proposal.quotes)
                saved.transcriptVersionID = source.transcriptVersionID; saved.responseIDs = ids
                try savePresentation(saved, sourceID: source.id)
                savedCount += 1
            }
        }
        return savedCount
    }
}

public extension RecordingExpression {
    /// The saved group title that outranks member titles, when one is set.
    var leadingDisplayTitle: String? {
        if let manual = manualTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !manual.isEmpty { return manual }
        let automatic = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return automatic.isEmpty ? nil : automatic
    }

    /// A saved manual group title outranks the automatic title and member titles.
    func displayTitle(in catalog: [String: SourceRecord]) -> String {
        if let leading = leadingDisplayTitle { return leading }
        for id in sourceIDs {
            guard let member = catalog[id] else { continue }
            let memberTitle = member.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !memberTitle.isEmpty { return memberTitle }
        }
        return title
    }
}

public extension SourceRecord {
    /// Explains why a saved multi-segment expression is currently unusable.
    func recordingExpressionIssue(in catalog: [String: SourceRecord]) -> String? {
        guard let saved = presentation?.expression, saved.sourceIDs.count > 1,
              recordingExpression(in: catalog) == nil else { return nil }
        guard recordingExpression != nil else { return "这段原文或文字授权已变化" }
        for id in saved.sourceIDs {
            guard let member = catalog[id] else { return "分组里有一段录音已不在资料库" }
            guard member.recordingExpression?.digest == saved.digest else { return "分组里有一段的原文或文字授权已变化" }
            if let pair = member.presentation?.recordingContext {
                guard saved.externalVersions?[pair.externalSourceID] == pair.externalVersionID,
                      saved.externalPolicies?[pair.externalSourceID] == pair.externalPolicyVersion else {
                    return "节目背景或原文授权已变化"
                }
            }
        }
        if let externals = saved.externalVersions {
            for (id, version) in externals {
                guard let external = catalog[id], external.transcriptVersionID == version,
                      external.policyVersion == saved.externalPolicies?[id],
                      !external.localOnly, !external.needsTranscriptionReview else {
                    return "节目原文或文字授权已变化"
                }
            }
        }
        return "分组内容已变化"
    }

    /// Short reason shown on a material that has no topic link yet.
    func topicAssignmentReason(in catalog: [String: SourceRecord]) -> String {
        let members = (presentation?.expression?.sourceIDs ?? [id]).compactMap { catalog[$0] }
        if members.contains(where: { $0.localOnly }) { return "部分文字仅本机保存，未交给 AI" }
        if members.contains(where: { $0.needsTranscriptionReview }) { return "转写仍在核对，暂未归组" }
        if members.contains(where: { ($0.transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { return "还没有可读原文，暂未归组" }
        if presentation?.expression != nil, recordingExpression == nil { return "分组内容已变化，等待重新判断" }
        if presentation?.automaticInput != nil, recordingExpression?.state != "completed" { return "连续表达仍在整理，完成后自动归组" }
        return "AI 尚未连接到主题"
    }
}

extension VoiceOSStore {
    /// Selecting any segment splits its whole expression, so every segment
    /// returns to its own title instead of leaving a truncated group behind.
    @discardableResult
    public func detachRecordingsFromExpressions(sourceIDs: Set<String>) throws -> Int {
        guard !sourceIDs.isEmpty else { return 0 }
        let catalog = Dictionary(uniqueKeysWithValues: try sources().map { ($0.id, $0) })
        let expressionIDs = Set(sourceIDs.compactMap { catalog[$0]?.presentation?.expression?.id })
        guard !expressionIDs.isEmpty else { return 0 }
        let detached = catalog.values.filter { source in
            guard let id = source.presentation?.expression?.id else { return false }
            return expressionIDs.contains(id)
        }.map(\.id)
        guard !detached.isEmpty else { return 0 }
        try db.transaction {
            for id in detached {
                guard let source = catalog[id], var presentation = source.presentation else { continue }
                presentation.expression = nil
                try saveExpressionPresentation(presentation, sourceID: id)
            }
        }
        return detached.count
    }
}

public extension SourceRecord {
    /// The stored full-transcript review failure, valid only for the current
    /// transcript and policy version.
    var transcriptionReviewFailure: TranscriptionReviewFailure? {
        guard let failure = presentation?.transcriptionReviewFailure,
              failure.transcriptVersionID == transcriptVersionID,
              failure.policyVersion == policyVersion else { return nil }
        return failure
    }
    /// Unresolved doubts from the current completed review, one per span.
    /// A review can repeat the same span; the first occurrence keeps its reason.
    var unresolvedTranscriptionIssues: [TranscriptionReview.Issue] {
        guard let review = transcriptionReview, review.completed, let issues = review.unresolved_issues else { return [] }
        var seen = Set<String>()
        return issues.filter { issue in
            let span = issue.span_id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !span.isEmpty else { return true }
            return seen.insert(span).inserted
        }
    }
    var unresolvedTranscriptionIssueCount: Int { unresolvedTranscriptionIssues.count }
}

extension VoiceOSStore {
    public func recordTranscriptionReviewFailure(sourceID: String, reason: String) throws {
        guard let source = try sources().first(where: { $0.id == sourceID }), let version = source.transcriptVersionID else {
            throw VoiceOSError("转写核对失败无法留存：缺少当前文字版本")
        }
        let clean = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw VoiceOSError("转写核对失败需要原因") }
        var saved = source.presentation ?? RecordingPresentation()
        let previous = saved.transcriptionReviewFailure
        let failure = TranscriptionReviewFailure(reason: clean, transcriptVersionID: version,
            policyVersion: source.policyVersion, failedAt: previous?.failedAt ?? Date())
        guard previous != failure else { return }
        saved.transcriptionReviewFailure = failure
        try savePresentation(saved, sourceID: sourceID)
    }
    public func clearTranscriptionReviewFailure(sourceID: String) throws {
        guard let source = try sources().first(where: { $0.id == sourceID }), var saved = source.presentation,
              saved.transcriptionReviewFailure != nil else { return }
        saved.transcriptionReviewFailure = nil
        try savePresentation(saved, sourceID: sourceID)
    }
    /// Failures still matching their material's current transcript and policy
    /// version, keyed exactly as the in-memory review dictionary.
    public func storedTranscriptionReviewFailures() throws -> [String: String] {
        Dictionary(uniqueKeysWithValues: try sources().compactMap { source in
            guard let failure = source.transcriptionReviewFailure else { return nil }
            return (source.id + ":" + failure.transcriptVersionID + ":" + String(failure.policyVersion), failure.reason)
        })
    }
}

/// One material's unresolved transcription doubts, sorted for the processing
/// page. `SourcePageIndex` derives this once per workspace snapshot.
public struct WorkspaceTranscriptReviewPoint: Identifiable, Sendable {
    public let source: SourceRecord
    public let count: Int
    public var id: String { source.id }
    public init(source: SourceRecord, count: Int) {
        self.source = source
        self.count = count
    }
}

public extension SourceRecord {
    /// The external context member this personal recording is attached to,
    /// when both sides still match the saved versions and permissions.
    func pairedContextSourceID(in catalog: [String: SourceRecord]) -> String? {
        guard let pair = presentation?.recordingContext, pair.personalSourceID == id,
              let external = catalog[pair.externalSourceID], !localOnly, !external.localOnly,
              !needsTranscriptionReview, !external.needsTranscriptionReview,
              transcriptVersionID == pair.personalVersionID,
              external.transcriptVersionID == pair.externalVersionID,
              policyVersion == pair.personalPolicyVersion,
              external.policyVersion == pair.externalPolicyVersion else { return nil }
        return external.id
    }
}

/// One materials-page body evaluation: rows for the selected filter and the
/// tab counts for every filter. Grouping and expression dedupe run once per
/// filter inside one construction, instead of once per tab plus once for rows.
public struct MaterialReadingPage: Sendable {
    public let rows: [SourceRecord]
    public let counts: [String: Int]
    public init(records: [SourceRecord], filter: String, filters: [String],
                readingStates: [String: SourceReadingState] = [:],
                catalog: [String: SourceRecord],
                expressions: [String: RecordingExpression] = [:]) {
        var byFilter: [String: [SourceRecord]] = [:]
        for name in Set(filters + [filter]) {
            byFilter[name] = Self.rows(records: records, filter: name, readingStates: readingStates,
                                       catalog: catalog, expressions: expressions)
        }
        rows = byFilter[filter] ?? []
        counts = byFilter.mapValues(\.count)
    }
    private static func rows(records: [SourceRecord], filter: String,
                             readingStates: [String: SourceReadingState],
                             catalog: [String: SourceRecord],
                             expressions: [String: RecordingExpression]) -> [SourceRecord] {
        let selected = records.filter { source in
            switch filter {
            case "回收站": return source.isTrashed
            case "已归档": return source.isArchived
            case "未读": return !source.isArchived && !source.isTrashed && (readingStates[source.id] ?? .unread) == .unread
            case "在读": return !source.isArchived && !source.isTrashed && readingStates[source.id] == .reading
            default: return !source.isArchived && !source.isTrashed
            }
        }
        let selectedIDs = Set(selected.map(\.id))
        let attachedContextIDs = Set(selected.compactMap { $0.pairedContextSourceID(in: catalog) })
            .intersection(selectedIDs)
        let entries = selected.compactMap { source -> (SourceRecord, String)? in
            guard !attachedContextIDs.contains(source.id) else { return nil }
            guard let expression = expressions[source.id], expression.sourceIDs.count > 1,
                  Set(expression.sourceIDs).isSubset(of: selectedIDs) else { return (source, source.createdAt) }
            guard expression.sourceIDs.first == source.id else { return nil }
            return (source, expression.sourceIDs.compactMap { catalog[$0]?.createdAt }.max() ?? source.createdAt)
        }
        return entries.sorted { $0.1 > $1.1 }.map(\.0)
    }
}

/// Everything one topic page reads: its materials, current claims and actions,
/// the per-section slices the cards show, and the unlinked material list.
public struct TopicReadingData: Sendable {
    public let sourceIDs: Set<String>
    public let sources: [SourceRecord]
    public let claims: [CandidateClaim]
    public let actions: [ActionRecord]
    public let claimIDs: Set<String>
    public let actionIDs: Set<String>
    public let sectionClaims: [String: [CandidateClaim]]
    public let sectionActions: [String: [ActionRecord]]
    public let sectionPosition: [String: Int]
    public let actionsByID: [String: ActionRecord]
    public let actionVersionByID: [String: Int]
    public let unlinkedSources: [SourceRecord]
    public init(topic: ReflectionQuestion, sourceIDs: Set<String>, records: [SourceRecord],
                claims: [CandidateClaim], actions: [ActionRecord]) {
        let sections = topic.organization?.sections ?? []
        let claimIDs = Set(sections.flatMap(\.claimIDs))
        let actionIDs = Set(sections.flatMap(\.actionIDs))
        let filteredClaims = claims.filter {
            claimIDs.contains($0.id) && $0.validity == "current" && $0.reviewState != "rejected"
        }
        let filteredActions = actions.filter {
            actionIDs.contains($0.id) && $0.validity == "current" && $0.state != "dismissed"
        }
        var claimSections: [String: [String]] = [:]
        for section in sections {
            for id in Set(section.claimIDs) { claimSections[id, default: []].append(section.id) }
        }
        var actionSections: [String: [String]] = [:]
        for section in sections {
            for id in Set(section.actionIDs) { actionSections[id, default: []].append(section.id) }
        }
        var claimsBySection: [String: [CandidateClaim]] = [:]
        for claim in filteredClaims {
            for sectionID in claimSections[claim.id] ?? [] {
                claimsBySection[sectionID, default: []].append(claim)
            }
        }
        var actionsBySection: [String: [ActionRecord]] = [:]
        for action in filteredActions {
            for sectionID in actionSections[action.id] ?? [] {
                actionsBySection[sectionID, default: []].append(action)
            }
        }
        var positions: [String: Int] = [:]
        for (offset, section) in sections.enumerated() where positions[section.id] == nil {
            positions[section.id] = offset
        }
        var byID: [String: ActionRecord] = [:]
        var versions: [String: Int] = [:]
        for action in filteredActions {
            byID[action.id] = action
            versions[action.id] = action.version
        }
        self.sourceIDs = sourceIDs
        self.sources = records.filter { sourceIDs.contains($0.id) }
        self.claims = filteredClaims
        self.actions = filteredActions
        self.claimIDs = claimIDs
        self.actionIDs = actionIDs
        sectionClaims = claimsBySection
        sectionActions = actionsBySection
        sectionPosition = positions
        actionsByID = byID
        actionVersionByID = versions
        unlinkedSources = records.filter {
            !sourceIDs.contains($0.id) && !$0.isTrashed && !($0.transcript ?? "").isEmpty
        }
    }
}

public enum TopicAdjacency {
    /// Shared material counts for every other topic. One inverted index over
    /// topic sources replaces one set intersection per topic.
    public static func sharedCounts(selectedTopicID: String, selectedSourceIDs: Set<String>,
                                    topics: [ReflectionQuestion],
                                    topicSources: [String: [String]]) -> [String: Int] {
        var topicIDsBySourceID: [String: [String]] = [:]
        for (topicID, sourceIDs) in topicSources {
            for sourceID in Set(sourceIDs) { topicIDsBySourceID[sourceID, default: []].append(topicID) }
        }
        var counts: [String: Int] = [:]
        for sourceID in selectedSourceIDs {
            for topicID in topicIDsBySourceID[sourceID] ?? [] where topicID != selectedTopicID {
                counts[topicID, default: 0] += 1
            }
        }
        let existing = Set(topics.map(\.id))
        return counts.filter { existing.contains($0.key) }
    }
}

public enum UnfinishedProcessingIntents {
    /// Intents whose captured source still matches its current transcript and
    /// policy versions. Dictionary lookups replace a per-intent library scan.
    public static func filter(_ intents: [ExpressionProcessingIntentRecord],
                              recordsByID: [String: SourceRecord]) -> [ExpressionProcessingIntentRecord] {
        intents.filter { intent in
            guard !intent.isDismissed, ![.completed, .cancelled, .frozen].contains(intent.state),
                  let input = intent.snapshot.context.sources.first,
                  let record = recordsByID[input.sourceID] else { return false }
            return record.transcriptVersionID == input.transcriptVersionID
                && record.policyVersion == intent.snapshot.policyVersion
        }
    }
}
