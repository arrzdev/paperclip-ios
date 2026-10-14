import Foundation
import PaperclipAPI
import Testing
@testable import PaperclipIOS

/// One fake server, store and approval page per test.
@MainActor
final class SignInHarness {
    let server: StubServer
    let credentials: TestCredentialStore
    let file: URL
    let log: LogSink
    let clock: TestClock
    let approval: FakeApproval
    let store: AccountStore

    init(approval behavior: FakeApproval.Behavior = .staysOpen) {
        let credentials = TestCredentialStore()
        let file = tempAccountsFile()
        let log = LogSink()
        self.server = StubServer()
        self.credentials = credentials
        self.file = file
        self.log = log
        self.clock = TestClock(iso("2026-10-13T22:21:00.000Z"))
        self.approval = FakeApproval(behavior)
        self.store = AccountStore(fileURL: file, credentials: credentials, makeClient: stubClients, log: log.log)
    }

    func flow(reauthenticating accountID: UUID? = nil) -> SignInFlow {
        let clock = self.clock
        let flow = SignInFlow(
            store: store,
            approval: approval,
            makeClient: stubClients,
            log: log.log,
            now: { clock.now },
            sleep: { try await clock.sleep($0) },
            reauthenticating: accountID
        )
        if accountID == nil {
            flow.urlText = server.address.displayName
        }
        return flow
    }

    /// Health, challenge and `me` answer as a 2026.1005.0 server; polls answer in order.
    func serveSignIn(
        polls: [String],
        health: String = JSON.healthOK,
        expiresAt: String = "2026-10-13T22:31:01.003Z"
    ) {
        serveSignIn(responses: polls.map(StubServer.Response.ok), health: health, expiresAt: expiresAt)
    }

    func serveSignIn(
        responses polls: [StubServer.Response],
        health: String = JSON.healthOK,
        expiresAt: String = "2026-10-13T22:31:01.003Z"
    ) {
        server.on("GET", "/api/health", .init(body: health))
        server.on("POST", "/api/cli-auth/challenges", .init(status: 201, body: JSON.challenge(host: server.host, expiresAt: expiresAt)))
        server.on("GET", "/api/cli-auth/challenges/c1", polls)
        server.on("GET", "/api/cli-auth/me", .init(body: JSON.me))
    }

    var polls: [URLRequest] {
        server.requests("GET", "/api/cli-auth/challenges/c1")
    }

