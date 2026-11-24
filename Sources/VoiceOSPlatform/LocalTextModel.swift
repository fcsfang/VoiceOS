import Foundation
import VoiceOSCore

/// Development configuration only. Never evaluate shell text or expose parsing errors.
public enum LocalTextModel {
    public struct Suite {
        public let recordingExpressions: ResponsesRecordingExpressionPort
        public let topics: ResponsesTopicOrganizationPort
        public let note: ResponsesMaterialNotePort
        public let recordingTitles: ResponsesRecordingTitlePort
        public let reminderFields: ResponsesReminderFieldPort
        public let followup:ResponsesRecordingFollowupPort
        public let assistant:ResponsesAssistantPort
        public let initiation:ResponsesTaskInitiationPort
        public let knowledgeReview:ResponsesKnowledgeReviewPort
        public let cognition:ResponsesModelPort
        public let relevance:ResponsesRelevancePort
        public let discussion:ResponsesDiscussionPort
        public let outcome:ResponsesOutcomePort
        public let english:ResponsesEnglishPracticePort
        public let association:ResponsesExpressionAssociationPort
        public let segmentExtraction:ResponsesSegmentExtractionPort
        public let segmentAggregation:ResponsesSegmentAggregationPort
        public let notificationAnalysis:ResponsesNotificationAnalysisPort
    }
    /// Read credentials once; publish all ports only after the complete suite validates.
    public struct Settings {
        public let address: URL
        public let key: String
        public let model: String
        public let noteEffort: String
        public let topicEffort: String
        public let reviewEffort: String
        public init(address: URL, key: String, model: String = LocalTextModel.defaultModel,
                    noteEffort: String = "high", topicEffort: String = "high", reviewEffort: String = "high") {
            self.address = address; self.key = key; self.model = model
            self.noteEffort = noteEffort; self.topicEffort = topicEffort
            self.reviewEffort = reviewEffort
        }
    }
    public static let defaultModel = "gpt-6.2-sol"

