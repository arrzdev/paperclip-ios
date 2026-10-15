import Foundation
import PaperclipAPI

// SCRATCH: signature-only stubs to prove the tests compile.

struct SearchDebounce {
    static let delay: Duration = .milliseconds(300)
    let sleep: @Sendable (Duration) async throws -> Void
    static let live = SearchDebounce(sleep: { try await Task.sleep(for: $0) })
    static func term(_ text: String) -> String? { nil }
    func wait() async -> Bool { false }
}

enum TaskStatusFilter: CaseIterable, Hashable {
    case open, all, backlog, todo, inProgress, inReview, blocked, done, cancelled
    var title: String { "" }
    var statuses: [IssueStatus] { [] }
}

enum TaskAssigneeFilter: Hashable {
    case anyone, me, agent(String)
}

struct TaskSection: Equatable, Identifiable {
    let id: String
    let title: String
    let issues: [Issue]
}

@MainActor
@Observable
final class TasksModel {
    static let pageSize = 50
    var status: TaskStatusFilter = .open
    var assignee: TaskAssigneeFilter = .anyone
    var searchText = ""
    private(set) var state: LoadState<[TaskSection]> = .loading
    private(set) var hasMore = false
    private(set) var pageError: String?
    private(set) var assigneeOptions: [TaskAssigneeFilter] = []

    init(store: AccountStore, accountID: UUID, debounce: SearchDebounce = .live) {}

    static func query(status: TaskStatusFilter, assignee: TaskAssigneeFilter, search: String?, offset: Int) -> IssueListQuery {
        IssueListQuery()
    }

    func assigneeTitle(_ option: TaskAssigneeFilter) -> String { "" }
    func refresh() async {}
    func loadMore() async {}
    func search() async {}
}
