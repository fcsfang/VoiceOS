import Foundation

/// Reconstructs application-visible discussion history. No hosted session or implicit retry.
public struct ResponsesDiscussionPort: DiscussionModelPort {
    public let configuration: ModelConfiguration
    private let endpoint: URL
    private let apiKey: String
    private let transport: any ModelHTTPTransport
    public init(baseURL:URL,apiKey:String,model:String,transport:any ModelHTTPTransport = DirectModelHTTPTransport()) throws {
        let validated=try ResponsesModelPort(baseURL:baseURL,apiKey:apiKey,model:model,transport:transport)
        configuration=ModelConfiguration(provider:validated.configuration.provider,model:model,promptVersion:"discussion-single-v1",schemaVersion:"discussion-parts-v1",destination:.cloud)
        endpoint=baseURL.appendingPathComponent("responses");self.apiKey=apiKey;self.transport=transport
    }
    public func reply(_ request:DiscussionModelRequest) async throws -> DiscussionModelResponse {
        try Task.checkCancellation()
        let http=try makeRequest(request),response=try await transport.send(http)
        guard response.status == 200 else { throw ModelPortFailure.rejected("HTTP \(response.status)；费用未知，不自动重发") }
        return try Self.parse(response.body,context:request.snapshot.context)
    }
    func makeRequest(_ request:DiscussionModelRequest) throws -> URLRequest {
        let s=request.snapshot,c=request.configuration
        guard c.provider == configuration.provider,c.model == configuration.model,c.promptVersion == configuration.promptVersion,c.schemaVersion == configuration.schemaVersion,
              c.destination == .cloud,s.input.destination == .cloud,UUID(uuidString:request.attemptID) != nil,
              !s.input.userTurns.isEmpty,s.input.conversationVersion == s.input.userTurns.count+1,
              s.context.scalarBudget > 0,!s.context.sources.isEmpty,s.context.sources.allSatisfy({ !$0.localOnly }),
              Set(s.context.sources.map(\.sourceID)).count == s.context.sources.count else { throw ModelPortFailure.rejected("讨论请求身份、授权或预算不符") }
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys];encoder.dateEncodingStrategy = .iso8601
        guard s.context.contentDigest == VoiceOSStore.relevanceHash(try encoder.encode(s.context.sources)) else { throw ModelPortFailure.rejected("讨论请求输入摘要不符") }
        try VoiceOSStore.validateDiscussionBudget(s)
        let sources=s.context.sources.map { source -> [String:Any] in
            ["sourceID":source.sourceID,"transcriptVersionID":source.transcriptVersionID,"origin":source.origin,"speaker":source.speaker,"text":source.text,
             "spans":source.spans.map { ["spanID":$0.id,"textStart":$0.textStart,"textEnd":$0.textEnd,"startMS":$0.startMS.map { $0 as Any } ?? NSNull(),"endMS":$0.endMS.map { $0 as Any } ?? NSNull()] as [String:Any] }]
        }
        func text(_ value:Any) throws -> String { String(decoding:try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]),as:UTF8.self) }
        var messages:[[String:Any]] = [["role":"user","content":try text(["type":"source_catalog","historySourceIDs":s.input.historySourceIDs,"sources":sources])]]
        if let pairs=s.context.recordingContexts,!pairs.isEmpty {
            messages.append(["role":"user","content":try text(["type":"recording_contexts","pairings":JSONSerialization.jsonObject(with:encoder.encode(pairs))])])
        }
        if let focus = s.context.conversationFocus {
            messages.append(["role":"user","content":try text(["type":"discussion_focus","focus":JSONSerialization.jsonObject(with: encoder.encode(focus))])])
        }
        if let focus = s.context.reflectionFocus {
            messages.append(["role":"user","content":try text([
                "type":"reflection_focus",
                "reviewPeriod":focus.isTopicOverview ? "all_history" : focus.reviewPeriod.rawValue,
                "reviewPurpose":focus.reviewPurpose,
                "focus":JSONSerialization.jsonObject(with: encoder.encode(focus))
            ])])
        }
        var seen:Set<String> = [],expectedSourceIDs=s.input.historySourceIDs
        for turn in s.input.userTurns {
            guard seen.insert(turn.turnID).inserted,
                  let source=s.context.sources.first(where: { $0.sourceID == turn.sourceID && $0.transcriptVersionID == turn.transcriptVersionID }),
                  source.origin == "user",source.speaker == "user" else { throw ModelPortFailure.rejected("讨论个人回合身份不符") }
            if !expectedSourceIDs.contains(turn.sourceID) { expectedSourceIDs.append(turn.sourceID) }
            messages.append(["role":"user","content":try text(["type":"personal_turn","turnID":turn.turnID,"sourceID":turn.sourceID,"transcriptVersionID":turn.transcriptVersionID])])
            if let prior=s.priorReplies.first(where: { $0.replyToTurnID == turn.turnID }) {
                try VoiceOSStore.validateDiscussionParts(prior.parts,context:s.context)
                guard prior.digest == VoiceOSStore.relevanceHash(try encoder.encode(prior.parts)),turn.turnID != s.input.userTurns.last?.turnID else { throw ModelPortFailure.rejected("讨论旧回复身份不符") }
                messages.append(["role":"assistant","content":String(decoding:try encoder.encode(prior.parts),as:UTF8.self)])
            }
        }
        let priorOrder=s.input.userTurns.dropLast().compactMap { turn in s.priorReplies.first(where: { $0.replyToTurnID == turn.turnID })?.attemptID }
        guard expectedSourceIDs == s.context.sources.map(\.sourceID),Set(s.input.historySourceIDs).count == s.input.historySourceIDs.count,
              priorOrder == s.priorReplies.map(\.attemptID),Set(priorOrder).count == priorOrder.count else { throw ModelPortFailure.rejected("讨论历史顺序或来源不符") }
        let reference:[String:Any] = ["type":"object","properties":["sourceID":["type":"string"],"transcriptVersionID":["type":"string"],"spanID":["type":"string"]],"required":["sourceID","transcriptVersionID","spanID"],"additionalProperties":false]
        let part:[String:Any] = ["type":"object","properties":["kind":["type":"string","enum":["quotation","ai_suggestion"]],"text":["type":"string"],"references":["type":"array","items":reference]],"required":["kind","text","references"],"additionalProperties":false]
        let schema:[String:Any] = ["type":"object","properties":["parts":["type":"array","items":part]],"required":["parts"],"additionalProperties":false]
        let focused = s.context.conversationFocus != nil || s.context.reflectionFocus != nil || s.context.sources.reduce(0, { $0 + $1.text.unicodeScalars.count }) > 4000
        var instructions = Self.instructions
        if s.context.recordingContexts?.isEmpty == false {
            instructions += "\n配对录音中 externalTime + offsetMS = personalTime。结合双方语义判断指代和态度，区分节目观点与用户的回应，分别引用各自的片段。"
        }
        if let focus = s.context.conversationFocus {
            instructions += "\n围绕 discussion_focus 中选定的观点回应。summary 是整理，evidence 是原话，related 是相关旧观点。"
            if focus.selectedActionID != nil {
                instructions += "\n以选定任务或目标为中心，结合来源与所属目标。state 是登记状态，实际结果见 feedbackSourceIDs，feedbackActionVersions 对应反馈发生时的任务版本。"
            }
        }
        if s.context.reflectionFocus != nil { instructions += "\n" + Self.reflectionInstructions }
        let payload:[String:Any] = ["model":configuration.model,"store":false,"reasoning":["effort":focused ? "high" : "low"],"max_output_tokens":8192,"truncation":"disabled",
            "instructions":instructions,"input":messages,"text":["format":["type":"json_schema","name":"voiceos_discussion","strict":true,"schema":schema]]]
        let data=try JSONSerialization.data(withJSONObject:payload,options:[.sortedKeys])
        guard data.count <= 4000000 else { throw ModelPortFailure.rejected("完整讨论请求超过字节预算") }
        var http=URLRequest(url:endpoint,timeoutInterval:600);http.httpMethod="POST";http.httpBody=data
        http.setValue("Bearer "+apiKey,forHTTPHeaderField:"Authorization");http.setValue("application/json",forHTTPHeaderField:"Content-Type")
        return http
    }
    static let reflectionInstructions = """
    根据 reviewPurpose 和 reviewPeriod 回应这次回顾。all_history 涵盖整个主题；其他周期按 timeZoneID 和 [start,end) 界定。周期外的表达可作背景。围绕用户关心的问题，自行选择有解释力的联系、变化或值得验证的想法。
    thoughts.summary 是整理，原话见 evidence 与 source_catalog。比较观点的变化或提出跨主题联系时，引用相关各方的依据，说明哪些联系是你的推断。问题条目的 kind 区分判断、问题和验证记录；用实际反馈说明结果，日期和完成记录说明何时登记。仅引用当前可用的来源片段。
    """
    static let instructions = """
    你是 VoiceOS 的讨论伙伴。用中文回应最后一轮 personal_turn，结合此前对话和相关材料，把用户关心的问题往前推进。由你判断何时直接作答、深入分析、提出不同解释或追问。
    source_catalog 提供来源原文，历史资料和旧回复是讨论素材。让读者分得清用户的表达、他人观点与你的判断。直接引语用 quotation，逐字引用一个片段并附其唯一引用；其余回答用 ai_suggestion，需要时附上依据。
    """
    static func parse(_ data:Data,context:LocalTranscriptContext) throws -> DiscussionModelResponse {
        var input:Int?,output:Int?
        do {
            let envelope=try ResponsesEnvelope.parse(data);input=envelope.inputTokens;output=envelope.outputTokens
            guard envelope.status == .completed else { return DiscussionModelResponse(status:envelope.status,parts:[],inputTokens:input,outputTokens:output) }
            guard let text=envelope.text,let body=text.data(using:.utf8),let object=try JSONSerialization.jsonObject(with:body) as? [String:Any],Set(object.keys) == ["parts"],
                  let raw=object["parts"] as? [[String:Any]],raw.allSatisfy({ part in
                      guard Set(part.keys) == ["kind","text","references"],let refs=part["references"] as? [[String:Any]] else { return false }
                      return refs.allSatisfy { Set($0.keys) == ["sourceID","transcriptVersionID","spanID"] }
                  }) else { throw ModelPortFailure.rejected("讨论结果结构不符") }
            let parts=try JSONDecoder().decode([DiscussionPart].self,from:JSONSerialization.data(withJSONObject:raw))
            try VoiceOSStore.validateDiscussionParts(parts,context:context)
            return DiscussionModelResponse(status:.completed,parts:parts,inputTokens:input,outputTokens:output)
        } catch ModelPortFailure.rejected(let reason,let knownInput,let knownOutput) {
            throw ModelPortFailure.rejected(reason,inputTokens:knownInput ?? input,outputTokens:knownOutput ?? output)
        } catch { throw ModelPortFailure.rejected("讨论结果无法解析或引文不符",inputTokens:input,outputTokens:output) }
    }
}