    public static func loadSuite(from file:URL, compactSegmentExtraction: Bool = false, compactSegmentAggregation: Bool = false, segmentRequestTimeout: TimeInterval = 120, segmentTransport: any ModelHTTPTransport = DirectModelHTTPTransport(), segmentStreaming: Bool = false, expandAmbiguousQuotes: Bool = false, strictSegmentAggregation: Bool = false) throws -> Suite {
        try loadSuite(settings: settings(from: file), compactSegmentExtraction: compactSegmentExtraction,
                      compactSegmentAggregation: compactSegmentAggregation, segmentRequestTimeout: segmentRequestTimeout,
                      segmentTransport: segmentTransport, segmentStreaming: segmentStreaming,
                      expandAmbiguousQuotes: expandAmbiguousQuotes, strictSegmentAggregation: strictSegmentAggregation)
    }
    /// 应用内部配置构建整套端口：设置页保存的地址、模型与思考强度都走这里。
    public static func loadSuite(settings cfg: Settings, compactSegmentExtraction: Bool = false, compactSegmentAggregation: Bool = false, segmentRequestTimeout: TimeInterval = 120, segmentTransport: any ModelHTTPTransport = DirectModelHTTPTransport(), segmentStreaming: Bool = false, expandAmbiguousQuotes: Bool = false, strictSegmentAggregation: Bool = false) throws -> Suite {
        let address = cfg.address, key = cfg.key, model = cfg.model
        do {
            let chosenTransport: any ModelHTTPTransport = segmentStreaming ? DirectStreamingModelHTTPTransport() : segmentTransport
            return Suite(recordingExpressions: try ResponsesRecordingExpressionPort(baseURL:address,apiKey:key,model:model),topics: try ResponsesTopicOrganizationPort(baseURL:address,apiKey:key,model:model,deadline:1800,effort:cfg.topicEffort),note: try ResponsesMaterialNotePort(baseURL:address,apiKey:key,model:model,effort:cfg.noteEffort),recordingTitles: try ResponsesRecordingTitlePort(baseURL:address,apiKey:key,model:model),reminderFields: try ResponsesReminderFieldPort(baseURL:address,apiKey:key,model:model),followup:try ResponsesRecordingFollowupPort(baseURL:address,apiKey:key,model:model),assistant:try ResponsesAssistantPort(baseURL:address,apiKey:key,model:model),initiation:try ResponsesTaskInitiationPort(baseURL:address,apiKey:key,model:model),knowledgeReview:try ResponsesKnowledgeReviewPort(baseURL:address,apiKey:key,model:model),cognition:try ResponsesModelPort(baseURL:address,apiKey:key,model:model),relevance:try ResponsesRelevancePort(baseURL:address,apiKey:key,model:model),discussion:try ResponsesDiscussionPort(baseURL:address,apiKey:key,model:model),outcome:try ResponsesOutcomePort(baseURL:address,apiKey:key,model:model),english:try ResponsesEnglishPracticePort(baseURL:address,apiKey:key,model:model),association:try ResponsesExpressionAssociationPort(baseURL:address,apiKey:key,model:model),segmentExtraction:try ResponsesSegmentExtractionPort(baseURL:address,apiKey:key,model:model,transport:chosenTransport,compactInput:compactSegmentExtraction,requestTimeout:segmentRequestTimeout,streaming:segmentStreaming,expandAmbiguousQuotes:expandAmbiguousQuotes),segmentAggregation:try ResponsesSegmentAggregationPort(baseURL:address,apiKey:key,model:model,transport:chosenTransport,compactInput:compactSegmentAggregation,requestTimeout:segmentRequestTimeout,streaming:segmentStreaming,strictProvenance:strictSegmentAggregation),notificationAnalysis:try ResponsesNotificationAnalysisPort(baseURL:address,apiKey:key,model:model))
        } catch { throw VoiceOSError("无法使用当前文本模型配置；请检查服务地址、模型与密钥") }
    }
    public static func load(from file: URL) throws -> ResponsesModelPort {
        let cfg = try settings(from: file)
        let address = cfg.address, key = cfg.key, model = cfg.model
        do { return try ResponsesModelPort(baseURL: address, apiKey: key, model: model) }
        catch { throw VoiceOSError("无法读取有效的文本模型配置；请选择项目的本地 .env 文件") }
    }
    public static func loadRelevance(from file: URL) throws -> ResponsesRelevancePort {
        let cfg = try settings(from: file)
        let address = cfg.address, key = cfg.key, model = cfg.model
        do { return try ResponsesRelevancePort(baseURL: address, apiKey: key, model: model) }
        catch { throw VoiceOSError("无法读取有效的文本模型配置；请选择项目的本地 .env 文件") }
    }
    public static func loadDiscussion(from file: URL) throws -> ResponsesDiscussionPort {
        let cfg = try settings(from: file)
        let address = cfg.address, key = cfg.key, model = cfg.model
        do { return try ResponsesDiscussionPort(baseURL: address, apiKey: key, model: model) }
        catch { throw VoiceOSError("无法读取有效的文本模型配置；请选择项目的本地 .env 文件") }
    }
    public static func loadOutcome(from file:URL) throws -> ResponsesOutcomePort {
        let cfg = try settings(from: file)
        let address = cfg.address, key = cfg.key, model = cfg.model
        do { return try ResponsesOutcomePort(baseURL:address,apiKey:key,model:model) }
        catch { throw VoiceOSError("无法读取有效的文本模型配置；请选择项目的本地 .env 文件") }
    }
    public static func loadEnglish(from file:URL) throws -> ResponsesEnglishPracticePort {
        let cfg = try settings(from: file)
        let address = cfg.address, key = cfg.key, model = cfg.model
        do { return try ResponsesEnglishPracticePort(baseURL:address,apiKey:key,model:model) }
        catch { throw VoiceOSError("无法读取有效的文本模型配置；请选择项目的本地 .env 文件") }
    }
    /// 读取配置文件（导入 / 迁移用），不打印任何密钥。
    public static func inspect(_ file: URL) throws -> Settings { try settings(from: file) }
    private static func settings(from file: URL) throws -> Settings {
        do {
            let bytes = try Data(contentsOf: file)
            guard bytes.count <= 16384, let text = String(data: bytes, encoding: .utf8) else { throw VoiceOSError("invalid config") }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{") {
                guard let root = try JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any],
                      let providers = root["provider"] as? [String: Any],
                      let openAI = providers["openai"] as? [String: Any],
                      let options = openAI["options"] as? [String: Any],
                      let rawAddress = options["baseURL"] as? String,
                      let key = options["apiKey"] as? String,
                      let address = URL(string: rawAddress), !key.isEmpty, key != "REPLACE_LOCALLY" else { throw VoiceOSError("missing config") }
                let model = (root["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? defaultModel
                let noteEffort = (root["noteEffort"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "high"
                let topicEffort = (root["topicEffort"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "high"
                let reviewEffort = (root["reviewEffort"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "high"
                return Settings(address: address, key: key, model: model, noteEffort: noteEffort, topicEffort: topicEffort, reviewEffort: reviewEffort)
            }
            var settings: [String: String] = [:]
            for raw in text.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }
                let fields = line.split(separator: "=", maxSplits: 1)
                guard fields.count == 2 else { throw VoiceOSError("invalid config") }
                let name = fields[0].trimmingCharacters(in: .whitespaces)
                guard settings[name] == nil else { throw VoiceOSError("duplicate config") }
                settings[name] = try JSONDecoder().decode(String.self, from: Data(fields[1].utf8))
            }
            guard let address = settings["OPENAI_BASE_URL"].flatMap(URL.init(string:)), let key = settings["OPENAI_API_KEY"], key != "REPLACE_LOCALLY" else { throw VoiceOSError("missing config") }
            func optional(_ name: String) -> String? {
                guard let value = settings[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
                return value
            }
            return Settings(address: address, key: key,
                            model: optional("VOICEOS_TEXT_MODEL") ?? defaultModel,
                            noteEffort: optional("VOICEOS_NOTE_EFFORT") ?? "high",
                            topicEffort: optional("VOICEOS_TOPIC_EFFORT") ?? "high",
                            reviewEffort: optional("VOICEOS_REVIEW_EFFORT") ?? "high")
        } catch { throw VoiceOSError("无法读取有效的文本模型配置；请选择项目的本地 .env 文件") }
    }
}
