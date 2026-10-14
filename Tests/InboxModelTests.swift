import Foundation
import PaperclipAPI
import Testing
@testable import PaperclipIOS

/// Inbox list: one fetch of the threads the user touched (archived hidden),
/// three local segments, `updatedSince` polling merged by issue id.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct InboxModelTests {
    // a1: unread, assigned to me. a2: read, created by me. a3: read, someone else's thread.
    let a1 = issueJSON(id: "issue-1", title: "Fix the login", assigneeUserId: "user-1", unread: true,
                       updatedAt: "2026-10-14T09:00:00.000Z", lastActivityAt: "2026-10-14T09:30:00.000Z")
    let a2 = issueJSON(id: "issue-2", title: "Board chat", createdByUserId: "user-1", unread: false,
                       updatedAt: "2026-10-14T10:00:00.123Z")
    let a3 = issueJSON(id: "issue-3", title: "Backups", unread: false,
                       updatedAt: "2026-10-14T08:00:00.000Z")

    private func model(_ server: StubServer, log: LogSink = LogSink()) throws -> (InboxModel, AccountStore, UUID) {
        let (store, id) = try signedInStore(server, log: log)
        return (InboxModel(store: store, accountID: id), store, id)
    }

    private func ids(_ state: LoadState<[InboxRow]>) -> [String] {
        if case .loaded(let rows) = state { return rows.map(\.id) }
        return []
    }

    @Test func startsLoading() throws {
        let (inbox, _, _) = try model(StubServer())
        #expect(inbox.state == .loading)
        #expect(inbox.segment == .unread)
    }

    @Test func tabsAreTodayInboxTasksMe() {
        #expect(AppTab.allCases == [.today, .inbox, .tasks, .me])
        #expect(AppTab.allCases.map(\.title) == ["Today", "Inbox", "Tasks", "Me"])
        #expect(InboxSegment.allCases.map(\.title) == ["Unread", "Mine", "All"])
    }

    @Test func refreshFetchesTouchedThreadsWithoutArchivedOnes() async throws {
        let server = StubServer()
        server.on("GET", companyIssuesPath, .ok(list(a1, a2, a3)))
        let (inbox, _, _) = try model(server)

        await inbox.refresh()

        let request = try #require(server.requests("GET", companyIssuesPath).last)
        let items = query(request)
        #expect(items["touchedByUserId"] == "me")
        #expect(items["inboxArchivedByUserId"] == "me")
        #expect(items["updatedSince"] == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(JSON.key)")
    }

    @Test func segmentsFilterTheLoadedThreadsNewestActivityFirst() async throws {
        let server = StubServer()
        server.on("GET", companyIssuesPath, .ok(list(a3, a1, a2)))
        let (inbox, _, _) = try model(server)
        await inbox.refresh()

        inbox.segment = .unread
        #expect(ids(inbox.state) == ["issue-1"])
        inbox.segment = .mine
        // Assigned to me or created by me; a2 has newer activity than a1.
        #expect(ids(inbox.state) == ["issue-2", "issue-1"])
        inbox.segment = .all
        #expect(ids(inbox.state) == ["issue-2", "issue-1", "issue-3"])

        #expect(inbox.count(.unread) == 1)
        #expect(inbox.count(.mine) == 2)
        #expect(inbox.count(.all) == 3)
        // Switching segments is local: one request only.
        #expect(server.requests("GET", companyIssuesPath).count == 1)
    }

    @Test func rowsCarryTheUnreadFlag() async throws {
        let server = StubServer()
        server.on("GET", companyIssuesPath, .ok(list(a1, a2)))
        let (inbox, _, _) = try model(server)
        await inbox.refresh()
        inbox.segment = .all

        guard case .loaded(let rows) = inbox.state else {
            Testing.Issue.record("expected loaded, got \(inbox.state)")
            return
        }
        #expect(rows.first { $0.id == "issue-1" }?.isUnread == true)
        #expect(rows.first { $0.id == "issue-2" }?.isUnread == false)
    }

    @Test func searchMatchesTitleOrIdentifierIgnoringCase() async throws {
        let server = StubServer()
        server.on("GET", companyIssuesPath, .ok(list(a1, a2, a3)))
        let (inbox, _, _) = try model(server)
        await inbox.refresh()
        inbox.segment = .all

        inbox.searchText = "BACKUP"
        #expect(ids(inbox.state) == ["issue-3"])
        inbox.searchText = "pap-2"
        #expect(ids(inbox.state) == ["issue-2"])
        inbox.searchText = "nothing like this"
        #expect(inbox.state == .empty)
        inbox.searchText = ""
        #expect(ids(inbox.state).count == 3)
    }

    @Test func noThreadsIsEmpty() async throws {
        let server = StubServer()
        server.on("GET", companyIssuesPath, .ok("[]"))
        let (inbox, _, _) = try model(server)
        await inbox.refresh()
        #expect(inbox.state == .empty)
    }

    @Test func emptySegmentIsEmptyEvenWhenOthersHaveRows() async throws {
        let server = StubServer()
        server.on("GET", companyIssuesPath, .ok(list(a2, a3)))
        let (inbox, _, _) = try model(server)
        await inbox.refresh()
        inbox.segment = .unread
        #expect(inbox.state == .empty)
    }

    @Test func serverErrorShowsAMessageWithoutTheKey() async throws {
        let server = StubServer()
        server.on("GET", companyIssuesPath, StubServer.Response(status: 500, body: JSON.unavailable))
        let log = LogSink()
        let (inbox, _, _) = try model(server, log: log)
        await inbox.refresh()

        #expect(inbox.state == .error(userMessage(for: APIError.server(status: 500, body: "Service unavailable"))))
        #expect(!log.lines.joined().contains(JSON.key))
    }

    @Test func unauthorizedSendsTheAccountToSignIn() async throws {
        let server = StubServer()
        server.on("GET", companyIssuesPath, StubServer.Response(status: 401, body: JSON.unauthorized))
        let (inbox, store, id) = try model(server)
        await inbox.refresh()

        #expect(inbox.state == .needsSignIn)
        #expect(store.route == .reSignIn(id))
    }

    @Test func pollAsksOnlyForChangesSinceTheNewestUpdateAndMergesById() async throws {
        let server = StubServer()
        let a1Replied = issueJSON(id: "issue-1", title: "Fix the login (renamed)", assigneeUserId: "user-1", unread: true,
                                  updatedAt: "2026-10-14T11:00:00.000Z")
        let a4 = issueJSON(id: "issue-4", title: "New thread", unread: true, updatedAt: "2026-10-14T11:05:00.000Z")
        server.on("GET", companyIssuesPath, .ok(list(a1, a2, a3)), .ok(list(a1Replied, a4)), .ok("[]"))
        let (inbox, _, _) = try model(server)
        await inbox.refresh()

        await inbox.poll()

        let first = try #require(server.requests("GET", companyIssuesPath).last)
        // The newest updatedAt seen (a2), in the server's clock: no device clock skew.
        #expect(query(first)["updatedSince"] == "2026-10-14T10:00:00.123Z")
        #expect(query(first)["touchedByUserId"] == "me")
        #expect(query(first)["inboxArchivedByUserId"] == "me")

        inbox.segment = .all
        guard case .loaded(let rows) = inbox.state else {
            Testing.Issue.record("expected loaded, got \(inbox.state)")
            return
        }
        #expect(rows.map(\.id) == ["issue-4", "issue-1", "issue-2", "issue-3"])
        #expect(rows.first { $0.id == "issue-1" }?.issue.title == "Fix the login (renamed)")

        await inbox.poll()
        let second = try #require(server.requests("GET", companyIssuesPath).last)
        #expect(query(second)["updatedSince"] == "2026-10-14T11:05:00.000Z")
        #expect(ids(inbox.state).count == 4)
    }

    @Test func pollMovesAThreadOutOfUnreadWhenItWasReadElsewhere() async throws {
        let server = StubServer()
        let a1Read = issueJSON(id: "issue-1", title: "Fix the login", assigneeUserId: "user-1", unread: false,
                               updatedAt: "2026-10-14T11:00:00.000Z")
        server.on("GET", companyIssuesPath, .ok(list(a1, a2)), .ok(list(a1Read)))
        let (inbox, _, _) = try model(server)
        await inbox.refresh()
        #expect(ids(inbox.state) == ["issue-1"])

        await inbox.poll()
        #expect(inbox.state == .empty)
        #expect(inbox.count(.all) == 2)
    }

    @Test func pollBeforeAnyLoadDoesAFullFetch() async throws {
        let server = StubServer()
        server.on("GET", companyIssuesPath, .ok(list(a1)))
        let (inbox, _, _) = try model(server)

        await inbox.poll()

        #expect(query(server.requests("GET", companyIssuesPath).last)["updatedSince"] == nil)
        #expect(ids(inbox.state) == ["issue-1"])
    }

    @Test func failedPollKeepsTheRowsOnScreen() async throws {
        let server = StubServer()
        server.on("GET", companyIssuesPath, .ok(list(a1)), StubServer.Response(status: 503, body: JSON.unavailable))
        let (inbox, _, _) = try model(server)
        await inbox.refresh()

        await inbox.poll()

        #expect(ids(inbox.state) == ["issue-1"])
    }

    @Test func unauthorizedPollSendsTheAccountToSignIn() async throws {
        let server = StubServer()
        server.on("GET", companyIssuesPath, .ok(list(a1)), StubServer.Response(status: 401, body: JSON.unauthorized))
        let (inbox, store, id) = try model(server)
        await inbox.refresh()

        await inbox.poll()

        #expect(inbox.state == .needsSignIn)
        #expect(store.route == .reSignIn(id))
    }

    @Test func pullToRefreshIsAFullFetch() async throws {
        let server = StubServer()
        server.on("GET", companyIssuesPath, .ok(list(a1, a2)), .ok(list(a2)))
        let (inbox, _, _) = try model(server)
        await inbox.refresh()

        await inbox.refresh()

        #expect(query(server.requests("GET", companyIssuesPath).last)["updatedSince"] == nil)
        // A full fetch replaces the list: a1 was archived or left the inbox elsewhere.
        inbox.segment = .all
        #expect(ids(inbox.state) == ["issue-2"])
    }

    @Test func pollingTicksEveryFifteenSecondsUntilCancelled() async throws {
        let server = StubServer()
        server.on("GET", companyIssuesPath, .ok(list(a1)))
        let (store, id) = try signedInStore(server)
        let sleeper = TestSleeper(ticks: 3)
        let inbox = InboxModel(store: store, accountID: id, poller: Poller(sleep: { try await sleeper.sleep($0) }))

        await inbox.runPolling()

        #expect(sleeper.durations == [.seconds(15), .seconds(15), .seconds(15), .seconds(15)])
        // First poll is a full fetch (nothing loaded), the next two are deltas.
        #expect(server.requests("GET", companyIssuesPath).count == 3)
        #expect(Poller.interval == .seconds(15))
    }
}
