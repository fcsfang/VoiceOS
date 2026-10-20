import Foundation
import Darwin
import VoiceOSCore
import VoiceOSPlatform

@main
struct Check {
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            let usage = "usage: voiceos-check <read|import|import-personal-audio|ingest-podcast|task-context|transcribe|transcribe-qwen|export|restore> <data-dir> [arguments]"
            guard args.count >= 2 else { throw VoiceOSError(usage) }
            let command = args[0], root = URL(fileURLWithPath: args[1])
            if command == "ingest-podcast" {
                guard args.count == 3 || (args.count == 4 && args[3] == "--allow-reminders") else { throw VoiceOSError("ingest-podcast <data-dir> <organized-podcast-directory> [--allow-reminders]") }
                try await ingestPodcast(at: URL(fileURLWithPath: args[2]), into: root, allowReminderWrites: args.count == 4)
                return
            }
            switch command {
            case "task-context":
                guard args.count == 3 else { throw VoiceOSError("task-context <data-dir> <output-json>") }
            case "read", "transcribe":
                guard args.count == 2 else { throw VoiceOSError(usage) }
            case "import", "import-personal-audio":
                guard (3...4).contains(args.count) else { throw VoiceOSError(usage) }
            case "export":
                guard args.count == 3 || (args.count == 4 && args[3] == "media") else { throw VoiceOSError(usage) }
            case "restore":
                guard args.count == 3 else { throw VoiceOSError(usage) }
                try await VoiceOSStore.restorePackage(from: URL(fileURLWithPath: args[2]), to: root, inspector: NativeMediaInspector())
                print("{\"restored\":true}")
                return
            case "transcribe-qwen":
                guard args.count == 5 else { throw VoiceOSError("transcribe-qwen <data-dir> <python> <runner> <local-model-dir>") }
            default:
                throw VoiceOSError(usage)
            }
            let store = try VoiceOSStore(root: root, inspector: NativeMediaInspector())
            try await store.recover()
            switch command {
            case "task-context":
                let count = try await store.writeExistingTaskInput(to: URL(fileURLWithPath: args[2]))
                print("已导出 \(count) 条获文字处理授权的现有任务。")
                return
            case "import", "import-personal-audio":
                let file = URL(fileURLWithPath: args[2]), commandID = args.count == 4 ? args[3] : UUID().uuidString
                if command == "import-personal-audio" { _ = try await store.importPersonalAudio(file, commandID: commandID) }
                else { _ = try await store.importFile(file, commandID: commandID) }
            case "transcribe":
                guard let data = UserDefaults(suiteName: "local.voiceos.app")?.data(forKey: "voiceos.localSpeechSelection.v1"),
                      let selection = try? JSONDecoder().decode(LocalSpeechSelection.self, from: data), selection.backend == .qwen else {
                    throw VoiceOSError("请先在应用中启用 Qwen 本地转写；不会默认使用 Apple")
                }
                try await store.processTranscriptions(using: selection.port())
            case "transcribe-qwen":
                let port = try LocalQwenSpeechPort(python: URL(fileURLWithPath: args[2]), runner: URL(fileURLWithPath: args[3]), model: URL(fileURLWithPath: args[4]))
                try await store.processTranscriptions(using: port)
            case "export":
                try await store.exportPackage(to: URL(fileURLWithPath: args[2]), includeMedia: args.count == 4)
            default:
                break
            }
            let records = try await store.sources()
            let output: [String: Any] = ["integrity": try await store.integrityCheck(), "records": records.map {
                ["id": $0.id, "state": $0.state, "kind": $0.kind, "bytes": $0.bytes,
                 "job_state": $0.jobState ?? "none", "text_scalars": $0.transcript?.unicodeScalars.count ?? 0] as [String: Any]
            }]
            print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
