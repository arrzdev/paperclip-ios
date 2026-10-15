import Foundation
import PaperclipAPI

/// The status picker of the Tasks tab.
enum TaskStatusFilter: CaseIterable, Hashable {
    case open, all, backlog, todo, inProgress, inReview, blocked, done, cancelled

    var title: String {
        switch self {
        case .open: "Open"
        case .all: "All"
        case .backlog: "Backlog"
        case .todo: "To do"
        case .inProgress: "In progress"
        case .inReview: "In review"
        case .blocked: "Blocked"
        case .done: "Done"
        case .cancelled: "Cancelled"
        }
    }

    /// The `status` filter sent; empty = every status.
    var statuses: [IssueStatus] {
        switch self {
        case .open: [.backlog, .todo, .inProgress, .inReview, .blocked]
        case .all: []
        case .backlog: [.backlog]
        case .todo: [.todo]
        case .inProgress: [.inProgress]
        case .inReview: [.inReview]
        case .blocked: [.blocked]
        case .done: [.done]
        case .cancelled: [.cancelled]
        }
    }
}

/// The assignee picker of the Tasks tab.
enum TaskAssigneeFilter: Hashable {
    case anyone
    /// `assigneeUserId=me`.
    case me
    /// `assigneeAgentId=<id>`.
    case agent(String)
}

/// Tasks of one project, in the server's order.
struct TaskSection: Equatable, Identifiable {
    /// The project id, "other" (a project not in the list) or "none".
    let id: String
    let title: String
    let issues: [Issue]
}

/// The Tasks tab: the whole company's tasks (never the inbox filters), filtered
/// by status and assignee, searched on the server (`q`) after a pause, in pages
/// of `pageSize`. Sections by project name, then "Other project", then
/// "No project". A failed project or agent fetch only loses names. No polling.
@MainActor
@Observable
final class TasksModel {
    static let pageSize = 50

    let store: AccountStore
    let accountID: UUID
    private let debounce: SearchDebounce

    var status: TaskStatusFilter = .open
    var assignee: TaskAssigneeFilter = .anyone
    var searchText = ""

    private(set) var state: LoadState<[TaskSection]> = .loading
    /// The last page was full: "Load more" may bring more.
    private(set) var hasMore = false
    private(set) var isLoadingMore = false
    /// Why the last "Load more" failed; the rows stay.
    private(set) var pageError: String?
    private(set) var assigneeOptions: [TaskAssigneeFilter] = [.anyone, .me]

    /// Loaded tasks in the server's order, without duplicates.
    private var issues: [Issue] = []
    private var projects: [Project] = []
    /// Agents that can take work (terminated ones left out).
    private var agents: [Agent] = []
    /// The first-page query of the rows on screen; nil until a load succeeds.
    private var loadedQuery: IssueListQuery?
    private var nextOffset = 0
    /// The search term of the last first-page load. `requestIsCurrent` is false
    /// when that load was cancelled, so the same term is sent again.
    private var requestedSearch: String?
    private var requestIsCurrent = true
    /// Bumped by every first-page load, so an older answer is dropped.
    private var generation = 0

    init(store: AccountStore, accountID: UUID, debounce: SearchDebounce = .live) {
        self.store = store
        self.accountID = accountID
        self.debounce = debounce
    }

    static func query(status: TaskStatusFilter, assignee: TaskAssigneeFilter, search: String?, offset: Int) -> IssueListQuery {
        var query = IssueListQuery()
        query.status = status.statuses
        switch assignee {
        case .anyone: break
        case .me: query.assigneeUserId = "me"
        case .agent(let id): query.assigneeAgentId = id
        }
        query.search = search.flatMap { SearchDebounce.term($0) }
        query.limit = pageSize
        query.offset = offset > 0 ? offset : nil
        return query
    }

    func assigneeTitle(_ option: TaskAssigneeFilter) -> String {
        switch option {
        case .anyone: "Anyone"
        case .me: "Me"
        case .agent(let id): agents.first { $0.id == id }?.name ?? "Agent"
        }
    }

    /// First page with the current filters and search, plus projects and
    /// agents (screen appears, filter change, pull to refresh).
    func refresh() async {
        await loadFirstPage(search: SearchDebounce.term(searchText), withExtras: true)
    }

    /// Server search after `SearchDebounce.delay`; nothing when the term is the
    /// one already loaded or the wait was cancelled. Never logs the text.
    func search() async {
        let term = SearchDebounce.term(searchText)
        if requestIsCurrent && term == requestedSearch { return }
        guard await debounce.wait() else { return }
        await loadFirstPage(search: term, withExtras: false)
    }

