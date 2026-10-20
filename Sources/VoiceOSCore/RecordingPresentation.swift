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
        if let manual = presentation?.manualTitle { return manual }
        guard presentation?.transcriptVersionID == transcriptVersionID else { return nil }
        return presentation?.automatic?.title
    }
    var contentSummary: String? {
        guard !needsTranscriptionReview,presentation?.transcriptVersionID == transcriptVersionID, let summary = presentation?.automatic?.summary else { return nil }
        return (transcriptionReview?.unresolved_issues?.isEmpty == false ? "部分转写待核对。" : "") + summary
    }
    var expressedDate: Date? {
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
    var displayTitle: String {
        if let contentTitle { return contentTitle }
        return ["audio", "video"].contains(kind) ? "录音 · " + recordingDateLabel : name
    }
    var recordingDateLabel: String {
        let expressed = expressedDate
        let date = expressed ?? ConversationReflectionFocus.date(createdAt)
        guard let date else { return "时间待核对" }
        let style = Date.VerbatimFormatStyle(
            format: "\(month: .defaultDigits)月\(day: .defaultDigits)日 \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
            locale: Locale(identifier: "zh_CN"), timeZone: TimeZone(identifier: timeZone) ?? .current,
            calendar: Calendar(identifier: .gregorian))
        return (expressed == nil ? "导入于 " : "") + date.formatted(style)
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
        current.corrections = nil
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        if let previous = saved.transcriptionReview, try encoder.encode(previous) == encoder.encode(current) { return }
        let affected = current.changed || current.unresolved_issues?.isEmpty == false ||
            saved.transcriptionReview?.corrections?.isEmpty == false || saved.transcriptionReview?.unresolved_issues?.isEmpty == false
        saved.transcriptionReview = current
        if affected { saved.automatic = nil; saved.transcriptVersionID = nil }
        try savePresentation(saved, sourceID: sourceID)
    }
    public func renameRecording(sourceID: String, title: String?) throws {
        guard let source = try sources().first(where: { $0.id == sourceID }) else { throw VoiceOSError("录音不存在") }
        let clean = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean == nil || (!clean!.isEmpty && clean!.count <= 100 && !clean!.contains(where: \.isNewline)) else { throw VoiceOSError("请输入一行、不超过100字的标题") }
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
        try db.transaction {
            for proposal in proposals {
                guard let source = catalog[proposal.sourceID], !source.localOnly, source.policyVersion == input.policies[source.id] else { throw VoiceOSError("命名期间录音授权已变化") }
                var saved = source.presentation ?? RecordingPresentation()
                saved.automatic = proposal; saved.transcriptVersionID = source.transcriptVersionID; saved.responseIDs = ids
                try savePresentation(saved, sourceID: source.id)
            }
        }
        return proposals.count
    }
}
