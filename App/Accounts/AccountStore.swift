import Foundation
import PaperclipAPI

/// Builds the API client for a server and key. Tests inject a stubbed session.
typealias ClientFactory = @Sendable (ServerAddress, String?) -> APIClient

let liveClientFactory: ClientFactory = { server, apiKey in
    APIClient(server: server, apiKey: apiKey)
}

/// Where the app goes for the current account.
enum AppRoute: Equatable {
    /// No account yet: server URL entry and sign-in.
    case addServer
    /// The key was rejected (401), revoked or signed out.
    case reSignIn(UUID)
    case pickCompany(UUID)
    case home(UUID)
}

/// The servers the user signed in to, the current one, and its API client.
///
/// Metadata is JSON at `fileURL` (Application Support in the app) and must
/// round-trip exactly. Keys live only in `credentials` (the Keychain in the
/// app), one item per account id.
@MainActor
@Observable
final class AccountStore {
    private(set) var accounts: [Account] = []
    private(set) var currentAccountID: UUID?

    let fileURL: URL
    let makeClient: ClientFactory
    let log: AppLog
    private let credentials: CredentialStore

    init(
        fileURL: URL,
        credentials: CredentialStore,
        makeClient: @escaping ClientFactory = liveClientFactory,
        log: AppLog = .system
    ) {
        self.fileURL = fileURL
        self.credentials = credentials
        self.makeClient = makeClient
        self.log = log
    }

