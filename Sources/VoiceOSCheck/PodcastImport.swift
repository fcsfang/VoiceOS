import Foundation
import VoiceOSCore
import VoiceOSPlatform

func ingestPodcast(at directory: URL, into root: URL, allowReminderWrites: Bool = false) async throws {
    let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
    try await store.recover()
    let count = try await store.ingestOrganizedPodcast(at: directory, allowReminderWrites: allowReminderWrites)
    print("完整 Qwen 逐字稿与 \(count) 条任务/待核对意图已保存；未标记完成。")
}
