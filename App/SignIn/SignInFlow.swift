import Foundation
import PaperclipAPI

/// Device-flow sign-in to one server:
/// URL → `GET /api/health` → `POST /api/cli-auth/challenges` → approval page →
/// poll `GET /api/cli-auth/challenges/:id?token=…` → `GET /api/cli-auth/me` →
/// `AccountStore.saveSignIn`.
@MainActor
@Observable
final class SignInFlow {
    enum State: Equatable {
        case editing
        case checking
        /// Health checked; sign-in allowed. A version mismatch shows `versionWarning`.
        case ready(ServerAddress, ServerCheck)
        case waitingForApproval(URL)
        case signedIn(UUID)
        case failed(Failure)
    }

    enum Failure: Equatable {
        case invalidURL(ServerAddress.ValidationError)
        /// Network error or not a Paperclip server. Text is redacted.
        case unreachable(String)
        /// `GET /api/health` answered with a status other than `ok`.
        case unhealthy(String)
        /// The challenge was cancelled on the server (the user denied it).
        case denied
        /// The challenge expired before approval.
        case expired
        /// The user closed the approval page before approving.
        case cancelled
        /// Any other API error after the server check. Text is redacted.
        case server(String)
    }

    var urlText = ""
    private(set) var state: State = .editing

    private let store: AccountStore
    private let approval: ApprovalPresenter
    private let makeClient: ClientFactory
    private let log: AppLog
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private let reauthenticatingID: UUID?

    /// With `reauthenticating`, `urlText` starts as that account's server
    /// (`displayName`) and success updates that account.
    init(
        store: AccountStore,
        approval: ApprovalPresenter,
        makeClient: @escaping ClientFactory = liveClientFactory,
        log: AppLog = .system,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        reauthenticating accountID: UUID? = nil
    ) {
        self.store = store
        self.approval = approval
        self.makeClient = makeClient
        self.log = log
        self.now = now
        self.sleep = sleep
        self.reauthenticatingID = accountID
        // TODO: prefill urlText when reauthenticating.
    }

    /// Shown with the sign-in button when the server is not on the pinned
    /// commit; names the pinned commit. Nil otherwise.
    var versionWarning: String? {
        nil // TODO
    }

    /// User-facing text for `.failed`; never contains a key or token.
    var errorMessage: String? {
        nil // TODO
    }

    /// Normalises `urlText` and calls `GET /api/health` without a key.
    func checkServer() async {
        // TODO
    }

    /// From `.ready` with `canSignIn`: creates the challenge, presents
    /// `approvalUrl`, polls every `suggestedPollIntervalMs` (default 1 s) until
    /// approved, cancelled, expired (server status or `now() >= expiresAt`) or
    /// the user closes the page (then one last poll decides). Dismisses the page
    /// when polling ends. On approval: `GET /api/cli-auth/me` with the new key,
    /// then saves the account; the key is stored only after `me` succeeds.
    /// Logs each step through `log`, never with a key or token.
    func signIn() async {
        // TODO
    }
}
