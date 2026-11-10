import Foundation

public enum TaskInitiationRoute: String, Codable, CaseIterable, Sendable {
    case agentHandoff = "agent_handoff", guidedStart = "guided_start", clarify, captureOnly = "capture_only"
}
public enum TaskInitiationMode: String, Codable, Sendable { case direct, interactive }
public enum TaskInitiationPreference: String, Codable, Sendable {
    case quickDelivery = "quick_delivery", learnWhileDoing = "learn_while_doing"
}
public struct TaskInitiationProposal: Codable, Sendable {
    public let isTaskInitiation: Bool
    public let route: TaskInitiationRoute
    public let title: String
    public let objective: String
    public let knownFacts: [String]
    public let assumptions: [String]
    public let missingInformation: [String]
    public let constraints: [String]
    public let acceptanceCriteria: [String]
    public let preference: TaskInitiationPreference
    public let targetExecutor: String
    public let deliverables: [String]
    public let guidePrerequisites: [String]
    public let guideSteps: [String]
    public let firstAction: String
    public let verification: String
    public let clarifyQuestion: String
    public let reason: String
    public init(isTaskInitiation: Bool, route: TaskInitiationRoute, title: String = "", objective: String = "",
                knownFacts: [String] = [], assumptions: [String] = [], missingInformation: [String] = [],
                constraints: [String] = [], acceptanceCriteria: [String] = [],
                preference: TaskInitiationPreference = .quickDelivery, targetExecutor: String = "",
                deliverables: [String] = [], guidePrerequisites: [String] = [], guideSteps: [String] = [],
                firstAction: String = "", verification: String = "", clarifyQuestion: String = "", reason: String = "") {
        self.isTaskInitiation = isTaskInitiation; self.route = route; self.title = title; self.objective = objective
        self.knownFacts = knownFacts; self.assumptions = assumptions; self.missingInformation = missingInformation
        self.constraints = constraints; self.acceptanceCriteria = acceptanceCriteria; self.preference = preference
        self.targetExecutor = targetExecutor; self.deliverables = deliverables; self.guidePrerequisites = guidePrerequisites
        self.guideSteps = guideSteps; self.firstAction = firstAction; self.verification = verification
        self.clarifyQuestion = clarifyQuestion; self.reason = reason
    }
    private enum CodingKeys: String, CodingKey {
        case isTaskInitiation = "is_task_initiation", route, title, objective
        case knownFacts = "known_facts", assumptions, missingInformation = "missing_information", constraints
        case acceptanceCriteria = "acceptance_criteria", preference = "execution_preference", targetExecutor = "target_executor"
        case deliverables, guidePrerequisites = "guide_prerequisites", guideSteps = "guide_steps"
        case firstAction = "first_action", verification, clarifyQuestion = "clarify_question", reason
    }
    /// Model output is parsed at this boundary: only route and is_task_initiation
    /// decide the route, so their absence must fail instead of silently defaulting.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isTaskInitiation = try container.decode(Bool.self, forKey: .isTaskInitiation)
        route = try container.decode(TaskInitiationRoute.self, forKey: .route)
        title = (try? container.decode(String.self, forKey: .title)) ?? ""
        objective = (try? container.decode(String.self, forKey: .objective)) ?? ""
        knownFacts = (try? container.decode([String].self, forKey: .knownFacts)) ?? []
        assumptions = (try? container.decode([String].self, forKey: .assumptions)) ?? []
        missingInformation = (try? container.decode([String].self, forKey: .missingInformation)) ?? []
        constraints = (try? container.decode([String].self, forKey: .constraints)) ?? []
        acceptanceCriteria = (try? container.decode([String].self, forKey: .acceptanceCriteria)) ?? []
        preference = (try? container.decode(TaskInitiationPreference.self, forKey: .preference)) ?? .quickDelivery
        targetExecutor = (try? container.decode(String.self, forKey: .targetExecutor)) ?? ""
        deliverables = (try? container.decode([String].self, forKey: .deliverables)) ?? []
        guidePrerequisites = (try? container.decode([String].self, forKey: .guidePrerequisites)) ?? []
        guideSteps = (try? container.decode([String].self, forKey: .guideSteps)) ?? []
        firstAction = (try? container.decode(String.self, forKey: .firstAction)) ?? ""
        verification = (try? container.decode(String.self, forKey: .verification)) ?? ""
        clarifyQuestion = (try? container.decode(String.self, forKey: .clarifyQuestion)) ?? ""
        reason = (try? container.decode(String.self, forKey: .reason)) ?? ""
    }
    func replacing(route: TaskInitiationRoute? = nil, title: String? = nil,
                   preference: TaskInitiationPreference? = nil) -> TaskInitiationProposal {
        .init(isTaskInitiation: isTaskInitiation, route: route ?? self.route, title: title ?? self.title,
              objective: objective, knownFacts: knownFacts, assumptions: assumptions,
              missingInformation: missingInformation, constraints: constraints, acceptanceCriteria: acceptanceCriteria,
              preference: preference ?? self.preference, targetExecutor: targetExecutor, deliverables: deliverables,
              guidePrerequisites: guidePrerequisites, guideSteps: guideSteps, firstAction: firstAction,
              verification: verification, clarifyQuestion: clarifyQuestion, reason: reason)
    }
}
public struct TaskInitiationInput: Codable, Sendable {
    public let sourceID: String
    public let transcriptVersionID: String
    public let text: String
    public let answer: String
    public let mode: TaskInitiationMode
    public let preferredRoute: TaskInitiationRoute?
    public let recordedAt: String
    public let timeZone: String
    public init(sourceID: String, transcriptVersionID: String, text: String, answer: String,
                mode: TaskInitiationMode, preferredRoute: TaskInitiationRoute?, recordedAt: String, timeZone: String) {
        self.sourceID = sourceID; self.transcriptVersionID = transcriptVersionID; self.text = text; self.answer = answer
        self.mode = mode; self.preferredRoute = preferredRoute; self.recordedAt = recordedAt; self.timeZone = timeZone
    }
}
public struct TaskInitiationRecord: Identifiable, Sendable {
    public let id, sourceID, transcriptVersionID, state, createdAt, updatedAt: String
    public let route: TaskInitiationRoute
    public let proposal: TaskInitiationProposal
    public let input: TaskInitiationInput
    public let editedArtifact, copiedAt: String?
    public let basisChanged: Bool
    public init(id: String, sourceID: String, transcriptVersionID: String, state: String, createdAt: String,
                updatedAt: String, route: TaskInitiationRoute, proposal: TaskInitiationProposal,
                input: TaskInitiationInput, editedArtifact: String?, copiedAt: String?, basisChanged: Bool) {
        self.id = id; self.sourceID = sourceID; self.transcriptVersionID = transcriptVersionID; self.state = state
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.route = route; self.proposal = proposal
        self.input = input; self.editedArtifact = editedArtifact; self.copiedAt = copiedAt
        self.basisChanged = basisChanged
    }
    public var artifact: String { editedArtifact ?? TaskInitiationComposer.render(proposal) }
    public var isConfirmed: Bool { state == "confirmed" }
    public var isClarifying: Bool { state == "clarify" }
}
public protocol TaskInitiationModelPort: Sendable {
    var configuration: ModelConfiguration { get }
    func initiate(_ input: TaskInitiationInput) async throws -> TaskInitiationProposal
}

