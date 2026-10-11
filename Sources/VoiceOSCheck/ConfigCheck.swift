import Foundation
import VoiceOSCore
import VoiceOSPlatform

/// Loads the complete text-model suite and prints only non-secret metadata.
func runConfigCheck(_ file: URL) throws {
    let suite = try LocalTextModel.loadSuite(from: file)
    let configurations: [ModelConfiguration] = [suite.cognition.configuration, suite.relevance.configuration, suite.discussion.configuration, suite.outcome.configuration, suite.english.configuration]
    let hosts = Set(configurations.compactMap { URL(string: $0.provider.replacingOccurrences(of: "responses:", with: "https://"))?.host })
    let output: [String: Any] = [
        "valid": true,
        "model": suite.cognition.configuration.model,
        "providers": configurations.map(\.provider),
        "prompt_versions": configurations.map(\.promptVersion),
        "schema_versions": configurations.map(\.schemaVersion),
        "hosts": Array(hosts).sorted(),
        "credential": "loaded_in_memory_only"
    ]
    print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), as: UTF8.self))
}
