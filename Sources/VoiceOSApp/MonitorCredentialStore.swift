import Foundation
import Security
import VoiceOSCore
import VoiceOSPlatform

/// The webhook URL is a credential. It lives only in the login keychain,
/// never in UserDefaults, the database, logs or model input.
enum MonitorCredentialStore {
    private static let item = KeychainCredential(service: "local.voiceos.app.monitor", account: "push.webhook")

    static func loadWebhookURL() -> String? {
        item.load()
    }

    static func saveWebhookURL(_ raw: String) throws {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else {
            throw VoiceOSError("推送地址无效：需要完整的 http 或 https 地址")
        }
        do {
            try item.save(value, accessible: kSecAttrAccessibleAfterFirstUnlock)
        } catch let error as KeychainCredentialError {
            throw VoiceOSError(error.operation == .add
                ? "推送地址无法保存到钥匙串（\(error.status)）；请重试"
                : "推送地址无法更新到钥匙串（\(error.status)）；请重试")
        }
    }

    static func tail(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "" }
        guard value.count > 4 else { return "已保存" }
        return "…" + String(value.suffix(4))
    }
}
