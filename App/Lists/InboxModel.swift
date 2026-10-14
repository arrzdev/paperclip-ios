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

/// The Inbox tab: one fetch of the threads the user touched and has not
/// archived; the segments and the search filter it locally. `poll()` asks only
/// for changes since the newest `updatedAt` loaded and merges them by id.
@MainActor
@Observable
final class InboxModel {
    let store: AccountStore
    let accountID: UUID
    private let poller: Poller

    var segment: InboxSegment = .unread
    var searchText = ""

    /// Loaded issues by id; nil before the first successful load.
    private var issues: [String: Issue]?
    private var failure: LoadState<[InboxRow]>?

    init(store: AccountStore, accountID: UUID, poller: Poller = .live) {
        self.store = store
        self.accountID = accountID
        self.poller = poller
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

    // MARK: - Private

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
            .filter { issue in
                switch segment {
                case .unread:
                    return issue.isUnreadForMe == true
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
            .map { InboxRow(issue: $0, isUnread: $0.isUnreadForMe == true) }
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
