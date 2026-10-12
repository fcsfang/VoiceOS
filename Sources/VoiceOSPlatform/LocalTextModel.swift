import Foundation
import VoiceOSCore

/// Development configuration only. Never evaluate shell text or expose parsing errors.
public enum LocalTextModel {
    public struct Suite {
        public let cognition:ResponsesModelPort
        public let relevance:ResponsesRelevancePort
        public let discussion:ResponsesDiscussionPort
        public let outcome:ResponsesOutcomePort
        public let english:ResponsesEnglishPracticePort
        public let association:ResponsesExpressionAssociationPort
        public let segmentExtraction:ResponsesSegmentExtractionPort
        public let segmentAggregation:ResponsesSegmentAggregationPort
    }
    /// Read credentials once; publish all ports only after the complete suite validates.
    public static func loadSuite(from file:URL, compactSegmentExtraction: Bool = false, compactSegmentAggregation: Bool = false, segmentRequestTimeout: TimeInterval = 120, segmentTransport: any ModelHTTPTransport = DirectModelHTTPTransport()) throws -> Suite {
        let (address,key)=try settings(from:file)
        do {
            return Suite(cognition:try ResponsesModelPort(baseURL:address,apiKey:key,model:"gpt-6.1-sol"),relevance:try ResponsesRelevancePort(baseURL:address,apiKey:key,model:"gpt-6.1-sol"),discussion:try ResponsesDiscussionPort(baseURL:address,apiKey:key,model:"gpt-6.1-sol"),outcome:try ResponsesOutcomePort(baseURL:address,apiKey:key,model:"gpt-6.1-sol"),english:try ResponsesEnglishPracticePort(baseURL:address,apiKey:key,model:"gpt-6.1-sol"),association:try ResponsesExpressionAssociationPort(baseURL:address,apiKey:key,model:"gpt-6.1-sol"),segmentExtraction:try ResponsesSegmentExtractionPort(baseURL:address,apiKey:key,model:"gpt-6.1-sol",transport:segmentTransport,compactInput:compactSegmentExtraction,requestTimeout:segmentRequestTimeout),segmentAggregation:try ResponsesSegmentAggregationPort(baseURL:address,apiKey:key,model:"gpt-6.1-sol",transport:segmentTransport,compactInput:compactSegmentAggregation,requestTimeout:segmentRequestTimeout))
        } catch { throw VoiceOSError("无法读取有效的文本模型配置；请选择项目的本地 .env 文件") }
    }
    public static func load(from file: URL) throws -> ResponsesModelPort {
        let (address, key) = try settings(from: file)
        do { return try ResponsesModelPort(baseURL: address, apiKey: key, model: "gpt-6.1-sol") }
        catch { throw VoiceOSError("无法读取有效的文本模型配置；请选择项目的本地 .env 文件") }
    }
    public static func loadRelevance(from file: URL) throws -> ResponsesRelevancePort {
        let (address, key) = try settings(from: file)
        do { return try ResponsesRelevancePort(baseURL: address, apiKey: key, model: "gpt-6.1-sol") }
        catch { throw VoiceOSError("无法读取有效的文本模型配置；请选择项目的本地 .env 文件") }
    }
    public static func loadDiscussion(from file: URL) throws -> ResponsesDiscussionPort {
        let (address, key) = try settings(from: file)
        do { return try ResponsesDiscussionPort(baseURL: address, apiKey: key, model: "gpt-6.1-sol") }
        catch { throw VoiceOSError("无法读取有效的文本模型配置；请选择项目的本地 .env 文件") }
    }
    public static func loadOutcome(from file:URL) throws -> ResponsesOutcomePort {
        let (address,key)=try settings(from:file)
        do { return try ResponsesOutcomePort(baseURL:address,apiKey:key,model:"gpt-6.1-sol") }
        catch { throw VoiceOSError("无法读取有效的文本模型配置；请选择项目的本地 .env 文件") }
    }
    public static func loadEnglish(from file:URL) throws -> ResponsesEnglishPracticePort {
        let (address,key)=try settings(from:file)
        do { return try ResponsesEnglishPracticePort(baseURL:address,apiKey:key,model:"gpt-6.1-sol") }
        catch { throw VoiceOSError("无法读取有效的文本模型配置；请选择项目的本地 .env 文件") }
    }
    private static func settings(from file: URL) throws -> (URL, String) {
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
                return (address, key)
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
            return (address, key)
        } catch { throw VoiceOSError("无法读取有效的文本模型配置；请选择项目的本地 .env 文件") }
    }
}
