import Foundation

/// One strict structured request. No tools, no retries, and no conversation
/// state: the input carries everything the proposal may rely on.
public struct ResponsesTaskInitiationPort: TaskInitiationModelPort {
    public let configuration: ModelConfiguration
    private let endpoint: URL
    private let apiKey: String
    private let transport: any ModelHTTPTransport
    public init(baseURL: URL, apiKey: String, model: String, transport: any ModelHTTPTransport = DirectModelHTTPTransport()) throws {
        let validated = try ResponsesModelPort(baseURL: baseURL, apiKey: apiKey, model: model, transport: transport)
        configuration = .init(provider: validated.configuration.provider, model: model,
                              promptVersion: "task-initiation-v2", schemaVersion: "task-initiation-v2", destination: .cloud)
        endpoint = baseURL.appendingPathComponent("responses"); self.apiKey = apiKey; self.transport = transport
    }
    public func initiate(_ input: TaskInitiationInput) async throws -> TaskInitiationProposal {
        guard !input.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              input.text.unicodeScalars.count <= 4000 else { throw VoiceOSError("没有可用于生成启动包的原话") }
        var payload = try basePayload(input)
        payload["instructions"] = """
        你是 VoiceOS 的启动分析器。完整阅读用户这次表达，只输出一个结构化结果；不做任何外部操作，也不假定自己读过仓库、文件、日历或外部服务。

        先判断用户这次想做什么：
        - 只是提问、闲聊或知识型问题，而你可以直接、可靠地回答：返回路线 answer，is_task_initiation 为 false，并在 answer 里写出完整回答正文（中文纯文本，可多段，准确直接；不确定就说明不确定，不编造事实，不假装查过资料）。answer 路线不需要 title 或 objective。
        - 想开始、继续或交付某项工作，或明确要求生成提示词、教程、先理清思路：is_task_initiation 为 true，并从下面三条任务路线中选择。
        - 只是情绪表达、自由记录，或明确说「不要安排 / 只记录 / 先别处理」：is_task_initiation 为 false，路线为 capture_only。用户明确否定优先，此时即使指定了路线也返回 capture_only。

        任务路线三选一：
        - agent_handoff：用户希望交给 Codex、Claude Code、AI 或专业工具执行，需要一份可复制、脱离本会话也能独立理解的任务提示词。
        - guided_start：用户想自己动手，需要一份最小可操作教程；guide_steps 给出操作步骤，first_action 是现在就能做的第一步，verification 说明怎样确认做到。
        - clarify：目标或选择仍不清楚，且当前是 interactive 模式时才可以反问；clarify_question 问最能影响下一步的问题。direct 模式绝不能返回 clarify，应带显式假设生成草稿。

        answer 只用于直接回答：其它路线的 answer 返回空字符串。

        preferredRoute 是用户明确选择的路线，优先采用；但用户明确拒绝任务化时仍返回 capture_only。execution_preference：以交付为主选 quick_delivery；用户说要弄懂、边做边学或解释实现时选 learn_while_doing。

        事实、假设、待确认必须分开：known_facts 只写用户原话中明确提供的事实；assumptions 写为继续而采用、并需用户核实的假设；missing_information 写真正影响启动的未知项。不得把推测写成事实，不得编造菜单、文件、仓库、已有进度或外部环境内容；缺少环境信息时，要求执行者或用户先检查真实环境。acceptance_criteria 写可检查的完成条件。任务路线的 title 为空时用 objective 首行。reason 用中文说明路线判断。所有数组没有内容时返回 []。只返回指定 JSON。
        """
        payload["text"] = ["format": ["type": "json_schema", "name": "task_initiation", "strict": true, "schema": Self.outputSchema]]
        let data = try await send(payload)
        let envelope = try ResponsesEnvelope.parse(data)
        guard envelope.status == .completed, let text = envelope.text else { throw VoiceOSError("任务启动没有完整结果") }
        return try JSONDecoder().decode(TaskInitiationProposal.self, from: Data(text.utf8))
    }
    /// One plain-text call for the manual fallback: answer the same original
    /// words instead of turning them into a task.
    public func answer(_ input: TaskInitiationInput) async throws -> String {
        guard !input.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              input.text.unicodeScalars.count <= 4000 else { throw VoiceOSError("没有可用于直接回答的原话") }
        var content = """
        请用中文直接回答下面这段原话里的问题或请求。输出纯文本，可以分多段。不知道或不确定时明确说明，不编造事实，也不假装读过仓库、文件、日历或外部服务。
        """
        content += "\n\n原话：\n" + input.text
        let clarification = input.answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clarification.isEmpty { content += "\n\n补充说明：\n" + clarification }
        let payload: [String: Any] = ["model": configuration.model, "store": false, "reasoning": ["effort": "high"],
                                      "max_output_tokens": 8192, "truncation": "disabled",
                                      "input": [["role": "user", "content": content]]]
        let data = try await send(payload)
        let envelope = try ResponsesEnvelope.parse(data)
        guard envelope.status == .completed, let text = envelope.text,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoiceOSError("这次没有拿到回答内容，请稍后重试")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func basePayload(_ input: TaskInitiationInput) throws -> [String: Any] {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let clock = ISO8601DateFormatter(); clock.timeZone = .current
        let text = "当前时间：\(clock.string(from: Date()))；时区：\(TimeZone.current.identifier)。这个时间不代表已核查任何资料。\n"
            + String(decoding: try encoder.encode(input), as: UTF8.self)
        return ["model": configuration.model, "store": false, "reasoning": ["effort": "high"],
                "max_output_tokens": 8192, "truncation": "disabled", "input": [["role": "user", "content": text]]]
    }
    private func send(_ payload: [String: Any]) async throws -> Data {
        try Task.checkCancellation()
        var request = URLRequest(url: endpoint, timeoutInterval: 300)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let reply = try await transport.send(request)
        guard reply.status == 200 else { throw VoiceOSError("模型服务返回 HTTP \(reply.status)；可手动重试") }
        return reply.body
    }
    private static let outputSchema: [String: Any] = {
        let string: [String: Any] = ["type": "string"]
        let strings: [String: Any] = ["type": "array", "items": string]
        let properties: [String: Any] = [
            "is_task_initiation": ["type": "boolean"],
            "route": ["type": "string", "enum": ["agent_handoff", "guided_start", "clarify", "capture_only", "answer"]],
            "title": string, "objective": string,
            "known_facts": strings, "assumptions": strings, "missing_information": strings,
            "constraints": strings, "acceptance_criteria": strings,
            "execution_preference": ["type": "string", "enum": ["quick_delivery", "learn_while_doing"]],
            "target_executor": string, "deliverables": strings,
            "guide_prerequisites": strings, "guide_steps": strings,
            "first_action": string, "verification": string, "clarify_question": string, "reason": string,
            "answer": string
        ]
        return ["type": "object", "properties": properties,
                "required": Array(properties.keys).sorted(), "additionalProperties": false]
    }()
}
