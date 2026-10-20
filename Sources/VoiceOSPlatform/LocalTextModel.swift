import Foundation
import VoiceOSCore

/// Development configuration only. Never evaluate shell text or expose parsing errors.
public enum LocalTextModel {
    public static func load(from file: URL) throws -> ResponsesModelPort {
        do {
            let bytes = try Data(contentsOf: file)
            guard bytes.count <= 16384, let text = String(data: bytes, encoding: .utf8) else { throw VoiceOSError("invalid config") }
            var settings: [String: String] = [:]
            for raw in text.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }
                let fields = line.split(separator: "=", maxSplits: 1)
                guard fields.count == 2 else { throw VoiceOSError("invalid config") }
                let name = fields[0].trimmingCharacters(in: .whitespaces)
                guard settings[name] == nil else { throw VoiceOSError("duplicate config") }
                settings[name] = try JSONDecoder().decode(String.self, from: Data(fields[1].utf8))
            }
            guard let address = settings["OPENAI_BASE_URL"].flatMap(URL.init(string:)), let key = settings["OPENAI_API_KEY"], key != "REPLACE_LOCALLY" else { throw VoiceOSError("missing config") }
            return try ResponsesModelPort(baseURL: address, apiKey: key, model: "gpt-6.1-sol")
        } catch { throw VoiceOSError("无法读取有效的文本模型配置；请选择项目的本地 .env 文件") }
    }
}
