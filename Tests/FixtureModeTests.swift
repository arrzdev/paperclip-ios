import Foundation
import PaperclipAPI
import Testing
@testable import PaperclipIOS

// UI-test mode: the fake account and the fixture server the UI tests run on.

@MainActor
struct FixtureModeTests {
    @Test func signsInOneFakeAccountWithItsCompany() throws {
        let store = FixtureMode.makeStore()
        #expect(store.accounts.count == 1)
        let account = try #require(store.currentAccount)
        #expect(account.server.displayName == "paperclip.test")
        #expect(account.selectedCompanyId == "company-1")
        #expect(store.route == .home(account.id))
        #expect(store.currentClient?.apiKey == FixtureMode.apiKey)
    }

    @Test func routesEveryScreenRequestToAFixture() {
        func get(_ path: String, _ query: [String: String] = [:]) -> FixtureRoute {
            FixtureRoutes.route(method: "GET", path: path, query: query)
        }
        #expect(get("/api/companies") == .file("companies"))
        #expect(get("/api/companies/company-1") == .first("companies"))
        #expect(get("/api/companies/company-1/issues", ["touchedByUserId": "me"]) == .file("inbox-issues"))
        #expect(get("/api/companies/company-1/issues", ["unreadForUserId": "me"]) == .file("inbox-issues"))
        #expect(get("/api/companies/company-1/issues", ["limit": "50"]) == .file("issues"))
        #expect(get("/api/companies/company-1/costs/summary") == .file("costs-summary"))
        #expect(get("/api/companies/company-1/live-runs") == .file("company-live-runs"))
        #expect(get("/api/issues/issue-1/comments", ["order": "asc"]) == .list("comment"))
        #expect(get("/api/issues/issue-1/comments", ["after": "c-1"]) == .json("[]"))
        #expect(get("/api/agents/agent-1") == .file("agent"))
        #expect(get("/api/approvals/approval-1/comments") == .file("approval-comments"))
        #expect(get("/api/nothing/here") == .notFound)
        #expect(FixtureRoutes.route(method: "POST", path: "/api/agents/a/pause", query: [:]) == .file("agent-paused"))
        #expect(FixtureRoutes.route(method: "POST", path: "/api/issues/i/read", query: [:]) == .json("{}"))
    }

    @Test func answersAMissingRouteWith404() async throws {
        let client = try #require(FixtureMode.makeStore().currentClient)
        await #expect(throws: APIError.notFound) {
            _ = try await client.document(issueId: "issue-1", key: "plan")
        }
    }

    /// Every list the UI tests open decodes from the bundled fixtures.
    @Test func screensDecodeFromBundledFixtures() async throws {
        let client = try #require(FixtureMode.makeStore().currentClient)
        let company = "company-1"
        #expect(try await client.companies().isEmpty == false)
        #expect(try await client.company(id: company).id == company)
        _ = try await client.sidebarBadges(companyId: company)
        _ = try await client.attention(companyId: company)
        _ = try await client.dashboard(companyId: company)
        #expect(try await client.issues(companyId: company, query: .inbox).isEmpty == false)
        #expect(try await client.issues(companyId: company).isEmpty == false)
        _ = try await client.issue(id: "issue-1")
        #expect(try await client.commentThread(issueId: "issue-1").count == 1)
        _ = try await client.comments(issueId: "issue-1", limit: 5)
        _ = try await client.interactions(issueId: "issue-1")
        _ = try await client.liveRuns(issueId: "issue-1")
        #expect(try await client.agents(companyId: company).isEmpty == false)
        _ = try await client.agent(id: "agent-1")
        _ = try await client.companyLiveRuns(companyId: company)
        _ = try await client.runLog(runId: "run-1")
        #expect(try await client.activity(companyId: company, limit: 100).isEmpty == false)
        #expect(try await client.goals(companyId: company).isEmpty == false)
        _ = try await client.costSummary(companyId: company)
        _ = try await client.projects(companyId: company)
        #expect(try await client.approvals(companyId: company, status: .pending).isEmpty == false)
        _ = try await client.approval(id: "approval-1")
        _ = try await client.approvalComments(approvalId: "approval-1")
        try await client.markRead(issueId: "issue-1")
    }
}