    /// The next page with the same filters and search, appended. A failure
    /// keeps the rows and sets `pageError`; a 401 ends in `needsSignIn`.
    func loadMore() async {
        guard hasMore, !isLoadingMore, case .loaded = state, var query = loadedQuery else { return }
        query.offset = nextOffset
        let generation = self.generation
        isLoadingMore = true
        pageError = nil
        defer { isLoadingMore = false }
        do {
            let page = try await fetch(query)
            guard generation == self.generation else { return }
            append(page)
            nextOffset += page.count
            hasMore = page.count >= Self.pageSize
            publish()
        } catch {
            guard generation == self.generation, !Task.isCancelled else { return }
            if case APIError.unauthorized = error {
                state = .needsSignIn
                hasMore = false
            } else {
                pageError = userMessage(for: error)
            }
            store.log("Tasks page failed for account \(accountID): \(userMessage(for: error))")
        }
    }

    // MARK: - Private

    private func loadFirstPage(search: String?, withExtras: Bool) async {
        let query = Self.query(status: status, assignee: assignee, search: search, offset: 0)
        generation += 1
        let generation = self.generation
        requestedSearch = search
        requestIsCurrent = true
        pageError = nil
        // Other filters or another search: do not show the old rows meanwhile.
        if query != loadedQuery { state = .loading }
        do {
            let fetched = try await fetch(query)
            if withExtras { await loadExtras() }
            guard generation == self.generation else { return }
            issues = []
            append(fetched)
            loadedQuery = query
            nextOffset = fetched.count
            hasMore = fetched.count >= Self.pageSize
            publish()
        } catch {
            guard generation == self.generation else { return }
            if Task.isCancelled {
                requestIsCurrent = false
                if loadedQuery != nil { publish() }
                return
            }
            loadedQuery = nil
            hasMore = false
            if case APIError.unauthorized = error {
                state = .needsSignIn
            } else {
                state = .error(userMessage(for: error))
            }
            store.log("Tasks failed for account \(accountID): \(userMessage(for: error))")
        }
    }

    /// Projects (section names) and agents (assignee picker); a failure only loses names.
    private func loadExtras() async {
        guard let companyId = companyID else { return }
        do {
            projects = try await store.call(accountID) { try await $0.projects(companyId: companyId) }
        } catch {
            projects = []
            store.log("Tasks projects failed for account \(accountID): \(userMessage(for: error))")
        }
        do {
            let all = try await store.call(accountID) { try await $0.agents(companyId: companyId) }
            agents = all.filter { $0.status != "terminated" }
        } catch {
            agents = []
            store.log("Tasks agents failed for account \(accountID): \(userMessage(for: error))")
        }
        var options: [TaskAssigneeFilter] = [.anyone, .me] + agents.map { TaskAssigneeFilter.agent($0.id) }
        // Keep the picked agent selectable even when the list lost it.
        if case .agent = assignee, !options.contains(assignee) { options.append(assignee) }
        assigneeOptions = options
    }

    /// Appends the tasks not loaded yet (a task can move between two pages).
    private func append(_ page: [Issue]) {
        var known = Set(issues.map(\.id))
        for issue in page where !known.contains(issue.id) {
            issues.append(issue)
            known.insert(issue.id)
        }
    }

    private func publish() {
        state = issues.isEmpty ? .empty : .loaded(Self.sections(issues, projects: projects))
    }

    /// Known projects by name, then "Other project", then "No project"; rows keep their order.
    static func sections(_ issues: [Issue], projects: [Project]) -> [TaskSection] {
        let known = Set(projects.map(\.id))
        var byProject: [String: [Issue]] = [:]
        var other: [Issue] = []
        var none: [Issue] = []
        for issue in issues {
            if let projectId = issue.projectId {
                if known.contains(projectId) {
                    byProject[projectId, default: []].append(issue)
                } else {
                    other.append(issue)
                }
            } else {
                none.append(issue)
            }
        }
        var sections: [TaskSection] = []
        var seen: Set<String> = []
        let sorted = projects.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        for project in sorted where !seen.contains(project.id) {
            seen.insert(project.id)
            if let rows = byProject[project.id] {
                sections.append(TaskSection(id: project.id, title: project.name, issues: rows))
            }
        }
        if !other.isEmpty { sections.append(TaskSection(id: "other", title: "Other project", issues: other)) }
        if !none.isEmpty { sections.append(TaskSection(id: "none", title: "No project", issues: none)) }
        return sections
    }

    private var companyID: String? {
        store.accounts.first { $0.id == accountID }?.selectedCompanyId
    }

    private func fetch(_ query: IssueListQuery) async throws -> [Issue] {
        guard let companyId = companyID else { throw AccountStoreError.unknownAccount }
        return try await store.call(accountID) { try await $0.issues(companyId: companyId, query: query) }
    }
}
