import Foundation
import CryptoKit

private struct CompletedQwenTranscript: Codable, SpeechPort {
    let backend: String
    let text: String
    let spans: [TranscriptSpan]
    let processed_chunks: Int?
    let total_chunks: Int?
    let complete: Bool?
    let duration_seconds: Double?
    var transcription_review: TranscriptionReview? = nil
    var backendIdentity: String { backend }
    func transcribe(_ url: URL, locale: String) async throws -> SpeechText {
        guard backend.hasPrefix("Qwen3-ASR"), complete == true || (processed_chunks != nil && processed_chunks == total_chunks) else { throw VoiceOSError("完整 Qwen 转写尚未完成") }
        return SpeechText(text: text, spans: spans)
    }
}
private struct OrganizedSource: Codable {
    let voiceos_source_id: String?
    let voiceos_transcript_version_id: String?
    let source_name: String?
    var transcription_input_sha256: String? = nil
    var user_corrected_transcript: Bool? = nil
}
private struct OrganizedTasks: Decodable {
    let source_folders: [String]
    let all_audio_complete: Bool
    let all_windows_checked: Bool
    let api_review_completed: Bool?
    let continuations_checked: Bool?
    let independent_semantic_review_completed: Bool?
    let intent_review_completed: Bool?
    let audio_review_completed: Bool?
    let transcription_review_completed: Bool?
    let items: [Task]
    let recording_contexts: [RecordingContextSnapshot]?
    let context_links: [ContextLink]?
    let context_response_ids: [String]?
    struct ContextLink: Decodable {
        let taskID: String
        let personalSourceID: String
        let personalQuote: String
        let externalSourceID: String
        let externalQuote: String
        let externalStatement: String
        let relation: String
        let explanation: String
    }
    struct Task: Decodable {
        let id: String
        let title: String
        let intent_type: String
        let uncertain: Bool
        let followup_state: String
        let notes: String
        let references: [Reference]
        let continuation: OrganizedTaskContinuation?
    }
    struct Reference: Decodable {
        let recording: String
        let quote: String
        let citation_status: String
        let span_ids: [String]?
        let start_ms: Double?
        let end_ms: Double?
    }
}

