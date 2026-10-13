import Foundation
import CryptoKit
import VoiceOSCore
import VoiceOSPlatform

private struct CompletedQwenTranscript: Decodable, SpeechPort {
    let backend: String
    let text: String
    let spans: [TranscriptSpan]
    let processed_chunks: Int
    let total_chunks: Int
    var backendIdentity: String { backend }
    func transcribe(_ url: URL, locale: String) async throws -> SpeechText {
        guard backend.hasPrefix("Qwen3-ASR"), processed_chunks == total_chunks else { throw VoiceOSError("完整 Qwen 转写尚未完成") }
        return SpeechText(text: text, spans: spans)
    }
}
private struct OrganizedTasks: Decodable {
    let source_folders: [String]
    let all_audio_complete: Bool
    let all_windows_checked: Bool
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
    }
}

func ingestPodcast(at directory: URL, into root: URL, allowReminderWrites: Bool = false) async throws {
    let taskData = try Data(contentsOf: directory.appendingPathComponent("完整任务清单.json"))
    let tasks = try JSONDecoder().decode(OrganizedTasks.self, from: taskData)
    guard tasks.all_audio_complete, tasks.all_windows_checked else { throw VoiceOSError("全长转写与漏项复查尚未完成") }
    let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
    try await store.recover()
    if allowReminderWrites {
        guard let access = try await store.reminderAccess(), access.enabled, access.title == "VoiceOS" else { throw VoiceOSError("请先在应用中连接正式 VoiceOS 清单") }
    }
    var sources: [String: String] = [:]
    var budget = 1
    for path in tasks.source_folders {
        let folder = URL(fileURLWithPath: path), name = folder.lastPathComponent
        let transcript = try JSONDecoder().decode(CompletedQwenTranscript.self, from: Data(contentsOf: folder.appendingPathComponent("Qwen完整逐字稿.json")))
        let audio = folder.appendingPathComponent("完整本人音轨.wav")
        let namedAudio = folder.appendingPathComponent(name + "_完整本人音轨.wav")
        if !FileManager.default.fileExists(atPath: namedAudio.path) { try FileManager.default.linkItem(at: audio, to: namedAudio) }
        let id = try await store.importPersonalAudio(namedAudio, commandID: "podcast-full-qwen:" + name)
        try await store.processTranscriptions(using: transcript, sourceIDs: [id])
        if allowReminderWrites {
            let policy = try await store.sourcePolicy(sourceID: id)
            if policy.localOnly { _ = try await store.setSourceLocalOnly(sourceID: id, expectedVersion: policy.version, localOnly: false) }
        }
        sources[name] = id
        budget += transcript.text.unicodeScalars.count
    }
    let context = try await store.prepareLocalTranscriptContext(sourceIDs: tasks.source_folders.compactMap { sources[URL(fileURLWithPath: $0).lastPathComponent] }, scalarBudget: budget)
    var proposals: [ClaimProposal] = []
    for task in tasks.items {
        var references: [ClaimReference] = [], seen: Set<String> = []
        let located = task.references.filter { $0.citation_status == "located" && !$0.quote.isEmpty }
        guard let original = located.first else { throw VoiceOSError("任务 \(task.id) 的原话尚未定位，不能丢弃或伪造出处") }
        for ref in located {
            guard let id = sources[ref.recording], let source = context.sources.first(where: { $0.sourceID == id }) else { throw VoiceOSError("任务引用缺少完整录音来源") }
            for spanID in ref.span_ids ?? [] where seen.insert(id + spanID).inserted {
                references.append(.init(sourceID: id, transcriptVersionID: source.transcriptVersionID, spanID: spanID))
            }
        }
        let isTask = task.intent_type == "task" && !task.uncertain && task.followup_state == "pending"
        let kind: ActionKind = isTask ? .task : .opportunity
        let labels = ["question": "问题", "goal": "长期目标", "idea": "想法", "uncertain": "待核对"]
        let prefix = task.followup_state == "recorded_activity" ? "录音中活动" : (labels[task.intent_type] ?? (isTask ? "" : "待核对"))
        let title = (prefix.isEmpty ? "" : "【\(prefix)】") + task.title + (task.uncertain ? "（待核对）" : "")
        let statement = title + (task.notes.isEmpty ? "" : "\n说明：" + task.notes)
        proposals.append(.init(statement: statement, ownership: .userTentative, references: references,
                               action: .init(title: title, kind: kind, quote: original.quote, autoSend: false)))
    }
    let listDigest = SHA256.hash(data: taskData).map { String(format: "%02x", $0) }.joined()
    let ids = try await store.importOrganizedClaims(context: context, proposals: proposals, commandID: "podcast-comprehensive:" + context.contentDigest + ":" + listDigest)
    print("已将 \(sources.count) 段完整 Qwen 逐字稿与 \(ids.count) 条任务/待核对意图保存到日常资料库；未标记完成。")
}
