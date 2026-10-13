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
        .addServer // TODO
    }

    /// Reads the accounts file. A missing file means no accounts.
    func load() throws {
        throw NotImplemented() // TODO
    }

    /// Saves a completed sign-in and makes it the current account. Signing in
    /// again to a server already in the list (same `storageKey`) updates that
    /// account (same id, selected company kept, `needsSignIn` cleared) instead
    /// of adding one. `keyExpiresAt` = `approvedAt + Account.keyLifetime`.
    @discardableResult
    func saveSignIn(server: ServerAddress, me: CliAuthMe, apiKey: String, approvedAt: Date) throws -> Account {
        throw NotImplemented() // TODO
    }

    func select(_ id: UUID) throws {
        throw NotImplemented() // TODO
    }

    func selectCompany(_ companyId: String?, for id: UUID) throws {
        throw NotImplemented() // TODO
    }

    /// The account's server with its key from the Keychain (no key when signed out).
    func client(for id: UUID) -> APIClient? {
        nil // TODO
    }

    /// Runs `operation` with the account's client. On `APIError.unauthorized`
    /// the key is deleted, the account is marked `needsSignIn` (persisted) and
    /// the error is rethrown. Never retries with the same key.
    func call<T>(_ id: UUID, _ operation: (APIClient) async throws -> T) async throws -> T {
        throw NotImplemented() // TODO
    }

    /// `POST /api/cli-auth/revoke-current` with the account's key, then deletes
    /// the key even when the revoke fails, and marks the account `needsSignIn`.
    func signOut(_ id: UUID) async {
        // TODO
    }

    /// Signs out, then forgets the account. The current account moves to the
    /// first remaining one, or none.
    func remove(_ id: UUID) async throws {
        throw NotImplemented() // TODO
    }
}
