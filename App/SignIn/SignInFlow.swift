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
    /// Set when the approval page returns (the user closed it, or `dismiss()`).
    @ObservationIgnored private var approvalPageClosed = false

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
        if let accountID, let account = store.accounts.first(where: { $0.id == accountID }) {
            urlText = account.server.displayName
        }
    }

    /// Shown with the sign-in button when the server is not on the pinned
    /// commit; names the pinned commit. Nil otherwise.
    var versionWarning: String? {
        guard case .ready(_, .versionMismatch(let serverCommit)) = state else { return nil }
        let build = serverCommit.map { "build \($0)" } ?? "an unknown build"
        return "This server runs \(build). The app is tested with Paperclip \(PaperclipPin.version) "
            + "(\(PaperclipPin.commit)); some screens may not work."
    }

    /// User-facing text for `.failed`; never contains a key or token.
    var errorMessage: String? {
        guard case .failed(let failure) = state else { return nil }
        switch failure {
        case .invalidURL(.empty):
            return "Enter your Paperclip server address."
        case .invalidURL(.insecureScheme):
            return "Use an https:// address. Plain http is only allowed for localhost."
        case .invalidURL(.invalid):
            return "That is not a valid server address."
        case .unreachable(let text):
            return text
        case .unhealthy(let status):
            return "The server is not ready (status: \(status)). Try again later."
        case .denied:
            return "Sign-in was denied in the browser."
        case .expired:
            return "The sign-in request expired. Try again."
        case .cancelled:
            return "The approval page was closed before sign-in was approved."
        case .server(let text):
            return text
        }
    }

    /// Normalises `urlText` and calls `GET /api/health` without a key.
    func checkServer() async {
        let server: ServerAddress
        do {
            server = try ServerAddress(urlText)
        } catch let error as ServerAddress.ValidationError {
            state = .failed(.invalidURL(error))
            return
        } catch {
            state = .failed(.invalidURL(.invalid))
            return
        }
        urlText = server.displayName
        state = .checking
        log("Sign-in: checking \(server.displayName)")
        do {
            let check = try await makeClient(server, nil).checkServer()
            if case .unhealthy(let status) = check {
                log("Sign-in: \(server.displayName) is unhealthy (\(status))")
                state = .failed(.unhealthy(status))
            } else {
                state = .ready(server, check)
            }
        } catch {
            let message = userMessage(for: error)
            log("Sign-in: server check failed: \(message)")
            state = .failed(.unreachable(message))
        }
    }

    /// From `.ready` with `canSignIn`: creates the challenge, presents
    /// `approvalUrl`, polls every `suggestedPollIntervalMs` (default 1 s) until
    /// approved, cancelled, expired (server status or `now() >= expiresAt`) or
    /// the user closes the page (then one last poll decides). Dismisses the page
    /// when polling ends. On approval: `GET /api/cli-auth/me` with the new key,
    /// then saves the account; the key is stored only after `me` succeeds.
    /// Logs each step through `log`, never with a key or token.
    func signIn() async {
        guard case .ready(let server, let check) = state, check.canSignIn else { return }
        let client = makeClient(server, nil)

        let challenge: CliAuthChallenge
        do {
            challenge = try await client.createCliAuthChallenge()
        } catch {
            fail(.server(userMessage(for: error)), secrets: [])
            return
        }
        let secrets = [challenge.token, challenge.boardApiToken]
        log("Sign-in: challenge created on \(server.displayName), waiting for approval")

        let url = client.approvalURL(for: challenge)
        state = .waitingForApproval(url)
        approvalPageClosed = false
        let page = Task { @MainActor in
            await self.approval.present(url)
            self.approvalPageClosed = true
        }
        let outcome = await pollUntilDecided(client, challenge)
        approval.dismiss()
        await page.value

        let approvedAt: Date
        switch outcome {
        case .approved(let date):
            approvedAt = date
        case .failed(let failure):
            fail(failure, secrets: secrets)
            return
        }
        log("Sign-in: approved, loading the user")

        do {
            let me = try await makeClient(server, challenge.boardApiToken).me()
            let account = try store.saveSignIn(
                server: server, me: me, apiKey: challenge.boardApiToken, approvedAt: approvedAt
            )
            if let reauthenticatingID, reauthenticatingID != account.id {
                log("Sign-in: signed in to another server than the account being refreshed")
            }
            state = .signedIn(account.id)
        } catch {
            fail(.server(userMessage(for: error)), secrets: secrets)
        }
    }

    // MARK: - Private

    private enum PollOutcome {
        case approved(Date)
        case failed(Failure)
    }

    /// Polls while the approval page is open. Once the page closes, one more
    /// poll decides between approved and cancelled.
    private func pollUntilDecided(_ client: APIClient, _ challenge: CliAuthChallenge) async -> PollOutcome {
        let interval = Duration.milliseconds(max(challenge.suggestedPollIntervalMs ?? 1000, 100))
        while true {
            let isLastPoll = approvalPageClosed
            let challengeState: CliAuthChallengeState
            do {
                challengeState = try await client.cliAuthChallengeState(id: challenge.id, token: challenge.token)
            } catch {
                return .failed(.server(userMessage(for: error)))
            }
            switch challengeState.status {
            case .approved:
                return .approved(challengeState.approvedAt ?? now())
            case .cancelled:
                return .failed(.denied)
            case .expired:
                return .failed(.expired)
            case .pending, .unknown:
                break
            }
            if isLastPoll { return .failed(.cancelled) }
            // Closed during this poll: poll once more right away to decide.
            if approvalPageClosed { continue }
            if now() >= challenge.expiresAt { return .failed(.expired) }
            do {
                try await sleep(interval)
            } catch {
                return .failed(.cancelled)
            }
        }
    }

    private func fail(_ failure: Failure, secrets: [String]) {
        let redacted: Failure
        switch failure {
        case .unreachable(let text):
            redacted = .unreachable(Self.redact(text, secrets))
        case .server(let text):
            redacted = .server(Self.redact(text, secrets))
        default:
            redacted = failure
        }
        state = .failed(redacted)
        log("Sign-in failed: \(errorMessage ?? "")")
    }

    /// The client redacts only what it sent on that call; a server may echo
    /// the key or the device token in any later error.
    private static func redact(_ text: String, _ secrets: [String]) -> String {
        var text = text
        for secret in secrets where !secret.isEmpty {
            text = text.replacingOccurrences(of: secret, with: "<redacted>")
            // As sent in a query string (`+` as `%2B`) and fully encoded.
            let queryAllowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&=?/"))
            for allowed in [queryAllowed, .alphanumerics] {
                if let encoded = secret.addingPercentEncoding(withAllowedCharacters: allowed) {
                    text = text.replacingOccurrences(of: encoded, with: "<redacted>")
                }
            }
        }
        return text
    }
}
