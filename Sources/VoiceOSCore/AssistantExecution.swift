import Foundation

public enum AssistantTaskKind: String, Codable, Sendable { case research, draft, comparison }
public struct AssistantReference: Codable, Hashable, Sendable {
    public let url: String
    public let title: String
    public init(url: String, title: String) { self.url = url; self.title = title }
}
public struct AssistantAssessment: Codable, Sendable {
    public let explicitDelegation: Bool
    public let supported: Bool
    public let kind: AssistantTaskKind
    public let reason: String
    public init(explicitDelegation: Bool, supported: Bool, kind: AssistantTaskKind, reason: String) {
        self.explicitDelegation = explicitDelegation; self.supported = supported; self.kind = kind; self.reason = reason
    }
}
public struct AssistantTaskInput: Codable, Sendable {
    public let actionID: String
    public let actionVersion: Int
    public let claimID: String
    public let claimReviewVersion: Int
    public let title: String
    public let note: String
    public let instruction: String
    public let context: LocalTranscriptContext
    public let policyVersions: [String: Int]
    public let references: [ClaimReference]
}
public struct AssistantExecutionRequest: Sendable {
    public let executionID: String
    public let input: AssistantTaskInput
    public let assessment: AssistantAssessment
    public init(executionID: String, input: AssistantTaskInput, assessment: AssistantAssessment) {
        self.executionID = executionID; self.input = input; self.assessment = assessment
    }
}
public struct AssistantExecutionResult: Codable, Sendable {
    public let title: String
    public let markdown: String
    public let references: [AssistantReference]
    public let responseID: String
    public let usedWebSearch: Bool
    public init(title: String, markdown: String, references: [AssistantReference] = [], responseID: String, usedWebSearch: Bool = false) {
        self.title = title; self.markdown = markdown; self.references = references; self.responseID = responseID; self.usedWebSearch = usedWebSearch
    }
}
public protocol AssistantModelPort: Sendable {
    var configuration: ModelConfiguration { get }
    func assess(_ input: AssistantTaskInput) async throws -> AssistantAssessment
    func execute(_ request: AssistantExecutionRequest) async throws -> AssistantExecutionResult
}
public struct AssistantAssessmentIssue: Identifiable, Sendable {
    public let id: String
    public let actionID: String
    public let actionVersion: Int
    public let title: String
    public let error: String
    public let createdAt: String
}
public struct AssistantExecutionRecord: Identifiable, Codable, Sendable {
    public let id: String
    public let actionID: String
    public let actionVersion: Int
    public let state: String
    public let validity: String
    public let title: String
    public let instruction: String
    public let instructionSourceID: String?
    public let sourceIDs: [String]
    public let report: String?
    public let references: [AssistantReference]
    public let responseID: String?
    public let error: String?
    public let resultSourceID: String?
    public let questionID: String?
    public let createdAt: String
    public let updatedAt: String
}

