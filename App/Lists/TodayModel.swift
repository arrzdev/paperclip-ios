import Foundation
import PaperclipAPI

/// A "Needs you" card: a request, approval or review from the attention feed,
/// or one of my open tasks.
struct NeedsYouCard: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        case interaction, approval, review, assignedTask
    }

    let id: String
    let kind: Kind
    let title: String
    let identifier: String?
    let detail: String?
    /// The issue the card belongs to; nil for an approval without one.
    let issueID: String?
    /// Path in the web UI; Open goes there when the card has no issue.
    let webPath: String?
    /// The request behind an interaction card, with its buttons; nil when its
    /// fetch failed (the card only opens the task).
    var request: InteractionCard? = nil
}

/// An unread thread with the first line of its newest reply not written by me.
struct ReplyRow: Equatable, Identifiable, Sendable {
    let issue: Issue
    let preview: String?

    var id: String { issue.id }
}

struct TodayContent: Equatable, Sendable {
    let needsYou: [NeedsYouCard]
    let newReplies: [ReplyRow]
}

/// The line at the bottom of Today.
struct Pulse: Equatable, Sendable {
    let working: Int
    let blocked: Int
    let doneToday: Int

    var text: String {
        let agents = working == 1 ? "agent" : "agents"
        return "\(working) \(agents) working · \(blocked) blocked · \(doneToday) done today"
    }
}

/// Web UI path of an issue: `PAP-12` → `/PAP/issues/PAP-12`.
func webPath(identifier: String?) -> String? {
    guard let identifier, let prefix = identifier.split(separator: "-").first, !prefix.isEmpty else { return nil }
    return "/\(prefix)/issues/\(identifier)"
}

/// The Today tab: "Needs you" cards (attention feed + my open tasks), "New
/// replies" (unread threads with a preview) and the pulse line. `poll()`
/// refetches the cards and the pulse, and asks only for replies changed since
/// the newest `updatedAt` loaded. Previews are fetched only for new or changed
/// threads. Swipe on a reply marks it read or archives it, like the Inbox.
@MainActor
@Observable
final class TodayModel {
    let store: AccountStore
    let accountID: UUID
    private let poller: Poller
    private let now: @Sendable () -> Date
    private let calendar: Calendar

    static let replyLimit = 10
    static let emptyMessage = "All clear. Nothing needs you."
    static let assignedStatuses: [IssueStatus] = [.todo, .inProgress, .inReview, .blocked]

    private var cards: [NeedsYouCard]?
    /// Unread threads by id; nil before the first successful load.
    private var replies: [String: Issue]?
    private var previews: [String: CachedPreview] = [:]
    /// Preview fetches that failed, by thread stamp; retried on refresh.
    private var failedPreviews: [String: Date] = [:]
    /// Read or archived by a swipe; the replies query no longer returns them.
    private var hiddenIDs: Set<String> = []
    private var failure: LoadState<TodayContent>?

    /// Nil until loaded and when the dashboard failed.
    private(set) var pulse: Pulse?
    private(set) var undo: InboxUndo?
    /// Set when an action failed and was rolled back.
    private(set) var actionError: String?
    /// Accept, Reject and Answer on request cards.
    let requests: RequestActions

    init(
        store: AccountStore,
        accountID: UUID,
        poller: Poller = .live,
        now: @escaping @Sendable () -> Date = { Date() },
        calendar: Calendar = .current
    ) {
        self.store = store
        self.accountID = accountID
        self.poller = poller
        self.now = now
        self.calendar = calendar
        requests = RequestActions(store: store, accountID: accountID)
    }

    var state: LoadState<TodayContent> {
        if requests.needsSignIn { return .needsSignIn }
        if let failure { return failure }
        guard let cards, replies != nil else { return .loading }
        // A request answered here leaves at once.
        let visible = cards.filter { card in card.request.map { !requests.isHidden($0.id) } ?? true }
        let rows = visibleReplies().map { ReplyRow(issue: $0, preview: previews[$0.id]?.text) }
        if visible.isEmpty && rows.isEmpty { return .empty }
        return .loaded(TodayContent(needsYou: visible, newReplies: rows))
    }

