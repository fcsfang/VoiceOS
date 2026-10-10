import Foundation
import Darwin
import VoiceOSCore
import VoiceOSPlatform

@main
struct Check {
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard args.count >= 2 else { throw VoiceOSError("usage: voiceos-check <import|read|transcribe> <isolated-root> [file] [command-id]") }
            if args[0] == "restore" {
                guard args.count == 3 else { throw VoiceOSError("restore requires package path") }
                try await VoiceOSStore.restorePackage(from: URL(fileURLWithPath: args[2]), to: URL(fileURLWithPath: args[1]), inspector: NativeMediaInspector())
                print("{\"restored\":true}")
                return
            }
            let crash = ProcessInfo.processInfo.environment["VOICEOS_TEST_CRASH_AT"]
            let store = try VoiceOSStore(root: URL(fileURLWithPath: args[1]), inspector: NativeMediaInspector(), checkpoint: { point in
                if point.rawValue == crash { kill(getpid(), SIGKILL) }
            })
            try await store.recover()
            if args[0] == "import" {
                guard args.count >= 3 else { throw VoiceOSError("missing file") }
                _ = try await store.importFile(URL(fileURLWithPath: args[2]), commandID: args.count > 3 ? args[3] : UUID().uuidString)
            } else if args[0] == "export" {
                guard args.count >= 3 else { throw VoiceOSError("export requires new package directory") }
                try await store.exportPackage(to: URL(fileURLWithPath: args[2]), includeMedia: args.count == 4 && args[3] == "media")
            } else if args[0] == "transcribe" { try await store.processTranscriptions(using: NativeSpeechPort()) }
            else if args[0] != "read" { throw VoiceOSError("unknown command") }
            let records = try await store.sources()
            // Deliberately omit paths, names and transcript contents from public diagnostics.
            let output: [String: Any] = ["integrity": try await store.integrityCheck(), "records": records.map {
                ["id": $0.id, "state": $0.state, "kind": $0.kind, "bytes": $0.bytes, "job_state": $0.jobState ?? "none", "text_scalars": $0.transcript?.unicodeScalars.count ?? 0] as [String: Any]
            }]
            print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted,.sortedKeys]), as: UTF8.self))
        } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    }
}
