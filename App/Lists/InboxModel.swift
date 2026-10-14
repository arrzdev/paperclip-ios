import Foundation
import PaperclipAPI

enum InboxSegment: CaseIterable {
    case unread, mine, all

    var title: String {
        switch self {
        case .unread: "Unread"
        case .mine: "Mine"
        case .all: "All"
        }
    }
}

struct InboxRow: Equatable, Identifiable {
    let issue: Issue
    var isUnread: Bool

    var id: String { issue.id }
}

/// A swipe action that can be undone.
enum InboxAction: Equatable {
    case markedRead, markedUnread, archived

    /// Toast text.
    var title: String {
        switch self {
        case .markedRead: "Marked as read"
        case .markedUnread: "Marked as unread"
        case .archived: "Archived"
        }
    }
}

/// The last action, undoable until `expiresAt`.
struct InboxUndo: Equatable {
    let action: InboxAction
    let issueID: String
    let expiresAt: Date
}

/// The Inbox tab: one fetch of the threads the user touched and has not
/// archived; the segments and the search filter it locally. `poll()` asks only
/// for changes since the newest `updatedAt` loaded and merges them by id.
/// Swipe actions (read / unread, archive) change the list at once, roll back on
/// error and can be undone for `undoWindow`.
@MainActor
@Observable
final class InboxModel {
    let store: AccountStore
    let accountID: UUID
    private let poller: Poller
    private let now: @Sendable () -> Date

    static let undoWindow: TimeInterval = 5

    var segment: InboxSegment = .unread
    var searchText = ""

    /// Loaded issues by id; nil before the first successful load.
    private var issues: [String: Issue]?
    private var failure: LoadState<[InboxRow]>?
    /// Read state set by a swipe until the server sends the issue again.
    private var unreadOverrides: [String: Bool] = [:]
    /// Archived by a swipe; the inbox query no longer returns them.
    private var archivedIDs: Set<String> = []

    private(set) var undo: InboxUndo?
    /// Set when an action failed and was rolled back.
    private(set) var actionError: String?

    init(
        store: AccountStore,
        accountID: UUID,
        poller: Poller = .live,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.accountID = accountID
        self.poller = poller
        self.now = now
    }

    var state: LoadState<[InboxRow]> {
        if let failure { return failure }
        guard issues != nil else { return .loading }
        let rows = rows(in: segment).filter(matchesSearch)
        return rows.isEmpty ? .empty : .loaded(rows)
    }

    /// Threads in `segment`, ignoring the search.
    func count(_ segment: InboxSegment) -> Int {
        rows(in: segment).count
    }

