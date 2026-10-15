import Foundation
import PaperclipAPI
import Testing
@testable import PaperclipIOS

/// The Tasks tab (spec §3): the company's tasks grouped by project, status and
/// assignee filters, server search (`q`) after a 300 ms pause, pages of 50.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct TasksModelTests {
    let projectsPath = "/api/companies/company-1/projects"
    let agentsPath = "/api/companies/company-1/agents"
    let open = "backlog,todo,in_progress,in_review,blocked"

    // Server order: t1, t2, t3, t4, t5. Projects sort by name: Mobile app, Website.
    let t1 = issueJSON(id: "issue-1", title: "Fix the login", projectId: "project-2")
    let t2 = issueJSON(id: "issue-2", title: "Board chat")
    let t3 = issueJSON(id: "issue-3", title: "Ship the build", projectId: "project-1")
    let t4 = issueJSON(id: "issue-4", title: "Old work", projectId: "project-gone")
    let t5 = issueJSON(id: "issue-5", title: "Landing page", projectId: "project-2")

    /// `project-2` is listed first to prove sections sort by name, not by the server's order.
    static let projects = #"[{"id":"project-2","companyId":"company-1","name":"Website","status":"planned","archivedAt":null},{"id":"project-1","companyId":"company-1","name":"Mobile app","status":"in_progress","archivedAt":null}]"#

    private func makeServer(issues: String = "[]") -> StubServer {
        let server = StubServer()
        server.on("GET", projectsPath, .ok(Self.projects))
        server.on("GET", agentsPath, .ok(DefaultAssigneeTests.agentsJSON))
        server.on("GET", companyIssuesPath, .ok(issues))
        return server
    }

    private func model(
        _ server: StubServer, sleeper: TestSleeper = TestSleeper(ticks: 1), log: LogSink = LogSink()
    ) throws -> (TasksModel, AccountStore, UUID) {
        let (store, id) = try signedInStore(server, log: log)
        let debounce = SearchDebounce(sleep: { try await sleeper.sleep($0) })
        return (TasksModel(store: store, accountID: id, debounce: debounce), store, id)
    }

    private func sections(_ state: LoadState<[TaskSection]>) -> [String] {
        if case .loaded(let sections) = state { return sections.map(\.title) }
        return []
    }

    private func ids(_ state: LoadState<[TaskSection]>) -> [[String]] {
        if case .loaded(let sections) = state { return sections.map { $0.issues.map(\.id) } }
        return []
    }

    /// `count` issues `issue-<first>`… in one JSON array.
    private func page(from first: Int, count: Int) -> String {
        "[" + (first..<(first + count)).map { issueJSON(id: "issue-\($0)") }.joined(separator: ",") + "]"
    }

    private func lastQuery(_ server: StubServer) -> [String: String] {
        query(server.requests("GET", companyIssuesPath).last)
    }

    // MARK: Query building

    @Test func defaultQueryIsOpenTasksFirstPage() {
        let items = TasksModel.query(status: .open, assignee: .anyone, search: nil, offset: 0)
        #expect(items.status == [.backlog, .todo, .inProgress, .inReview, .blocked])
        #expect(items.limit == 50)
        #expect(items.offset == nil)
        #expect(items.assigneeUserId == nil)
        #expect(items.assigneeAgentId == nil)
        #expect(items.search == nil)
        // The Tasks tab is the whole company, not the inbox.
        #expect(items.touchedByUserId == nil)
        #expect(items.inboxArchivedByUserId == nil)
    }

    @Test func filterCombinationsBuildTheRightQuery() {
        let all = TasksModel.query(status: .all, assignee: .me, search: "login", offset: 0)
        #expect(all.status.isEmpty)
        #expect(all.assigneeUserId == "me")
        #expect(all.assigneeAgentId == nil)
        #expect(all.search == "login")

        let done = TasksModel.query(status: .done, assignee: .agent("agent-2"), search: nil, offset: 50)
        #expect(done.status == [.done])
        #expect(done.assigneeAgentId == "agent-2")
        #expect(done.assigneeUserId == nil)
        #expect(done.offset == 50)
        #expect(done.limit == 50)

        let review = TasksModel.query(status: .inReview, assignee: .anyone, search: "  ", offset: 0)
        #expect(review.status == [.inReview])
        // A blank search sends no `q`.
        #expect(review.search == nil)
    }

    @Test func everyStatusFilterHasATitleAndItsStatuses() {
        #expect(TaskStatusFilter.allCases == [.open, .all, .backlog, .todo, .inProgress, .inReview, .blocked, .done, .cancelled])
        #expect(TaskStatusFilter.allCases.map(\.title) == [
            "Open", "All", "Backlog", "To do", "In progress", "In review", "Blocked", "Done", "Cancelled",
        ])
        #expect(TaskStatusFilter.cancelled.statuses == [.cancelled])
        #expect(TaskStatusFilter.all.statuses.isEmpty)
    }

    @Test func searchTermIsTrimmedAndBlankIsNone() {
        #expect(SearchDebounce.term("  login \n") == "login")
        #expect(SearchDebounce.term(" \n ") == nil)
        #expect(SearchDebounce.term("") == nil)
        #expect(SearchDebounce.delay == .milliseconds(300))
    }

    // MARK: Load

    @Test func startsLoadingWithOpenTasksForAnyone() throws {
        let (tasks, _, _) = try model(makeServer())
        #expect(tasks.state == .loading)
        #expect(tasks.status == .open)
        #expect(tasks.assignee == .anyone)
        #expect(tasks.searchText == "")
    }

    @Test func refreshFetchesTheCompanyTasksWithTheFilters() async throws {
        let server = makeServer(issues: list(t1))
        let (tasks, _, _) = try model(server)
        tasks.status = .done
        tasks.assignee = .me

        await tasks.refresh()

        let request = try #require(server.requests("GET", companyIssuesPath).last)
        let items = query(request)
        #expect(items["status"] == "done")
        #expect(items["assigneeUserId"] == "me")
        #expect(items["limit"] == "50")
        #expect(items["offset"] == nil)
        #expect(items["q"] == nil)
        #expect(items["touchedByUserId"] == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(JSON.key)")
        #expect(server.requests("GET", projectsPath).count == 1)
    }

    @Test func tasksAreGroupedByProjectNameThenOtherThenNone() async throws {
        let server = makeServer(issues: list(t1, t2, t3, t4, t5))
        let (tasks, _, _) = try model(server)
        await tasks.refresh()

        // Known projects by name; a project the list does not have (archived) is
        // "Other project"; tasks without a project come last.
        #expect(sections(tasks.state) == ["Mobile app", "Website", "Other project", "No project"])
        // Rows keep the server's order inside a section.
        #expect(ids(tasks.state) == [["issue-3"], ["issue-1", "issue-5"], ["issue-4"], ["issue-2"]])
        guard case .loaded(let loaded) = tasks.state else { return }
        #expect(loaded.map(\.id) == ["project-1", "project-2", "other", "none"])
    }

    @Test func failedProjectsStillShowTheTasks() async throws {
        let server = makeServer(issues: list(t1, t2))
        server.on("GET", projectsPath, StubServer.Response(status: 503, body: JSON.unavailable))
        let (tasks, _, _) = try model(server)
        await tasks.refresh()

        #expect(sections(tasks.state) == ["Other project", "No project"])
        #expect(ids(tasks.state) == [["issue-1"], ["issue-2"]])
    }

    @Test func noTasksIsEmpty() async throws {
        let (tasks, _, _) = try model(makeServer(issues: "[]"))
        await tasks.refresh()
        #expect(tasks.state == .empty)
        #expect(tasks.hasMore == false)
    }

    @Test func serverErrorShowsAMessageWithoutTheKey() async throws {
        let server = makeServer()
        server.on("GET", companyIssuesPath, StubServer.Response(status: 500, body: JSON.unavailable))
        let log = LogSink()
        let (tasks, _, _) = try model(server, log: log)
        await tasks.refresh()

        #expect(tasks.state == .error(userMessage(for: APIError.server(status: 500, body: "Service unavailable"))))
        #expect(!log.lines.joined().contains(JSON.key))
    }

    @Test func unauthorizedSendsTheAccountToSignIn() async throws {
        let server = makeServer()
        server.on("GET", companyIssuesPath, StubServer.Response(status: 401, body: JSON.unauthorized))
        let (tasks, store, id) = try model(server)
        await tasks.refresh()

        #expect(tasks.state == .needsSignIn)
        #expect(store.route == .reSignIn(id))
    }

    @Test func aFilterChangeRefetchesFromTheFirstPage() async throws {
        let server = makeServer()
        server.on("GET", companyIssuesPath, query: ["status": open], .ok(page(from: 1, count: 50)))
        server.on("GET", companyIssuesPath, query: ["status": open, "offset": "50"], .ok(page(from: 51, count: 3)))
        server.on("GET", companyIssuesPath, query: ["status": "blocked"], .ok(list(t1)))
        let (tasks, _, _) = try model(server)
        await tasks.refresh()
        await tasks.loadMore()

        tasks.status = .blocked
        await tasks.refresh()

        #expect(lastQuery(server)["status"] == "blocked")
        #expect(lastQuery(server)["offset"] == nil)
        #expect(ids(tasks.state) == [["issue-1"]])
    }

    // MARK: Paging

    @Test func aFullFirstPageOffersMore() async throws {
        let (tasks, _, _) = try model(makeServer(issues: page(from: 1, count: 50)))
        await tasks.refresh()
        #expect(tasks.hasMore)
        #expect(Array(ids(tasks.state).joined()).count == 50)
    }

    @Test func aShortPageIsTheEnd() async throws {
        let (tasks, _, _) = try model(makeServer(issues: page(from: 1, count: 49)))
        await tasks.refresh()
        #expect(tasks.hasMore == false)
    }

    @Test func loadMoreAsksForTheNextPageWithTheSameFiltersAndAppends() async throws {
        let server = makeServer()
        server.on("GET", companyIssuesPath, query: ["status": "todo"], .ok(page(from: 1, count: 50)))
        // The next page repeats issue-50 (a task moved between the two reads); it shows once.
        server.on("GET", companyIssuesPath, query: ["status": "todo", "offset": "50"], .ok(page(from: 50, count: 4)))
        let (tasks, _, _) = try model(server)
        tasks.status = .todo
        await tasks.refresh()

        await tasks.loadMore()

        let items = lastQuery(server)
        #expect(items["offset"] == "50")
        #expect(items["limit"] == "50")
        #expect(items["status"] == "todo")
        let loaded = Array(ids(tasks.state).joined())
        #expect(loaded.count == 53)
        #expect(Set(loaded).count == 53)
        #expect(loaded.last == "issue-53")
        #expect(tasks.hasMore == false)
    }

    @Test func loadMoreAtTheEndSendsNothing() async throws {
        let server = makeServer(issues: list(t1))
        let (tasks, _, _) = try model(server)
        await tasks.refresh()

        await tasks.loadMore()

        #expect(server.requests("GET", companyIssuesPath).count == 1)
    }

    @Test func failedLoadMoreKeepsTheRowsAndSaysWhy() async throws {
        let server = makeServer()
        server.on("GET", companyIssuesPath, query: ["status": open], .ok(page(from: 1, count: 50)))
        server.on("GET", companyIssuesPath, query: ["status": open, "offset": "50"], StubServer.Response(status: 500, body: JSON.unavailable))
        let (tasks, _, _) = try model(server)
        await tasks.refresh()

        await tasks.loadMore()

        #expect(Array(ids(tasks.state).joined()).count == 50)
        #expect(tasks.pageError == userMessage(for: APIError.server(status: 500, body: "Service unavailable")))
        #expect(tasks.hasMore)

        await tasks.refresh()
        #expect(tasks.pageError == nil)
    }

    @Test func unauthorizedLoadMoreSendsTheAccountToSignIn() async throws {
        let server = makeServer()
        server.on("GET", companyIssuesPath, query: ["status": open], .ok(page(from: 1, count: 50)))
        server.on("GET", companyIssuesPath, query: ["status": open, "offset": "50"], StubServer.Response(status: 401, body: JSON.unauthorized))
        let (tasks, store, id) = try model(server)
        await tasks.refresh()

        await tasks.loadMore()

        #expect(tasks.state == .needsSignIn)
        #expect(store.route == .reSignIn(id))
    }

    // MARK: Assignee picker

    @Test func assigneeOptionsAreAnyoneMeAndTheAgentsThatCanWork() async throws {
        let (tasks, _, _) = try model(makeServer())
        await tasks.refresh()

        #expect(tasks.assigneeOptions == [.anyone, .me, .agent("agent-1"), .agent("agent-2")])
        #expect(tasks.assigneeOptions.map { tasks.assigneeTitle($0) } == ["Anyone", "Me", "Luis", "Marta"])
    }

    @Test func failedAgentsLeaveAnyoneAndMe() async throws {
        let server = makeServer(issues: list(t1))
        server.on("GET", agentsPath, StubServer.Response(status: 503, body: JSON.unavailable))
        let (tasks, _, _) = try model(server)
        await tasks.refresh()

        #expect(tasks.assigneeOptions == [.anyone, .me])
        // The list itself still loads.
        #expect(ids(tasks.state) == [["issue-1"]])
    }

    // MARK: Search

    @Test func searchWaitsThenAsksTheServerWithQ() async throws {
        let server = makeServer(issues: list(t1))
        let sleeper = TestSleeper(ticks: 1)
        let (tasks, _, _) = try model(server, sleeper: sleeper)
        await tasks.refresh()

        tasks.searchText = "  login "
        await tasks.search()

        #expect(sleeper.durations == [.milliseconds(300)])
        #expect(server.requests("GET", companyIssuesPath).count == 2)
        let items = lastQuery(server)
        #expect(items["q"] == "login")
        // Filters still apply to a search.
        #expect(items["status"] == open)
        #expect(items["offset"] == nil)
    }

    @Test func aSearchCancelledWhileWaitingSendsNothing() async throws {
        let server = makeServer(issues: list(t1))
        // The view runs `search()` in `.task(id: searchText)`: a new keystroke cancels the wait.
        let (tasks, _, _) = try model(server, sleeper: TestSleeper(ticks: 0))
        await tasks.refresh()

        tasks.searchText = "log"
        await tasks.search()

        #expect(server.requests("GET", companyIssuesPath).count == 1)
    }

    @Test func theSameSearchIsNotSentTwice() async throws {
        let server = makeServer(issues: list(t1))
        let (tasks, _, _) = try model(server, sleeper: TestSleeper(ticks: 5))
        await tasks.refresh()

        // On appear the search task runs with empty text: the refresh already loaded it.
        await tasks.search()
        #expect(server.requests("GET", companyIssuesPath).count == 1)

        tasks.searchText = "login"
        await tasks.search()
        tasks.searchText = "login "
        await tasks.search()
        #expect(server.requests("GET", companyIssuesPath).count == 2)
    }

    @Test func clearingTheSearchFetchesWithoutQ() async throws {
        let server = makeServer(issues: list(t1))
        let (tasks, _, _) = try model(server, sleeper: TestSleeper(ticks: 5))
        await tasks.refresh()
        tasks.searchText = "login"
        await tasks.search()

        tasks.searchText = ""
        await tasks.search()

        #expect(server.requests("GET", companyIssuesPath).count == 3)
        #expect(lastQuery(server)["q"] == nil)
    }

    @Test func pullToRefreshAndPagingKeepTheActiveSearch() async throws {
        let server = makeServer()
        server.on("GET", companyIssuesPath, query: ["q": "login"], .ok(page(from: 1, count: 50)))
        server.on("GET", companyIssuesPath, query: ["q": "login", "offset": "50"], .ok(list(t1)))
        let (tasks, _, _) = try model(server)
        tasks.searchText = "login"
        await tasks.search()

        await tasks.loadMore()
        #expect(lastQuery(server)["q"] == "login")
        await tasks.refresh()
        #expect(lastQuery(server)["q"] == "login")
    }

    @Test func aSearchWithNoMatchesIsEmpty() async throws {
        let server = makeServer(issues: list(t1))
        server.on("GET", companyIssuesPath, query: ["q": "zzz"], .ok("[]"))
        let (tasks, _, _) = try model(server)
        await tasks.refresh()

        tasks.searchText = "zzz"
        await tasks.search()

        #expect(tasks.state == .empty)
    }

    @Test func unauthorizedSearchSendsTheAccountToSignIn() async throws {
        let server = makeServer(issues: list(t1))
        server.on("GET", companyIssuesPath, query: ["q": "login"], StubServer.Response(status: 401, body: JSON.unauthorized))
        let (tasks, store, id) = try model(server)
        await tasks.refresh()

        tasks.searchText = "login"
        await tasks.search()

        #expect(tasks.state == .needsSignIn)
        #expect(store.route == .reSignIn(id))
    }

    @Test func theSearchTextIsNeverLogged() async throws {
        let server = makeServer()
        server.on("GET", companyIssuesPath, StubServer.Response(status: 500, body: JSON.unavailable))
        let log = LogSink()
        let (tasks, _, _) = try model(server, log: log)

        tasks.searchText = "secret-plan-x"
        await tasks.search()

        #expect(!log.lines.joined().contains("secret-plan-x"))
    }
}
