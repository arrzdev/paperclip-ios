import Foundation
import PaperclipAPI
import Testing
@testable import PaperclipIOS

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AccountStoreTests {
    let approvedAt = iso(JSON.approvedAt)
    let revokePath = "/api/cli-auth/revoke-current"

    @Test func startsEmptyWithoutAFile() throws {
        let store = makeStore()
        try store.load()
        #expect(store.accounts.isEmpty)
        #expect(store.currentAccount == nil)
        #expect(store.currentClient == nil)
        #expect(store.route == .addServer)
    }

    @Test func savedSignInPersistsMetadataAndKeepsTheKeyInTheKeychainOnly() throws {
        let file = tempAccountsFile()
        let credentials = InMemoryCredentialStore()
        let server = StubServer()
        let store = makeStore(file: file, credentials: credentials)

        let account = try store.saveSignIn(server: server.address, me: try decodeMe(), apiKey: JSON.key, approvedAt: approvedAt)

        #expect(account.server == server.address)
        #expect(account.userId == "user-1")
        #expect(account.userName == "Board")
        #expect(account.companyIds == ["company-1", "company-2"])
        #expect(account.selectedCompanyId == nil)
        #expect(account.keyExpiresAt == approvedAt.addingTimeInterval(Account.keyLifetime))
        #expect(!account.needsSignIn)
        #expect(store.currentAccount?.id == account.id)
        #expect(try credentials.apiKey(for: account.id) == JSON.key)

        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains(server.host))
        #expect(!text.contains(JSON.key))

        let reloaded = makeStore(file: file, credentials: credentials)
        try reloaded.load()
        #expect(reloaded.accounts == store.accounts)
        #expect(reloaded.currentAccount?.id == account.id)
    }

    @Test func signingInToTheSameServerAgainUpdatesTheAccount() throws {
        let server = StubServer()
        let credentials = InMemoryCredentialStore()
        let store = makeStore(credentials: credentials)
        let first = try store.saveSignIn(server: server.address, me: try decodeMe(), apiKey: "pcp_board_OLD", approvedAt: approvedAt)
        try store.selectCompany("company-2", for: first.id)

        let typedAgain = try ServerAddress(server.host + "/api/")
        let second = try store.saveSignIn(server: typedAgain, me: try decodeMe(), apiKey: JSON.key, approvedAt: approvedAt)

        #expect(second.id == first.id)
        #expect(second.selectedCompanyId == "company-2")
        #expect(store.accounts.count == 1)
        #expect(try credentials.apiKey(for: first.id) == JSON.key)
    }

    @Test func switchingAccountChangesTheClientServerAndKey() throws {
        let a = StubServer()
        let b = StubServer()
        let store = makeStore()
        let accountA = try store.saveSignIn(server: a.address, me: try decodeMe(), apiKey: "pcp_board_A", approvedAt: approvedAt)
        let accountB = try store.saveSignIn(server: b.address, me: try decodeMe(), apiKey: "pcp_board_B", approvedAt: approvedAt)
        #expect(store.currentAccount?.id == accountB.id)

        try store.select(accountA.id)
        #expect(store.currentClient?.server == a.address)
        #expect(store.currentClient?.apiKey == "pcp_board_A")

        try store.select(accountB.id)
        #expect(store.currentClient?.server == b.address)
        #expect(store.currentClient?.apiKey == "pcp_board_B")
    }

    @Test func selectedCompanyIsPerAccountAndPersisted() throws {
        let file = tempAccountsFile()
        let credentials = InMemoryCredentialStore()
        let store = makeStore(file: file, credentials: credentials)
        let account = try store.saveSignIn(server: StubServer().address, me: try decodeMe(), apiKey: JSON.key, approvedAt: approvedAt)
        #expect(store.route == .pickCompany(account.id))

        try store.selectCompany("company-2", for: account.id)
        #expect(store.route == .home(account.id))

        let reloaded = makeStore(file: file, credentials: credentials)
        try reloaded.load()
        #expect(reloaded.currentAccount?.selectedCompanyId == "company-2")
    }

    @Test func signOutRevokesTheKeyThenDeletesIt() async throws {
        let server = StubServer()
        server.on("POST", revokePath, .init(body: JSON.revoked))
        let credentials = InMemoryCredentialStore()
        let store = makeStore(credentials: credentials)
        let account = try store.saveSignIn(server: server.address, me: try decodeMe(), apiKey: JSON.key, approvedAt: approvedAt)

        await store.signOut(account.id)

        let revoke = try #require(server.requests("POST", revokePath).first)
        #expect(revoke.value(forHTTPHeaderField: "Authorization") == "Bearer \(JSON.key)")
        #expect(try credentials.apiKey(for: account.id) == nil)
        #expect(store.accounts.first?.needsSignIn == true)
        #expect(store.route == .reSignIn(account.id))
    }

    @Test func signOutDeletesTheKeyEvenWhenRevokeFails() async throws {
        let server = StubServer()
        server.on("POST", revokePath, .init(status: 500, body: #"{"error":"boom"}"#))
        let credentials = InMemoryCredentialStore()
        let store = makeStore(credentials: credentials)
        let account = try store.saveSignIn(server: server.address, me: try decodeMe(), apiKey: JSON.key, approvedAt: approvedAt)

        await store.signOut(account.id)

        #expect(server.requests("POST", revokePath).count == 1)
        #expect(try credentials.apiKey(for: account.id) == nil)
        #expect(store.accounts.first?.needsSignIn == true)
    }

    @Test func removeSignsOutAndForgetsTheAccount() async throws {
        let a = StubServer()
        let b = StubServer()
        a.on("POST", revokePath, .init(body: JSON.revoked))
        b.on("POST", revokePath, .init(body: JSON.revoked))
        let file = tempAccountsFile()
        let credentials = InMemoryCredentialStore()
        let store = makeStore(file: file, credentials: credentials)
        let accountA = try store.saveSignIn(server: a.address, me: try decodeMe(), apiKey: "pcp_board_A", approvedAt: approvedAt)
        let accountB = try store.saveSignIn(server: b.address, me: try decodeMe(), apiKey: "pcp_board_B", approvedAt: approvedAt)

        try await store.remove(accountB.id)

        #expect(store.accounts.map(\.id) == [accountA.id])
        #expect(store.currentAccount?.id == accountA.id)
        #expect(try credentials.apiKey(for: accountB.id) == nil)
        #expect(try credentials.apiKey(for: accountA.id) == "pcp_board_A")
        #expect(b.requests("POST", revokePath).count == 1)
        #expect(a.requests("POST", revokePath).isEmpty)

        let reloaded = makeStore(file: file, credentials: credentials)
        try reloaded.load()
        #expect(reloaded.accounts.map(\.id) == [accountA.id])
    }

    @Test func unauthorizedMarksTheAccountNeedsSignInAndDropsTheKey() async throws {
        let server = StubServer()
        server.on("GET", "/api/companies", .init(status: 401, body: JSON.unauthorized))
        let file = tempAccountsFile()
        let credentials = InMemoryCredentialStore()
        let store = makeStore(file: file, credentials: credentials)
        let account = try store.saveSignIn(server: server.address, me: try decodeMe(), apiKey: JSON.key, approvedAt: approvedAt)

        await #expect(throws: APIError.unauthorized) {
            try await store.call(account.id) { try await $0.companies() }
        }

        #expect(server.requests("GET", "/api/companies").count == 1)
        #expect(store.accounts.first?.needsSignIn == true)
        #expect(try credentials.apiKey(for: account.id) == nil)
        #expect(store.route == .reSignIn(account.id))

        let reloaded = makeStore(file: file, credentials: credentials)
        try reloaded.load()
        #expect(reloaded.accounts.first?.needsSignIn == true)
    }

    @Test func keyExpiryWarningStartsThreeDaysBefore() throws {
        let now = iso("2026-10-13T12:00:00.000Z")
        var account = Account(
            id: UUID(), server: try ServerAddress("paperclip.test"),
            userId: nil, userName: nil, userEmail: nil, companyIds: [], selectedCompanyId: nil,
            keyExpiresAt: now.addingTimeInterval(4 * 24 * 60 * 60), needsSignIn: false
        )
        #expect(account.keyStatus(now: now) == .valid)

        let soon = now.addingTimeInterval(3 * 24 * 60 * 60)
        account.keyExpiresAt = soon
        #expect(account.keyStatus(now: now) == .expiresSoon(soon))

        account.keyExpiresAt = now.addingTimeInterval(-1)
        #expect(account.keyStatus(now: now) == .expired)

        account.needsSignIn = true
        #expect(account.keyStatus(now: now) == .needsSignIn)
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct CompanyPickerModelTests {
    let approvedAt = iso(JSON.approvedAt)

    @Test func listsCompaniesAndSavesTheChoice() async throws {
        let server = StubServer()
        server.on("GET", "/api/companies", .init(body: JSON.companies))
        let store = makeStore()
        try store.saveSignIn(server: server.address, me: try decodeMe(), apiKey: JSON.key, approvedAt: approvedAt)
        let model = CompanyPickerModel(store: store)

        await model.load()

        #expect(model.companies.map(\.name) == ["Acme", "Globex"])
        #expect(model.errorMessage == nil)
        #expect(model.selectedCompanyId == nil)
        let globex = try #require(model.companies.last)
        try model.select(globex)
        #expect(store.currentAccount?.selectedCompanyId == "company-2")
        #expect(model.selectedCompanyId == "company-2")
    }

    @Test func aSingleCompanyIsSelectedAutomatically() async throws {
        let server = StubServer()
        server.on("GET", "/api/companies", .init(body: JSON.oneCompany))
        let store = makeStore()
        let account = try store.saveSignIn(server: server.address, me: try decodeMe(), apiKey: JSON.key, approvedAt: approvedAt)

        await CompanyPickerModel(store: store).load()

        #expect(store.currentAccount?.selectedCompanyId == "company-1")
        #expect(store.route == .home(account.id))
    }

    @Test func unauthorizedSendsTheAccountToSignIn() async throws {
        let server = StubServer()
        server.on("GET", "/api/companies", .init(status: 401, body: JSON.unauthorized))
        let store = makeStore()
        let account = try store.saveSignIn(server: server.address, me: try decodeMe(), apiKey: JSON.key, approvedAt: approvedAt)
        let model = CompanyPickerModel(store: store)

        await model.load()

        #expect(model.companies.isEmpty)
        #expect(model.errorMessage != nil)
        #expect(store.route == .reSignIn(account.id))
    }
}
