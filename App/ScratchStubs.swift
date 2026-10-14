import Foundation
import PaperclipAPI

// Scratch: signatures only, to type-check the tests. Not for merge.

enum LoadState<Value: Equatable>: Equatable {
    case loading
    case loaded(Value)
    case empty
    case error(String)
    case needsSignIn
}

enum AppTab: CaseIterable {
    case today, inbox, tasks, me
    var title: String { "" }
}

struct Poller: Sendable {
    static let interval: Duration = .seconds(15)
    static let live = Poller(sleep: { try await Task.sleep(for: $0) })
    let sleep: @Sendable (Duration) async throws -> Void
    func run(_ tick: () async -> Void) async {}
}

enum InboxSegment: CaseIterable {
    case unread, mine, all
    var title: String { "" }
}

struct InboxRow: Equatable, Identifiable {
    let issue: Issue
    var isUnread: Bool
    var id: String { issue.id }
}

enum InboxAction: Equatable {
    case markedRead, markedUnread, archived
}

struct InboxUndo: Equatable {
    let action: InboxAction
    let issueID: String
    let expiresAt: Date
}

@MainActor
@Observable
final class InboxModel {
    var segment: InboxSegment = .unread
    var searchText = ""
    private(set) var undo: InboxUndo?
    private(set) var actionError: String?

    init(store: AccountStore, accountID: UUID, poller: Poller = .live, now: @escaping @Sendable () -> Date = { Date() }) {}

    var state: LoadState<[InboxRow]> { .loading }
    func count(_ segment: InboxSegment) -> Int { 0 }
    func refresh() async {}
    func poll() async {}
    func runPolling() async {}
    func toggleRead(_ row: InboxRow) async {}
    func archive(_ row: InboxRow) async {}
    func undoLast() async {}
}

struct NeedsYouCard: Equatable, Identifiable {
    enum Kind: Equatable { case interaction, approval, review, assignedTask }
    let id: String
    let kind: Kind
    let title: String
    let identifier: String?
    let detail: String?
    let issueID: String?
    let webPath: String?
}

struct ReplyRow: Equatable, Identifiable {
    let issue: Issue
    let preview: String?
    var id: String { issue.id }
}

struct TodayContent: Equatable {
    var needsYou: [NeedsYouCard]
    var newReplies: [ReplyRow]
}

struct Pulse: Equatable {
    let working: Int
    let blocked: Int
    let doneToday: Int
    var text: String { "" }
}

func webPath(identifier: String?) -> String? { nil }

@MainActor
@Observable
final class TodayModel {
    static let replyLimit = 10
    static let emptyMessage = ""
    private(set) var pulse: Pulse?
    private(set) var undo: InboxUndo?
    private(set) var actionError: String?

    init(
        store: AccountStore, accountID: UUID, poller: Poller = .live,
        now: @escaping @Sendable () -> Date = { Date() }, calendar: Calendar = .current
    ) {}

    var state: LoadState<TodayContent> { .loading }
    func refresh() async {}
    func poll() async {}
    func runPolling() async {}
    func markRead(_ row: ReplyRow) async {}
    func archive(_ row: ReplyRow) async {}
}
