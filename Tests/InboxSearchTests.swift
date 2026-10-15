import Foundation
import PaperclipAPI
import Testing
@testable import PaperclipIOS

/// Inbox search (spec §3 Inbox) uses the Tasks search model: typing filters the
/// loaded threads by title at once; after a 300 ms pause the server searches
/// the same inbox (`q`, which also matches descriptions and comments) and its
/// results replace the local filter. The segments still apply.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct InboxSearchTests {
    let a1 = issueJSON(id: "issue-1", title: "Fix the login", assigneeUserId: "user-1", unread: true,
                       updatedAt: "2026-10-14T09:00:00.000Z")
    let a2 = issueJSON(id: "issue-2", title: "Board chat", createdByUserId: "user-1", unread: false,
                       updatedAt: "2026-10-14T10:00:00.000Z")
    // "restore" is only in a3's comments, not in its title.
    let a3 = issueJSON(id: "issue-3", title: "Backups", unread: false,
                       updatedAt: "2026-10-14T08:00:00.000Z")

    private func loadedInbox(
        _ server: StubServer, sleeper: TestSleeper = TestSleeper(ticks: 1), log: LogSink = LogSink()
    ) async throws -> (InboxModel, AccountStore, UUID) {
        server.on("GET", companyIssuesPath, .ok(list(a1, a2, a3)))
        let (store, id) = try signedInStore(server, log: log)
        let debounce = SearchDebounce(sleep: { try await sleeper.sleep($0) })
        let inbox = InboxModel(store: store, accountID: id, debounce: debounce)
        await inbox.refresh()
        inbox.segment = .all
        return (inbox, store, id)
    }

    private func ids(_ state: LoadState<[InboxRow]>) -> [String] {
        if case .loaded(let rows) = state { return rows.map(\.id) }
        return []
    }

    @Test func searchWaitsThenAsksTheServerInsideTheInbox() async throws {
        let server = StubServer()
        let sleeper = TestSleeper(ticks: 1)
        let (inbox, _, _) = try await loadedInbox(server, sleeper: sleeper)

        inbox.searchText = " restore "
        await inbox.search()

        #expect(sleeper.durations == [.milliseconds(300)])
        let items = query(server.requests("GET", companyIssuesPath).last)
        #expect(items["q"] == "restore")
        #expect(items["touchedByUserId"] == "me")
        #expect(items["inboxArchivedByUserId"] == "me")
        #expect(items["updatedSince"] == nil)
    }

    @Test func serverResultsReplaceTheLocalTitleFilter() async throws {
        let server = StubServer()
        server.on("GET", companyIssuesPath, query: ["q": "restore"], .ok(list(a3)))
        let (inbox, _, _) = try await loadedInbox(server)

        inbox.searchText = "restore"
        // Before the server answers, only titles match: nothing.
        #expect(inbox.state == .empty)

        await inbox.search()

        #expect(ids(inbox.state) == ["issue-3"])
    }

    @Test func segmentsStillApplyToSearchResults() async throws {
        let server = StubServer()
        server.on("GET", companyIssuesPath, query: ["q": "board"], .ok(list(a1, a2)))
        let (inbox, _, _) = try await loadedInbox(server)

        inbox.searchText = "board"
        await inbox.search()

        inbox.segment = .unread
        #expect(ids(inbox.state) == ["issue-1"])
        inbox.segment = .all
        #expect(ids(inbox.state) == ["issue-2", "issue-1"])
    }

    @Test func aSearchCancelledWhileWaitingSendsNothing() async throws {
        let server = StubServer()
        let (inbox, _, _) = try await loadedInbox(server, sleeper: TestSleeper(ticks: 0))

        inbox.searchText = "rest"
        await inbox.search()

        #expect(server.requests("GET", companyIssuesPath).count == 1)
        // The local title filter still works.
        inbox.searchText = "back"
        #expect(ids(inbox.state) == ["issue-3"])
    }

    @Test func blankSearchSendsNothing() async throws {
        let server = StubServer()
        let (inbox, _, _) = try await loadedInbox(server)

        inbox.searchText = "   "
        await inbox.search()

        #expect(server.requests("GET", companyIssuesPath).count == 1)
        #expect(ids(inbox.state).count == 3)
    }

    @Test func clearingTheSearchShowsTheWholeInboxAgain() async throws {
        let server = StubServer()
        server.on("GET", companyIssuesPath, query: ["q": "restore"], .ok(list(a3)))
        let (inbox, _, _) = try await loadedInbox(server, sleeper: TestSleeper(ticks: 5))
        inbox.searchText = "restore"
        await inbox.search()

        inbox.searchText = ""
        await inbox.search()

        #expect(ids(inbox.state) == ["issue-2", "issue-1", "issue-3"])
        // Clearing needs no request: the inbox is already loaded.
        #expect(server.requests("GET", companyIssuesPath).count == 2)
    }

    @Test func swipeActionsApplyToSearchResults() async throws {
        let server = StubServer()
        server.on("GET", companyIssuesPath, query: ["q": "restore"], .ok(list(a3)))
        server.on("POST", "/api/issues/issue-3/inbox-archive", .ok("{}"))
        let (inbox, _, _) = try await loadedInbox(server)
        inbox.searchText = "restore"
        await inbox.search()

        guard case .loaded(let rows) = inbox.state, let row = rows.first else {
            Testing.Issue.record("expected a result, got \(inbox.state)")
            return
        }
        await inbox.archive(row)

        #expect(inbox.state == .empty)
    }

    @Test func failedSearchKeepsTheLocalFilterAndDoesNotLogTheText() async throws {
        let server = StubServer()
        server.on("GET", companyIssuesPath, query: ["q": "back"], StubServer.Response(status: 500, body: JSON.unavailable))
        let log = LogSink()
        let (inbox, _, _) = try await loadedInbox(server, log: log)

        inbox.searchText = "back"
        await inbox.search()

        #expect(ids(inbox.state) == ["issue-3"])
        #expect(!log.lines.joined().lowercased().contains("back"))
    }

    @Test func unauthorizedSearchSendsTheAccountToSignIn() async throws {
        let server = StubServer()
        server.on("GET", companyIssuesPath, query: ["q": "back"], StubServer.Response(status: 401, body: JSON.unauthorized))
        let (inbox, store, id) = try await loadedInbox(server)

        inbox.searchText = "back"
        await inbox.search()

        #expect(inbox.state == .needsSignIn)
        #expect(store.route == .reSignIn(id))
    }
}
