import Foundation
import PaperclipAPI
import Testing
@testable import PaperclipIOS

/// Today: "Needs you" cards, "New replies" with a preview, the pulse line and
/// the empty state. Spec §2; Open goes to the web UI until task detail exists.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct TodayModelTests {
    let attentionPath = "/api/companies/company-1/attention"
    let dashboardPath = "/api/companies/company-1/dashboard"
    let start = iso("2026-10-14T12:00:00.000Z")

    // Query of each issue list Today asks for.
    let assignedQuery = ["assigneeUserId": "me", "status": "todo,in_progress,in_review,blocked"]
    let repliesQuery = ["touchedByUserId": "me", "inboxArchivedByUserId": "me", "unreadForUserId": "me"]
    let doneQuery = ["status": "done"]

    static func attentionItem(
        id: String, sourceKind: String, subjectKind: String, title: String, identifier: String? = nil,
        href: String? = nil, relatedIssueID: String? = nil, relatedIdentifier: String? = nil,
        relatedTitle: String? = nil, prompt: String? = nil, whyNow: String = "Waiting for you"
    ) -> String {
        func text(_ value: String?) -> String { value.map { "\"" + $0 + "\"" } ?? "null" }
        let related = relatedIssueID.map {
            #"{"kind":"issue","id":"\#($0)","companyId":"company-1","title":\#(text(relatedTitle)),"identifier":\#(text(relatedIdentifier)),"status":"in_review","href":\#(text(relatedIdentifier.map { "/PAP/issues/" + $0 }))}"#
        } ?? "null"
        let detail = prompt.map { #"{"kind":"confirmation","promptExcerpt":"\#($0)","isPlanTarget":false,"images":[]}"# } ?? "null"
        return """
        {"id":"\(id)","companyId":"company-1","sourceKind":"\(sourceKind)",\
        "subject":{"kind":"\(subjectKind)","id":"\(id)-subject","companyId":"company-1","title":"\(title)",\
        "identifier":\(text(identifier)),"status":"pending","href":\(text(href))},\
        "whyNow":"\(whyNow)","decisionVerbs":[],"inlineResolvable":true,"severity":"high","rank":1,\
        "activityAt":"2026-10-14T09:30:00.000Z","createdAt":"2026-10-14T09:00:00.000Z","updatedAt":"2026-10-14T09:00:00.000Z",\
        "relatedIssue":\(related),"detail":\(detail),"dismissal":null}
        """
    }

    static func feed(_ items: String...) -> String {
        #"{"companyId":"company-1","generatedAt":"2026-10-14T10:00:00.000Z","totalCount":\#(items.count),"deskBadgeCount":0,"nextCursor":null,"countsBySourceKind":{},"items":["# + items.joined(separator: ",") + "]}"
    }

    static let dashboard = #"{"companyId":"company-1","agents":{"active":5,"running":3,"paused":1,"error":0},"tasks":{"open":20,"inProgress":4,"blocked":2,"done":120},"pendingApprovals":1}"#

    static func comment(_ id: String, issueID: String, body: String, userId: String?) -> String {
        let author = userId.map { #""authorUserId":"\#($0)","authorAgentId":null,"authorType":"user""# }
            ?? #""authorUserId":null,"authorAgentId":"agent-1","authorType":"agent""#
        return #"{"id":"\#(id)","issueId":"\#(issueID)",\#(author),"body":"\#(body)","createdAt":"2026-10-14T09:00:00.000Z"}"#
    }

    let interaction = TodayModelTests.attentionItem(
        id: "att-1", sourceKind: "issue_thread_interaction", subjectKind: "interaction", title: "Approve the plan?",
        relatedIssueID: "issue-1", relatedIdentifier: "PAP-1", relatedTitle: "iOS plan", prompt: "Send the plan to the board?"
    )
    let approval = TodayModelTests.attentionItem(
        id: "att-2", sourceKind: "approval", subjectKind: "approval", title: "Hire a designer",
        href: "/PAP/approvals/att-2-subject", whyNow: "Approval pending"
    )
    let failedRun = TodayModelTests.attentionItem(id: "att-3", sourceKind: "failed_run", subjectKind: "run", title: "Run failed")

    /// Today with every call answered; override what a test needs.
    private func makeServer(
        attention: String? = nil,
        assigned: String = "[]",
        replies: String = "[]",
        done: String = "[]"
    ) -> StubServer {
        let server = StubServer()
        server.on("GET", attentionPath, .ok(attention ?? Self.feed()))
        server.on("GET", companyIssuesPath, query: assignedQuery, .ok(assigned))
        server.on("GET", companyIssuesPath, query: repliesQuery, .ok(replies))
        server.on("GET", companyIssuesPath, query: doneQuery, .ok(done))
        server.on("GET", dashboardPath, .ok(Self.dashboard))
        return server
    }

    private func today(_ server: StubServer, clock: TestClock? = nil) throws -> (TodayModel, AccountStore, UUID) {
        let (store, id) = try signedInStore(server)
        let clock = clock ?? TestClock(start)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return (TodayModel(store: store, accountID: id, now: { clock.now }, calendar: utc), store, id)
    }

    private func content(_ model: TodayModel) -> TodayContent? {
        if case .loaded(let content) = model.state { return content }
        return nil
    }

    // MARK: States

    @Test func startsLoading() throws {
        let (model, _, _) = try today(makeServer())
        #expect(model.state == .loading)
        #expect(model.pulse == nil)
    }

    @Test func nothingNeedsYouIsTheEmptyStateWithThePulse() async throws {
        let (model, _, _) = try today(makeServer())
        await model.refresh()

        #expect(model.state == .empty)
        #expect(TodayModel.emptyMessage == "All clear. Nothing needs you.")
        #expect(model.pulse == Pulse(working: 3, blocked: 2, doneToday: 0))
    }

    @Test func attentionErrorShowsAMessage() async throws {
        let server = makeServer()
        server.on("GET", attentionPath, StubServer.Response(status: 500, body: JSON.unavailable))
        let (model, _, _) = try today(server)
        await model.refresh()

        #expect(model.state == .error(userMessage(for: APIError.server(status: 500, body: "Service unavailable"))))
    }

    @Test func unauthorizedSendsTheAccountToSignIn() async throws {
        let server = makeServer()
        server.on("GET", attentionPath, StubServer.Response(status: 401, body: JSON.unauthorized))
        let (model, store, id) = try today(server)
        await model.refresh()

        #expect(model.state == .needsSignIn)
        #expect(store.route == .reSignIn(id))
    }

    // MARK: Needs you

    @Test func needsYouShowsRequestsApprovalsAndMyTasks() async throws {
        let mine = issueJSON(id: "issue-7", title: "Review the logo", status: "in_review", assigneeUserId: "user-1")
        // issue-1 already has a request card: no second card for it.
        let alreadyCarded = issueJSON(id: "issue-1", title: "iOS plan", status: "in_progress", assigneeUserId: "user-1")
        let (model, _, _) = try today(makeServer(
            attention: Self.feed(interaction, approval, failedRun), assigned: list(mine, alreadyCarded)
        ))
        await model.refresh()

        let cards = try #require(content(model)).needsYou
        // Failed runs, budgets and other attention kinds are not "needs you" in the app.
        #expect(cards.map(\.kind) == [.interaction, .approval, .assignedTask])
        #expect(cards.map(\.id) == ["att-1", "att-2", "issue-7"])

        #expect(cards[0].title == "iOS plan")
        #expect(cards[0].identifier == "PAP-1")
        #expect(cards[0].detail == "Send the plan to the board?")
        #expect(cards[0].issueID == "issue-1")
        #expect(cards[0].webPath == "/PAP/issues/PAP-1")

        #expect(cards[1].title == "Hire a designer")
        #expect(cards[1].detail == "Approval pending")
        #expect(cards[1].issueID == nil)
        #expect(cards[1].webPath == "/PAP/approvals/att-2-subject")

        #expect(cards[2].title == "Review the logo")
        #expect(cards[2].identifier == "PAP-7")
        #expect(cards[2].issueID == "issue-7")
        #expect(cards[2].webPath == "/PAP/issues/PAP-7")
    }

    @Test func myOpenTasksAreAskedForByStatus() async throws {
        let server = makeServer()
        let (model, _, _) = try today(server)
        await model.refresh()

        let assigned = server.requests("GET", companyIssuesPath).filter { query($0)["assigneeUserId"] != nil }
        #expect(assigned.count == 1)
        #expect(query(assigned.first)["status"] == "todo,in_progress,in_review,blocked")
    }

    // MARK: New replies

    @Test func newRepliesAreUnreadThreadsNewestReplyFirstWithTheFirstLineOfTheReply() async throws {
        let older = issueJSON(id: "issue-2", title: "Board chat", unread: true, updatedAt: "2026-10-14T09:00:00.000Z",
                              lastExternalCommentAt: "2026-10-14T08:59:00.000Z")
        let newer = issueJSON(id: "issue-3", title: "Backups", unread: true, updatedAt: "2026-10-14T11:00:00.000Z",
                              lastExternalCommentAt: "2026-10-14T10:59:00.000Z")
        let server = makeServer(replies: list(older, newer))
        // Newest comment first (server default); my own comment is skipped.
        server.on("GET", "/api/issues/issue-3/comments", .ok(list(
            Self.comment("c3", issueID: "issue-3", body: "Thanks", userId: "user-1"),
            Self.comment("c2", issueID: "issue-3", body: "\\n  Restore test passed.\\nDetails below.", userId: nil)
        )))
        server.on("GET", "/api/issues/issue-2/comments", .ok(list(
            Self.comment("c1", issueID: "issue-2", body: "Plan ready", userId: nil)
        )))
        let (model, _, _) = try today(server)
        await model.refresh()

        let replies = try #require(content(model)).newReplies
        #expect(replies.map(\.id) == ["issue-3", "issue-2"])
        #expect(replies[0].preview == "Restore test passed.")
        #expect(replies[1].preview == "Plan ready")
        #expect(query(server.requests("GET", "/api/issues/issue-3/comments").first)["limit"] == "5")
    }

    @Test func atMostTenRepliesAndAFailedPreviewIsNotAnError() async throws {
        let threads = (1...12).map { number in
            issueJSON(id: "issue-\(number)", unread: true,
                      updatedAt: String(format: "2026-10-14T10:%02d:00.000Z", number),
                      lastExternalCommentAt: String(format: "2026-10-14T10:%02d:00.000Z", number))
        }
        let server = makeServer(replies: "[" + threads.joined(separator: ",") + "]")
        // No comment routes: every preview fetch gets a 404.
        let (model, _, _) = try today(server)
        await model.refresh()

        let replies = try #require(content(model)).newReplies
        #expect(replies.count == TodayModel.replyLimit)
        #expect(TodayModel.replyLimit == 10)
        #expect(replies.first?.id == "issue-12")
        #expect(replies.allSatisfy { $0.preview == nil })
        #expect(server.allRequests.filter { $0.url?.path.hasSuffix("/comments") == true }.count == 10)
    }

    // MARK: Pulse

    @Test func pulseCountsRunningAgentsBlockedTasksAndTasksDoneToday() async throws {
        let doneToday = issueJSON(id: "issue-8", status: "done", updatedAt: "2026-10-14T09:00:00.000Z",
                                  completedAt: "2026-10-14T08:00:00.000Z")
        // Updated today, completed yesterday: not done today.
        let doneYesterday = issueJSON(id: "issue-9", status: "done", updatedAt: "2026-10-14T09:00:00.000Z",
                                      completedAt: "2026-10-13T23:00:00.000Z")
        let server = makeServer(done: list(doneToday, doneYesterday))
        let (model, _, _) = try today(server)
        await model.refresh()

        #expect(model.pulse == Pulse(working: 3, blocked: 2, doneToday: 1))
        let done = server.requests("GET", companyIssuesPath).filter { query($0)["status"] == "done" }
        #expect(query(done.first)["updatedSince"] == "2026-10-14T00:00:00.000Z")
    }

    @Test func pulseText() {
        #expect(Pulse(working: 3, blocked: 2, doneToday: 12).text == "3 agents working · 2 blocked · 12 done today")
        #expect(Pulse(working: 1, blocked: 0, doneToday: 1).text == "1 agent working · 0 blocked · 1 done today")
    }

    @Test func pulseFailureHidesOnlyThePulse() async throws {
        let server = makeServer(attention: Self.feed(approval))
        server.on("GET", dashboardPath, StubServer.Response(status: 500, body: JSON.unavailable))
        let (model, _, _) = try today(server)
        await model.refresh()

        #expect(model.pulse == nil)
        #expect(content(model)?.needsYou.map(\.id) == ["att-2"])
    }

    // MARK: Polling

    @Test func pollRefetchesCardsAndAsksOnlyForNewReplies() async throws {
        let first = issueJSON(id: "issue-2", unread: true, updatedAt: "2026-10-14T09:00:00.000Z",
                              lastExternalCommentAt: "2026-10-14T09:00:00.000Z")
        let second = issueJSON(id: "issue-3", unread: true, updatedAt: "2026-10-14T11:00:00.000Z",
                               lastExternalCommentAt: "2026-10-14T11:00:00.000Z")
        let server = makeServer(attention: Self.feed(approval))
        server.on("GET", companyIssuesPath, query: repliesQuery, .ok(list(first)), .ok(list(second)))
        server.on("GET", "/api/issues/issue-2/comments", .ok(list(Self.comment("c1", issueID: "issue-2", body: "One", userId: nil))))
        server.on("GET", "/api/issues/issue-3/comments", .ok(list(Self.comment("c2", issueID: "issue-3", body: "Two", userId: nil))))
        let (model, _, _) = try today(server)
        await model.refresh()
        server.on("GET", attentionPath, .ok(Self.feed(interaction)))

        await model.poll()

        let replyRequests = server.requests("GET", companyIssuesPath).filter { query($0)["unreadForUserId"] != nil }
        #expect(query(replyRequests.last)["updatedSince"] == "2026-10-14T09:00:00.000Z")
        let loaded = try #require(content(model))
        #expect(loaded.newReplies.map(\.id) == ["issue-3", "issue-2"])
        #expect(loaded.needsYou.map(\.id) == ["att-1"])
        // The unchanged thread keeps its preview without a second comments call.
        #expect(server.requests("GET", "/api/issues/issue-2/comments").count == 1)
        #expect(server.requests("GET", dashboardPath).count == 2)
    }

    @Test func pollingTicksEveryFifteenSecondsUntilCancelled() async throws {
        let server = makeServer()
        let (store, id) = try signedInStore(server)
        let sleeper = TestSleeper(ticks: 2)
        let model = TodayModel(store: store, accountID: id, poller: Poller(sleep: { try await sleeper.sleep($0) }))

        await model.runPolling()

        #expect(sleeper.durations == [.seconds(15), .seconds(15), .seconds(15)])
        #expect(server.requests("GET", attentionPath).count == 2)
    }

    // MARK: Swipe on New replies (same actions as the Inbox)

    @Test func swipeRightMarksAReplyReadAndLeftArchivesIt() async throws {
        let one = issueJSON(id: "issue-2", unread: true, updatedAt: "2026-10-14T09:00:00.000Z",
                            lastExternalCommentAt: "2026-10-14T09:00:00.000Z")
        let two = issueJSON(id: "issue-3", unread: true, updatedAt: "2026-10-14T10:00:00.000Z",
                            lastExternalCommentAt: "2026-10-14T10:00:00.000Z")
        let server = makeServer(attention: Self.feed(approval), replies: list(one, two))
        server.on("POST", "/api/issues/issue-3/read", .ok(#"{"ok":true}"#))
        server.on("POST", "/api/issues/issue-2/inbox-archive", StubServer.Response(status: 500, body: JSON.unavailable))
        let (model, _, _) = try today(server)
        await model.refresh()
        let replies = try #require(content(model)).newReplies

        await model.markRead(try #require(replies.first { $0.id == "issue-3" }))
        #expect(content(model)?.newReplies.map(\.id) == ["issue-2"])
        #expect(model.undo == InboxUndo(action: .markedRead, issueID: "issue-3", expiresAt: start.addingTimeInterval(5)))

        await model.archive(try #require(replies.first { $0.id == "issue-2" }))
        #expect(server.requests("POST", "/api/issues/issue-2/inbox-archive").count == 1)
        // The archive failed: the reply is back and the error is shown.
        #expect(content(model)?.newReplies.map(\.id) == ["issue-2"])
        #expect(model.actionError != nil)
    }

    @Test func webPathForAnIssueUsesItsPrefix() {
        #expect(webPath(identifier: "PAP-12") == "/PAP/issues/PAP-12")
        #expect(webPath(identifier: nil) == nil)
    }
}