    var revokes: [URLRequest] {
        server.requests("POST", "/api/cli-auth/revoke-current")
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SignInFlowTests {
    // MARK: Server check

    @Test func badURLsFailWithoutCallingAServer() async {
        let h = SignInHarness()
        let flow = h.flow()

        flow.urlText = "   "
        await flow.checkServer()
        #expect(flow.state == .failed(.invalidURL(.empty)))
        #expect(flow.errorMessage != nil)

        flow.urlText = "http://paperclip.test"
        await flow.checkServer()
        #expect(flow.state == .failed(.invalidURL(.insecureScheme)))

        #expect(h.server.allRequests.isEmpty)
    }

    @Test func normalisesTheURLAndChecksHealthWithoutAKey() async {
        let h = SignInHarness()
        h.serveSignIn(polls: [])
        let flow = h.flow()
        flow.urlText = "  \(h.server.host)/api/  "

        await flow.checkServer()

        #expect(flow.state == .ready(h.server.address, .ok(commit: JSON.pinnedCommit)))
        #expect(flow.versionWarning == nil)
        let health = h.server.requests("GET", "/api/health")
        #expect(health.count == 1)
        #expect(health.first?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func anotherServerBuildWarnsButStillSignsIn() async throws {
        let h = SignInHarness()
        h.serveSignIn(polls: [JSON.approved], health: JSON.healthOtherCommit)
        let flow = h.flow()

        await flow.checkServer()
        #expect(flow.state == .ready(h.server.address, .versionMismatch(serverCommit: "9f8e7d6c5b4a")))
        let warning = try #require(flow.versionWarning)
        #expect(warning.contains("467125f"))

        await flow.signIn()
        #expect(h.store.accounts.count == 1)
    }

    @Test func anUnhealthyServerCannotSignIn() async {
        let h = SignInHarness()
        h.serveSignIn(polls: [JSON.approved], health: JSON.healthDegraded)
        let flow = h.flow()

        await flow.checkServer()
        #expect(flow.state == .failed(.unhealthy("degraded")))

        await flow.signIn()
        #expect(h.server.requests("POST", "/api/cli-auth/challenges").isEmpty)
    }

    // MARK: Device flow

    @Test func signsInOnceTheUserApproves() async throws {
        let h = SignInHarness()
        h.serveSignIn(polls: [JSON.pending, JSON.pending, JSON.approved])
        let flow = h.flow()

        await flow.checkServer()
        await flow.signIn()

        let account = try #require(h.store.accounts.first)
        #expect(flow.state == .signedIn(account.id))
        #expect(h.store.currentAccount?.id == account.id)
        #expect(account.server == h.server.address)
        #expect(account.userName == "Board")
        #expect(account.companyIds == ["company-1", "company-2"])
        #expect(account.keyExpiresAt == iso(JSON.approvedAt).addingTimeInterval(Account.keyLifetime))
        #expect(try h.credentials.apiKey(for: account.id) == JSON.key)

        // The approval page opened on this server and closed once approved.
        #expect(h.approval.presented.compactMap(\.host) == [h.server.host])
        #expect(h.approval.dismissed)

        let challenge = try #require(h.server.requests("POST", "/api/cli-auth/challenges").first)
        let body = try #require(jsonObject(challenge))
        #expect(body["clientName"] as? String == "Paperclip iOS")
        #expect(body["requestedAccess"] as? String == "board")
        #expect(challenge.value(forHTTPHeaderField: "Authorization") == nil)

        // Polls carry the challenge token, no key, and stop at approval.
        #expect(h.polls.count == 3)
        #expect(h.polls.allSatisfy { $0.url?.query?.contains("token=") == true })
        #expect(h.polls.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })

        let me = try #require(h.server.requests("GET", "/api/cli-auth/me").first)
        #expect(me.value(forHTTPHeaderField: "Authorization") == "Bearer \(JSON.key)")
    }

    @Test func deniedInTheBrowser() async {
        let h = SignInHarness()
        h.serveSignIn(polls: [JSON.pending, JSON.state("cancelled")])
        let flow = h.flow()

        await flow.checkServer()
        await flow.signIn()

        #expect(flow.state == .failed(.denied))
        #expect(flow.errorMessage != nil)
        #expect(h.approval.dismissed)
        #expect(h.store.accounts.isEmpty)
        #expect(h.credentials.storedKeyCount == 0)
        #expect(h.server.requests("GET", "/api/cli-auth/me").isEmpty)
    }

    @Test func serverExpiresTheChallenge() async {
        let h = SignInHarness()
        h.serveSignIn(polls: [JSON.pending, JSON.state("expired")])
        let flow = h.flow()

        await flow.checkServer()
        await flow.signIn()

        #expect(flow.state == .failed(.expired))
        #expect(h.approval.dismissed)
        #expect(h.store.accounts.isEmpty)
    }

    @Test func challengeRunsOutOfTimeWhileWaiting() async {
        let h = SignInHarness()
        // Expires 5 s after the clock starts; polls every 1 s and never approved.
        h.serveSignIn(polls: [JSON.pending], expiresAt: "2026-10-13T22:21:05.000Z")
        let flow = h.flow()

        await flow.checkServer()
        await flow.signIn()

        #expect(flow.state == .failed(.expired))
        #expect(h.polls.count >= 1)
        #expect(h.polls.count <= 7)
        #expect(h.approval.dismissed)
        #expect(h.store.accounts.isEmpty)
    }

    @Test func closingThePageBeforeApprovingCancels() async {
        let h = SignInHarness(approval: .userCloses)
        h.serveSignIn(polls: [JSON.pending])
        let flow = h.flow()

        await flow.checkServer()
        await flow.signIn()

        #expect(flow.state == .failed(.cancelled))
        #expect(h.store.accounts.isEmpty)
        #expect(h.credentials.storedKeyCount == 0)
    }

    @Test func closingThePageAfterApprovingStillSignsIn() async throws {
        let h = SignInHarness(approval: .userCloses)
        h.serveSignIn(polls: [JSON.approved])
        let flow = h.flow()

        await flow.checkServer()
        await flow.signIn()

        let account = try #require(h.store.accounts.first)
        #expect(flow.state == .signedIn(account.id))
    }

    @Test func signingInAgainAfterA401RefreshesTheSameAccount() async throws {
        let h = SignInHarness()
        let old = try h.store.saveSignIn(
            server: h.server.address, me: try decodeMe(), apiKey: "pcp_board_OLD",
            approvedAt: iso("2026-09-20T00:00:00.000Z")
        )
        try h.store.selectCompany("company-1", for: old.id)
        h.server.on("GET", "/api/companies", .init(status: 401, body: JSON.unauthorized))
        await #expect(throws: APIError.unauthorized) {
            try await h.store.call(old.id) { try await $0.companies() }
        }
        #expect(h.store.route == .reSignIn(old.id))

        h.serveSignIn(polls: [JSON.approved])
        let flow = h.flow(reauthenticating: old.id)
        #expect(flow.urlText == h.server.address.displayName)
        await flow.checkServer()
        await flow.signIn()

        #expect(flow.state == .signedIn(old.id))
        #expect(h.store.accounts.count == 1)
        #expect(h.store.accounts.first?.needsSignIn == false)
        #expect(h.store.accounts.first?.selectedCompanyId == "company-1")
        #expect(try h.credentials.apiKey(for: old.id) == JSON.key)
        #expect(h.store.route == .home(old.id))
    }

    // MARK: Poll errors

    @Test func aTransientPollErrorIsRetried() async throws {
        let h = SignInHarness()
        let unavailable = StubServer.Response(status: 503, body: JSON.unavailable)
        h.serveSignIn(responses: [.ok(JSON.pending), unavailable, unavailable, unavailable, .ok(JSON.approved)])
        let flow = h.flow()

        await flow.checkServer()
        await flow.signIn()

        let account = try #require(h.store.accounts.first)
        #expect(flow.state == .signedIn(account.id))
        #expect(h.polls.count == 5)
    }

    @Test func aPollKeepsFailingAfterThreeRetries() async {
        let h = SignInHarness()
        h.serveSignIn(responses: [.ok(JSON.pending), .init(status: 503, body: JSON.unavailable)])
        let flow = h.flow()

        await flow.checkServer()
        await flow.signIn()

        guard case .failed(.server) = flow.state else {
            Issue.record("Expected a server failure, got \(flow.state)")
            return
        }
        // One good poll, the failing poll and three retries.
        #expect(h.polls.count == 5)
        #expect(h.approval.dismissed)
        #expect(h.store.accounts.isEmpty)
    }

    @Test func aClientErrorOnAPollFailsAtOnce() async {
        let h = SignInHarness()
        h.serveSignIn(responses: [.ok(JSON.pending), .init(status: 400, body: JSON.invalidToken)])
        let flow = h.flow()

        await flow.checkServer()
        await flow.signIn()

        guard case .failed(.server) = flow.state else {
            Issue.record("Expected a server failure, got \(flow.state)")
            return
        }
        #expect(h.polls.count == 2)
    }

    // MARK: Approved key that is not kept

    @Test func revokesTheNewKeyWhenLoadingTheUserFails() async throws {
        let h = SignInHarness()
        h.serveSignIn(polls: [JSON.approved])
        h.server.on("GET", "/api/cli-auth/me", .init(status: 500, body: #"{"error":"boom"}"#))
        h.server.on("POST", "/api/cli-auth/revoke-current", .init(body: JSON.revoked))
        let flow = h.flow()

        await flow.checkServer()
        await flow.signIn()

        guard case .failed(.server) = flow.state else {
            Issue.record("Expected a server failure, got \(flow.state)")
            return
        }
        let revoke = try #require(h.revokes.first)
        #expect(h.revokes.count == 1)
        #expect(revoke.value(forHTTPHeaderField: "Authorization") == "Bearer \(JSON.key)")
        #expect(h.store.accounts.isEmpty)
        #expect(h.credentials.storedKeyCount == 0)
    }

    @Test func revokesTheNewKeyWhenSavingTheAccountFails() async throws {
        let h = SignInHarness()
        h.serveSignIn(polls: [JSON.approved])
        h.server.on("POST", "/api/cli-auth/revoke-current", .init(body: JSON.revoked))
        h.credentials.failsWrites = true
        let flow = h.flow()

        await flow.checkServer()
        await flow.signIn()

        guard case .failed = flow.state else {
            Issue.record("Expected a failure, got \(flow.state)")
            return
        }
        let revoke = try #require(h.revokes.first)
        #expect(revoke.value(forHTTPHeaderField: "Authorization") == "Bearer \(JSON.key)")
        #expect(h.store.accounts.isEmpty)
        #expect(h.credentials.storedKeyCount == 0)
        for line in h.log.lines {
            #expect(!line.contains(JSON.key))
        }
    }

    @Test func aFailedRevokeStillEndsInTheSignInError() async {
        let h = SignInHarness()
        h.serveSignIn(polls: [JSON.approved])
        h.server.on("GET", "/api/cli-auth/me", .init(status: 500, body: #"{"error":"boom"}"#))
        h.server.on("POST", "/api/cli-auth/revoke-current", .init(status: 503, body: JSON.unavailable))
        let flow = h.flow()

        await flow.checkServer()
        await flow.signIn()

        guard case .failed(.server) = flow.state else {
            Issue.record("Expected a server failure, got \(flow.state)")
            return
        }
        #expect(h.revokes.count == 1)
        #expect(h.store.accounts.isEmpty)
    }

    @Test func noRevokeWhenTheChallengeIsNotApproved() async {
        let h = SignInHarness()
        h.serveSignIn(polls: [JSON.state("cancelled")])
        let flow = h.flow()

        await flow.checkServer()
        await flow.signIn()

        #expect(flow.state == .failed(.denied))
        #expect(h.revokes.isEmpty)
    }

    // MARK: Secrets

    @Test func noKeyOrTokenInLogsErrorsOrTheAccountsFileWhenSignInFails() async throws {
        let h = SignInHarness()
        h.serveSignIn(polls: [JSON.approved])
        // A server that echoes the secrets back in its error message.
        h.server.on("GET", "/api/cli-auth/me", .init(
            status: 500, body: #"{"error":"rejected pcp_board_TEST for challenge-secret+fixture"}"#
        ))
        let flow = h.flow()

        await flow.checkServer()
        await flow.signIn()

        guard case .failed = flow.state else {
            Issue.record("Expected a failure, got \(flow.state)")
            return
        }
        let message = try #require(flow.errorMessage)
        let texts = h.log.lines + [message, String(describing: flow.state)]
        for text in texts {
            #expect(!text.contains(JSON.key))
            #expect(!text.contains("challenge-secret"))
        }
        #expect(!h.log.lines.isEmpty)
        #expect(h.store.accounts.isEmpty)
        #expect(h.credentials.storedKeyCount == 0)
    }

    @Test func noKeyOrTokenInLogsOrTheAccountsFileAfterSignIn() async throws {
        let h = SignInHarness()
        h.serveSignIn(polls: [JSON.pending, JSON.approved])
        let flow = h.flow()

        await flow.checkServer()
        await flow.signIn()

        #expect(h.store.accounts.count == 1)
        let file = try String(contentsOf: h.file, encoding: .utf8)
        #expect(!file.contains(JSON.key))
        #expect(!file.contains("challenge-secret"))
        #expect(!h.log.lines.isEmpty)
        for line in h.log.lines {
            #expect(!line.contains(JSON.key))
            #expect(!line.contains("challenge-secret"))
        }
    }
}
