import Foundation
import VoiceOSCore

/// 应用内部维护的文本模型配置：地址、模型型号与思考强度。密钥不在这里，
/// 只进系统钥匙串；设置页直接编辑这些值，不再依赖外部 .env 文件。
public struct TextModelConfiguration: Codable, Equatable, Sendable {
    public var baseURL: String
    public var model: String
    public var noteEffort: String
    public var topicEffort: String
    /// 完整转写核对与整理脚本的思考强度；旧配置没有这一项时按 high 解码。
    public var reviewEffort: String
    public static let defaultsKey = "voiceos.textModel.internal.v1"

    public init(baseURL: String, model: String = LocalTextModel.defaultModel,
                noteEffort: String = "high", topicEffort: String = "high", reviewEffort: String = "high") {
        self.baseURL = baseURL; self.model = model
        self.noteEffort = noteEffort; self.topicEffort = topicEffort
        self.reviewEffort = reviewEffort
    }

    private enum CodingKeys: String, CodingKey { case baseURL, model, noteEffort, topicEffort, reviewEffort }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? LocalTextModel.defaultModel
        noteEffort = try container.decodeIfPresent(String.self, forKey: .noteEffort) ?? "high"
        topicEffort = try container.decodeIfPresent(String.self, forKey: .topicEffort) ?? "high"
        reviewEffort = try container.decodeIfPresent(String.self, forKey: .reviewEffort) ?? "high"
    }

    public static func load() -> TextModelConfiguration? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let config = try? JSONDecoder().decode(TextModelConfiguration.self, from: data) else { return nil }
        return config
    }

    public func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    public static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    /// 由设置页输入组装并校验地址；无效返回 nil。尾部多余的 `/` 会被规范掉，
/// 与端口策略要求的精确 `https://主机/v1` 一致。
    public func validated() -> TextModelConfiguration? {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme != nil else { return nil }
        var copy = self
        copy.baseURL = trimmed
        return copy
    }
}

/// 密钥只存系统钥匙串，不写入 UserDefaults、不打印。
public enum TextModelKeychain {
    private static let item = KeychainCredential(service: "local.voiceos.textmodel", account: "apiKey")

    public static func apiKey() -> String? {
        guard let key = item.load(), !key.isEmpty else { return nil }
        return key
    }

    public static func save(_ key: String) throws {
        do {
            try item.save(key)
        } catch let error as KeychainCredentialError {
            throw VoiceOSError(error.operation == .add ? "无法保存模型密钥到钥匙串" : "无法更新钥匙串中的模型密钥")
        }
    }

    public static func delete() {
        item.delete()
    }
}
