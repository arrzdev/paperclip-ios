import Foundation
import PaperclipAPI
import Testing
@testable import PaperclipIOS

/// Me → Accounts (spec §4 E): every server with its user and companies, a
/// "Needs you" badge per account and company fetched with that account's own
/// key, switch by tapping a company, sign out and remove by swiping a server.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AccountsModelTests {
    static let keyA = "pcp_board_TEST_A"
    static let keyB = "pcp_board_TEST_B"
    static let companiesB = #"[{"id":"company-3","name":"Initech","issuePrefix":"INI","status":"active"}]"#

    static func badges(inbox: Int) -> String {
        #"{"inbox":\#(inbox),"approvals":1,"failedRuns":0,"joinRequests":0}"#
    }

    static func badgesPath(_ companyID: String) -> String {
        "/api/companies/\(companyID)/sidebar-badges"
    }

    struct Setup {
        let store: AccountStore
        let credentials: InMemoryCredentialStore
        let file: URL
        let serverA: StubServer
        let serverB: StubServer
        let a: UUID
        let b: UUID
    }

    /// Two servers: A (current, company-1 selected; companies Acme and Globex)
    /// and B (Initech). Each has its own key.
    private func twoAccounts(log: LogSink = LogSink()) throws -> Setup {
        let serverA = StubServer()
        serverA.on("GET", "/api/companies", .ok(JSON.companies))
        serverA.on("GET", Self.badgesPath("company-1"), .ok(Self.badges(inbox: 3)))
        serverA.on("GET", Self.badgesPath("company-2"), .ok(Self.badges(inbox: 0)))
        serverA.on("POST", "/api/cli-auth/revoke-current", .ok(JSON.revoked))
        let serverB = StubServer()
        serverB.on("GET", "/api/companies", .ok(Self.companiesB))
        serverB.on("GET", Self.badgesPath("company-3"), .ok(Self.badges(inbox: 1)))
        serverB.on("POST", "/api/cli-auth/revoke-current", .ok(JSON.revoked))

        let file = tempAccountsFile()
        let credentials = InMemoryCredentialStore()
        let store = makeStore(file: file, credentials: credentials, log: log)
        let approvedAt = iso(JSON.approvedAt)
        let a = try store.saveSignIn(server: serverA.address, me: try decodeMe(), apiKey: Self.keyA, approvedAt: approvedAt)
        let b = try store.saveSignIn(server: serverB.address, me: try decodeMe(), apiKey: Self.keyB, approvedAt: approvedAt)
        try store.selectCompany("company-1", for: a.id)
        try store.select(a.id)
        return Setup(
            store: store, credentials: credentials, file: file,
            serverA: serverA, serverB: serverB, a: a.id, b: b.id
        )
    }

    private func section(_ model: AccountsModel, _ id: UUID) -> AccountSection? {
        model.sections.first { $0.account.id == id }
    }

    // MARK: Refresh

    @Test func listsEveryServerWithItsUserAndCompaniesInStoreOrder() async throws {
        let setup = try twoAccounts()
        let model = AccountsModel(store: setup.store, poller: Poller(sleep: TestSleeper(ticks: 0).sleep))

        await model.refresh()

        #expect(model.sections.map(\.account.id) == [setup.a, setup.b])
        #expect(section(model, setup.a)?.account.userName == "Board")
        #expect(section(model, setup.a)?.companies.map(\.name) == ["Acme", "Globex"])
        #expect(section(model, setup.b)?.companies.map(\.name) == ["Initech"])
        #expect(section(model, setup.a)?.errorMessage == nil)
    }

    @Test func eachServerIsAskedWithItsOwnKey() async throws {
        let setup = try twoAccounts()
        let model = AccountsModel(store: setup.store, poller: Poller(sleep: TestSleeper(ticks: 0).sleep))

        await model.refresh()

        let sentA = setup.serverA.allRequests.compactMap { $0.value(forHTTPHeaderField: "Authorization") }
        let sentB = setup.serverB.allRequests.compactMap { $0.value(forHTTPHeaderField: "Authorization") }
        #expect(!sentA.isEmpty)
        #expect(!sentB.isEmpty)
        #expect(sentA.allSatisfy { $0 == "Bearer \(Self.keyA)" })
        #expect(sentB.allSatisfy { $0 == "Bearer \(Self.keyB)" })
    }

    @Test func badgePerAccountAndCompanyIsTheServerInboxCount() async throws {
        let setup = try twoAccounts()
        let model = AccountsModel(store: setup.store, poller: Poller(sleep: TestSleeper(ticks: 0).sleep))

        await model.refresh()

        #expect(model.badge(accountID: setup.a, companyID: "company-1") == 3)
        #expect(model.badge(accountID: setup.a, companyID: "company-2") == 0)
        #expect(model.badge(accountID: setup.b, companyID: "company-3") == 1)
        // A company of another server has no badge here.
        #expect(model.badge(accountID: setup.a, companyID: "company-3") == nil)
        #expect(setup.serverA.requests("GET", Self.badgesPath("company-1")).count == 1)
        #expect(setup.serverB.requests("GET", Self.badgesPath("company-3")).count == 1)
    }

    @Test func marksOnlyTheCurrentAccountAndCompany() async throws {
        let setup = try twoAccounts()
        let model = AccountsModel(store: setup.store, poller: Poller(sleep: TestSleeper(ticks: 0).sleep))

        await model.refresh()

        #expect(model.isCurrent(accountID: setup.a, companyID: "company-1"))
        #expect(!model.isCurrent(accountID: setup.a, companyID: "company-2"))
        #expect(!model.isCurrent(accountID: setup.b, companyID: "company-3"))
    }

    @Test func a401OnOneServerMarksOnlyThatAccount() async throws {
        let setup = try twoAccounts()
        setup.serverB.on("GET", "/api/companies", .init(status: 401, body: JSON.unauthorized))
        let model = AccountsModel(store: setup.store, poller: Poller(sleep: TestSleeper(ticks: 0).sleep))

        await model.refresh()

        #expect(setup.store.accounts.first { $0.id == setup.b }?.needsSignIn == true)
        #expect(setup.store.accounts.first { $0.id == setup.a }?.needsSignIn == false)
        #expect(try setup.credentials.apiKey(for: setup.b) == nil)
        #expect(try setup.credentials.apiKey(for: setup.a) == Self.keyA)
        // The current account keeps working.
        #expect(setup.store.currentAccountID == setup.a)
        #expect(setup.store.route == .home(setup.a))
        #expect(model.badge(accountID: setup.a, companyID: "company-1") == 3)
        #expect(section(model, setup.b)?.account.needsSignIn == true)
        #expect(section(model, setup.b)?.companies.isEmpty == true)
    }

    @Test func a401OnABadgeMarksOnlyThatAccount() async throws {
        let setup = try twoAccounts()
        setup.serverB.on("GET", Self.badgesPath("company-3"), .init(status: 401, body: JSON.unauthorized))
        let model = AccountsModel(store: setup.store, poller: Poller(sleep: TestSleeper(ticks: 0).sleep))

        await model.refresh()

        #expect(setup.store.accounts.first { $0.id == setup.b }?.needsSignIn == true)
        #expect(setup.store.accounts.first { $0.id == setup.a }?.needsSignIn == false)
        #expect(model.badge(accountID: setup.b, companyID: "company-3") == nil)
        #expect(model.badge(accountID: setup.a, companyID: "company-1") == 3)
    }

    @Test func aSignedOutServerIsNotCalled() async throws {
        let setup = try twoAccounts()
        await setup.store.signOut(setup.b)
        let before = setup.serverB.allRequests.count
        let model = AccountsModel(store: setup.store, poller: Poller(sleep: TestSleeper(ticks: 0).sleep))

        await model.refresh()

        #expect(setup.serverB.allRequests.count == before)
        #expect(section(model, setup.b)?.account.needsSignIn == true)
        #expect(section(model, setup.b)?.companies.isEmpty == true)
        #expect(model.badge(accountID: setup.a, companyID: "company-1") == 3)
    }

    @Test func aFailedCompanyListShowsAnErrorOnThatServerOnly() async throws {
        let setup = try twoAccounts()
        setup.serverB.on("GET", "/api/companies", .init(status: 503, body: JSON.unavailable))
        let model = AccountsModel(store: setup.store, poller: Poller(sleep: TestSleeper(ticks: 0).sleep))

        await model.refresh()

        #expect(section(model, setup.b)?.errorMessage != nil)
        #expect(section(model, setup.b)?.companies.isEmpty == true)
        #expect(setup.store.accounts.first { $0.id == setup.b }?.needsSignIn == false)
        #expect(section(model, setup.a)?.errorMessage == nil)
        #expect(section(model, setup.a)?.companies.count == 2)
    }

    @Test func aFailedBadgeKeepsTheLastCount() async throws {
        let setup = try twoAccounts()
        setup.serverA.on(
            "GET", Self.badgesPath("company-1"),
            .ok(Self.badges(inbox: 3)), .init(status: 503, body: JSON.unavailable)
        )
        let model = AccountsModel(store: setup.store, poller: Poller(sleep: TestSleeper(ticks: 0).sleep))

        await model.refresh()
        await model.poll()

        #expect(setup.serverA.requests("GET", Self.badgesPath("company-1")).count == 2)
        #expect(model.badge(accountID: setup.a, companyID: "company-1") == 3)
        #expect(section(model, setup.a)?.companies.count == 2)
    }

    // MARK: Poll

    @Test func pollRefetchesBadgesOnly() async throws {
        let setup = try twoAccounts()
        setup.serverA.on(
            "GET", Self.badgesPath("company-1"),
            .ok(Self.badges(inbox: 3)), .ok(Self.badges(inbox: 5))
        )
        let model = AccountsModel(store: setup.store, poller: Poller(sleep: TestSleeper(ticks: 0).sleep))
        await model.refresh()

        await model.poll()

        #expect(model.badge(accountID: setup.a, companyID: "company-1") == 5)
        #expect(setup.serverA.requests("GET", "/api/companies").count == 1)
        #expect(setup.serverB.requests("GET", "/api/companies").count == 1)
        #expect(setup.serverB.requests("GET", Self.badgesPath("company-3")).count == 2)
    }

    @Test func runPollingPollsEveryIntervalUntilCancelled() async throws {
        let setup = try twoAccounts()
        let sleeper = TestSleeper(ticks: 2)
        let model = AccountsModel(store: setup.store, poller: Poller(sleep: sleeper.sleep))
        await model.refresh()

        await model.runPolling()

        #expect(sleeper.durations == [Poller.interval, Poller.interval, Poller.interval])
        #expect(setup.serverA.requests("GET", Self.badgesPath("company-1")).count == 3)
        #expect(setup.serverA.requests("GET", "/api/companies").count == 1)
    }

    // MARK: Switch

    @Test func switchingToACompanyOfAnotherServerSelectsBothAndPersists() async throws {
        let setup = try twoAccounts()
        let model = AccountsModel(store: setup.store, poller: Poller(sleep: TestSleeper(ticks: 0).sleep))
        await model.refresh()

        try model.switchTo(accountID: setup.b, companyID: "company-3")

        #expect(setup.store.currentAccountID == setup.b)
        #expect(setup.store.currentAccount?.selectedCompanyId == "company-3")
        #expect(setup.store.route == .home(setup.b))
        #expect(model.isCurrent(accountID: setup.b, companyID: "company-3"))
        #expect(!model.isCurrent(accountID: setup.a, companyID: "company-1"))
        // Server A keeps its own company for when the user comes back.
        #expect(setup.store.accounts.first { $0.id == setup.a }?.selectedCompanyId == "company-1")

        let reloaded = makeStore(file: setup.file, credentials: setup.credentials)
        try reloaded.load()
        #expect(reloaded.currentAccountID == setup.b)
        #expect(reloaded.currentAccount?.selectedCompanyId == "company-3")
    }

    @Test func switchingCompanyOnTheSameServer() async throws {
        let setup = try twoAccounts()
        let model = AccountsModel(store: setup.store, poller: Poller(sleep: TestSleeper(ticks: 0).sleep))
        await model.refresh()

        try model.switchTo(accountID: setup.a, companyID: "company-2")

        #expect(setup.store.currentAccountID == setup.a)
        #expect(setup.store.currentAccount?.selectedCompanyId == "company-2")
        #expect(model.isCurrent(accountID: setup.a, companyID: "company-2"))
    }

    @Test func switchingToAnUnknownAccountThrowsAndChangesNothing() async throws {
        let setup = try twoAccounts()
        let model = AccountsModel(store: setup.store, poller: Poller(sleep: TestSleeper(ticks: 0).sleep))

        #expect(throws: AccountStoreError.unknownAccount) {
            try model.switchTo(accountID: UUID(), companyID: "company-1")
        }
        #expect(setup.store.currentAccountID == setup.a)
        #expect(setup.store.currentAccount?.selectedCompanyId == "company-1")
    }

    // MARK: Sign out and remove

    @Test func signOutRevokesWithThatKeyAndDeletesOnlyThatKey() async throws {
        let setup = try twoAccounts()
        let model = AccountsModel(store: setup.store, poller: Poller(sleep: TestSleeper(ticks: 0).sleep))
        await model.refresh()

        await model.signOut(setup.b)

        let revoke = setup.serverB.requests("POST", "/api/cli-auth/revoke-current")
        #expect(revoke.count == 1)
        #expect(revoke.first?.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.keyB)")
        #expect(setup.serverA.requests("POST", "/api/cli-auth/revoke-current").isEmpty)
        #expect(try setup.credentials.apiKey(for: setup.b) == nil)
        #expect(try setup.credentials.apiKey(for: setup.a) == Self.keyA)
        // The server stays in the list, signed out, so the user can sign in again.
        #expect(section(model, setup.b)?.account.needsSignIn == true)
        #expect(section(model, setup.b)?.companies.isEmpty == true)
        #expect(model.badge(accountID: setup.b, companyID: "company-3") == nil)
        #expect(setup.store.currentAccountID == setup.a)
    }

    @Test func signOutDeletesTheKeyEvenWhenTheRevokeFails() async throws {
        let setup = try twoAccounts()
        setup.serverB.on("POST", "/api/cli-auth/revoke-current", .init(status: 503, body: JSON.unavailable))
        let model = AccountsModel(store: setup.store, poller: Poller(sleep: TestSleeper(ticks: 0).sleep))
        await model.refresh()

        await model.signOut(setup.b)

        #expect(try setup.credentials.apiKey(for: setup.b) == nil)
        #expect(section(model, setup.b)?.account.needsSignIn == true)
    }

    @Test func removeForgetsTheServerAndItsKey() async throws {
        let setup = try twoAccounts()
        let model = AccountsModel(store: setup.store, poller: Poller(sleep: TestSleeper(ticks: 0).sleep))
        await model.refresh()

        try await model.remove(setup.b)

        #expect(model.sections.map(\.account.id) == [setup.a])
        #expect(setup.store.accounts.map(\.id) == [setup.a])
        #expect(try setup.credentials.apiKey(for: setup.b) == nil)
        #expect(setup.serverB.requests("POST", "/api/cli-auth/revoke-current").count == 1)
        #expect(model.badge(accountID: setup.b, companyID: "company-3") == nil)
    }

    @Test func aServerAddedAfterTheFirstLoadShowsOnTheNextRefresh() async throws {
        let setup = try twoAccounts()
        let model = AccountsModel(store: setup.store, poller: Poller(sleep: TestSleeper(ticks: 0).sleep))
        await model.refresh()
        let serverC = StubServer()
        serverC.on("GET", "/api/companies", .ok(JSON.oneCompany))
        serverC.on("GET", Self.badgesPath("company-1"), .ok(Self.badges(inbox: 7)))
        let c = try setup.store.saveSignIn(
            server: serverC.address, me: try decodeMe(), apiKey: JSON.key, approvedAt: iso(JSON.approvedAt)
        )

        await model.refresh()

        #expect(model.sections.map(\.account.id) == [setup.a, setup.b, c.id])
        #expect(model.badge(accountID: c.id, companyID: "company-1") == 7)
        // Same company id on another server is a different badge.
        #expect(model.badge(accountID: setup.a, companyID: "company-1") == 3)
    }

    // MARK: Secrets

    @Test func noKeyIsLogged() async throws {
        let log = LogSink()
        let setup = try twoAccounts(log: log)
        setup.serverB.on("GET", "/api/companies", .init(status: 401, body: JSON.unauthorized))
        let model = AccountsModel(store: setup.store, poller: Poller(sleep: TestSleeper(ticks: 0).sleep))

        await model.refresh()
        await model.poll()
        await model.signOut(setup.a)

        #expect(!log.lines.isEmpty)
        for line in log.lines {
            #expect(!line.contains("pcp_board_"))
        }
    }
}
