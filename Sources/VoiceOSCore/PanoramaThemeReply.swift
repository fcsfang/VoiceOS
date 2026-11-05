import Foundation

public struct PanoramaThemeQuote: Codable, Sendable, Identifiable {
    public let id: String
    public let text: String
    public let sourceTitle: String
    public let occurredAt: String
    public let questionID: String
    public let questionTitle: String
}

/// The exact material a theme reply is generated from: the user's own words first,
/// then the claims behind them and the one question still open in the theme.
public struct PanoramaThemeBriefing: Codable, Sendable {
    public let regionID: String
    public let title: String
    public let summary: String
    public let quotes: [PanoramaThemeQuote]
    public let statements: [String]
    public let openQuestionID: String?
    public let openQuestionTitle: String?
    public let openQuestionEvidenceCount: Int
    public let digest: String

    public static func make(snapshot: PanoramaSnapshot, regionID: String) -> PanoramaThemeBriefing? {
        guard let region = snapshot.proposal.regions.first(where: { $0.id == regionID }) else { return nil }
        return make(snapshot: snapshot, region: region)
    }

    public static func make(snapshot: PanoramaSnapshot, region: PanoramaRegion) -> PanoramaThemeBriefing {
        let sources = Dictionary(snapshot.input.sources.map { ($0.transcript.sourceID, $0) }, uniquingKeysWith: { first, _ in first })
        let claims = Dictionary(snapshot.input.claims.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let questions = snapshot.proposal.questions.filter { $0.regionID == region.id }
        func latest(_ question: PanoramaQuestion) -> String {
            question.evidence.compactMap { sources[$0.sourceID]?.occurredAt }.max() ?? ""
        }
        let ranked = questions.sorted {
            if $0.evidence.count != $1.evidence.count { return $0.evidence.count > $1.evidence.count }
            return latest($0) > latest($1)
        }
        struct Candidate {
            let question: PanoramaQuestion
            let evidence: PanoramaEvidence
            let title: String
            let date: String
            let score: Int
            let fillers: Int
            let length: Int
        }
        let regionBigrams = themeBigrams(region.title)
        var candidates: [Candidate] = []
        var seen = Set<String>()
        for question in ranked {
            let questionBigrams = themeBigrams(question.title)
            for evidence in question.evidence {
                let text = evidence.quote.trimmingCharacters(in: .whitespacesAndNewlines)
                let length = text.unicodeScalars.count
                guard length >= 12, length <= 400, seen.insert(String(text.prefix(24))).inserted else { continue }
                let fillers = themeFillerCount(text)
                let claimBonus = evidence.claimIDs.contains { claims[$0]?.statement.hasPrefix("【观点】") == true } ? 2 : 0
                let score = 3 * themeQuality(text)
                    + 2 * questionBigrams.intersection(themeBigrams(text)).count
                    + regionBigrams.intersection(themeBigrams(text)).count
                    + claimBonus
                let source = sources[evidence.sourceID]
                candidates.append(.init(question: question, evidence: evidence, title: source?.title ?? "", date: source?.occurredAt ?? "",
                    score: score, fillers: fillers, length: length))
            }
        }
        let strict = candidates.filter { $0.fillers <= 3 && $0.length <= 180 }
        let eligible = strict.count >= 2 ? strict : candidates
        let ordered = eligible.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.fillers != $1.fillers { return $0.fillers < $1.fillers }
            return $0.length < $1.length
        }
        var picked: [Candidate] = []
        if let first = ordered.first {
            picked.append(first)
            if let second = ordered.first(where: { $0.evidence.sourceID != first.evidence.sourceID })
                ?? ordered.first(where: { $0.question.id != first.question.id })
                ?? ordered.dropFirst().first {
                picked.append(second)
            }
        }
        let quotes = picked.map { candidate in
            PanoramaThemeQuote(
                id: candidate.question.id + "/" + String(candidate.evidence.start),
                text: candidate.evidence.quote.trimmingCharacters(in: .whitespacesAndNewlines),
                sourceTitle: candidate.title,
                occurredAt: candidate.date,
                questionID: candidate.question.id,
                questionTitle: candidate.question.title
            )
        }
        var statements: [String] = []
        var seenStatements = Set<String>()
        for candidate in picked {
            for claimID in candidate.evidence.claimIDs {
                guard let claim = claims[claimID] else { continue }
                let statement = normalizedStatement(claim.statement)
                guard !statement.isEmpty, seenStatements.insert(statement).inserted else { continue }
                statements.append(statement)
                if statements.count == 4 { break }
            }
            if statements.count == 4 { break }
        }
        let quoteQuestionIDs = Set(picked.map(\.question.id))
        let open = ranked.first(where: { !quoteQuestionIDs.contains($0.id) }) ?? ranked.first
        let digestValue = Digest(regionID: region.id, title: region.title, summary: region.summary,
            quotes: quotes.map { [$0.text, $0.sourceTitle, $0.occurredAt] },
            statements: statements,
            openQuestionTitle: open?.title ?? "",
            openQuestionEvidenceCount: open?.evidence.count ?? 0)
        let digest = (try? VoiceOSStore.relevanceJSON(digestValue)).map { VoiceOSStore.relevanceHash(Data($0.utf8)) } ?? region.id
        return .init(regionID: region.id, title: region.title, summary: region.summary,
            quotes: quotes, statements: statements,
            openQuestionID: open?.id, openQuestionTitle: open?.title,
            openQuestionEvidenceCount: open?.evidence.count ?? 0, digest: digest)
    }