extension VoiceOSStore {
    private func assistantInput(actionID: String, expectedVersion: Int, instruction: String, instructionSourceID: String? = nil, allowsCompleted: Bool = false, destination: ModelDestination = .local) throws -> AssistantTaskInput {
        guard ready, let action = try actions(includeHistory: true).first(where: { $0.id == actionID }),
              action.version == expectedVersion, action.validity == "current", (action.state == "open" || allowsCompleted && action.state == "completed"), action.kind == "task", action.intentActor == "user",
              let claim = try candidateClaim(id: action.claimID), claim.reviewVersion == action.claimReviewVersion,
              claim.ownership == "user_tentative", !claim.references.isEmpty else { throw VoiceOSError("仅当前有效的个人待办可交给 AI；请核对原话与归属") }
        var ids: [String] = []
        for ref in claim.references where !ids.contains(ref.sourceID) { ids.append(ref.sourceID) }
        if let instructionSourceID, !ids.contains(instructionSourceID) { ids.append(instructionSourceID) }
        try requireReviewedTranscriptions(sourceIDs:ids,destination:destination)
        let catalog = Dictionary(uniqueKeysWithValues: try sources().map { ($0.id, $0) })
        guard ids.allSatisfy({ id in catalog[id]?.presentation?.automaticInput == nil || (catalog[id]?.recordingExpression?.state == "completed" && catalog[id]?.recordingExpression?.taskReviewPending != true) }) else { throw VoiceOSError("连续表达仍在整体核对，AI 待办将在完成后继续") }
        let budget = max(1, ids.reduce(0) { $0 + (catalog[$1]?.transcript?.unicodeScalars.count ?? 0) })
        let context = try prepareLocalTranscriptContext(sourceIDs: ids, scalarBudget: budget)
        guard claim.references.allSatisfy({ ref in context.sources.contains(where: { $0.sourceID == ref.sourceID && $0.transcriptVersionID == ref.transcriptVersionID && $0.origin == "user" && $0.speaker == "user" && $0.spans.contains(where: { $0.id == ref.spanID }) }) }),
              instructionSourceID == nil || context.sources.first(where: { $0.sourceID == instructionSourceID })?.text == instruction else { throw VoiceOSError("委托原话版本或归属已变化") }
        var policies: [String: Int] = [:]
        for id in ids { policies[id] = try sourcePolicy(sourceID: id).version }
        return .init(actionID: actionID, actionVersion: action.version, claimID: claim.id, claimReviewVersion: claim.reviewVersion, title: action.title, note: action.note, instruction: instruction, context: context, policyVersions: policies, references: claim.references)
    }
    private func validateAssistantInput(_ input: AssistantTaskInput, destination: ModelDestination, allowsCompletionHistory: Bool = false) throws {
        var version = input.actionVersion
        if allowsCompletionHistory, let action = try db.query("SELECT version FROM actions WHERE id=?", [input.actionID]).first,
           let latest = action["version"].flatMap(Int.init), latest > version {
            let changes = try db.query("SELECT * FROM action_revisions WHERE action_id=? AND version>? ORDER BY version", [input.actionID,String(version)])
            guard changes.count == latest-version,changes.allSatisfy({ ["open","completed"].contains($0["state"] ?? "") }) else { throw VoiceOSError("委托事项已撤回或修改") }
            version = latest
        }
        let instructionID = input.context.sources.first(where: { !input.references.map(\.sourceID).contains($0.sourceID) })?.sourceID
        let live = try assistantInput(actionID: input.actionID, expectedVersion: version, instruction: input.instruction, instructionSourceID: instructionID, allowsCompleted: allowsCompletionHistory,destination:destination)
        let current = AssistantTaskInput(actionID: live.actionID,actionVersion: input.actionVersion,claimID: live.claimID,claimReviewVersion: live.claimReviewVersion,title: live.title,note: live.note,instruction: live.instruction,context: live.context,policyVersions: live.policyVersions,references: live.references)
        guard try Self.relevanceJSON(current) == Self.relevanceJSON(input) else { throw VoiceOSError("委托、原话或授权已变化，请重新交给 AI") }
        if destination == .cloud, input.context.sources.contains(where: \.localOnly) { throw VoiceOSError("委托依据含仅本地资料，请先允许这些原话用于云端") }
    }
    public func assistantExecutions(actionID: String? = nil) throws -> [AssistantExecutionRecord] {
        for row in try db.query("SELECT * FROM assistant_executions WHERE validity='current'") {
            let input = try JSONDecoder().decode(AssistantTaskInput.self, from: Data(row["input_json"]!.utf8))
            if (try? validateAssistantInput(input, destination: .local, allowsCompletionHistory: row["state"] == "completed")) == nil {
                activeAssistantRequests[row["id"]!]?()
                try db.execute("UPDATE assistant_executions SET validity='frozen',state=CASE WHEN state IN ('queued','running') THEN 'cancelled' ELSE state END,error='委托或依据已变化；保留历史结果',updated_at=? WHERE id=?", [Self.now(),row["id"]])
                if let sourceID = row["result_source_id"] { try db.execute("UPDATE sources SET state='quarantined',error='助理交付依据已变化，保留历史内容' WHERE id=?",[sourceID]); try invalidateCognition(sourceID: sourceID) }
            }
            if row["state"] == "completed", let sourceID = row["result_source_id"] { _ = try? validateAssistantResultBasis(sourceID: sourceID) }
        }
        let rows = try db.query("SELECT * FROM assistant_executions \(actionID == nil ? "" : "WHERE action_id=?") ORDER BY sequence DESC,id", actionID.map { [$0] } ?? [])
        return try rows.map { row in
            let input = try JSONDecoder().decode(AssistantTaskInput.self, from: Data(row["input_json"]!.utf8))
            let result = try row["result_json"].map { try JSONDecoder().decode(AssistantExecutionResult.self, from: Data($0.utf8)) }
            return .init(id: row["id"]!,actionID: input.actionID,actionVersion: input.actionVersion,state: row["state"]!,validity: row["validity"]!,title: result?.title ?? input.title,instruction: input.instruction,instructionSourceID: row["instruction_source_id"],sourceIDs: input.context.sources.map(\.sourceID),report: result?.markdown,references: result?.references ?? [],responseID: result?.responseID,error: row["error"],resultSourceID: row["result_source_id"],questionID: row["question_id"],createdAt: row["created_at"]!,updatedAt: row["updated_at"]!)
        }
    }
    @discardableResult
    public func enqueueAssistantExecution(actionID: String, expectedVersion: Int, instruction: String = "", questionID: String? = nil, allowInstructionCloud: Bool = false) throws -> AssistantExecutionRecord {
        _ = try assistantExecutions()
        let instruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = try assistantExecutions(actionID: actionID).first(where: { $0.actionVersion == expectedVersion && $0.validity == "current" && $0.instruction == instruction && ["queued","running","completed"].contains($0.state) }) { return existing }
        _ = try assistantInput(actionID: actionID, expectedVersion: expectedVersion, instruction: "")
        if let questionID { guard try reflectionQuestions().contains(where: { $0.id == questionID }) else { throw VoiceOSError("主题不存在") } }
        let instructionID = instruction.isEmpty ? nil : try recordUserExpression(instruction)
        if allowInstructionCloud, let instructionID { let policy = try sourcePolicy(sourceID: instructionID); _ = try setSourceLocalOnly(sourceID: instructionID, expectedVersion: policy.version, localOnly: false) }
        let input = try assistantInput(actionID: actionID, expectedVersion: expectedVersion, instruction: instruction, instructionSourceID: instructionID)
        let id = UUID().uuidString, now = Self.now()
        let sequence = try db.query("SELECT COALESCE(MAX(sequence),0)+1 AS next FROM assistant_executions").first?["next"]
        try db.execute("INSERT INTO assistant_executions(id,action_id,action_version,input_json,sequence,instruction_source_id,question_id,state,validity,created_at,updated_at) VALUES(?,?,?,?,?,?,?,'queued','current',?,?)", [id,actionID,String(expectedVersion),try Self.relevanceJSON(input),sequence,instructionID,questionID,now,now])
        return try assistantExecutions(actionID: actionID).first(where: { $0.id == id })!
    }
    public func discoverAutomaticAssistantExecutions(using port: any AssistantModelPort) async throws {
        guard !assistantDiscoveryActive else { return }; assistantDiscoveryActive = true
        defer { assistantDiscoveryActive = false }
        _ = try assistantExecutions()
        for action in try actions() where action.kind == "task" && action.intentActor == "user" {
            try Task.checkCancellation()
            let prior = try db.query("SELECT * FROM assistant_assessments WHERE action_id=? AND action_version=?", [action.id,String(action.version)]).first
            if let prior {
                // A crash between the completed assessment and queue insertion
                // must not lose a real delegation, and must never resend it.
                if prior["state"] == "completed", let json = prior["assessment_json"],
                   let assessment = try? JSONDecoder().decode(AssistantAssessment.self, from: Data(json.utf8)), assessment.explicitDelegation,
                   let cached = try? JSONDecoder().decode(AssistantTaskInput.self, from: Data((prior["input_json"] ?? "").utf8)),
                   (try? validateAssistantInput(cached, destination: port.configuration.destination)) != nil,
                   try assistantExecutions(actionID: action.id).isEmpty {
                    let record = try enqueueAssistantExecution(actionID: action.id, expectedVersion: action.version)
                    try db.execute("UPDATE assistant_executions SET assessment_json=? WHERE id=?", [json,record.id])
                }
                continue
            }
            guard try assistantExecutions(actionID: action.id).isEmpty,
                  let input = try? assistantInput(actionID: action.id, expectedVersion: action.version, instruction: ""),
                  (try? validateAssistantInput(input, destination: port.configuration.destination)) != nil else { continue }
            let id = UUID().uuidString
            try db.execute("INSERT INTO assistant_assessments(id,action_id,action_version,input_json,state,created_at) VALUES(?,?,?,?,'running',?)", [id,action.id,String(action.version),try Self.relevanceJSON(input),Self.now()])
            do {
                let result = try await runAssistantAssessment(input, key: "assessment:"+id, using: port)
                try validateAssistantInput(input, destination: port.configuration.destination)
                try db.execute("UPDATE assistant_assessments SET state='completed',assessment_json=? WHERE id=?", [try Self.relevanceJSON(result),id])
                if result.explicitDelegation {
                    let record = try enqueueAssistantExecution(actionID: action.id, expectedVersion: action.version)
                    try db.execute("UPDATE assistant_executions SET assessment_json=? WHERE id=?", [try Self.relevanceJSON(result),record.id])
                }
            } catch {
                try db.execute("UPDATE assistant_assessments SET state='failed',error=? WHERE id=?", [Self.assistantError(error),id])
                try Task.checkCancellation()
            }
        }
    }
    public func assistantAssessmentIssues() throws -> [AssistantAssessmentIssue] {
        let current = Dictionary(uniqueKeysWithValues: try actions().map { ($0.id,$0) })
        return try db.query("SELECT * FROM assistant_assessments WHERE state='failed' ORDER BY created_at,id").compactMap { row in
            guard let action = current[row["action_id"]!],action.version == row["action_version"].flatMap(Int.init),
                  try assistantExecutions(actionID: action.id).isEmpty else { return nil }
            return .init(id:row["id"]!,actionID:action.id,actionVersion:action.version,title:action.title,error:row["error"] ?? "委托识别未完成",createdAt:row["created_at"]!)
        }
    }
    public func retryAssistantAssessment(actionID: String, expectedVersion: Int, using port: any AssistantModelPort) async throws {
        guard !assistantDiscoveryActive else { throw VoiceOSError("正在识别其他委托，请稍后重试") }
        guard let row = try db.query("SELECT * FROM assistant_assessments WHERE action_id=? AND action_version=? AND state='failed'", [actionID,String(expectedVersion)]).first else { throw VoiceOSError("没有可重试的委托识别") }
        let input = try assistantInput(actionID: actionID, expectedVersion: expectedVersion, instruction: "")
        try validateAssistantInput(input, destination: port.configuration.destination)
        assistantDiscoveryActive = true; defer { assistantDiscoveryActive = false }
        let id = row["id"]!
        try db.execute("UPDATE assistant_assessments SET state='running',input_json=?,error=NULL WHERE id=?", [try Self.relevanceJSON(input),id])
        do {
            let assessment = try await runAssistantAssessment(input, key: "assessment:"+id, using: port)
            try validateAssistantInput(input, destination: port.configuration.destination)
            try db.execute("UPDATE assistant_assessments SET state='completed',assessment_json=? WHERE id=?", [try Self.relevanceJSON(assessment),id])
            if assessment.explicitDelegation {
                let record = try enqueueAssistantExecution(actionID: actionID, expectedVersion: expectedVersion)
                try db.execute("UPDATE assistant_executions SET assessment_json=? WHERE id=?", [try Self.relevanceJSON(assessment),record.id])
            }
        } catch {
            try db.execute("UPDATE assistant_assessments SET state='failed',error=? WHERE id=?", [Self.assistantError(error),id]); throw error
        }
    }
    private static func assistantError(_ error: Error) -> String {
        if case ModelPortFailure.rejected(let reason, _, _) = error { return reason }
        if error is CancellationError { return "请求已中断，结果未接纳" }
        return error.localizedDescription
    }
    private func runAssistantAssessment(_ input: AssistantTaskInput, key: String, using port: any AssistantModelPort) async throws -> AssistantAssessment {
        let request = Task { let result = try await port.assess(input); try Task.checkCancellation(); return result }
        activeAssistantRequests[key] = { request.cancel() }
        defer { activeAssistantRequests[key] = nil }
        return try await withTaskCancellationHandler(operation: { try await request.value }, onCancel: { request.cancel() })
    }
    private func runAssistantDelivery(_ input: AssistantExecutionRequest, using port: any AssistantModelPort) async throws -> AssistantExecutionResult {
        let request = Task { let result = try await port.execute(input); try Task.checkCancellation(); return result }
        activeAssistantRequests[input.executionID] = { request.cancel() }
        defer { activeAssistantRequests[input.executionID] = nil }
        return try await withTaskCancellationHandler(operation: { try await request.value }, onCancel: { request.cancel() })
    }
    public func processNextAssistantExecution(using port: any AssistantModelPort, onProgress: (@Sendable () async -> Void)? = nil) async throws -> Bool {
        guard !assistantExecutionActive else { return false }
        _ = try assistantExecutions()
        guard let row = try db.query("SELECT * FROM assistant_executions WHERE state='queued' AND validity='current' ORDER BY sequence,id LIMIT 1").first else { return false }
        assistantExecutionActive = true; defer { assistantExecutionActive = false }
        let id = row["id"]!, input = try JSONDecoder().decode(AssistantTaskInput.self, from: Data(row["input_json"]!.utf8))
        try db.execute("UPDATE assistant_executions SET state='running',updated_at=?,error=NULL WHERE id=?", [Self.now(),id])
        await onProgress?()
        do {
            try validateAssistantInput(input, destination: port.configuration.destination)
            let assessment: AssistantAssessment
            if let json = row["assessment_json"] { assessment = try JSONDecoder().decode(AssistantAssessment.self, from: Data(json.utf8)) }
            else {
                assessment = try await runAssistantAssessment(input, key: id, using: port)
                try validateAssistantInput(input, destination: port.configuration.destination)
                try requireAssistantRunning(id)
                try db.execute("UPDATE assistant_executions SET assessment_json=? WHERE id=?", [try Self.relevanceJSON(assessment),id])
            }
            guard assessment.supported else { throw VoiceOSError(assessment.reason.isEmpty ? "此任务暂不支持 AI 代办" : assessment.reason) }
            try validateAssistantInput(input, destination: port.configuration.destination)
            try requireAssistantRunning(id)
            let result = try await runAssistantDelivery(.init(executionID: id, input: input, assessment: assessment), using: port)
            try Task.checkCancellation()
            try validateAssistantInput(input, destination: port.configuration.destination)
            try requireAssistantRunning(id)
            try Self.validateAssistantResult(result, kind: assessment.kind)
            try db.transaction {
                let sourceID = try saveAssistantResultSource(result, executionID: id, allowsCloud: port.configuration.destination == .cloud)
                try db.execute("UPDATE assistant_executions SET state='completed',result_json=?,result_source_id=?,updated_at=? WHERE id=?", [try Self.relevanceJSON(result),sourceID,Self.now(),id])

            }
            if let questionID = row["question_id"], let sourceID = try db.query("SELECT result_source_id FROM assistant_executions WHERE id=?", [id]).first?["result_source_id"] { try linkReflectionQuestionSource(questionID: questionID, sourceID: sourceID) }
        } catch {
            try db.execute("UPDATE assistant_executions SET state='failed',error=?,updated_at=? WHERE id=? AND state='running'", [Self.assistantError(error),Self.now(),id])
        }
        await onProgress?()
        return true
    }
    private func requireAssistantRunning(_ id: String) throws {
        guard try db.query("SELECT id FROM assistant_executions WHERE id=? AND state='running' AND validity='current'", [id]).first != nil else { throw VoiceOSError("委托已取消或失效") }
    }
    public func cancelAssistantExecution(id: String) throws {
        activeAssistantRequests[id]?()
        try db.execute("UPDATE assistant_executions SET state='cancelled',updated_at=?,error='用户取消；已派发请求不会接纳后续结果' WHERE id=? AND state IN ('queued','running')", [Self.now(),id])
    }
    public func retryAssistantExecution(id: String) throws {
        _ = try assistantExecutions()
        guard let row = try db.query("SELECT * FROM assistant_executions WHERE id=? AND state IN ('failed','cancelled') AND validity='current'", [id]).first else { throw VoiceOSError("请重新交给 AI，旧委托已失效或不能重试") }
        let input = try JSONDecoder().decode(AssistantTaskInput.self, from: Data(row["input_json"]!.utf8))
        try validateAssistantInput(input, destination: .local)
        try db.execute("UPDATE assistant_executions SET state='queued',assessment_json=CASE WHEN state='failed' AND result_json IS NULL THEN NULL ELSE assessment_json END,error=NULL,updated_at=? WHERE id=?", [Self.now(),id])
    }
    public func attachAssistantExecution(id: String, questionID: String) throws {
        guard let result = try assistantExecutions().first(where: { $0.id == id }), result.state == "completed",result.validity == "current",let sourceID = result.resultSourceID else { throw VoiceOSError("只有当前有效的 AI 交付可以接回主题") }
        try linkReflectionQuestionSource(questionID: questionID, sourceID: sourceID)
        try db.execute("UPDATE assistant_executions SET question_id=?,updated_at=? WHERE id=?", [questionID,Self.now(),id])
    }
    static func validateAssistantResult(_ result: AssistantExecutionResult, kind: AssistantTaskKind) throws {
        guard !result.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,!result.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,!result.responseID.isEmpty,
              result.references.allSatisfy({ ref in guard let url = URL(string: ref.url) else { return false }; return ["http","https"].contains(url.scheme ?? "") && url.host != nil }),
              kind != .research || (result.usedWebSearch && !result.references.isEmpty) else { throw VoiceOSError("调研未取得真实检索引用，或交付不完整；不会用模型记忆冒充调研") }
    }
    private func saveAssistantResultSource(_ result: AssistantExecutionResult, executionID: String, allowsCloud: Bool) throws -> String {
        // AI output is a reference material, never a personal expression or an actual task outcome.
        let id = UUID().uuidString,asset = UUID().uuidString,version = UUID().uuidString,job = UUID().uuidString,transcript = UUID().uuidString,textVersion = UUID().uuidString
        let data = Data(result.markdown.utf8),hash = Self.relevanceHash(data),relative = "assets/\(asset).txt",now = Self.now()
        let file = try assetURL(relativePath: relative)
        try data.write(to: file, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
        try handle.synchronize(); try DurableFiles.syncDirectory(file.deletingLastPathComponent())
        try db.execute("INSERT INTO sources(id,command_id,input_fingerprint,asset_id,version_id,name,kind,speaker,origin,state,created_at,timezone,expected_bytes,expected_hash,relative_path,duration,local_only) VALUES(?,?,?,?,?,?,'ai_text','assistant','ai','saved',?,?,?,?,?,0,?)", [id,"assistant-result:"+executionID,"assistant-text-v1:"+hash,asset,version,result.title,now,TimeZone.current.identifier,String(data.count),hash,relative,allowsCloud ? "0" : "1"])
        try db.execute("INSERT INTO assets(id,source_id,relative_path,bytes,sha256,role) VALUES(?,?,?,?,?,'original')", [asset,id,relative,String(data.count),hash])
        try db.execute("INSERT INTO jobs(id,source_id,input_version_id,stage,config,state) VALUES(?,?,?,'transcription','assistant-text-v1','completed')", [job,id,version])
        try db.execute("INSERT INTO transcripts(id,source_id,input_asset_id,input_version_id,job_id,kind,text,locale,backend,created_at,current_version_id) VALUES(?,?,?,?,?,'verbatim',?,'zh_CN','assistant-response',?,?)", [transcript,id,asset,version,job,result.markdown,now,textVersion])
        try db.execute("INSERT INTO transcript_versions(id,transcript_id,version_no,text,spans_json,reason,actor,created_at) VALUES(?,?,1,?,?,'original','system',?)", [textVersion,transcript,result.markdown,try Self.relevanceJSON(SpeechText(text: result.markdown).spans),now])
        return id
    }
    func validateAssistantResultBasis(sourceID: String) throws {
        guard let row = try db.query("SELECT * FROM assistant_executions WHERE result_source_id=?", [sourceID]).first else { throw VoiceOSError("AI 资料没有可核对的助理委托") }
        do {
            guard row["state"] == "completed",row["validity"] == "current" else { throw VoiceOSError("助理交付已暂停使用") }
            let input = try JSONDecoder().decode(AssistantTaskInput.self, from: Data(row["input_json"]!.utf8))
            guard let action = try db.query("SELECT * FROM actions WHERE id=?", [input.actionID]).first,
                  (action["version"].flatMap(Int.init) ?? 0) >= input.actionVersion,action["validity"] == "current",["open","completed"].contains(action["state"] ?? ""),action["claim_id"] == input.claimID,
                  let claim = try db.query("SELECT * FROM claims WHERE id=?", [input.claimID]).first,
                  claim["validity"] == "current",claim["review_version"] == String(input.claimReviewVersion) else { throw VoiceOSError("助理委托或认知依据已变化") }
            let latest = Int(action["version"]!)!
            let revisions = try db.query("SELECT state FROM action_revisions WHERE action_id=? AND version>? ORDER BY version", [input.actionID,String(input.actionVersion)])
            guard revisions.count == latest-input.actionVersion,revisions.allSatisfy({ ["open","completed"].contains($0["state"] ?? "") }),action["title"] == input.title,action["note"] == input.note else { throw VoiceOSError("委托事项已修改或撤回") }
            try validateLocalTranscriptContext(input.context)
            for (id, expected) in input.policyVersions { guard try sourcePolicy(sourceID: id).version == expected else { throw VoiceOSError("助理输入授权已变化") } }
            let result = try JSONDecoder().decode(AssistantExecutionResult.self, from: Data(row["result_json"]!.utf8))
            guard let source = try db.query("SELECT s.origin,s.speaker,s.state,s.local_only,v.text FROM sources s JOIN transcripts t ON t.source_id=s.id JOIN transcript_versions v ON v.id=t.current_version_id WHERE s.id=?", [sourceID]).first,
                  source["origin"] == "ai",source["speaker"] == "assistant",["saved","reference_only"].contains(source["state"] ?? ""),source["text"] == result.markdown else { throw VoiceOSError("助理交付原文或归属已变化") }
            if source["local_only"] == "0" { try requireReviewedTranscriptions(sourceIDs:input.context.sources.map(\.sourceID),destination:.cloud) }
        } catch {
            try db.execute("UPDATE assistant_executions SET validity='frozen',error='助理交付依据已变化，保留历史内容',updated_at=? WHERE id=?", [Self.now(),row["id"]])
            try db.execute("UPDATE sources SET state='quarantined',error='助理交付依据已变化，保留历史内容' WHERE id=?", [sourceID])
            try invalidateCognition(sourceID: sourceID)
            throw error
        }
    }

    static func inspectAssistantText(_ file: URL) throws -> MediaInfo {
        let data = try Data(contentsOf: file)
        guard let text = String(data: data, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VoiceOSError("AI 交付原文不是有效 UTF-8 文本") }
        return MediaInfo(duration: 0, kind: "ai_text")
    }
    static func validateStoredAssistantExecutions(_ database: Database) throws {
        guard try database.query("SELECT sequence FROM assistant_executions GROUP BY sequence HAVING COUNT(*)>1").isEmpty else { throw VoiceOSError("助理委托顺序重复") }
        for row in try database.query("SELECT * FROM assistant_executions") {
            guard let sequence = row["sequence"].flatMap(Int64.init), sequence >= 1 else { throw VoiceOSError("助理委托缺少有效顺序") }
            guard let json = row["input_json"],let input = try? JSONDecoder().decode(AssistantTaskInput.self, from: Data(json.utf8)),input.actionID == row["action_id"],String(input.actionVersion) == row["action_version"],
                  try database.query("SELECT claim_id FROM actions WHERE id=?", [input.actionID]).first?["claim_id"] == input.claimID,
                  input.policyVersions.keys.sorted() == input.context.sources.map(\.sourceID).sorted() else { throw VoiceOSError("助理委托的输入身份不一致") }
            for source in input.context.sources {
                guard let stored = try database.query("SELECT s.version_id,s.origin,s.speaker,s.policy_version,v.text,v.spans_json,t.source_id FROM transcript_versions v JOIN transcripts t ON t.id=v.transcript_id JOIN sources s ON s.id=t.source_id WHERE v.id=?", [source.transcriptVersionID]).first,
                      stored["source_id"] == source.sourceID,stored["version_id"] == source.sourceVersionID,stored["origin"] == source.origin,stored["speaker"] == source.speaker,stored["text"] == source.text,
                      let policy = input.policyVersions[source.sourceID],policy >= 1,policy <= (stored["policy_version"].flatMap(Int.init) ?? 0),
                      try relevanceJSON(JSONDecoder().decode([TranscriptSpan].self, from: Data((stored["spans_json"] ?? "").utf8))) == relevanceJSON(source.spans) else { throw VoiceOSError("助理委托原话与真实版本不一致") }
            }
            guard input.context.contentDigest == relevanceHash(Data(try relevanceJSON(input.context.sources).utf8)),
                  !input.references.isEmpty,input.references.allSatisfy({ ref in input.context.sources.contains(where: { $0.sourceID == ref.sourceID && $0.transcriptVersionID == ref.transcriptVersionID && $0.origin == "user" && $0.speaker == "user" && $0.spans.contains(where: { $0.id == ref.spanID }) }) }) else { throw VoiceOSError("助理委托摘要或个人原话引用不一致") }
            if let json = row["result_json"] {
                let result = try JSONDecoder().decode(AssistantExecutionResult.self, from: Data(json.utf8))
                let assessment = try JSONDecoder().decode(AssistantAssessment.self, from: Data((row["assessment_json"] ?? "").utf8))
                try validateAssistantResult(result, kind: assessment.kind)
                guard let sourceID = row["result_source_id"],let source = try database.query("SELECT s.*,t.text FROM sources s JOIN transcripts t ON t.source_id=s.id WHERE s.id=?", [sourceID]).first,
                      source["kind"] == "ai_text",source["origin"] == "ai",source["speaker"] == "assistant",source["text"] == result.markdown,source["expected_hash"] == relevanceHash(Data(result.markdown.utf8)),source["expected_bytes"] == String(Data(result.markdown.utf8).count),source["input_fingerprint"] == "assistant-text-v1:"+relevanceHash(Data(result.markdown.utf8)) else { throw VoiceOSError("助理交付归属与原文不一致") }
            } else if row["state"] == "completed" || row["result_source_id"] != nil { throw VoiceOSError("已完成的助理委托缺少交付") }
        }
        for source in try database.query("SELECT id FROM sources WHERE kind='ai_text'") {
            guard try database.query("SELECT id FROM assistant_executions WHERE result_source_id=?", [source["id"]]).count == 1 else { throw VoiceOSError("AI 资料缺少助理交付来源") }
        }
    }
}
