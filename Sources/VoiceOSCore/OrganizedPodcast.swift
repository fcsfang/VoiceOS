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
}
private struct OrganizedTasks: Decodable {
    let source_folders: [String]
    let all_audio_complete: Bool
    let all_windows_checked: Bool
    let api_review_completed: Bool?
    let items: [Task]
    struct Task: Decodable {
        let id: String
        let title: String
        let intent_type: String
        let uncertain: Bool
        let followup_state: String
        let notes: String
        let references: [Reference]
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

extension VoiceOSStore {
public func ingestOrganizedPodcast(at directory: URL, allowReminderWrites: Bool = false, requireAPIReview: Bool = false) async throws -> Int {
    let taskData = try Data(contentsOf: directory.appendingPathComponent("完整任务清单.json"))
    let tasks = try JSONDecoder().decode(OrganizedTasks.self, from: taskData)
    guard tasks.all_audio_complete, tasks.all_windows_checked else { throw VoiceOSError("全长转写与漏项复查尚未完成") }
    guard !requireAPIReview || tasks.api_review_completed == true else { throw VoiceOSError("外部 API 意图核对尚未完成；没有接入初稿或写入提醒事项") }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    if allowReminderWrites {
        guard let access = try reminderAccess(), access.enabled, access.title == "VoiceOS" else { throw VoiceOSError("请先在应用中连接正式 VoiceOS 清单") }
    }
    var sourceIDs: [String: String] = [:]
    var budget = 1
    for path in tasks.source_folders {
        let folder = URL(fileURLWithPath: path), name = folder.lastPathComponent
        let transcript = try JSONDecoder().decode(CompletedQwenTranscript.self, from: Data(contentsOf: folder.appendingPathComponent("Qwen完整逐字稿.json")))
        let manifest = try JSONDecoder().decode(OrganizedSource.self, from: Data(contentsOf: folder.appendingPathComponent("source.json")))
        let id: String
        if let existingID = manifest.voiceos_source_id {
            guard let existing = try sources().first(where: { $0.id == existingID }),
                  existing.transcriptVersionID == manifest.voiceos_transcript_version_id,
                  existing.transcript == transcript.text, existing.transcriptionBackend == transcript.backend,
                  try encoder.encode(existing.spans) == encoder.encode(transcript.spans) else { throw VoiceOSError("完整整理的原话版本已变化，请重新整理") }
            guard !existing.localOnly else { throw VoiceOSError("这份文字已限制为仅本机，完整整理结果暂未接回；原件和逐字稿保留") }
            id = existingID
        } else {
            let audio = folder.appendingPathComponent("完整本人音轨.wav")
            let namedAudio = folder.appendingPathComponent(name + "_完整本人音轨.wav")
            if !FileManager.default.fileExists(atPath: namedAudio.path) { try FileManager.default.linkItem(at: audio, to: namedAudio) }
            id = try await importPersonalAudio(namedAudio, commandID: "podcast-full-qwen:" + name)
            try await processTranscriptions(using: transcript, sourceIDs: [id])
        }
        if allowReminderWrites, manifest.voiceos_source_id == nil {
            let policy = try sourcePolicy(sourceID: id)
            if policy.localOnly { _ = try setSourceLocalOnly(sourceID: id, expectedVersion: policy.version, localOnly: false) }
        }
        sourceIDs[name] = id
        budget += transcript.text.unicodeScalars.count
    }
    let context = try prepareLocalTranscriptContext(sourceIDs: tasks.source_folders.compactMap { sourceIDs[URL(fileURLWithPath: $0).lastPathComponent] }, scalarBudget: budget)
    var proposals: [ClaimProposal] = []
    for task in tasks.items {
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
                  let span = source.spans.first(where: { Double($0.endMS ?? 0) > (ref.start_ms ?? 0) && Double($0.startMS ?? 0) < (ref.end_ms ?? 0) }) else { throw VoiceOSError("待核对事项 \(task.id) 缺少可追溯的录音段落；完整清单保留") }
            references.append(.init(sourceID: id, transcriptVersionID: source.transcriptVersionID, spanID: span.id))
            let scalars = Array(source.text.unicodeScalars)
            quote = String(String.UnicodeScalarView(scalars[span.textStart..<span.textEnd]))
            notes += "；逐字引用未定位，原话栏显示待核对录音段落，不能视为精确引文。"
        }
        let needsReview = task.uncertain || located.isEmpty
        let isTask = task.intent_type == "task" && !needsReview && task.followup_state == "pending"
        let kind: ActionKind = isTask ? .task : .opportunity
        let labels = ["question": "问题", "goal": "长期目标", "idea": "想法", "uncertain": "待核对", "claim": "观点"]
        let prefix = task.followup_state == "recorded_activity" ? "录音中活动" : (labels[task.intent_type] ?? (isTask ? "" : "待核对"))
        let title = (prefix.isEmpty ? "" : "【\(prefix)】") + task.title + (needsReview ? "（待核对）" : "")
        let statement = title + (notes.isEmpty ? "" : "\n说明：" + notes)
        let action: ExtractedAction? = task.intent_type == "claim" ? nil : .init(title: title, kind: kind, quote: quote, autoSend: false)
        proposals.append(.init(statement: statement, ownership: .userTentative, references: references,
                               action: action, contentKind: task.intent_type == "claim" ? .statement : nil))
    }
    let listDigest = SHA256.hash(data: taskData).map { String(format: "%02x", $0) }.joined()
    let command = "podcast-comprehensive:" + context.contentDigest + ":" + listDigest
    guard try db.query("SELECT state FROM contexts WHERE command_id=?", [command]).first?["state"] != "frozen" else { throw VoiceOSError("这份整理的原话或授权已变化，旧结果继续暂停；没有重新激活任务") }
    let ids = try importOrganizedClaims(context: context, proposals: proposals, commandID: command)
    guard let claimID = ids.first else { return 0 }
    let actions = try db.query("SELECT a.id,c.ordinal FROM actions a JOIN claims c ON c.id=a.claim_id WHERE c.attempt_id=(SELECT attempt_id FROM claims WHERE id=?) AND a.command_id=('extracted:'||c.attempt_id||':'||c.ordinal) ORDER BY c.ordinal", [claimID])
    guard actions.count == proposals.filter({ $0.action != nil }).count else { throw VoiceOSError("整理事项与保存的任务数量不一致") }
    let actionIDs = Dictionary(uniqueKeysWithValues: actions.map { (Int($0["ordinal"]!)!, $0["id"]!) })
    try db.transaction {
        for (index, task) in tasks.items.enumerated() where proposals[index].action != nil {
            guard let actionID = actionIDs[index] else { throw VoiceOSError("整理事项缺少对应任务") }
            let metadata = ActionIntentMetadata(intentType: task.intent_type, followupState: task.followup_state, uncertain: task.uncertain)
            try db.execute("UPDATE actions SET intent_json=? WHERE id=?", [String(decoding: try encoder.encode(metadata), as: UTF8.self), actionID])
        }
    }
    return ids.count
}
public func writeOrganizingInput(sourceID: String, to folder: URL) throws -> LocalTranscriptContext {
    guard let record = try sources().first(where: { $0.id == sourceID }), record.origin == "user", record.speaker == "user",
          record.jobState == "completed", let text = record.transcript, !text.isEmpty,
          let backend = record.transcriptionBackend, backend.hasPrefix("Qwen3-ASR"), let duration = record.duration,
          let version = record.transcriptVersionID else { throw VoiceOSError("请先完成本人音轨的 Qwen 转写") }
    let context = try prepareLocalTranscriptContext(sourceIDs: [sourceID], scalarBudget: text.unicodeScalars.count)
    guard !context.sources[0].localOnly else { throw VoiceOSError("请允许本份文字用于完整整理") }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let transcript = CompletedQwenTranscript(backend: backend, text: text, spans: record.spans,
                                           processed_chunks: nil, total_chunks: nil, complete: true, duration_seconds: duration)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let transcriptURL = folder.appendingPathComponent("Qwen完整逐字稿.json")
    if FileManager.default.fileExists(atPath: transcriptURL.path) {
        let saved = try JSONDecoder().decode(CompletedQwenTranscript.self, from: Data(contentsOf: transcriptURL))
        guard saved.text == text, try encoder.encode(saved.spans) == encoder.encode(record.spans) else { throw VoiceOSError("保存的整理输入属于另一版原话") }
    } else { try encoder.encode(transcript).write(to: transcriptURL, options: .atomic) }
    try encoder.encode(OrganizedSource(voiceos_source_id: sourceID, voiceos_transcript_version_id: version, source_name: record.name)).write(to: folder.appendingPathComponent("source.json"), options: .atomic)
    return context
}
}