    /// The store the app uses: `accounts.json` in Application Support, keys in the Keychain.
    static func live() -> AccountStore {
        let manager = FileManager.default
        let folder = (try? manager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? manager.temporaryDirectory
        return AccountStore(
            fileURL: folder.appendingPathComponent("accounts.json"),
            credentials: KeychainCredentialStore()
        )
    }

    var currentAccount: Account? {
        accounts.first { $0.id == currentAccountID }
    }

    /// Client for the current account's server and key.
    var currentClient: APIClient? {
        currentAccountID.flatMap { client(for: $0) }
    }

    /// `.addServer` with no account; for the current account `.reSignIn` when it
    /// needs sign-in, `.pickCompany` with no company selected, else `.home`.
    var route: AppRoute {
        guard let account = currentAccount else { return .addServer }
        if account.needsSignIn { return .reSignIn(account.id) }
        if account.selectedCompanyId == nil { return .pickCompany(account.id) }
        return .home(account.id)
    }

    /// Reads the accounts file. A missing file means no accounts.
    func load() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            accounts = []
            currentAccountID = nil
            return
        }
        let file = try Self.decoder.decode(AccountsFile.self, from: Data(contentsOf: fileURL))
        accounts = file.accounts.map { account in
            var account = account
            // A key missing from the Keychain (restored backup, other device) means sign in again.
            if !account.needsSignIn, hasNoKey(account.id) {
                account.needsSignIn = true
            }
            return account
        }
        currentAccountID = file.currentAccountID.flatMap { id in accounts.contains { $0.id == id } ? id : nil }
            ?? accounts.first?.id
        log("Loaded \(accounts.count) account(s)")
    }

    /// Saves a completed sign-in and makes it the current account. Signing in
    /// again to a server already in the list (same `storageKey`) updates that
    /// account (same id, selected company kept, `needsSignIn` cleared) instead
    /// of adding one. `keyExpiresAt` = `approvedAt + Account.keyLifetime`.
    ///
    /// All or nothing: if the accounts file cannot be written, the account's
    /// previous key (none for a new account), `accounts` and `currentAccountID`
    /// are restored and the error is rethrown.
    @discardableResult
    func saveSignIn(server: ServerAddress, me: CliAuthMe, apiKey: String, approvedAt: Date) throws -> Account {
        let previousAccounts = accounts
        let previousCurrentAccountID = currentAccountID
        let existing = accounts.firstIndex { $0.server.storageKey == server.storageKey }
        var account = existing.map { accounts[$0] } ?? Account(
            id: UUID(), server: server, userId: nil, userName: nil, userEmail: nil,
            companyIds: [], selectedCompanyId: nil, keyExpiresAt: nil, needsSignIn: false
        )
        account.server = server
        account.userId = me.userId ?? me.user?.id
        account.userName = me.user?.name
        account.userEmail = me.user?.email
        account.companyIds = me.companyIds
        account.keyExpiresAt = approvedAt.addingTimeInterval(Account.keyLifetime)
        account.needsSignIn = false

        // Read before writing: a Keychain read error stops here with nothing changed.
        var previousKey: String?
        if existing != nil {
            previousKey = try credentials.apiKey(for: account.id)
        }
        try credentials.setAPIKey(apiKey, for: account.id)
        if let existing {
            accounts[existing] = account
        } else {
            accounts.append(account)
        }
        currentAccountID = account.id
        do {
            try save()
        } catch {
            accounts = previousAccounts
            currentAccountID = previousCurrentAccountID
            do {
                try credentials.setAPIKey(previousKey, for: account.id)
            } catch let keychainError {
                log("Account \(account.id): could not restore the previous key: \(keychainError)")
            }
            log("Account \(account.id): sign-in not saved, rolled back")
            throw error
        }
        log("Signed in to \(server.displayName) as account \(account.id)")
        return account
    }

    func select(_ id: UUID) throws {
        guard accounts.contains(where: { $0.id == id }) else { throw AccountStoreError.unknownAccount }
        currentAccountID = id
        try save()
    }

    func selectCompany(_ companyId: String?, for id: UUID) throws {
        try update(id) { $0.selectedCompanyId = companyId }
    }

    /// The account's server with its key from the Keychain (no key when signed out).
    func client(for id: UUID) -> APIClient? {
        guard let account = accounts.first(where: { $0.id == id }) else { return nil }
        let apiKey: String? = try? credentials.apiKey(for: id)
        return makeClient(account.server, apiKey)
    }

    /// Runs `operation` with the account's client. On `APIError.unauthorized`
    /// the key is deleted, the account is marked `needsSignIn` (persisted) and
    /// the error is rethrown. Never retries with the same key.
    func call<T>(_ id: UUID, _ operation: (APIClient) async throws -> T) async throws -> T {
        guard let client = client(for: id) else { throw AccountStoreError.unknownAccount }
        do {
            return try await operation(client)
        } catch APIError.unauthorized {
            log("Account \(id): key rejected (401), sign-in needed")
            markNeedsSignIn(id)
            throw APIError.unauthorized
        }
    }

    /// `POST /api/cli-auth/revoke-current` with the account's key, then deletes
    /// the key even when the revoke fails, and marks the account `needsSignIn`.
    func signOut(_ id: UUID) async {
        if let client = client(for: id), client.apiKey != nil {
            do {
                try await client.revokeCurrentKey()
                log("Account \(id): key revoked")
            } catch {
                log("Account \(id): revoke failed, deleting the key anyway")
            }
        }
        markNeedsSignIn(id)
    }

    /// Signs out, then forgets the account. The current account moves to the
    /// first remaining one, or none.
    func remove(_ id: UUID) async throws {
        await signOut(id)
        accounts.removeAll { $0.id == id }
        if currentAccountID == id || currentAccountID == nil {
            currentAccountID = accounts.first?.id
        }
        try save()
        log("Removed account \(id)")
    }

    // MARK: - Private

    /// True only when the Keychain answered and has no key (a read error is not "signed out").
    private func hasNoKey(_ id: UUID) -> Bool {
        do {
            return try credentials.apiKey(for: id) == nil
        } catch {
            return false
        }
    }

    private func markNeedsSignIn(_ id: UUID) {
        do {
            try credentials.setAPIKey(nil, for: id)
        } catch {
            log("Account \(id): could not delete the key: \(error)")
        }
        do {
            try update(id) { $0.needsSignIn = true }
        } catch {
            log("Account \(id): could not save the sign-out: \(error)")
        }
    }

    private func update(_ id: UUID, _ change: (inout Account) -> Void) throws {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { throw AccountStoreError.unknownAccount }
        change(&accounts[index])
        try save()
    }

    private func save() throws {
        let data = try Self.encoder.encode(AccountsFile(accounts: accounts, currentAccountID: currentAccountID))
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Dates are stored as raw `Date` values so they round-trip exactly
    /// (ISO 8601 text would drop sub-second precision).
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        return decoder
    }()
}

enum AccountStoreError: Error, Equatable {
    case unknownAccount
}

/// The accounts file: metadata only, never a key.
private struct AccountsFile: Codable {
    var accounts: [Account]
    var currentAccountID: UUID?
}