    /// Full fetch: replaces the list (screen appears, pull to refresh).
    func refresh() async {
        do {
            let fetched = try await fetch(IssueListQuery.inbox)
            issues = Dictionary(fetched.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            unreadOverrides = [:]
            archivedIDs = []
            failure = nil
        } catch {
            failure = failureState(for: error)
            store.log("Inbox failed for account \(accountID): \(userMessage(for: error))")
        }
    }

    /// Changes since the newest `updatedAt` loaded (the server's clock), merged
    /// by id. Before any load it is a full fetch. A failed poll keeps the rows;
    /// a 401 still ends in `needsSignIn`.
    func poll() async {
        guard let loaded = issues, failure == nil else {
            await refresh()
            return
        }
        var query = IssueListQuery.inbox
        query.updatedSince = loaded.values.map(\.updatedAt).max()
        do {
            let changed = try await fetch(query)
            var merged = issues ?? loaded
            for issue in changed {
                merged[issue.id] = issue
                unreadOverrides[issue.id] = nil
                archivedIDs.remove(issue.id)
            }
            issues = merged
        } catch APIError.unauthorized {
            failure = .needsSignIn
        } catch {
            store.log("Inbox poll failed for account \(accountID): \(userMessage(for: error))")
        }
    }

    /// Polls every `Poller.interval` until the calling task is cancelled.
    func runPolling() async {
        await poller.run { await self.poll() }
    }

    // MARK: - Swipe actions

    /// Unread → `POST /issues/:id/read`, read → `DELETE`.
    func toggleRead(_ row: InboxRow) async {
        let change: Change = .unread(!row.isUnread)
        await perform(change, on: row.id, undo: row.isUnread ? .markedRead : .markedUnread)
    }

    /// `POST /issues/:id/inbox-archive`; the thread leaves every segment.
    func archive(_ row: InboxRow) async {
        await perform(.archived(true), on: row.id, undo: .archived)
    }

    /// Reverses the last action if its window is still open.
    func undoLast() async {
        guard let last = undo else { return }
        undo = nil
        guard now() < last.expiresAt else { return }
        let change: Change = switch last.action {
        case .markedRead: .unread(true)
        case .markedUnread: .unread(false)
        case .archived: .archived(false)
        }
        await perform(change, on: last.issueID, undo: nil)
    }

    /// Hides the undo toast once its window has passed.
    func clearExpiredUndo() {
        if let undo, now() >= undo.expiresAt { self.undo = nil }
    }

    func dismissActionError() {
        actionError = nil
    }

    // MARK: - Private

    private enum Change {
        case unread(Bool)
        case archived(Bool)
    }

    /// Applies `change` at once, then sends it. On error the previous local
    /// state comes back and `actionError` says why; a 401 ends in `needsSignIn`.
    private func perform(_ change: Change, on issueID: String, undo action: InboxAction?) async {
        let previousUnread = unreadOverrides[issueID]
        let wasArchived = archivedIDs.contains(issueID)
        let offered = action.map { InboxUndo(action: $0, issueID: issueID, expiresAt: now().addingTimeInterval(Self.undoWindow)) }
        switch change {
        case .unread(let unread): unreadOverrides[issueID] = unread
        case .archived(true): archivedIDs.insert(issueID)
        case .archived(false): archivedIDs.remove(issueID)
        }
        actionError = nil
        if let offered { undo = offered }
        do {
            try await store.call(accountID) { (client: APIClient) -> Void in
                switch change {
                case .unread(true): try await client.markUnread(issueId: issueID)
                case .unread(false): try await client.markRead(issueId: issueID)
                case .archived(true): try await client.archiveFromInbox(issueId: issueID)
                case .archived(false): try await client.unarchiveFromInbox(issueId: issueID)
                }
            }
        } catch {
            unreadOverrides[issueID] = previousUnread
            if wasArchived { archivedIDs.insert(issueID) } else { archivedIDs.remove(issueID) }
            if let offered, undo == offered { undo = nil }
            if case APIError.unauthorized = error {
                failure = .needsSignIn
            } else {
                actionError = userMessage(for: error)
            }
            store.log("Inbox action failed for account \(accountID): \(userMessage(for: error))")
        }
    }

    private var account: Account? {
        store.accounts.first { $0.id == accountID }
    }

    private func fetch(_ query: IssueListQuery) async throws -> [Issue] {
        guard let companyId = account?.selectedCompanyId else { throw AccountStoreError.unknownAccount }
        return try await store.call(accountID) { try await $0.issues(companyId: companyId, query: query) }
    }

    private func failureState(for error: Error) -> LoadState<[InboxRow]> {
        if case APIError.unauthorized = error { return .needsSignIn }
        return .error(userMessage(for: error))
    }

    /// Newest activity first.
    private func rows(in segment: InboxSegment) -> [InboxRow] {
        let userId = account?.userId
        let all: [Issue] = issues.map { Array($0.values) } ?? []
        return all
            .filter { !archivedIDs.contains($0.id) }
            .filter { issue in
                switch segment {
                case .unread:
                    return isUnread(issue)
                case .mine:
                    guard let userId else { return false }
                    return issue.assigneeUserId == userId || issue.createdByUserId == userId
                case .all:
                    return true
                }
            }
            .sorted { first, second in
                let (a, b) = (activity(first), activity(second))
                return a == b ? first.id < second.id : a > b
            }
            .map { InboxRow(issue: $0, isUnread: isUnread($0)) }
    }

    private func isUnread(_ issue: Issue) -> Bool {
        unreadOverrides[issue.id] ?? (issue.isUnreadForMe == true)
    }

    private func activity(_ issue: Issue) -> Date {
        issue.lastActivityAt ?? issue.updatedAt
    }

    private func matchesSearch(_ row: InboxRow) -> Bool {
        let text = searchText.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return true }
        return row.issue.title.localizedCaseInsensitiveContains(text)
            || (row.issue.identifier?.localizedCaseInsensitiveContains(text) ?? false)
    }
}
