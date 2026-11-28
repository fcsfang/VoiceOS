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
    public enum ReadError: Error, Sendable, Equatable {
        case queryFailed(OSStatus)
        case invalidData
    }

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
        try? read()
    }

    /// Returns nil when the item does not exist. Callers that need to explain
    /// an unreadable credential can distinguish it from a missing item.
    public func read() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ReadError.queryFailed(status) }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw ReadError.invalidData
        }
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
