import Foundation
import PaperclipAPI
import Testing
@testable import PaperclipIOS

/// Swipe actions on the Inbox: right = read / unread, left = archive.
/// Optimistic, rolled back on error, undo for 5 s.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct InboxActionsTests {
    let unreadIssue = issueJSON(id: "issue-1", title: "Fix the login", assigneeUserId: "user-1", unread: true,
                                updatedAt: "2026-10-14T10:00:00.000Z")
    let readIssue = issueJSON(id: "issue-2", title: "Board chat", createdByUserId: "user-1", unread: false,
                              updatedAt: "2026-10-14T09:00:00.000Z")
    let readPath = "/api/issues/issue-1/read"
    let archivePath = "/api/issues/issue-1/inbox-archive"
    let start = iso("2026-10-14T12:00:00.000Z")

    private func loadedInbox(
        _ server: StubServer, clock: TestClock? = nil
    ) async throws -> (InboxModel, AccountStore, UUID) {
        server.on("GET", companyIssuesPath, .ok(list(unreadIssue, readIssue)))
        let (store, id) = try signedInStore(server)
        let clock = clock ?? TestClock(start)
        let inbox = InboxModel(store: store, accountID: id, now: { clock.now })
        await inbox.refresh()
        inbox.segment = .all
        return (inbox, store, id)
    }

    private func rows(_ inbox: InboxModel) -> [InboxRow] {
        if case .loaded(let rows) = inbox.state { return rows }
        return []
    }

    private func row(_ inbox: InboxModel, _ id: String) throws -> InboxRow {
        try #require(rows(inbox).first { $0.id == id })
    }

    // MARK: Archive (swipe left)

    @Test func archiveHidesTheThreadAndOffersUndo() async throws {
        let server = StubServer()
        server.on("POST", archivePath, .ok(#"{"ok":true}"#))
        let (inbox, _, _) = try await loadedInbox(server)

        await inbox.archive(try row(inbox, "issue-1"))

        #expect(server.requests("POST", archivePath).count == 1)
        #expect(rows(inbox).map(\.id) == ["issue-2"])
        #expect(inbox.count(.all) == 1)
        #expect(inbox.count(.unread) == 0)
        #expect(inbox.undo == InboxUndo(action: .archived, issueID: "issue-1", expiresAt: start.addingTimeInterval(5)))
        #expect(inbox.actionError == nil)
    }

    @Test func failedArchivePutsTheThreadBack() async throws {
        let server = StubServer()
        server.on("POST", archivePath, StubServer.Response(status: 500, body: JSON.unavailable))
        let (inbox, _, _) = try await loadedInbox(server)

        await inbox.archive(try row(inbox, "issue-1"))

        #expect(rows(inbox).map(\.id) == ["issue-1", "issue-2"])
        #expect(inbox.undo == nil)
        #expect(inbox.actionError == userMessage(for: APIError.server(status: 500, body: "Service unavailable")))
    }

    @Test func undoArchiveUnarchivesAndShowsTheThreadAgain() async throws {
        let server = StubServer()
        server.on("POST", archivePath, .ok(#"{"ok":true}"#))
        server.on("DELETE", archivePath, .ok(#"{"ok":true}"#))
        let (inbox, _, _) = try await loadedInbox(server)
        await inbox.archive(try row(inbox, "issue-1"))

        await inbox.undoLast()

        #expect(server.requests("DELETE", archivePath).count == 1)
        #expect(rows(inbox).map(\.id) == ["issue-1", "issue-2"])
        #expect(inbox.undo == nil)
    }

    // MARK: Read / unread (swipe right)

    @Test func swipeOnAnUnreadThreadMarksItRead() async throws {
        let server = StubServer()
        server.on("POST", readPath, .ok(#"{"ok":true}"#))
        let (inbox, _, _) = try await loadedInbox(server)

        await inbox.toggleRead(try row(inbox, "issue-1"))

        #expect(server.requests("POST", readPath).count == 1)
        #expect(try row(inbox, "issue-1").isUnread == false)
        #expect(inbox.count(.unread) == 0)
        inbox.segment = .unread
        #expect(inbox.state == .empty)
        #expect(inbox.undo == InboxUndo(action: .markedRead, issueID: "issue-1", expiresAt: start.addingTimeInterval(5)))
    }

    @Test func swipeOnAReadThreadMarksItUnread() async throws {
        let server = StubServer()
        server.on("DELETE", "/api/issues/issue-2/read", .ok(#"{"ok":true}"#))
        let (inbox, _, _) = try await loadedInbox(server)

        await inbox.toggleRead(try row(inbox, "issue-2"))

        #expect(server.requests("DELETE", "/api/issues/issue-2/read").count == 1)
        #expect(try row(inbox, "issue-2").isUnread == true)
        #expect(inbox.count(.unread) == 2)
        #expect(inbox.undo?.action == .markedUnread)
    }

    @Test func failedReadRollsBack() async throws {
        let server = StubServer()
        server.on("POST", readPath, StubServer.Response(status: 503, body: JSON.unavailable))
        let (inbox, _, _) = try await loadedInbox(server)

        await inbox.toggleRead(try row(inbox, "issue-1"))

        #expect(try row(inbox, "issue-1").isUnread == true)
        #expect(inbox.undo == nil)
        #expect(inbox.actionError != nil)
    }

    @Test func undoReadMarksItUnreadAgain() async throws {
        let server = StubServer()
        server.on("POST", readPath, .ok(#"{"ok":true}"#))
        server.on("DELETE", readPath, .ok(#"{"ok":true}"#))
        let (inbox, _, _) = try await loadedInbox(server)
        await inbox.toggleRead(try row(inbox, "issue-1"))

        await inbox.undoLast()

        #expect(server.requests("DELETE", readPath).count == 1)
        #expect(try row(inbox, "issue-1").isUnread == true)
        #expect(inbox.undo == nil)
    }

    // MARK: Undo window, 401

    @Test func undoAfterFiveSecondsDoesNothing() async throws {
        let server = StubServer()
        server.on("POST", archivePath, .ok(#"{"ok":true}"#))
        server.on("DELETE", archivePath, .ok(#"{"ok":true}"#))
        let clock = TestClock(start)
        let (inbox, _, _) = try await loadedInbox(server, clock: clock)
        await inbox.archive(try row(inbox, "issue-1"))

        try await clock.sleep(.seconds(5))
        await inbox.undoLast()

        #expect(server.requests("DELETE", archivePath).isEmpty)
        #expect(rows(inbox).map(\.id) == ["issue-2"])
        #expect(inbox.undo == nil)
    }

    @Test func aNewActionReplacesTheUndo() async throws {
        let server = StubServer()
        server.on("POST", archivePath, .ok(#"{"ok":true}"#))
        server.on("DELETE", "/api/issues/issue-2/read", .ok(#"{"ok":true}"#))
        let (inbox, _, _) = try await loadedInbox(server)

        await inbox.archive(try row(inbox, "issue-1"))
        await inbox.toggleRead(try row(inbox, "issue-2"))

        #expect(inbox.undo?.issueID == "issue-2")
        #expect(inbox.undo?.action == .markedUnread)
    }

    @Test func unauthorizedActionSendsTheAccountToSignIn() async throws {
        let server = StubServer()
        server.on("POST", archivePath, StubServer.Response(status: 401, body: JSON.unauthorized))
        let (inbox, store, id) = try await loadedInbox(server)

        await inbox.archive(try row(inbox, "issue-1"))

        #expect(inbox.state == .needsSignIn)
        #expect(store.route == .reSignIn(id))
        #expect(inbox.undo == nil)
    }
}
