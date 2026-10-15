import Foundation
import PaperclipAPI
import Testing
@testable import PaperclipIOS

/// Me → More, read only (spec §3): Activity, Approvals history, Goals, Costs,
/// and "Open in web" for everything the app cuts.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct MoreModelsTests {
    static let activityPath = "/api/companies/company-1/activity"
    static let agentsPath = "/api/companies/company-1/agents"
    static let approvalsPath = "/api/companies/company-1/approvals"
    static let goalsPath = "/api/companies/company-1/goals"
    static let costsPath = "/api/companies/company-1/costs/summary"
    static let companyPath = "/api/companies/company-1"

    static func event(
        _ id: String,
        action: String,
        actorType: String,
        actorId: String,
        agentId: String? = nil,
        entityType: String = "issue",
        entityId: String = "issue-1",
        details: String = "null",
        createdAt: String = "2026-10-14T09:00:00.000Z"
    ) -> String {
        let agent = agentId.map { "\"" + $0 + "\"" } ?? "null"
        return #"{"id":"\#(id)","companyId":"company-1","actorType":"\#(actorType)","actorId":"\#(actorId)","action":"\#(action)","entityType":"\#(entityType)","entityId":"\#(entityId)","agentId":\#(agent),"runId":null,"details":\#(details),"createdAt":"\#(createdAt)"}"#
    }

    static func goal(_ id: String, title: String, parent: String? = nil, level: String = "team", status: String = "active") -> String {
        let parentText = parent.map { "\"" + $0 + "\"" } ?? "null"
        return #"{"id":"\#(id)","companyId":"company-1","title":"\#(title)","description":null,"level":"\#(level)","status":"\#(status)","parentId":\#(parentText),"ownerAgentId":null,"createdAt":"2026-10-03T22:23:09.561Z","updatedAt":"2026-10-03T22:23:09.561Z"}"#
    }

    static func costs(spend: Int, budget: Int, utilization: Double) -> String {
        #"{"companyId":"company-1","spendCents":\#(spend),"budgetCents":\#(budget),"utilizationPercent":\#(utilization)}"#
    }

    // MARK: Activity

    private func activityRows(_ model: ActivityModel) -> [ActivityRow] {
        if case .loaded(let rows) = model.state { return rows }
        return []
    }

    @Test func activityNamesActorsAndDescribesTheEvent() async throws {
        let server = StubServer()
        server.on("GET", Self.activityPath, .ok(list(
            Self.event("e1", action: "issue.comment_added", actorType: "agent", actorId: "agent-1", agentId: "agent-1",
                       details: #"{"identifier":"PAP-12","issueTitle":"Fix the login","bodySnippet":"Done"}"#),
            Self.event("e2", action: "agent.paused", actorType: "user", actorId: "user-1",
                       entityType: "agent", entityId: "agent-2"),
            Self.event("e3", action: "approval.approved", actorType: "user", actorId: "user-9",
                       entityType: "approval", entityId: "approval-1"),
            Self.event("e4", action: "environment.lease_released", actorType: "system", actorId: "system",
                       entityType: "environment_lease", entityId: "lease-1",
                       details: #"{"driver":"local","nested":{"a":[1,2]}}"#)
        )))
        server.on("GET", Self.agentsPath, .ok(TaskDetailModelTests.agents))
        let (store, id) = try signedInStore(server)
        let model = ActivityModel(store: store, accountID: id)

        await model.refresh()

        let rows = activityRows(model)
        #expect(rows.map(\.id) == ["e1", "e2", "e3", "e4"])
        #expect(rows.map(\.actor) == ["Luis", "You", "User", "System"])
        #expect(rows.map(\.text) == [
            "Issue comment added · PAP-12 Fix the login",
            "Agent paused",
            "Approval approved",
            "Environment lease released",
        ])
        #expect(rows.first?.date == iso("2026-10-14T09:00:00.000Z"))
        let request = try #require(server.requests("GET", Self.activityPath).first)
        #expect(query(request)["limit"] == String(ActivityModel.limit))
    }

    @Test func onlyIssueEventsOpenATask() async throws {
        let server = StubServer()
        server.on("GET", Self.activityPath, .ok(list(
            Self.event("e1", action: "issue.updated", actorType: "user", actorId: "user-1", entityId: "issue-7"),
            Self.event("e2", action: "agent.paused", actorType: "user", actorId: "user-1", entityType: "agent", entityId: "agent-2")
        )))
        server.on("GET", Self.agentsPath, .ok("[]"))
        let (store, id) = try signedInStore(server)
        let model = ActivityModel(store: store, accountID: id)

        await model.refresh()

        #expect(activityRows(model).map(\.taskRoute) == [TaskRoute(issueID: "issue-7"), nil])
    }

    @Test func failedAgentsOnlyLoseTheNames() async throws {
        let server = StubServer()
        server.on("GET", Self.activityPath, .ok(list(
            Self.event("e1", action: "issue.updated", actorType: "agent", actorId: "agent-1", agentId: "agent-1")
        )))
        server.on("GET", Self.agentsPath, .init(status: 503, body: JSON.unavailable))
        let (store, id) = try signedInStore(server)
        let model = ActivityModel(store: store, accountID: id)

        await model.refresh()

        #expect(activityRows(model).map(\.actor) == ["Agent"])
    }

    @Test func noActivityIsEmptyAndA401GoesToSignIn() async throws {
        let server = StubServer()
        server.on("GET", Self.activityPath, .ok("[]"), .init(status: 401, body: JSON.unauthorized))
        server.on("GET", Self.agentsPath, .ok("[]"))
        let (store, id) = try signedInStore(server)
        let model = ActivityModel(store: store, accountID: id)

        await model.refresh()
        #expect(model.state == .empty)

        await model.refresh()
        #expect(model.state == .needsSignIn)
        #expect(store.route == .reSignIn(id))
    }

    // MARK: Approvals history

    @Test func approvalsHistoryAsksForEveryStatusNewestFirst() async throws {
        let server = StubServer()
        server.on("GET", Self.approvalsPath, .ok(list(
            ApprovalDetailModelTests.approval(id: "old", status: "approved", createdAt: "2026-10-10T08:00:00.000Z"),
            ApprovalDetailModelTests.approval(id: "new", status: "pending", createdAt: "2026-10-14T08:00:00.000Z"),
            ApprovalDetailModelTests.approval(id: "mid", status: "rejected", createdAt: "2026-10-12T08:00:00.000Z")
        )))
        let (store, id) = try signedInStore(server)
        let model = ApprovalsHistoryModel(store: store, accountID: id)

        await model.refresh()

        guard case .loaded(let approvals) = model.state else {
            Testing.Issue.record("expected approvals, got \(model.state)")
            return
        }
        #expect(approvals.map(\.id) == ["new", "mid", "old"])
        #expect(approvals.map(\.status) == [.pending, .rejected, .approved])
        let request = try #require(server.requests("GET", Self.approvalsPath).first)
        #expect(query(request)["status"] == nil)
        #expect(approvals.first.map(ApprovalsHistoryModel.route(for:)) == ApprovalRoute(approvalID: "new"))
    }

    @Test func noApprovalsIsEmptyAndAFailureIsAnError() async throws {
        let server = StubServer()
        server.on("GET", Self.approvalsPath, .ok("[]"), .init(status: 503, body: JSON.unavailable))
        let (store, id) = try signedInStore(server)
        let model = ApprovalsHistoryModel(store: store, accountID: id)

        await model.refresh()
        #expect(model.state == .empty)

        await model.refresh()
        if case .error = model.state {} else { Testing.Issue.record("expected an error, got \(model.state)") }
    }

    // MARK: Goals

    private func goalRows(_ model: GoalsModel) -> [GoalRow] {
        if case .loaded(let rows) = model.state { return rows }
        return []
    }

    @Test func goalsAreATreeInServerOrder() async throws {
        let server = StubServer()
        server.on("GET", Self.goalsPath, .ok(list(
            Self.goal("child-b", title: "Child B", parent: "root-1"),
            Self.goal("root-1", title: "Root 1", level: "company"),
            Self.goal("grandchild", title: "Grandchild", parent: "child-a", level: "agent"),
            Self.goal("root-2", title: "Root 2", level: "company", status: "planned"),
            Self.goal("child-a", title: "Child A", parent: "root-1"),
            Self.goal("orphan", title: "Orphan", parent: "gone")
        )))
        let (store, id) = try signedInStore(server)
        let model = GoalsModel(store: store, accountID: id)

        await model.refresh()

        let rows = goalRows(model)
        #expect(rows.map(\.goal.title) == ["Root 1", "Child B", "Child A", "Grandchild", "Root 2", "Orphan"])
        #expect(rows.map(\.depth) == [0, 1, 1, 2, 0, 0])
        #expect(rows.map(\.id) == ["root-1", "child-b", "child-a", "grandchild", "root-2", "orphan"])
    }

    @Test func aParentCycleShowsEveryGoalOnce() async throws {
        let server = StubServer()
        server.on("GET", Self.goalsPath, .ok(list(
            Self.goal("a", title: "A", parent: "b"),
            Self.goal("b", title: "B", parent: "a"),
            Self.goal("self", title: "Self", parent: "self")
        )))
        let (store, id) = try signedInStore(server)
        let model = GoalsModel(store: store, accountID: id)

        await model.refresh()

        let rows = goalRows(model)
        #expect(rows.count == 3)
        #expect(Set(rows.map(\.id)) == ["a", "b", "self"])
    }

    @Test func noGoalsIsEmpty() async throws {
        let server = StubServer()
        server.on("GET", Self.goalsPath, .ok("[]"))
        let (store, id) = try signedInStore(server)
        let model = GoalsModel(store: store, accountID: id)

        await model.refresh()

        #expect(model.state == .empty)
    }

    // MARK: Costs

    @Test func costsShowSpendBudgetAndUse() async throws {
        let server = StubServer()
        server.on("GET", Self.costsPath, .ok(Self.costs(spend: 1234, budget: 5000, utilization: 24.68)))
        let (store, id) = try signedInStore(server)
        let model = CostsModel(store: store, accountID: id)

        await model.refresh()

        #expect(model.state == .loaded(CostLine(spent: "$12.34", budget: "$50.00", utilization: "25%")))
        if case .loaded(let line) = model.state {
            #expect(line.text == "$12.34 of $50.00 · 25%")
        }
    }

    @Test func costsWithoutABudget() async throws {
        let server = StubServer()
        server.on("GET", Self.costsPath, .ok(Self.costs(spend: 5, budget: 0, utilization: 0)))
        let (store, id) = try signedInStore(server)
        let model = CostsModel(store: store, accountID: id)

        await model.refresh()

        #expect(model.state == .loaded(CostLine(spent: "$0.05", budget: nil, utilization: nil)))
        if case .loaded(let line) = model.state {
            #expect(line.text == "$0.05 · No budget")
        }
    }

    @Test func aCostsFailureIsAnErrorAndA401GoesToSignIn() async throws {
        let server = StubServer()
        server.on("GET", Self.costsPath, .init(status: 503, body: JSON.unavailable), .init(status: 401, body: JSON.unauthorized))
        let (store, id) = try signedInStore(server)
        let model = CostsModel(store: store, accountID: id)

        await model.refresh()
        if case .error = model.state {} else { Testing.Issue.record("expected an error, got \(model.state)") }

        await model.refresh()
        #expect(model.state == .needsSignIn)
    }

    // MARK: Open in web

    @Test func everyCutFeatureHasAWebPage() {
        #expect(WebLink.cut == [
            .companySettings, .secrets, .toolConnections, .plugins, .skills, .routines, .orgChart, .hireAgent,
        ])
        #expect(WebLink.cut.map { $0.path(prefix: "PAP") } == [
            "/PAP/company/settings",
            "/PAP/company/settings/secrets",
            "/PAP/company/settings/tools",
            "/PAP/company/settings/instance/plugins",
            "/PAP/skills/studio",
            "/PAP/routines",
            "/PAP/org",
            "/PAP/agents/new",
        ])
        #expect(WebLink.cut.allSatisfy { !$0.title.isEmpty })
        #expect(WebLink.agent(urlKey: "ada").path(prefix: "PAP") == "/PAP/agents/ada")
    }

    @Test func webLinksUseTheServerAndTheCompanyPrefix() async throws {
        let server = StubServer()
        server.on("GET", Self.companyPath, .ok(#"{"id":"company-1","name":"Acme","issuePrefix":"ACM","status":"active"}"#))
        let (store, id) = try signedInStore(server)
        let model = MoreModel(store: store, accountID: id)
        #expect(model.url(for: .routines) == nil)

        await model.refresh()

        #expect(model.companyName == "Acme")
        #expect(model.url(for: .routines)?.absoluteString == "https://\(server.host)/ACM/routines")
        #expect(model.url(for: .agent(urlKey: "ada"))?.absoluteString == "https://\(server.host)/ACM/agents/ada")
    }

    @Test func noPrefixMeansNoWebLink() async throws {
        let server = StubServer()
        server.on("GET", Self.companyPath, .init(status: 503, body: JSON.unavailable))
        let (store, id) = try signedInStore(server)
        let model = MoreModel(store: store, accountID: id)

        await model.refresh()

        #expect(model.url(for: .routines) == nil)
    }
}