/// Semantic fields come from the model; the copyable handoff and tutorial are
/// assembled here so structure, fact/assumption separation and the fixed
/// environment check cannot vary between responses.
public enum TaskInitiationComposer {
    public static func validate(_ proposal: TaskInitiationProposal, mode: TaskInitiationMode,
                                preferredRoute: TaskInitiationRoute?) throws -> TaskInitiationProposal {
        var result = proposal
        if !result.isTaskInitiation {
            result = result.replacing(route: .captureOnly)
        } else if let preferredRoute, result.route != preferredRoute {
            throw VoiceOSError("生成路线与所选路线不一致，请重新生成")
        }
        if result.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let fallback = result.objective.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map(String.init) ?? ""
            result = result.replacing(title: fallback.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        switch result.route {
        case .captureOnly:
            break
        case .clarify:
            guard mode == .interactive else { throw VoiceOSError("直接生成时不能反问；请按显式假设给出草稿") }
            guard !result.clarifyQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw VoiceOSError("澄清路线必须给出一个关键问题")
            }
        case .agentHandoff:
            guard !result.objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  result.acceptanceCriteria.contains(where: nonEmpty) else {
                throw VoiceOSError("交接路线缺少目标或可检查的验收标准")
            }
        case .guidedStart:
            guard result.guideSteps.contains(where: nonEmpty),
                  !result.firstAction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !result.verification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw VoiceOSError("教程路线缺少步骤、第一步或验证方法")
            }
        }
        return result
    }

    public static func render(_ proposal: TaskInitiationProposal) -> String {
        switch proposal.route {
        case .clarify, .captureOnly: return ""
        case .agentHandoff: return handoff(proposal)
        case .guidedStart: return guide(proposal)
        }
    }

    public static func secretWarning(in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard secretPatterns.contains(where: { $0.firstMatch(in: text, range: range) != nil }) else { return nil }
        return "检测到可能包含密码、密钥或令牌的内容；复制或交付前请先删除这些敏感信息。"
    }

    private static func handoff(_ proposal: TaskInitiationProposal) -> String {
        var sections: [String] = []
        let goal = firstNonEmpty(proposal.objective, proposal.title) ?? "（待确认任务目标）"
        sections.append("# 任务目标\n" + goal)

        var background = bullets(proposal.knownFacts)
        if background.isEmpty { background = ["- （暂无用户提供的事实）"] }
        background += bullets(proposal.assumptions, prefix: "假设（请先核实）：")
        background += bullets(proposal.missingInformation, prefix: "待确认：")
        sections.append("# 已知背景\n" + background.joined(separator: "\n"))

        var preference: [String] = []
        if let executor = firstNonEmpty(proposal.targetExecutor) { preference.append("- 建议执行者：\(executor)") }
        preference.append(proposal.preference == .learnWhileDoing
            ? "- 边做边学：交付时解释关键实现、入口与验证方法"
            : "- 执行偏好：优先快速交付")
        preference += bullets(proposal.constraints)
        sections.append("# 约束与偏好\n" + preference.joined(separator: "\n"))

        sections.append("# 请先做的事\n- 先检查真实环境（仓库、文件、工具与已有资料），不要假设已经读过它们。")
        sections.append("""
        # 执行要求
        - 先确认目标、现有资料和限制，再分步执行。
        - 遵守现有项目或工具约定；必要时先说明计划，再增量完成。
        - 不确定的事实明确标为假设，不编造未核实的信息。
        """)

        let deliverables = bullets(proposal.deliverables)
        sections.append("# 预期交付物\n" + (deliverables.isEmpty ? "- （暂无）" : deliverables.joined(separator: "\n")))
        let acceptance = bullets(proposal.acceptanceCriteria)
        sections.append("# 验收标准\n" + (acceptance.isEmpty ? "- （暂无）" : acceptance.joined(separator: "\n")))
        sections.append("# 遇到阻碍时\n- 说明缺失信息与最小可继续方案，不得编造事实。")
        return sections.joined(separator: "\n\n")
    }

    private static func guide(_ proposal: TaskInitiationProposal) -> String {
        var goal = "# 任务目标\n" + (firstNonEmpty(proposal.objective, proposal.title) ?? "（待确认任务目标）")
        if proposal.preference == .learnWhileDoing {
            goal += "\n\n边做边学：交付时解释关键实现、入口与验证方法"
        }
        var prerequisites = bullets(proposal.guidePrerequisites)
        if prerequisites.isEmpty { prerequisites = ["- （暂无）"] }
        prerequisites += bullets(proposal.assumptions, prefix: "假设（请先核实）：")
        prerequisites += bullets(proposal.missingInformation, prefix: "待确认：")
        let steps = proposal.guideSteps.map(trimmed).filter { !$0.isEmpty }.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
        return [
            goal,
            "# 开始前需要的条件\n" + prerequisites.joined(separator: "\n"),
            "# 操作步骤\n" + (steps.isEmpty ? "（待确认具体步骤）" : steps.joined(separator: "\n")),
            "# 第一步\n" + (firstNonEmpty(proposal.firstAction) ?? "（待确认）"),
            "# 验证是否做到\n" + (firstNonEmpty(proposal.verification) ?? "（待确认）")
        ].joined(separator: "\n\n")
    }

    private static func bullets(_ values: [String], prefix: String = "") -> [String] {
        values.map(trimmed).filter { !$0.isEmpty }.map { "- " + prefix + $0 }
    }
    private static func trimmed(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
    private static func nonEmpty(_ value: String) -> Bool { !trimmed(value).isEmpty }
    private static func firstNonEmpty(_ values: String...) -> String? {
        values.map(trimmed).first { !$0.isEmpty }
    }
    private static let secretPatterns: [NSRegularExpression] = [
        #"(?<![A-Za-z0-9])sk-[A-Za-z0-9_-]{16,}"#,
        #"AKIA[0-9A-Z]{16}"#,
        #"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----"#,
        #"(?i)\b(password|passwd|api_key|token)\s*="#
    ].compactMap { try? NSRegularExpression(pattern: $0) }
}

