import Foundation
import Security

/// Stores one board API key per account.
protocol CredentialStore: Sendable {
    func apiKey(for account: UUID) throws -> String?
    /// `nil` deletes the key.
    func setAPIKey(_ key: String?, for account: UUID) throws
}

struct KeychainError: Error, Equatable {
    let status: OSStatus
}

/// One generic password item per account, readable after first unlock, never
/// synced off the device. No access group: the app is re-signed by a third party.
struct KeychainCredentialStore: CredentialStore {
    var service = "paperclip-ios.board-api-key"

    func apiKey(for account: UUID) throws -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError(status: status) }
        return String(data: data, encoding: .utf8)
    }

    func setAPIKey(_ key: String?, for account: UUID) throws {
        let query = baseQuery(account)
        let deleteStatus = SecItemDelete(query as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw KeychainError(status: deleteStatus)
        }
        guard let key else { return }
        var item = query
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    private func baseQuery(_ account: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.uuidString,
        ]
    }
}

/// In-memory store for tests and previews.
final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private var keys: [UUID: String] = [:]
    private let lock = NSLock()

    func apiKey(for account: UUID) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return keys[account]
    }

    func setAPIKey(_ key: String?, for account: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        keys[account] = key
    }

    var storedKeyCount: Int {
        lock.lock(); defer { lock.unlock() }
        return keys.count
    }
}
