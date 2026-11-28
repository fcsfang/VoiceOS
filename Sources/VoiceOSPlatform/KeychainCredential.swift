import Foundation
import Security

/// One generic-password item in the login keychain. Callers own their
/// service/account names and map failures to their own user-facing wording.
public struct KeychainCredentialError: Error, Sendable, Equatable {
    public enum Operation: Sendable { case add, update }
    public let operation: Operation
    public let status: OSStatus
}

public struct KeychainCredential: Sendable {
    public let service: String
    public let account: String
    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }

    public func save(_ value: String, accessible: CFString? = nil) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            if let accessible { add[kSecAttrAccessible as String] = accessible }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainCredentialError(operation: .add, status: addStatus)
            }
        } else if status != errSecSuccess {
            throw KeychainCredentialError(operation: .update, status: status)
        }
    }

    public func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}