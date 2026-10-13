import Foundation
import PaperclipAPI
import Security

/// Stores one board API key per server.
protocol CredentialStore: Sendable {
    func apiKey(for server: ServerAddress) throws -> String?
    func setAPIKey(_ key: String?, for server: ServerAddress) throws
}

struct KeychainError: Error, Equatable {
    let status: OSStatus
}

/// One generic password item per server, readable after first unlock, never
/// synced off the device. No access group: the app is re-signed by a third party.
struct KeychainCredentialStore: CredentialStore {
    var service = "paperclip-ios.board-api-key"

    func apiKey(for server: ServerAddress) throws -> String? {
        var query = baseQuery(server)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError(status: status) }
        return String(data: data, encoding: .utf8)
    }

    func setAPIKey(_ key: String?, for server: ServerAddress) throws {
        let query = baseQuery(server)
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

    private func baseQuery(_ server: ServerAddress) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: server.storageKey,
        ]
    }
}

/// In-memory store for tests and previews.
final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private var keys: [String: String] = [:]
    private let lock = NSLock()

    func apiKey(for server: ServerAddress) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return keys[server.storageKey]
    }

    func setAPIKey(_ key: String?, for server: ServerAddress) throws {
        lock.lock(); defer { lock.unlock() }
        keys[server.storageKey] = key
    }
}