extension VoiceOSStore {
    public func taskInitiationInput(sourceID: String, mode: TaskInitiationMode,
                                    preferredRoute: TaskInitiationRoute? = nil, answer: String = "") throws -> TaskInitiationInput {
        guard ready else { throw VoiceOSError("资料库尚未完成恢复") }
        guard let source = try sources().first(where: { $0.id == sourceID }) else { throw VoiceOSError("材料不存在") }
        guard source.origin == "user", source.speaker == "user", ["saved", "reference_only"].contains(source.state) else {
            throw VoiceOSError("启动包只接受本人已保存的原话")
        }
        guard !source.localOnly else { throw VoiceOSError("这份材料仍是仅本地资料；请先允许用于云端，再生成启动包") }
        guard !source.needsTranscriptionReview else { throw VoiceOSError("请先完成这份录音的全文转写校正，再生成启动包") }
        guard let text = source.transcript, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoiceOSError("这份材料还没有可用的原话")
        }
        guard text.unicodeScalars.count <= 4000 else { throw VoiceOSError("这份原话超过 4000 字；请拆分或精简后再生成启动包") }
        guard let version = source.transcriptVersionID else { throw VoiceOSError("这份材料还没有可用的转写版本") }
        return .init(sourceID: source.id, transcriptVersionID: version, text: text, answer: answer, mode: mode,
                     preferredRoute: preferredRoute, recordedAt: source.createdAt, timeZone: source.timeZone)
    }

    @discardableResult
    public func recordTaskInitiation(_ input: TaskInitiationInput, proposal: TaskInitiationProposal,
                                     commandID: String = UUID().uuidString) throws -> TaskInitiationRecord {
        guard ready else { throw VoiceOSError("资料库尚未完成恢复") }
        var validated = try TaskInitiationComposer.validate(proposal, mode: input.mode, preferredRoute: input.preferredRoute)
        validated = taskInitiationTitleFallback(validated, text: input.text)
        try validateTaskInitiationBasis(input)
        if let existing = try db.query("SELECT id FROM task_initiations WHERE command_id=?", [commandID]).first {
            return try taskInitiationRecord(id: existing["id"]!)
        }
        let id = UUID().uuidString, now = Self.now(), state = validated.route == .clarify ? "clarify" : "draft"
        try db.execute("""
        INSERT INTO task_initiations(id,command_id,source_id,transcript_version_id,state,route,input_json,proposal_json,created_at,updated_at)
        VALUES(?,?,?,?,?,?,?,?,?,?)
        """, [id, commandID, input.sourceID, input.transcriptVersionID, state, validated.route.rawValue,
              try Self.relevanceJSON(input), try Self.relevanceJSON(validated), now, now])
        return try taskInitiationRecord(id: id)
    }

    @discardableResult
    public func recordTaskInitiationClarification(id: String, answer: String,
                                                  proposal: TaskInitiationProposal) throws -> TaskInitiationRecord {
        guard ready else { throw VoiceOSError("资料库尚未完成恢复") }
        guard let row = try db.query("SELECT * FROM task_initiations WHERE id=?", [id]).first else {
            throw VoiceOSError("启动包不存在")
        }
        guard row["state"] == "clarify" else { throw VoiceOSError("只有待澄清的启动包可以回答") }
        let input = try JSONDecoder().decode(TaskInitiationInput.self, from: Data(row["input_json"]!.utf8))
        try validateTaskInitiationBasis(input)
        let cleanAnswer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanAnswer.isEmpty else { throw VoiceOSError("请先填写澄清回答") }
        let preferred = input.preferredRoute == .clarify ? nil : input.preferredRoute
        var validated = try TaskInitiationComposer.validate(proposal, mode: .direct, preferredRoute: preferred)
        validated = taskInitiationTitleFallback(validated, text: input.text)
        let nextInput = TaskInitiationInput(sourceID: input.sourceID, transcriptVersionID: input.transcriptVersionID,
                                            text: input.text, answer: cleanAnswer, mode: input.mode,
                                            preferredRoute: input.preferredRoute, recordedAt: input.recordedAt,
                                            timeZone: input.timeZone)
        try db.execute("""
        UPDATE task_initiations SET input_json=?,proposal_json=?,state='draft',route=?,edited_artifact=NULL,copied_at=NULL,updated_at=?
        WHERE id=?
        """, [try Self.relevanceJSON(nextInput), try Self.relevanceJSON(validated), validated.route.rawValue,
              Self.now(), id])
        return try taskInitiationRecord(id: id)
    }

    @discardableResult
    public func replaceTaskInitiation(id: String, preferredRoute: TaskInitiationRoute,
                                      proposal: TaskInitiationProposal) throws -> TaskInitiationRecord {
        guard ready else { throw VoiceOSError("资料库尚未完成恢复") }
        guard let row = try db.query("SELECT * FROM task_initiations WHERE id=?", [id]).first else {
            throw VoiceOSError("启动包不存在")
        }
        guard row["state"] == "draft" else { throw VoiceOSError("已确认的启动包不能更换路线") }
        guard preferredRoute != .clarify else { throw VoiceOSError("直接生成时不能改用澄清路线") }
        let input = try JSONDecoder().decode(TaskInitiationInput.self, from: Data(row["input_json"]!.utf8))
        try validateTaskInitiationBasis(input)
        var validated = try TaskInitiationComposer.validate(proposal, mode: input.mode, preferredRoute: preferredRoute)
        validated = taskInitiationTitleFallback(validated, text: input.text)
        guard validated.route == preferredRoute else { throw VoiceOSError("生成路线与所选路线不一致，请重新生成") }
        let nextInput = TaskInitiationInput(sourceID: input.sourceID, transcriptVersionID: input.transcriptVersionID,
                                            text: input.text, answer: input.answer, mode: input.mode,
                                            preferredRoute: preferredRoute, recordedAt: input.recordedAt,
                                            timeZone: input.timeZone)
        try db.execute("""
        UPDATE task_initiations SET input_json=?,proposal_json=?,route=?,edited_artifact=NULL,copied_at=NULL,updated_at=?
        WHERE id=?
        """, [try Self.relevanceJSON(nextInput), try Self.relevanceJSON(validated), validated.route.rawValue,
              Self.now(), id])
        return try taskInitiationRecord(id: id)
    }

    @discardableResult
    public func setTaskInitiationPreference(id: String,
                                            preference: TaskInitiationPreference) throws -> TaskInitiationRecord {
        guard ready else { throw VoiceOSError("资料库尚未完成恢复") }
        guard let row = try db.query("SELECT * FROM task_initiations WHERE id=?", [id]).first else {
            throw VoiceOSError("启动包不存在")
        }
        guard row["state"] == "draft" else { throw VoiceOSError("已确认的启动包不能再调整偏好") }
        guard row["edited_artifact"] == nil else { throw VoiceOSError("启动包已手动编辑；不会再自动调整") }
        let proposal = try JSONDecoder().decode(TaskInitiationProposal.self, from: Data(row["proposal_json"]!.utf8))
        guard proposal.preference != preference else { return try taskInitiationRecord(id: id) }
        let rebuilt = proposal.replacing(preference: preference)
        try db.execute("UPDATE task_initiations SET proposal_json=?,updated_at=? WHERE id=?",
                       [try Self.relevanceJSON(rebuilt), Self.now(), id])
        return try taskInitiationRecord(id: id)
    }

    @discardableResult
    public func confirmTaskInitiation(id: String, artifact: String) throws -> TaskInitiationRecord {
        guard ready else { throw VoiceOSError("资料库尚未完成恢复") }
        guard let row = try db.query("SELECT * FROM task_initiations WHERE id=?", [id]).first else {
            throw VoiceOSError("启动包不存在")
        }
        guard row["state"] == "draft" else { throw VoiceOSError("只有草稿可以确认") }
        let proposal = try JSONDecoder().decode(TaskInitiationProposal.self, from: Data(row["proposal_json"]!.utf8))
        guard proposal.route == .agentHandoff || proposal.route == .guidedStart else {
            throw VoiceOSError("这次启动没有可确认的交接材料")
        }
        guard !artifact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoiceOSError("启动材料不能为空")
        }
        let edited = artifact == TaskInitiationComposer.render(proposal) ? nil : artifact
        try db.execute("UPDATE task_initiations SET state='confirmed',edited_artifact=?,updated_at=? WHERE id=?",
                       [edited, Self.now(), id])
        return try taskInitiationRecord(id: id)
    }

    @discardableResult
    public func markTaskInitiationCopied(id: String, artifact: String) throws -> TaskInitiationRecord {
        guard ready else { throw VoiceOSError("资料库尚未完成恢复") }
        guard let row = try db.query("SELECT * FROM task_initiations WHERE id=?", [id]).first else {
            throw VoiceOSError("启动包不存在")
        }
        let proposal = try JSONDecoder().decode(TaskInitiationProposal.self, from: Data(row["proposal_json"]!.utf8))
        guard proposal.route == .agentHandoff || proposal.route == .guidedStart else {
            throw VoiceOSError("这次启动没有可复制的材料")
        }
        guard !artifact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoiceOSError("启动材料不能为空")
        }
        let edited = artifact == TaskInitiationComposer.render(proposal) ? nil : artifact
        let now = Self.now()
        try db.execute("UPDATE task_initiations SET edited_artifact=?,copied_at=?,updated_at=? WHERE id=?",
                       [edited, now, now, id])
        return try taskInitiationRecord(id: id)
    }

    public func discardTaskInitiation(id: String) throws {
        guard ready else { throw VoiceOSError("资料库尚未完成恢复") }
        guard let row = try db.query("SELECT state FROM task_initiations WHERE id=?", [id]).first else {
            throw VoiceOSError("启动包不存在")
        }
        guard row["state"] != "confirmed" else { throw VoiceOSError("已确认的启动包不能删除") }
        try db.execute("DELETE FROM task_initiations WHERE id=?", [id])
    }

    public func taskInitiations(limit: Int = 200) throws -> [TaskInitiationRecord] {
        guard ready else { throw VoiceOSError("资料库尚未完成恢复") }
        guard limit > 0 else { return [] }
        let catalog = Dictionary(uniqueKeysWithValues: try sources().map { ($0.id, $0) })
        return try db.query("SELECT * FROM task_initiations ORDER BY created_at DESC, id DESC LIMIT ?", [String(limit)])
            .map { try Self.decodeTaskInitiation($0, sources: catalog) }
    }

    private func taskInitiationRecord(id: String) throws -> TaskInitiationRecord {
        guard let row = try db.query("SELECT * FROM task_initiations WHERE id=?", [id]).first else {
            throw VoiceOSError("启动包不存在")
        }
        let catalog = Dictionary(uniqueKeysWithValues: try sources().map { ($0.id, $0) })
        return try Self.decodeTaskInitiation(row, sources: catalog)
    }

    private func validateTaskInitiationBasis(_ input: TaskInitiationInput) throws {
        guard let source = try sources().first(where: { $0.id == input.sourceID }) else {
            throw VoiceOSError("启动包对应的材料已不存在")
        }
        guard source.origin == "user", source.speaker == "user", ["saved", "reference_only"].contains(source.state) else {
            throw VoiceOSError("启动包只接受本人已保存的原话")
        }
        guard !source.localOnly else { throw VoiceOSError("这份材料仍是仅本地资料；请先允许用于云端，再生成启动包") }
        guard !source.needsTranscriptionReview else { throw VoiceOSError("请先完成这份录音的全文转写校正，再生成启动包") }
        guard let text = source.transcript, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !input.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoiceOSError("这份材料还没有可用的原话")
        }
        guard input.text.unicodeScalars.count <= 4000 else { throw VoiceOSError("这份原话超过 4000 字；请拆分或精简后再生成启动包") }
        guard source.transcriptVersionID == input.transcriptVersionID, text == input.text else {
            throw VoiceOSError("原话或转写版本已变化，请重新生成启动包")
        }
    }

    private func taskInitiationTitleFallback(_ proposal: TaskInitiationProposal, text: String) -> TaskInitiationProposal {
        guard proposal.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return proposal }
        let fallback = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return proposal.replacing(title: fallback)
    }

    private static func decodeTaskInitiation(_ row: [String: String],
                                             sources: [String: SourceRecord]) throws -> TaskInitiationRecord {
        guard let id = row["id"], let state = row["state"], let rawRoute = row["route"],
              let route = TaskInitiationRoute(rawValue: rawRoute), let transcriptVersionID = row["transcript_version_id"],
              let createdAt = row["created_at"], let updatedAt = row["updated_at"] else {
            throw VoiceOSError("启动包记录不完整")
        }
        let input = try JSONDecoder().decode(TaskInitiationInput.self, from: Data((row["input_json"] ?? "").utf8))
        let proposal = try JSONDecoder().decode(TaskInitiationProposal.self, from: Data((row["proposal_json"] ?? "").utf8))
        guard proposal.route == route else { throw VoiceOSError("启动包路线与记录不一致") }
        let basisChanged: Bool
        if let source = sources[input.sourceID] {
            basisChanged = !["saved", "reference_only"].contains(source.state)
                || source.transcriptVersionID != input.transcriptVersionID || source.transcript != input.text
        } else {
            basisChanged = true
        }
        return .init(id: id, sourceID: input.sourceID, transcriptVersionID: transcriptVersionID,
                     state: state, createdAt: createdAt, updatedAt: updatedAt,
                     route: route, proposal: proposal, input: input,
                     editedArtifact: row["edited_artifact"], copiedAt: row["copied_at"], basisChanged: basisChanged)
    }

    static func validateStoredTaskInitiations(_ db: Database) throws {
        let sourceIDs = Set(try db.query("SELECT id FROM sources").compactMap { $0["id"] })
        var commandIDs: Set<String> = []
        for row in try db.query("SELECT * FROM task_initiations") {
            guard let commandID = row["command_id"], commandIDs.insert(commandID).inserted,
                  let state = row["state"], ["clarify", "draft", "confirmed"].contains(state),
                  let rawRoute = row["route"], let route = TaskInitiationRoute(rawValue: rawRoute),
                  let sourceID = row["source_id"], sourceIDs.contains(sourceID),
                  (state == "clarify") == (route == .clarify),
                  let createdAt = row["created_at"], !createdAt.isEmpty,
                  let updatedAt = row["updated_at"], !updatedAt.isEmpty else {
                throw VoiceOSError("启动包记录与状态不一致")
            }
            let input = try JSONDecoder().decode(TaskInitiationInput.self, from: Data((row["input_json"] ?? "").utf8))
            let proposal = try JSONDecoder().decode(TaskInitiationProposal.self, from: Data((row["proposal_json"] ?? "").utf8))
            guard input.sourceID == sourceID, input.transcriptVersionID == row["transcript_version_id"],
                  proposal.route == route,
                  route != .clarify || !proposal.clarifyQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw VoiceOSError("启动包记录与输入或路线不一致")
            }
            let hasArtifact = route == .agentHandoff || route == .guidedStart
            if !hasArtifact, row["edited_artifact"] != nil {
                throw VoiceOSError("仅记录或澄清的启动包不能携带交接材料")
            }
            if let edited = row["edited_artifact"], edited.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw VoiceOSError("启动包手改材料不能为空")
            }
            if row["copied_at"] != nil, !hasArtifact {
                throw VoiceOSError("仅记录或澄清的启动包不能标记已复制")
            }
            if state == "confirmed", !hasArtifact {
                throw VoiceOSError("已确认的启动包缺少交接材料")
            }
        }
    }
}
