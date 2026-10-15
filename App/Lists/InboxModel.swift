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
    private let debounce: SearchDebounce

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
    /// Server results (inbox query plus `q`) for `searchedTerm`, by id.
    private var searchResults: [String: Issue]?
    private var searchedTerm: String?

    private(set) var undo: InboxUndo?
    /// Set when an action failed and was rolled back.
    private(set) var actionError: String?

    init(
        store: AccountStore,
        accountID: UUID,
        poller: Poller = .live,
        now: @escaping @Sendable () -> Date = { Date() },
        debounce: SearchDebounce = .live
    ) {
        self.store = store
        self.accountID = accountID
        self.poller = poller
        self.now = now
        self.debounce = debounce
    }

    var state: LoadState<[InboxRow]> {
        if let failure { return failure }
        guard let issues else { return .loading }
        let rows: [InboxRow]
        if let results = activeSearchResults {
            rows = self.rows(in: segment, from: results)
        } else {
            rows = self.rows(in: segment, from: issues).filter(matchesSearch)
        }
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
            return
        }
        if let term = searchedTerm {
            await runSearch(term)
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
                if searchResults?[issue.id] != nil { searchResults?[issue.id] = issue }
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

    /// Server search after `SearchDebounce.delay`: the inbox query plus `q`
    /// (titles, descriptions and comments). Its results replace the local title
    /// filter while the text is unchanged; segments and swipes still apply.
    /// Blank text drops them without a request. Never logs the text.
    func search() async {
        guard let term = SearchDebounce.term(searchText) else {
            searchResults = nil
            searchedTerm = nil
            return
        }
        guard term != searchedTerm else { return }
        guard await debounce.wait() else { return }
        await runSearch(term)
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

    /// A failure keeps the local title filter; a 401 ends in `needsSignIn`.
    private func runSearch(_ term: String) async {
        var query = IssueListQuery.inbox
        query.search = term
        do {
            let found = try await fetch(query)
            searchResults = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            searchedTerm = term
        } catch APIError.unauthorized {
            failure = .needsSignIn
        } catch {
            searchResults = nil
            searchedTerm = nil
            if !Task.isCancelled {
                store.log("Inbox search failed for account \(accountID): \(userMessage(for: error))")
            }
        }
    }

    /// Server results while they match the text in the field.
    private var activeSearchResults: [String: Issue]? {
        guard let searchedTerm, searchedTerm == SearchDebounce.term(searchText) else { return nil }
        return searchResults
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

    private func rows(in segment: InboxSegment) -> [InboxRow] {
        rows(in: segment, from: issues ?? [:])
    }

    /// Newest activity first.
    private func rows(in segment: InboxSegment, from source: [String: Issue]) -> [InboxRow] {
        let userId = account?.userId
        return Array(source.values)
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