    /// Full fetch (screen appears, pull to refresh).
    func refresh() async {
        async let cardsResult = self.loadCards()
        async let repliesResult = self.loadReplies(since: nil)
        async let pulseResult = self.loadPulse()
        let (cards, replies, pulse) = await (cardsResult, repliesResult, pulseResult)
        self.pulse = pulse
        switch (cards, replies) {
        case (.success(let cards), .success(let replies)):
            self.cards = cards
            self.replies = Dictionary(replies.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            hiddenIDs = []
            failedPreviews = [:]
            failure = nil
        case (.failure(let error), _), (_, .failure(let error)):
            let unauthorized = [cards.error, replies.error].contains { $0.map(isUnauthorized) == true }
            failure = unauthorized ? .needsSignIn : .error(userMessage(for: error))
            store.log("Today failed for account \(accountID): \(userMessage(for: error))")
            return
        }
        await loadPreviews()
    }

    /// Cards and pulse again, replies changed since the newest `updatedAt`
    /// loaded (the server's clock), merged by id. Before any load it is a full
    /// fetch. A failed poll keeps what is on screen; a 401 ends in `needsSignIn`.
    func poll() async {
        guard let loaded = replies, cards != nil, failure == nil else {
            await refresh()
            return
        }
        let since = loaded.values.map(\.updatedAt).max()
        async let cardsResult = self.loadCards()
        async let repliesResult = self.loadReplies(since: since)
        async let pulseResult = self.loadPulse()
        let (newCards, changed, newPulse) = await (cardsResult, repliesResult, pulseResult)
        if [newCards.error, changed.error].contains(where: { $0.map(isUnauthorized) == true }) {
            failure = .needsSignIn
            return
        }
        if case .success(let fetched) = newCards { cards = fetched }
        if case .success(let changedIssues) = changed {
            var merged = replies ?? loaded
            for issue in changedIssues {
                merged[issue.id] = issue
                hiddenIDs.remove(issue.id)
            }
            replies = merged
        }
        if let newPulse { pulse = newPulse }
        if let error = newCards.error ?? changed.error {
            store.log("Today poll failed for account \(accountID): \(userMessage(for: error))")
        }
        await loadPreviews()
    }

    /// Polls every `Poller.interval` until the calling task is cancelled.
    func runPolling() async {
        await poller.run { await self.poll() }
    }

    /// The web page for a card, on this account's server.
    func webURL(for path: String?) -> URL? {
        guard let path, let base = account?.server.baseURL.absoluteString else { return nil }
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        return URL(string: trimmed + path)
    }

    // MARK: - Swipe actions on New replies

    /// `POST /issues/:id/read`; the reply leaves the list.
    func markRead(_ row: ReplyRow) async {
        await perform(.read, on: row.id, undo: .markedRead)
    }

    /// `POST /issues/:id/inbox-archive`; the reply leaves the list.
    func archive(_ row: ReplyRow) async {
        await perform(.archive, on: row.id, undo: .archived)
    }

    /// Reverses the last action if its window is still open.
    func undoLast() async {
        guard let last = undo else { return }
        undo = nil
        guard now() < last.expiresAt else { return }
        let change: Change = last.action == .archived ? .unarchive : .unread
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

    private struct CachedPreview {
        /// `lastExternalCommentAt` (or `updatedAt`) of the thread when fetched.
        let stamp: Date
        let text: String?
    }

    private struct PreviewFetch: Sendable {
        let issueID: String
        let stamp: Date
        let text: String?
        let failed: Bool
    }

    private enum Change {
        case read, unread, archive, unarchive
    }

    private var account: Account? {
        store.accounts.first { $0.id == accountID }
    }

    private func companyID() throws -> String {
        guard let companyId = account?.selectedCompanyId else { throw AccountStoreError.unknownAccount }
        return companyId
    }

    /// Requests, approvals and reviews from the attention feed, then my open
    /// tasks that no request card already points at.
    private func loadCards() async -> Result<[NeedsYouCard], Error> {
        do {
            let companyId = try companyID()
            let feed = try await store.call(accountID) { try await $0.attention(companyId: companyId) }
            var query = IssueListQuery()
            query.assigneeUserId = "me"
            query.status = Self.assignedStatuses
            let mine = try await store.call(accountID) { try await $0.issues(companyId: companyId, query: query) }

            let attention = try await withRequests(feed.items.compactMap(Self.card(for:)))
            let carded = Set(attention.compactMap(\.issueID))
            let tasks = mine.filter { !carded.contains($0.id) }.map { issue in
                NeedsYouCard(
                    id: issue.id, kind: .assignedTask, title: issue.title, identifier: issue.identifier,
                    detail: issue.status.label, issueID: issue.id, webPath: webPath(identifier: issue.identifier)
                )
            }
            return .success(attention + tasks)
        } catch {
            return .failure(error)
        }
    }

    /// Pairs each interaction card with its request, one fetch per task. A
    /// request no longer pending drops its card; a failed fetch leaves the
    /// card without buttons, except a 401.
    private func withRequests(_ entries: [(card: NeedsYouCard, subjectID: String)]) async throws -> [NeedsYouCard] {
        var issueIDs: [String] = []
        for entry in entries where entry.card.kind == .interaction {
            if let issueID = entry.card.issueID, !issueIDs.contains(issueID) { issueIDs.append(issueID) }
        }
        var interactions: [String: [IssueInteraction]] = [:]
        for issueID in issueIDs {
            do {
                interactions[issueID] = try await store.call(accountID) { try await $0.interactions(issueId: issueID) }
            } catch {
                if isUnauthorized(error) { throw error }
                store.log("Today requests failed for account \(accountID): \(userMessage(for: error))")
            }
        }
        return entries.compactMap { entry -> NeedsYouCard? in
            var card = entry.card
            guard card.kind == .interaction, let issueID = card.issueID,
                  let interaction = interactions[issueID]?.first(where: { $0.id == entry.subjectID }) else { return card }
            guard interaction.status == .pending else { return nil }
            card.request = InteractionCard(interaction, identifier: card.identifier, issueTitle: card.title)
            return card
        }
    }

    /// Nil for attention kinds Today does not show (failed runs, budgets, …).
    private static func card(for item: AttentionItem) -> (card: NeedsYouCard, subjectID: String)? {
        let kind: NeedsYouCard.Kind
        switch item.sourceKind {
        case .issueThreadInteraction: kind = .interaction
        case .approval: kind = .approval
        case .review: kind = .review
        default: return nil
        }
        let issue = item.relatedIssue ?? (item.subject.kind == "issue" ? item.subject : nil)
        let identifier = issue?.identifier ?? item.subject.identifier
        let detail = item.detail?.promptExcerpt ?? item.detail?.firstQuestionText ?? item.detail?.summaryExcerpt
        let card = NeedsYouCard(
            id: item.id,
            kind: kind,
            title: issue?.title ?? item.subject.title ?? item.whyNow ?? "",
            identifier: identifier,
            detail: detail ?? item.whyNow,
            issueID: issue?.id,
            webPath: item.relatedIssue?.href ?? item.subject.href ?? webPath(identifier: identifier)
        )
        return (card, item.subject.id)
    }

    private func loadReplies(since: Date?) async -> Result<[Issue], Error> {
        do {
            let companyId = try companyID()
            var query = IssueListQuery.inbox
            query.unreadForUserId = "me"
            query.updatedSince = since
            return .success(try await store.call(accountID) { try await $0.issues(companyId: companyId, query: query) })
        } catch {
            return .failure(error)
        }
    }

    /// Running agents and blocked tasks from the dashboard, plus tasks
    /// completed since the start of today. Nil when either call fails.
    private func loadPulse() async -> Pulse? {
        do {
            let companyId = try companyID()
            let startOfToday = calendar.startOfDay(for: now())
            let dashboard = try await store.call(accountID) { try await $0.dashboard(companyId: companyId) }
            var query = IssueListQuery()
            query.status = [.done]
            query.updatedSince = startOfToday
            let done = try await store.call(accountID) { try await $0.issues(companyId: companyId, query: query) }
            let doneToday = done.filter { ($0.completedAt ?? .distantPast) >= startOfToday }.count
            return Pulse(working: dashboard.agents.running, blocked: dashboard.tasks.blocked, doneToday: doneToday)
        } catch {
            store.log("Today pulse failed for account \(accountID): \(userMessage(for: error))")
            return nil
        }
    }

    /// Unread, not swiped away, newest reply first, at most `replyLimit`.
    private func visibleReplies() -> [Issue] {
        let all: [Issue] = replies.map { Array($0.values) } ?? []
        let sorted = all
            .filter { !hiddenIDs.contains($0.id) && $0.isUnreadForMe != false }
            .sorted { first, second in
                let (a, b) = (replyTime(first), replyTime(second))
                return a == b ? first.id < second.id : a > b
            }
        return Array(sorted.prefix(Self.replyLimit))
    }

    private func replyTime(_ issue: Issue) -> Date {
        issue.lastExternalCommentAt ?? issue.lastActivityAt ?? issue.updatedAt
    }

    private func previewStamp(_ issue: Issue) -> Date {
        issue.lastExternalCommentAt ?? issue.updatedAt
    }

    /// Fetches previews of the visible threads that are new or changed since
    /// their last fetch. A failed preview is not an error: the row shows none.
    private func loadPreviews() async {
        let wanted = visibleReplies().filter { issue in
            let stamp = previewStamp(issue)
            return previews[issue.id]?.stamp != stamp && failedPreviews[issue.id] != stamp
        }
        guard !wanted.isEmpty else { return }
        let fetched = await withTaskGroup(of: PreviewFetch.self, returning: [PreviewFetch].self) { group in
            for issue in wanted {
                let issueID = issue.id
                let stamp = previewStamp(issue)
                group.addTask { await self.fetchPreview(issueID: issueID, stamp: stamp) }
            }
            var results: [PreviewFetch] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
        for result in fetched {
            if result.failed {
                failedPreviews[result.issueID] = result.stamp
            } else {
                previews[result.issueID] = CachedPreview(stamp: result.stamp, text: result.text)
                failedPreviews[result.issueID] = nil
            }
        }
    }

    /// First non-empty line of the newest of the last 5 comments not written by me.
    private func fetchPreview(issueID: String, stamp: Date) async -> PreviewFetch {
        let userId = account?.userId
        do {
            let comments = try await store.call(accountID) { try await $0.comments(issueId: issueID, limit: 5) }
            let reply = comments.first { $0.authorUserId == nil || $0.authorUserId != userId }
            let line = reply?.body
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty }
            return PreviewFetch(issueID: issueID, stamp: stamp, text: line, failed: false)
        } catch {
            store.log("Today preview failed for account \(accountID): \(userMessage(for: error))")
            return PreviewFetch(issueID: issueID, stamp: stamp, text: nil, failed: true)
        }
    }

    /// Applies `change` at once, then sends it. On error the previous local
    /// state comes back and `actionError` says why; a 401 ends in `needsSignIn`.
    private func perform(_ change: Change, on issueID: String, undo action: InboxAction?) async {
        let wasHidden = hiddenIDs.contains(issueID)
        let offered = action.map { InboxUndo(action: $0, issueID: issueID, expiresAt: now().addingTimeInterval(InboxModel.undoWindow)) }
        switch change {
        case .read, .archive: hiddenIDs.insert(issueID)
        case .unread, .unarchive: hiddenIDs.remove(issueID)
        }
        actionError = nil
        if let offered { undo = offered }
        do {
            try await store.call(accountID) { (client: APIClient) -> Void in
                switch change {
                case .read: try await client.markRead(issueId: issueID)
                case .unread: try await client.markUnread(issueId: issueID)
                case .archive: try await client.archiveFromInbox(issueId: issueID)
                case .unarchive: try await client.unarchiveFromInbox(issueId: issueID)
                }
            }
        } catch {
            if wasHidden { hiddenIDs.insert(issueID) } else { hiddenIDs.remove(issueID) }
            if let offered, undo == offered { undo = nil }
            if isUnauthorized(error) {
                failure = .needsSignIn
            } else {
                actionError = userMessage(for: error)
            }
            store.log("Today action failed for account \(accountID): \(userMessage(for: error))")
        }
    }
}

private func isUnauthorized(_ error: Error) -> Bool {
    if case APIError.unauthorized = error { return true }
    return false
}

private extension Result {
    var error: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