private func transcriptInputDigest(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}
extension VoiceOSStore {
public func ingestOrganizedPodcast(at directory: URL, allowReminderWrites: Bool = false, requireAPIReview: Bool = true) async throws -> Int {
    let taskData = try Data(contentsOf: directory.appendingPathComponent("完整任务清单.json"))
    let tasks = try JSONDecoder().decode(OrganizedTasks.self, from: taskData)
    let needsAPIReview = requireAPIReview || allowReminderWrites
    guard tasks.all_audio_complete, tasks.all_windows_checked else { throw VoiceOSError("全长转写与漏项复查尚未完成") }
    guard !needsAPIReview || tasks.api_review_completed == true else { throw VoiceOSError("外部 API 意图核对尚未完成；没有接入初稿或写入提醒事项") }
    guard !needsAPIReview || tasks.continuations_checked == true else { throw VoiceOSError("已有任务接续核对尚未完成；没有接入初稿或写入提醒事项") }
    guard !needsAPIReview || ((tasks.intent_review_completed ?? tasks.independent_semantic_review_completed) == true && (tasks.transcription_review_completed ?? tasks.audio_review_completed) == true) else { throw VoiceOSError("意图核对或全文转写校正尚未完成；没有写入提醒事项") }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    if allowReminderWrites {
        guard let access = try reminderAccess(), access.enabled, access.title == "VoiceOS" else { throw VoiceOSError("请先在应用中连接正式 VoiceOS 清单") }
    }
    // Check every recording before replacing any saved transcript or creating tasks.
    let inputs = try tasks.source_folders.map { path in
        let folder = URL(fileURLWithPath: path)
        let original = try JSONDecoder().decode(CompletedQwenTranscript.self, from: Data(contentsOf: folder.appendingPathComponent("Qwen完整逐字稿.json")))
        let reviewed = folder.appendingPathComponent("Qwen核对逐字稿.json")
        let transcript = FileManager.default.fileExists(atPath: reviewed.path) ? try JSONDecoder().decode(CompletedQwenTranscript.self, from: Data(contentsOf: reviewed)) : original
        guard transcript.backend.hasPrefix("Qwen3-ASR"), transcript.complete == true || (transcript.processed_chunks != nil && transcript.processed_chunks == transcript.total_chunks) else { throw VoiceOSError("完整 Qwen 转写尚未完成") }
        try SpeechText(text: transcript.text, spans: transcript.spans).validate(duration: transcript.duration_seconds)
        if needsAPIReview {
            guard transcript.transcription_review?.isCompleteFullTextReview == true else { throw VoiceOSError("逐字稿缺少全文校正回执") }
        }
        let manifest = try JSONDecoder().decode(OrganizedSource.self, from: Data(contentsOf: folder.appendingPathComponent("source.json")))
        return (folder, original, transcript, manifest)
    }
    let manifestPersonalIDs=Set(inputs.compactMap { $0.3.voiceos_source_id })
    guard (tasks.recording_contexts ?? []).allSatisfy({ manifestPersonalIDs.contains($0.pairing.personalSourceID) }) else { throw VoiceOSError("节目配对不属于本次本人录音输入") }
    // Reject stale programme text/permissions before touching any personal transcript.
    for snapshot in tasks.recording_contexts ?? [] {
        try validateLocalTranscriptContext(snapshot.context)
        guard let current=try prepareRecordingContext(sourceID:snapshot.pairing.personalSourceID),
              try Self.relevanceJSON(current) == Self.relevanceJSON(snapshot) else { throw VoiceOSError("节目来源、原话或许可已变化，旧双轨整理未接入") }
    }
    // AI spelling repair must not recreate already connected tasks whose spoken instruction is unchanged.
    let previousClaims = Dictionary(uniqueKeysWithValues: try candidateClaims().map { ($0.id, $0) })
    let previousActions = try actions(includeHistory: true).filter { $0.validity == "current" }
    var reusedActions: [Int: ActionRecord] = [:]
    var sourceIDs: [String: String] = [:]
    var budget = 1
    for (folder, original, transcript, manifest) in inputs {
        let name = folder.lastPathComponent
        let id: String
        if let existingID = manifest.voiceos_source_id {
            guard let existing = try sources().first(where: { $0.id == existingID }),
                  existing.origin == "user",existing.speaker == "user",
                  existing.transcriptionBackend == original.backend, let originalVersion = manifest.voiceos_transcript_version_id else { throw VoiceOSError("完整整理的原话版本已变化，请重新整理") }
            guard !existing.localOnly else { throw VoiceOSError("这份文字已限制为仅本机，完整整理结果暂未接回；原件和逐字稿保留") }
            if let review = transcript.transcription_review, review.completed, review.changed {
                if existing.transcriptVersionID == originalVersion {
                    guard try (existing.transcript == original.text && encoder.encode(existing.spans) == encoder.encode(original.spans)) || manifest.transcription_input_sha256 == transcriptInputDigest(existing.transcript ?? "") else { throw VoiceOSError("校正依据的转写已变化") }
                }
                _ = try applyReviewedQwenTranscript(sourceID: existingID, expectedVersionID: originalVersion,
                                                   speech: SpeechText(text: transcript.text, spans: transcript.spans), responseID: review.response_id)
            } else {
                guard existing.transcriptVersionID == originalVersion, existing.transcript == transcript.text,
                      try encoder.encode(existing.spans) == encoder.encode(transcript.spans) else { throw VoiceOSError("完整整理的原话版本已变化，请重新整理") }
            }
            id = existingID
        } else {
            let audio = folder.appendingPathComponent("完整本人音轨.wav")
            let namedAudio = folder.appendingPathComponent(name + "_完整本人音轨.wav")
            if !FileManager.default.fileExists(atPath: namedAudio.path) { try FileManager.default.linkItem(at: audio, to: namedAudio) }
            id = try await importPersonalAudio(namedAudio, commandID: "podcast-full-qwen:" + name)
            try await processTranscriptions(using: original, sourceIDs: [id])
            if let review = transcript.transcription_review, review.completed, review.changed,
               let version = try sources().first(where: { $0.id == id })?.transcriptVersionID {
                _ = try applyReviewedQwenTranscript(sourceID: id, expectedVersionID: version,
                                                   speech: SpeechText(text: transcript.text, spans: transcript.spans), responseID: review.response_id)
            }
        }
        if allowReminderWrites, manifest.voiceos_source_id == nil {
            let policy = try sourcePolicy(sourceID: id)
            if policy.localOnly { _ = try setSourceLocalOnly(sourceID: id, expectedVersion: policy.version, localOnly: false) }
        }
        if let review = transcript.transcription_review { try saveTranscriptionReview(review, sourceID: id) }
        sourceIDs[name] = id
        budget += transcript.text.unicodeScalars.count
    }
    // Full-text correction may have advanced only the personal version. Rebind
    // the same physical session after verifying programme and both permissions.
    for snapshot in tasks.recording_contexts ?? [] {
        let pairing=snapshot.pairing
        guard let personal=try sources().first(where: { $0.id == pairing.personalSourceID }),
              let external=try sources().first(where: { $0.id == pairing.externalSourceID }),
              personal.policyVersion == pairing.personalPolicyVersion,external.policyVersion == pairing.externalPolicyVersion,
              external.transcriptVersionID == pairing.externalVersionID,
              let currentPair=personal.presentation?.recordingContext,
              try Self.relevanceJSON(currentPair) == Self.relevanceJSON(pairing) else { throw VoiceOSError("双轨整理期间配对、时间偏移、原话或许可已变化") }
        try attachRecordingContext(personalSourceID:pairing.personalSourceID,externalSourceID:pairing.externalSourceID,sessionID:pairing.sessionID,offsetMS:pairing.offsetMS)
    }
    let personalIDs=tasks.source_folders.compactMap { sourceIDs[URL(fileURLWithPath:$0).lastPathComponent] }
    let expectedSnapshots=try personalIDs.compactMap { try prepareRecordingContext(sourceID:$0) }
    let providedSnapshots=tasks.recording_contexts ?? []
    guard Set(expectedSnapshots.map { $0.pairing.personalSourceID }) == Set(providedSnapshots.map { $0.pairing.personalSourceID }),
          Set(providedSnapshots.map { $0.pairing.personalSourceID }).count == providedSnapshots.count else { throw VoiceOSError("完整整理缺少本次配对的节目上下文") }
    let expandedIDs=try recordingContextSourceIDs(sourceIDs:personalIDs)
    let catalog=Dictionary(uniqueKeysWithValues:try sources().map { ($0.id,$0) })
    budget=max(1,expandedIDs.reduce(0) { $0 + (catalog[$1]?.transcript?.unicodeScalars.count ?? 0) })
    let context = try prepareLocalTranscriptContext(sourceIDs:expandedIDs,scalarBudget:budget)
    let listDigest = SHA256.hash(data: taskData).map { String(format: "%02x", $0) }.joined()
    let command = "podcast-comprehensive:" + context.contentDigest + ":" + listDigest
    guard try db.query("SELECT state FROM contexts WHERE command_id=?", [command]).first?["state"] != "frozen" else { throw VoiceOSError("这份整理的原话或授权已变化，旧结果继续暂停；没有重新激活任务") }
    let alreadyImported = !(try db.query("SELECT c.id FROM claims c JOIN model_attempts m ON m.id=c.attempt_id JOIN contexts x ON x.id=m.context_id WHERE x.command_id=? AND m.state='completed'", [command])).isEmpty
    if !alreadyImported {
        try validateTaskContinuations(tasks.items.compactMap(\.continuation), excludingSourceIDs: Set(sourceIDs.values))
    }
    var proposals: [ClaimProposal] = []
    for (taskIndex, task) in tasks.items.enumerated() {
        var references: [ClaimReference] = [], seen: Set<String> = []
        let located = task.references.filter { $0.citation_status == "located" && !$0.quote.isEmpty }
        var quote = located.first?.quote ?? ""
        var notes = task.notes
        for ref in located {
            guard let id = sourceIDs[ref.recording], let source = context.sources.first(where: { $0.sourceID == id }) else { throw VoiceOSError("任务引用缺少完整录音来源") }
            for spanID in ref.span_ids ?? [] where seen.insert(id + spanID).inserted {
                references.append(.init(sourceID: id, transcriptVersionID: source.transcriptVersionID, spanID: spanID))
            }
        }
        if located.isEmpty {
            guard let ref = task.references.first, let id = sourceIDs[ref.recording],
                  let source = context.sources.first(where: { $0.sourceID == id }),
                  let span = source.spans.first(where: { span in
                      guard let start = span.startMS, let end = span.endMS,
                            let refStart = ref.start_ms, let refEnd = ref.end_ms else { return false }
                      return Double(end) > refStart && Double(start) < refEnd
                  }) ?? source.spans.first(where: { $0.startMS == nil && $0.endMS == nil }) else { throw VoiceOSError("待核对事项 \(task.id) 缺少可追溯的录音段落；完整清单保留") }
            references.append(.init(sourceID: id, transcriptVersionID: source.transcriptVersionID, spanID: span.id))
            let scalars = Array(source.text.unicodeScalars)
            quote = String(String.UnicodeScalarView(scalars[span.textStart..<span.textEnd]))
            notes += "；逐字引用未定位，原话栏显示待核对录音段落，不能视为精确引文。"
        }
        let needsReview = task.uncertain || located.isEmpty
        if let link = task.continuation {
            guard tasks.api_review_completed == true, tasks.continuations_checked == true, !needsReview,
                  located.count == task.references.count, located.allSatisfy({ $0.quote.unicodeScalars.count <= 4000 }),
                  link.relation != "repeat" || (task.intent_type == "task" && task.followup_state == "pending") else {
                throw VoiceOSError("接续事项缺少已核对的完整原话，清单保留但未关联旧任务")
            }
        }
        let isTask = task.intent_type == "task" && !needsReview && task.followup_state == "pending"
        let kind: ActionKind = isTask ? .task : .opportunity
        let labels = ["question": "问题", "goal": "长期目标", "idea": "想法", "uncertain": "待核对", "claim": "观点"]
        let prefix = task.followup_state == "withdrawn" ? "已撤回" : task.followup_state == "recorded_activity" ? "录音中活动" : (labels[task.intent_type] ?? (isTask ? "" : "待核对"))
        var title = (prefix.isEmpty ? "" : "【\(prefix)】") + task.title + (needsReview ? "（待核对）" : "")
        if isTask, task.continuation == nil {
            let matches = previousActions.filter { action in
                guard action.kind == "task", action.note == quote, let claim = previousClaims[action.claimID] else { return false }
                return Set(claim.references.map(\.sourceID)) == Set(references.map(\.sourceID))
            }
            if matches.count == 1, !reusedActions.values.contains(where: { $0.id == matches[0].id }) {
                reusedActions[taskIndex] = matches[0]; title = matches[0].title
            }
        }
        let statement = title + (notes.isEmpty ? "" : "\n说明：" + notes)
        let action: ExtractedAction? = task.intent_type == "claim" || task.continuation != nil ? nil : .init(title: title, kind: kind, quote: quote, autoSend: false)
        proposals.append(.init(statement: statement, ownership: .userTentative, references: references,
                               action: action, contentKind: task.intent_type == "claim" ? .statement : nil))
    }
    let personalProposalCount=proposals.count
    let links=tasks.context_links ?? []
    let contextReceipts=tasks.context_response_ids ?? []
    if !providedSnapshots.isEmpty {
        guard contextReceipts.count >= 2,Set(contextReceipts).count == contextReceipts.count,
              contextReceipts.allSatisfy({ !$0.isEmpty }) else { throw VoiceOSError("双轨语义关联缺少独立核对回执") }
    } else if !links.isEmpty { throw VoiceOSError("双轨关联缺少本次节目来源") }
    var linkPairings:[RecordingContext]=[]
    for link in links {
        guard let taskIndex=tasks.items.firstIndex(where: { $0.id == link.taskID }),
              let pairing=try recordingContext(sourceID:link.personalSourceID),pairing.externalSourceID == link.externalSourceID,
              tasks.items[taskIndex].references.contains(where: { sourceIDs[$0.recording] == link.personalSourceID }),
              ["summary","agreement","disagreement","qualification","application","question","uncertain"].contains(link.relation),
              !link.explanation.isEmpty,!link.externalStatement.isEmpty,
              let personal=context.sources.first(where: { $0.sourceID == link.personalSourceID }),
              let external=context.sources.first(where: { $0.sourceID == link.externalSourceID }),
              !link.personalQuote.isEmpty,personal.text.contains(link.personalQuote),
              tasks.items[taskIndex].references.contains(where: { reference in
                  sourceIDs[reference.recording] == link.personalSourceID && reference.citation_status == "located" &&
                  (reference.quote.contains(link.personalQuote) || link.personalQuote.contains(reference.quote))
              }),
              !link.externalQuote.isEmpty,external.text.contains(link.externalQuote),
              let range=external.text.range(of:link.externalQuote) else { throw VoiceOSError("节目观点关联没有双方当前原话依据") }
        let start=external.text[..<range.lowerBound].unicodeScalars.count,end=start+link.externalQuote.unicodeScalars.count
        let refs=external.spans.filter { $0.textEnd > start && $0.textStart < end }.map { ClaimReference(sourceID:external.sourceID,transcriptVersionID:external.transcriptVersionID,spanID:$0.id) }
        guard !refs.isEmpty else { throw VoiceOSError("节目引文缺少真实时间片") }
        proposals.append(.init(statement:link.externalStatement,ownership:.external,references:refs,contentKind:.statement))
        linkPairings.append(pairing)
    }
    let ids = try importOrganizedClaims(context: context, proposals: proposals, commandID: command)
    guard let claimID = ids.first else {
        try finishTranscriptImport(folders: tasks.source_folders)
        return 0
    }
    try db.transaction {
        for (index, old) in reusedActions {
            guard old.version == 1, old.state == "open",
                  let link = try db.query("SELECT id,action_version FROM reminder_links WHERE action_id=?", [old.id]).first,
                  link["action_version"] == "1" else { continue }
            let linkID = link["id"]!
            guard try db.query("SELECT id FROM reminder_observations WHERE link_id=? AND feedback_revision_id IS NOT NULL", [linkID]).isEmpty,
                  try db.query("SELECT id FROM reminder_status_resolutions WHERE link_id=?", [linkID]).isEmpty,
                  try db.query("SELECT id FROM reminder_schedule_operations WHERE link_id=?", [linkID]).isEmpty else { continue }
            let newClaim = try db.query("SELECT id FROM claims WHERE attempt_id=(SELECT attempt_id FROM claims WHERE id=?) AND ordinal=?", [claimID,String(index)]).first!["id"]!
            guard let newAction = try db.query("SELECT id FROM actions WHERE claim_id=? AND command_id LIKE 'extracted:%'", [newClaim]).first else { continue }
            try db.execute("UPDATE reminder_links SET action_id=? WHERE id=?", [newAction["id"],linkID])
        }
    }
    let actions = try db.query("SELECT a.id,c.ordinal FROM actions a JOIN claims c ON c.id=a.claim_id WHERE c.attempt_id=(SELECT attempt_id FROM claims WHERE id=?) AND a.command_id=('extracted:'||c.attempt_id||':'||c.ordinal) ORDER BY c.ordinal", [claimID])
    guard actions.count == proposals.filter({ $0.action != nil }).count else { throw VoiceOSError("整理事项与保存的任务数量不一致") }
    let actionIDs = Dictionary(uniqueKeysWithValues: actions.map { (Int($0["ordinal"]!)!, $0["id"]!) })
    try db.transaction {
        for (index, task) in tasks.items.enumerated() where proposals[index].action != nil {
            guard let actionID = actionIDs[index] else { throw VoiceOSError("整理事项缺少对应任务") }
            var metadata = ActionIntentMetadata(intentType: task.intent_type, followupState: task.followup_state, uncertain: task.uncertain)
            metadata.reminderFields = try self.actions(includeHistory: true).first(where: { $0.id == actionID })?.intent?.reminderFields
            try db.execute("UPDATE actions SET intent_json=? WHERE id=?", [String(decoding: try encoder.encode(metadata), as: UTF8.self), actionID])
        }
    }
    let claimIDs = try db.query("SELECT id FROM claims WHERE attempt_id=(SELECT attempt_id FROM claims WHERE id=?) ORDER BY ordinal", [claimID]).compactMap { $0["id"] }
    if !links.isEmpty {
        var bySource:[String:[RecordingContextLink]]=[:]
        let savedClaims=Dictionary(uniqueKeysWithValues:try candidateClaims().map { ($0.id,$0) })
        for (index,link) in links.enumerated() {
            let taskIndex=tasks.items.firstIndex { $0.id == link.taskID }!
            bySource[link.personalSourceID,default:[]].append(.init(personalClaimID:claimIDs[taskIndex],externalClaimID:claimIDs[personalProposalCount+index],relation:link.relation,explanation:link.explanation,personalQuote:link.personalQuote,externalQuote:link.externalQuote,pairing:linkPairings[index],responseIDs:contextReceipts,personalReviewVersion:savedClaims[claimIDs[taskIndex]]?.reviewVersion,externalReviewVersion:savedClaims[claimIDs[personalProposalCount+index]]?.reviewVersion))
        }
        for id in personalIDs {
            guard let source=try sources().first(where: { $0.id == id }) else { continue }
            var presentation=source.presentation ?? RecordingPresentation()
            presentation.contextLinks=bySource[id] ?? []
            try saveExpressionPresentation(presentation,sourceID:id)
        }
    }
    for (index, task) in tasks.items.enumerated() {
        guard let link = task.continuation else { continue }
        for (referenceIndex, ref) in task.references.enumerated() {
            guard let sourceID = sourceIDs[ref.recording] else { throw VoiceOSError("接续事项缺少录音出处") }
            try recordTaskContinuation(link, claimID: claimIDs[index], quote: ref.quote, recordingSourceID: sourceID,
                                       commandID: command + ":continuation:" + task.id + ":\(referenceIndex)")
        }
    }
    try finishTranscriptImport(folders: tasks.source_folders)
    return ids.count
}
private func finishTranscriptImport(folders: [String], writeReadableCopy: Bool = true) throws {
    // Replace the organizer input and discard temporary re-recognition files.
    for path in folders {
        let folder = URL(fileURLWithPath: path), reviewed = folder.appendingPathComponent("Qwen核对逐字稿.json")
        let transcriptURL = folder.appendingPathComponent("Qwen完整逐字稿.json")
        if FileManager.default.fileExists(atPath: reviewed.path) {
            let data = try Data(contentsOf: reviewed)
            try data.write(to: transcriptURL, options: .atomic)
            try FileManager.default.removeItem(at: reviewed)
        }
        let manifestURL = folder.appendingPathComponent("source.json")
        var sourceName = folder.lastPathComponent
        if let data = try? Data(contentsOf: manifestURL), var manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id = manifest["voiceos_source_id"] as? String, let current = try sources().first(where: { $0.id == id })?.transcriptVersionID {
            sourceName = manifest["source_name"] as? String ?? sourceName
            manifest["voiceos_transcript_version_id"] = current
            try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: manifestURL, options: .atomic)
        }
        var transcript = try JSONDecoder().decode(CompletedQwenTranscript.self, from: Data(contentsOf: transcriptURL))
        if writeReadableCopy, var review = transcript.transcription_review {
            review.correction_count = review.correction_count ?? review.corrections?.count
            review.corrections = nil
            transcript.transcription_review = review
            try JSONEncoder().encode(transcript).write(to: transcriptURL, options: .atomic)
        }
        for name in ["音频疑点核对", "全文AI校正", "完整本人音轨.wav"] {
            let temporary = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: temporary.path) { try FileManager.default.removeItem(at: temporary) }
        }
        guard writeReadableCopy else { continue }
        let scalars = Array(transcript.text.unicodeScalars)
        func stamp(_ milliseconds: Int) -> String {
            let seconds = max(milliseconds, 0) / 1000
            return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        }
        var lines = ["# 完整逐字稿 — \(sourceName)", "", "Qwen 本地转写，完整音轨 \(stamp(Int((transcript.duration_seconds ?? 0) * 1000)))。", ""]
        for span in transcript.spans {
            let location: String
            if let start = span.startMS, let end = span.endMS { location = "\(stamp(start))–\(stamp(end))" }
            else { location = "原文段落 · 录音时间未精确定位，可回听整段" }
            lines.append("[\(location)] \(String(String.UnicodeScalarView(scalars[span.textStart..<span.textEnd])))")
            lines.append("")
        }
        try lines.joined(separator: "\n").write(to: folder.appendingPathComponent("完整逐字稿.md"), atomically: true, encoding: .utf8)
    }
}
public func writeOrganizingInput(sourceID: String, to folder: URL, reviewTranscriptOnly: Bool = false) throws -> LocalTranscriptContext {
    guard let record = try sources().first(where: { $0.id == sourceID }), reviewTranscriptOnly || (record.origin == "user" && record.speaker == "user"),
          record.jobState == "completed", let text = record.transcript, !text.isEmpty,
          let backend = record.transcriptionBackend, backend.hasPrefix("Qwen3-ASR"), let duration = record.duration,
          let version = record.transcriptVersionID else { throw VoiceOSError("请先完成本人音轨的 Qwen 转写") }
    let context = try prepareLocalTranscriptContext(sourceIDs: [sourceID], scalarBudget: text.unicodeScalars.count)
    guard !context.sources[0].localOnly else { throw VoiceOSError("请允许本份文字用于完整整理") }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let externalURL=folder.appendingPathComponent("外部上下文.json")
    if !reviewTranscriptOnly,let snapshot=try prepareRecordingContext(sourceID:sourceID) {
        try JSONEncoder().encode(snapshot).write(to:externalURL,options:.atomic)
    } else if FileManager.default.fileExists(atPath:externalURL.path) { try FileManager.default.removeItem(at:externalURL) }

    let transcript = CompletedQwenTranscript(backend: backend, text: text, spans: record.spans,
                                           processed_chunks: nil, total_chunks: nil, complete: true, duration_seconds: duration, transcription_review: record.transcriptionReview)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let transcriptURL = folder.appendingPathComponent("Qwen完整逐字稿.json")
    let userCorrected = try db.query("SELECT id FROM transcript_versions WHERE id=? AND reason='transcription_error' AND actor='user'", [version]).first != nil
    if FileManager.default.fileExists(atPath: transcriptURL.path) {
        let saved = try JSONDecoder().decode(CompletedQwenTranscript.self, from: Data(contentsOf: transcriptURL))
        let manifest = try JSONDecoder().decode(OrganizedSource.self, from: Data(contentsOf: folder.appendingPathComponent("source.json")))
        if manifest.voiceos_source_id == sourceID, manifest.voiceos_transcript_version_id == version,
           manifest.transcription_input_sha256 == transcriptInputDigest(text), saved.transcription_review?.isCompleteFullTextReview == true,
           !userCorrected || (saved.text == text && manifest.user_corrected_transcript == true) { return context }
        guard saved.text == text, try encoder.encode(saved.spans) == encoder.encode(record.spans) else { throw VoiceOSError("保存的整理输入属于另一版原话") }
    } else { try encoder.encode(transcript).write(to: transcriptURL, options: .atomic) }
    try encoder.encode(OrganizedSource(voiceos_source_id: sourceID, voiceos_transcript_version_id: version, source_name: record.name, user_corrected_transcript: userCorrected ? true : nil)).write(to: folder.appendingPathComponent("source.json"), options: .atomic)
    return context
}
/// The same complete audio/text quality pass is used by short dictation and
/// full recording organization; it never creates knowledge or tasks by itself.
@discardableResult
public func applyTranscriptQualityResult(sourceID: String, expectedVersionID: String, from folder: URL) throws -> String {
    let original = try JSONDecoder().decode(CompletedQwenTranscript.self, from: Data(contentsOf: folder.appendingPathComponent("Qwen完整逐字稿.json")))
    let legacy = folder.appendingPathComponent("Qwen核对逐字稿.json")
    let reviewed = FileManager.default.fileExists(atPath: legacy.path) ? try JSONDecoder().decode(CompletedQwenTranscript.self, from: Data(contentsOf: legacy)) : original
    let manifest = try JSONDecoder().decode(OrganizedSource.self, from: Data(contentsOf: folder.appendingPathComponent("source.json")))
    guard let source = try sources().first(where: { $0.id == sourceID }), !source.localOnly,
          source.transcriptVersionID == expectedVersionID,
          source.transcript == original.text || manifest.transcription_input_sha256 == transcriptInputDigest(source.transcript ?? ""),
          source.transcriptionBackend == original.backend, reviewed.backend == original.backend,
          let review = reviewed.transcription_review, review.isCompleteFullTextReview,
          !review.response_id.isEmpty else { throw VoiceOSError("转写校正期间原话或许可已变化，未覆盖当前内容") }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    if FileManager.default.fileExists(atPath: legacy.path) {
        guard try encoder.encode(source.spans) == encoder.encode(original.spans) else { throw VoiceOSError("转写校正依据的音频范围已变化") }
    } else {
        guard source.spans.map(\.id) == reviewed.spans.map(\.id), source.spans.map(\.startMS) == reviewed.spans.map(\.startMS),
              source.spans.map(\.endMS) == reviewed.spans.map(\.endMS) else { throw VoiceOSError("转写校正依据的音频范围已变化") }
    }
    let speech = SpeechText(text: reviewed.text, spans: reviewed.spans)
    try speech.validate(duration: source.duration)
    if try db.query("SELECT id FROM transcript_versions WHERE id=? AND reason='transcription_error' AND actor='user'", [expectedVersionID]).first != nil {
        guard manifest.user_corrected_transcript == true, speech.text == source.transcript,
              try encoder.encode(speech.spans) == encoder.encode(source.spans), !review.changed else {
            throw VoiceOSError("用户明确更正的原文不能被自动校正覆盖")
        }
        try saveTranscriptionReview(review, sourceID: sourceID)
        try finishTranscriptImport(folders: [folder.path], writeReadableCopy: false)
        return expectedVersionID
    }
    let version = try applyReviewedQwenTranscript(sourceID: sourceID, expectedVersionID: expectedVersionID, speech: speech, responseID: review.response_id)
    try saveTranscriptionReview(review, sourceID: sourceID)
    try finishTranscriptImport(folders: [folder.path], writeReadableCopy: false)
    return version
}
}
