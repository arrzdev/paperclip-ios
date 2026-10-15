import Foundation
import PaperclipAPI
import Testing
@testable import PaperclipIOS

/// Approvals (spec §4 B.1–2): "Approval: <title>" cards on Today only while one
/// is pending, and Approval detail with the payload summary, the requester,
/// comments and Approve / Reject / Ask for changes, each with an optional note.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ApprovalDetailModelTests {
    let approvalPath = "/api/approvals/approval-1"
    let commentsPath = "/api/approvals/approval-1/comments"
    let agentsPath = "/api/companies/company-1/agents"
    let approvalsPath = "/api/companies/company-1/approvals"

    static func approval(
        id: String = "approval-1",
        status: String = "pending",
        agent: String? = "agent-1",
        user: String? = nil,
        payload: String = #"{"title":"Hire a designer","budgetMonthlyCents":5000}"#,
        createdAt: String = "2026-10-14T08:00:00.000Z",
        note: String? = nil
    ) -> String {
        func text(_ value: String?) -> String { value.map { "\"" + $0 + "\"" } ?? "null" }
        return #"{"id":"\#(id)","companyId":"company-1","type":"hire_agent","status":"\#(status)","requestedByAgentId":\#(text(agent)),"requestedByUserId":\#(text(user)),"payload":\#(payload),"decisionNote":\#(text(note)),"decidedByUserId":null,"decidedAt":null,"createdAt":"\#(createdAt)","updatedAt":"\#(createdAt)"}"#
    }

    static func comment(_ id: String, body: String, agent: Bool) -> String {
        let author = agent ? #""authorAgentId":"agent-1","authorUserId":null"# : #""authorAgentId":null,"authorUserId":"user-1""#
        return #"{"id":"\#(id)","companyId":"company-1","approvalId":"approval-1",\#(author),"body":"\#(body)","createdAt":"2026-10-14T08:30:00.000Z","updatedAt":"2026-10-14T08:30:00.000Z"}"#
    }

    private func makeServer(status: String = "pending") -> StubServer {
        let server = StubServer()
        server.on("GET", approvalPath, .ok(Self.approval(status: status)))
        server.on("GET", commentsPath, .ok(list(
            Self.comment("ac-1", body: "We need a designer.", agent: true),
            Self.comment("ac-2", body: "Budget?", agent: false)
        )))
        server.on("GET", agentsPath, .ok(TaskDetailModelTests.agents))
        return server
    }

    private func detail(_ server: StubServer, log: LogSink = LogSink()) throws -> (ApprovalDetailModel, AccountStore, UUID) {
        let (store, id) = try signedInStore(server, log: log)
        return (ApprovalDetailModel(store: store, accountID: id, approvalID: "approval-1"), store, id)
    }

    private func loaded(_ model: ApprovalDetailModel) -> ApprovalDetail? {
        if case .loaded(let detail) = model.state { return detail }
        return nil
    }

    // MARK: Today cards

    private func todayServer(approvals: String) -> StubServer {
        let server = StubServer()
        server.on("GET", "/api/companies/company-1/attention", .ok(TodayModelTests.feed()))
        server.on("GET", companyIssuesPath, .ok("[]"))
        server.on("GET", "/api/companies/company-1/dashboard", .ok(TodayModelTests.dashboard))
        server.on("GET", approvalsPath, .ok(approvals))
        return server
    }

    private func todayCards(_ server: StubServer) async throws -> (TodayModel, [NeedsYouCard]) {
        let (store, id) = try signedInStore(server)
        let model = TodayModel(store: store, accountID: id)
        await model.refresh()
        if case .loaded(let content) = model.state { return (model, content.needsYou) }
        return (model, [])
    }

    @Test func todayShowsPendingApprovalsNewestFirst() async throws {
        let server = todayServer(approvals: list(
            Self.approval(id: "approval-1", createdAt: "2026-10-14T08:00:00.000Z"),
            Self.approval(id: "approval-2", payload: #"{"summary":"Renew the domain"}"#, createdAt: "2026-10-14T09:00:00.000Z")
        ))
        let (_, cards) = try await todayCards(server)

        #expect(query(server.requests("GET", approvalsPath).first)["status"] == "pending")
        #expect(cards.map(\.id) == ["approval-2", "approval-1"])
        #expect(cards.map(\.kind) == [.approval, .approval])
        #expect(cards.map(\.title) == ["Approval: Renew the domain", "Approval: Hire a designer"])
        #expect(cards[0].approvalID == "approval-2")
        #expect(cards[0].approvalRoute == ApprovalRoute(approvalID: "approval-2"))
        #expect(cards[0].issueID == nil)
        #expect(cards[0].route == nil)
    }

    @Test func noPendingApprovalNoCard() async throws {
        let (model, cards) = try await todayCards(todayServer(approvals: "[]"))
        #expect(cards.isEmpty)
        #expect(model.state == .empty)
    }

    @Test func approvalAttentionItemsAreNotCardsTwice() async throws {
        let server = todayServer(approvals: list(Self.approval()))
        let item = TodayModelTests.attentionItem(
            id: "att-2", sourceKind: "approval", subjectKind: "approval", title: "Hire a designer",
            href: "/PAP/approvals/approval-1", whyNow: "Approval pending"
        )
        server.on("GET", "/api/companies/company-1/attention", .ok(TodayModelTests.feed(item)))
        let (_, cards) = try await todayCards(server)

        #expect(cards.map(\.id) == ["approval-1"])
    }

    @Test func approvalsUnauthorizedSendsTodayToSignIn() async throws {
        let server = todayServer(approvals: "[]")
        server.on("GET", approvalsPath, StubServer.Response(status: 401, body: JSON.unauthorized))
        let (store, id) = try signedInStore(server)
        let model = TodayModel(store: store, accountID: id)
        await model.refresh()

        #expect(model.state == .needsSignIn)
        #expect(store.route == .reSignIn(id))
    }

    // MARK: Detail

    @Test func startsLoading() throws {
        let (model, _, _) = try detail(makeServer())
        #expect(model.state == .loading)
        #expect(model.availableDecisions.isEmpty)
    }

    @Test func refreshLoadsTheApprovalItsSummaryRequesterAndComments() async throws {
        let (model, _, _) = try detail(makeServer())
        await model.refresh()

        let detail = try #require(loaded(model))
        #expect(detail.approval.title == "Hire a designer")
        #expect(detail.approval.summaryFields.map(\.label) == ["Budget monthly cents", "Title"])
        #expect(detail.comments.map(\.id) == ["ac-1", "ac-2"])
        #expect(model.requesterName == "Luis")
        #expect(model.authorName(for: detail.comments[0]) == "Luis")
        #expect(model.authorName(for: detail.comments[1]) == "You")
    }

    @Test func aRequesterWhoIsAUserOrUnknownAgent() async throws {
        let server = makeServer()
        server.on("GET", approvalPath, .ok(Self.approval(agent: nil, user: "user-1")))
        let (model, _, _) = try detail(server)
        await model.refresh()
        #expect(model.requesterName == "You")

        server.on("GET", approvalPath, .ok(Self.approval(agent: "agent-9")))
        await model.refresh()
        #expect(model.requesterName == "Agent")
    }

    @Test func agentsFailureNeverHidesTheApproval() async throws {
        let server = makeServer()
        server.on("GET", agentsPath, StubServer.Response(status: 500, body: JSON.unavailable))
        let (model, _, _) = try detail(server)
        await model.refresh()

        #expect(loaded(model) != nil)
        #expect(model.requesterName == "Agent")
    }

    @Test func errorAndUnauthorized() async throws {
        let server = makeServer()
        server.on("GET", approvalPath, StubServer.Response(status: 500, body: JSON.unavailable))
        let (model, store, id) = try detail(server)
        await model.refresh()
        #expect(model.state == .error(userMessage(for: APIError.server(status: 500, body: "Service unavailable"))))

        server.on("GET", approvalPath, StubServer.Response(status: 401, body: JSON.unauthorized))
        await model.refresh()
        #expect(model.state == .needsSignIn)
        #expect(store.route == .reSignIn(id))
    }

    @Test func decisionsFollowTheServerStatusRules() async throws {
        let cases: [(String, [ApprovalDecision])] = [
            ("pending", [.approve, .reject, .requestRevision]),
            ("revision_requested", [.approve, .reject]),
            ("approved", []),
            ("rejected", []),
            ("cancelled", []),
            ("pondering", []),
        ]
        for (status, decisions) in cases {
            let (model, _, _) = try detail(makeServer(status: status))
            await model.refresh()
            #expect(model.availableDecisions == decisions, "\(status)")
        }
        #expect(ApprovalDecision.approve.title == "Approve")
        #expect(ApprovalDecision.reject.title == "Reject")
        #expect(ApprovalDecision.requestRevision.title == "Ask for changes")
    }

    @Test func approveSendsTheTrimmedNoteAndShowsTheResult() async throws {
        let server = makeServer()
        server.on("POST", "/api/approvals/approval-1/approve", .ok(Self.approval(status: "approved", note: "Welcome")))
        let (model, _, _) = try detail(server)
        await model.refresh()

        #expect(await model.decide(.approve, note: "  Welcome \n"))

        let body = try #require(server.requests("POST", "/api/approvals/approval-1/approve").first.flatMap(jsonObject))
        #expect(body as? [String: String] == ["decisionNote": "Welcome"])
        #expect(loaded(model)?.approval.status == .approved)
        #expect(model.availableDecisions.isEmpty)
        #expect(model.actionError == nil)
    }

    @Test func aBlankNoteIsNotSent() async throws {
        let server = makeServer()
        server.on("POST", "/api/approvals/approval-1/request-revision", .ok(Self.approval(status: "revision_requested")))
        let (model, _, _) = try detail(server)
        await model.refresh()

        #expect(await model.decide(.requestRevision, note: "   "))

        let body = try #require(server.requests("POST", "/api/approvals/approval-1/request-revision").first.flatMap(jsonObject))
        #expect(body.isEmpty)
        #expect(model.availableDecisions == [.approve, .reject])
    }

    @Test func aFailedDecisionKeepsTheApprovalAndShowsWhy() async throws {
        let server = makeServer()
        server.on("POST", "/api/approvals/approval-1/reject", StubServer.Response(
            status: 422, body: #"{"error":"Only pending or revision requested approvals can be rejected"}"#
        ))
        let log = LogSink()
        let (model, _, _) = try detail(server, log: log)
        await model.refresh()

        #expect(await model.decide(.reject, note: "private-note-text") == false)

        #expect(loaded(model)?.approval.status == .pending)
        #expect(model.actionError == "Server error 422: Only pending or revision requested approvals can be rejected")
        #expect(!log.lines.contains { $0.contains("private-note-text") })
        model.dismissActionError()
        #expect(model.actionError == nil)
    }

    @Test func anUnauthorizedDecisionGoesToSignIn() async throws {
        let server = makeServer()
        server.on("POST", "/api/approvals/approval-1/approve", StubServer.Response(status: 401, body: JSON.unauthorized))
        let (model, store, id) = try detail(server)
        await model.refresh()

        #expect(await model.decide(.approve, note: "") == false)

        #expect(model.state == .needsSignIn)
        #expect(store.route == .reSignIn(id))
    }

    @Test func addCommentAppendsItAndABlankOneSendsNothing() async throws {
        let server = makeServer()
        server.on("POST", commentsPath, .ok(Self.comment("ac-3", body: "Fine by me.", agent: false)))
        let (model, _, _) = try detail(server)
        await model.refresh()

        #expect(await model.addComment("  ") == false)
        #expect(server.requests("POST", commentsPath).isEmpty)

        #expect(await model.addComment(" Fine by me. "))
        let body = try #require(server.requests("POST", commentsPath).first.flatMap(jsonObject))
        #expect(body as? [String: String] == ["body": "Fine by me."])
        #expect(loaded(model)?.comments.map(\.id) == ["ac-1", "ac-2", "ac-3"])
    }

    @Test func aFailedCommentReturnsFalseWithTheError() async throws {
        let server = makeServer()
        server.on("POST", commentsPath, StubServer.Response(status: 500, body: JSON.unavailable))
        let (model, _, _) = try detail(server)
        await model.refresh()

        #expect(await model.addComment("Hello") == false)
        #expect(model.actionError != nil)
        #expect(loaded(model)?.comments.count == 2)
    }

    @Test func routesAreValues() {
        #expect(ApprovalRoute(approvalID: "a") == ApprovalRoute(approvalID: "a"))
        #expect(ApprovalRoute(approvalID: "a") != ApprovalRoute(approvalID: "b"))
    }
}