    private struct Digest: Encodable {
        let regionID: String
        let title: String
        let summary: String
        let quotes: [[String]]
        let statements: [String]
        let openQuestionTitle: String
        let openQuestionEvidenceCount: Int
    }

    private static func normalizedStatement(_ raw: String) -> String {
        var text = raw
        for separator in ["\n说明：", "\n说明:"] {
            if let range = text.range(of: separator) { text = String(text[..<range.lowerBound]) }
        }
        for prefix in ["【观点】", "【问题】", "【想法】", "【长期目标】", "【待核对】"] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func themeBigrams(_ text: String) -> Set<String> {
        let characters = Array(text)
        guard characters.count >= 2 else { return [] }
        var result = Set<String>()
        for index in 0..<(characters.count - 1) {
            result.insert(String(characters[index...index + 1]))
        }
        return result
    }

    private static func themeFillerCount(_ text: String) -> Int {
        ["呃", "嗯", "啊", "就是说", "这个"].reduce(0) { $0 + text.components(separatedBy: $1).count - 1 }
    }

    private static func themeQuality(_ text: String) -> Int {
        var score = 0
        if text.contains("我") { score += 3 }
        if text.hasSuffix("。") { score += 2 }
        if text.hasPrefix("呃，") || text.hasPrefix("嗯，") || text.hasPrefix("啊，") || text.hasPrefix("就是") { score -= 3 }
        score -= max(0, themeFillerCount(text) - 2)
        return score
    }
}

public struct PanoramaThemeReplyResponse: Sendable {
    public let text: String
    public let inputTokens: Int?
    public let outputTokens: Int?
    public init(text: String, inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.text = text
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public protocol PanoramaThemeReplyPort: Sendable {
    var configuration: ModelConfiguration { get }
    func reply(_ briefing: PanoramaThemeBriefing) async throws -> PanoramaThemeReplyResponse
}

/// One direct text request for the theme reader. Same Responses envelope as the other
/// ports; no tools, no retry, no stored model-side state.
public struct ResponsesThemeReplyPort: PanoramaThemeReplyPort {
    public let configuration: ModelConfiguration
    private let endpoint: URL
    private let apiKey: String
    private let transport: any ModelHTTPTransport

    public init(baseURL: URL, apiKey: String, model: String, transport: any ModelHTTPTransport = DirectModelHTTPTransport()) throws {
        let validated = try ResponsesModelPort(baseURL: baseURL, apiKey: apiKey, model: model, transport: transport)
        configuration = ModelConfiguration(provider: validated.configuration.provider, model: model,
            promptVersion: "theme-reply-v1", schemaVersion: "theme-reply-text-v1", destination: .cloud)
        endpoint = baseURL.appendingPathComponent("responses")
        self.apiKey = apiKey
        self.transport = transport
    }

    public func reply(_ briefing: PanoramaThemeBriefing) async throws -> PanoramaThemeReplyResponse {
        try Task.checkCancellation()
        let http = try makeRequest(briefing)
        let response = try await transport.send(http)
        guard response.status == 200 else { throw ModelPortFailure.rejected("HTTP \(response.status)；费用未知，不自动重发") }
        let envelope = try ResponsesEnvelope.parse(response.body)
        guard envelope.status == .completed, let raw = envelope.text,
              let data = raw.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["reply"], let reply = object["reply"] as? String else {
            throw ModelPortFailure.rejected("主题回应结构不符", inputTokens: envelope.inputTokens, outputTokens: envelope.outputTokens)
        }
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.unicodeScalars.count <= 1200 else {
            throw ModelPortFailure.rejected("主题回应为空或过长", inputTokens: envelope.inputTokens, outputTokens: envelope.outputTokens)
        }
        return .init(text: text, inputTokens: envelope.inputTokens, outputTokens: envelope.outputTokens)
    }

    func makeRequest(_ briefing: PanoramaThemeBriefing) throws -> URLRequest {
        let input: [String: Any] = [
            "theme": ["title": briefing.title, "summary": briefing.summary],
            "user_quotes": briefing.quotes.map { ["text": $0.text, "date": $0.occurredAt, "source": $0.sourceTitle] },
            "user_claims": briefing.statements,
            "open_question": briefing.openQuestionTitle ?? ""
        ]
        let schema: [String: Any] = ["type": "object", "properties": ["reply": ["type": "string"]],
            "required": ["reply"], "additionalProperties": false]
        let content = String(decoding: try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]), as: UTF8.self)
        let payload: [String: Any] = [
            "model": configuration.model,
            "store": false,
            "reasoning": ["effort": "medium"],
            "max_output_tokens": 800,
            "truncation": "disabled",
            "instructions": Self.instructions,
            "input": [["role": "user", "content": content]],
            "text": ["format": ["type": "json_schema", "name": "voiceos_theme_reply", "strict": true, "schema": schema]]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard data.count <= 200_000 else { throw ModelPortFailure.rejected("主题回应请求超过字节预算") }
        var request = URLRequest(url: endpoint, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    static let instructions = """
    你是 VoiceOS 的思考伙伴。用户点开一个主题，你要接着他本人说过的话往下想。
    只使用提供的原话、观点和未解问题，不编造用户没有说过的事实，不把 AI 的推测写成用户的结论。
    写作要求：
    1. 第一句复述你听到的核心，用用户自己的措辞，不夸奖。
    2. 第二句指出一个用户没有明说的模式、前提或矛盾。这是回应的价值，只复述没有意义。
    3. 如果用户的话里有一个问题，直接给出你的回答或可能答案；如果是一个判断，往下推一步。明确这是你的看法，不是已证实的事实。
    4. 最后只给一个具体的下一步或一个更准的问题，不要列清单。
    5. 三到五句中文，全文不超过 220 字，不用列表，不用“首先/其次”，不空泛，不说“作为 AI”。
    6. 材料不足以支撑分析时直说依据不足，不要硬编。
    """
}

extension VoiceOSStore {
    public func panoramaThemeReply(_ briefing: PanoramaThemeBriefing, using port: any PanoramaThemeReplyPort) async throws -> String {
        try Task.checkCancellation()
        let configuration = port.configuration
        guard !configuration.provider.isEmpty, !configuration.model.isEmpty, !configuration.promptVersion.isEmpty else {
            throw VoiceOSError("主题回应端口配置无效")
        }
        let digest = Self.relevanceHash(Data((briefing.digest + "|" + configuration.promptVersion).utf8))
        if let row = try db.query("SELECT reply FROM panorama_theme_replies WHERE region_id=? AND digest=? AND state='completed' ORDER BY rowid DESC LIMIT 1", [briefing.regionID, digest]).first,
           let reply = row["reply"], !reply.isEmpty {
            return reply
        }
        let response = try await port.reply(briefing)
        let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.unicodeScalars.count <= 1200 else { throw VoiceOSError("主题回应为空或过长") }
        try db.execute("INSERT OR REPLACE INTO panorama_theme_replies(region_id,digest,reply,model,prompt_version,state,created_at) VALUES(?,?,?,?,?,'completed',?)",
            [briefing.regionID, digest, text, configuration.model, configuration.promptVersion, Self.now()])
        return text
    }
}
