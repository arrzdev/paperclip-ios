import Foundation
import PaperclipAPI
import Testing
@testable import PaperclipIOS

/// The undo toast hides at `expiresAt`; the error banner can be dismissed.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct InboxUndoToastTests {
    let archivePath = "/api/issues/issue-1/inbox-archive"
    let start = iso("2026-10-14T12:00:00.000Z")

    private func archivedInbox(_ server: StubServer, clock: TestClock) async throws -> InboxModel {
        server.on("GET", companyIssuesPath, .ok(list(issueJSON(id: "issue-1", unread: true))))
        let (store, id) = try signedInStore(server)
        let inbox = InboxModel(store: store, accountID: id, now: { clock.now })
        await inbox.refresh()
        guard case .loaded(let rows) = inbox.state else { throw CancellationError() }
        await inbox.archive(try #require(rows.first))
        return inbox
    }

    @Test func undoStaysUntilItExpires() async throws {
        let server = StubServer()
        server.on("POST", archivePath, .ok(#"{"ok":true}"#))
        let clock = TestClock(start)
        let inbox = try await archivedInbox(server, clock: clock)

        try await clock.sleep(.seconds(4))
        inbox.clearExpiredUndo()
        #expect(inbox.undo?.action == .archived)

        try await clock.sleep(.seconds(1))
        inbox.clearExpiredUndo()
        #expect(inbox.undo == nil)
    }

    @Test func errorBannerCanBeDismissed() async throws {
        let server = StubServer()
        server.on("POST", archivePath, StubServer.Response(status: 500, body: JSON.unavailable))
        let inbox = try await archivedInbox(server, clock: TestClock(start))
        #expect(inbox.actionError != nil)

        inbox.dismissActionError()

        #expect(inbox.actionError == nil)
    }
}
