import Foundation
import Security
import VoiceOSCore

/// The webhook URL is a credential. It lives only in the login keychain,
/// never in UserDefaults, the database, logs or model input.
enum MonitorCredentialStore {
    private static let service = "local.voiceos.app.monitor"
    private static let account = "push.webhook"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func loadWebhookURL() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }

    static func saveWebhookURL(_ raw: String) throws {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else {
            throw VoiceOSError("推送地址无效：需要完整的 http 或 https 地址")
        }
        let data = Data(value.utf8)
        let status = SecItemUpdate(baseQuery as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw VoiceOSError("推送地址无法保存到钥匙串（\(addStatus)）；请重试")
            }
        } else if status != errSecSuccess {
            throw VoiceOSError("推送地址无法更新到钥匙串（\(status)）；请重试")
        }
    }

    static func deleteWebhookURL() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    static func tail(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "" }
        guard value.count > 4 else { return "已保存" }
        return "…" + String(value.suffix(4))
    }
}
