import Foundation
import Security

/// Thin wrapper over the macOS Keychain. Each GitHub account gets its own item.
enum Keychain {
    static let service = "com.vt.cideck.github-token"
    static let legacyAccount = "default"
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var tokenCache: [String: String] = [:]

    static func save(_ token: String, account: String) throws {
        let data = Data(token.utf8)

        // Update first; SecItemAdd would fail with errSecDuplicateItem otherwise.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary,
                                         [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess {
            cache(token, for: account)
            return
        }
        if updateStatus != errSecItemNotFound { throw KeychainError(status: updateStatus) }

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        cache(token, for: account)
    }

    static func read(account: String) -> String? {
        cacheLock.lock()
        let cached = tokenCache[account]
        cacheLock.unlock()
        if let cached { return cached }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8)
        else { return nil }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        cache(trimmed, for: account)
        return trimmed
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        cacheLock.lock()
        tokenCache.removeValue(forKey: account)
        cacheLock.unlock()
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func cache(_ token: String, for account: String) {
        cacheLock.lock()
        tokenCache[account] = token
        cacheLock.unlock()
    }
}

struct KeychainError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error"
        return "Keychain error \(status): \(message)"
    }
}
