import Foundation
import PaperclipAPI

// Me → More, read only: Activity, Approvals history, Goals and Costs. Each
// is a look-up screen: refreshed on appear and by pull to refresh, never polled.

// MARK: - Activity

/// One event of the company feed: who, what (with the task), when.
struct ActivityRow: Identifiable, Equatable {
    let id: String
    /// The agent's name, "You", "User", "Agent" or "System".
    let actor: String
    /// "Issue comment added · PAP-12 Fix the login".
    let text: String
    let date: Date
    /// Set for task events only.
    let taskRoute: TaskRoute?
}

/// `GET /companies/:id/activity?limit=100`, newest first. Agents are an extra
/// for names: a failure shows "Agent".
@MainActor
@Observable
final class ActivityModel {
    static let limit = 100

    let store: AccountStore
    let accountID: UUID

    private(set) var state: LoadState<[ActivityRow]> = .loading

    init(store: AccountStore, accountID: UUID) {
        self.store = store
        self.accountID = accountID
    }

    func refresh() async {
        guard let companyId = selectedCompanyID(store, accountID) else { return }
        let events: [ActivityEvent]
        do {
            events = try await store.call(accountID) { try await $0.activity(companyId: companyId, limit: Self.limit) }
        } catch {
            state = isUnauthorizedError(error) ? .needsSignIn : .error(userMessage(for: error))
            store.log("Activity failed for account \(accountID): \(userMessage(for: error))")
            return
        }
        var agents: [Agent] = []
        if events.contains(where: { $0.actorType == "agent" }) {
            do {
                agents = try await store.call(accountID) { try await $0.agents(companyId: companyId) }
            } catch {
                store.log("Activity agents failed for account \(accountID): \(userMessage(for: error))")
            }
        }
        let myUserID = store.accounts.first { $0.id == accountID }?.userId
        let rows = events.map { Self.row($0, agents: agents, myUserID: myUserID) }
        state = rows.isEmpty ? .empty : .loaded(rows)
    }

    static func row(_ event: ActivityEvent, agents: [Agent], myUserID: String?) -> ActivityRow {
        ActivityRow(
            id: event.id,
            actor: actorName(event, agents: agents, myUserID: myUserID),
            text: text(for: event),
            date: event.createdAt,
            taskRoute: event.entityType == "issue" ? TaskRoute(issueID: event.entityId) : nil
        )
    }

    private static func actorName(_ event: ActivityEvent, agents: [Agent], myUserID: String?) -> String {
        switch event.actorType {
        case "agent":
            let agentID = event.agentId ?? event.actorId
            return agents.first { $0.id == agentID }?.name ?? "Agent"
        case "user":
            return event.actorId == myUserID ? "You" : "User"
        default:
            return "System"
        }
    }

    /// "issue.comment_added" → "Issue comment added", plus " · PAP-12 Title" for a task.
    static func text(for event: ActivityEvent) -> String {
        let words = event.action
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        let action = words.prefix(1).uppercased() + words.dropFirst()
        let task = [string(event.details, "identifier"), string(event.details, "issueTitle")]
            .compactMap { $0 }
            .joined(separator: " ")
        return task.isEmpty ? action : "\(action) · \(task)"
    }

    private static func string(_ details: JSONValue?, _ key: String) -> String? {
        guard case .string(let text)? = details?[key] else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Approvals history

/// Every approval of the company (all statuses), newest first.
@MainActor
@Observable
final class ApprovalsHistoryModel {
    let store: AccountStore
    let accountID: UUID

    private(set) var state: LoadState<[Approval]> = .loading

    init(store: AccountStore, accountID: UUID) {
        self.store = store
        self.accountID = accountID
    }

    static func route(for approval: Approval) -> ApprovalRoute {
        ApprovalRoute(approvalID: approval.id)
    }

    func refresh() async {
        guard let companyId = selectedCompanyID(store, accountID) else { return }
        do {
            let approvals = try await store.call(accountID) { try await $0.approvals(companyId: companyId) }
            let sorted = approvals.sorted { $0.createdAt > $1.createdAt }
            state = sorted.isEmpty ? .empty : .loaded(sorted)
        } catch {
            state = isUnauthorizedError(error) ? .needsSignIn : .error(userMessage(for: error))
            store.log("Approvals history failed for account \(accountID): \(userMessage(for: error))")
        }
    }
}

// MARK: - Goals

/// A goal and how deep it sits in the tree (0 = root).
struct GoalRow: Identifiable, Equatable {
    let goal: Goal
    let depth: Int
    var id: String { goal.id }
}

/// `GET /companies/:id/goals` as a tree in server order. A missing parent puts
/// the goal at the root; a cycle never hides or repeats a goal.
@MainActor
@Observable
final class GoalsModel {
    let store: AccountStore
    let accountID: UUID

    private(set) var state: LoadState<[GoalRow]> = .loading

    init(store: AccountStore, accountID: UUID) {
        self.store = store
        self.accountID = accountID
    }

    func refresh() async {
        guard let companyId = selectedCompanyID(store, accountID) else { return }
        do {
            let goals = try await store.call(accountID) { try await $0.goals(companyId: companyId) }
            let rows = Self.tree(goals)
            state = rows.isEmpty ? .empty : .loaded(rows)
        } catch {
            state = isUnauthorizedError(error) ? .needsSignIn : .error(userMessage(for: error))
            store.log("Goals failed for account \(accountID): \(userMessage(for: error))")
        }
    }

    static func tree(_ goals: [Goal]) -> [GoalRow] {
        let ids = Set(goals.map(\.id))
        func parent(of goal: Goal) -> String? {
            guard let parentId = goal.parentId, parentId != goal.id, ids.contains(parentId) else { return nil }
            return parentId
        }
        var children: [String: [Goal]] = [:]
        for goal in goals {
            if let parentId = parent(of: goal) {
                children[parentId, default: []].append(goal)
            }
        }
        var rows: [GoalRow] = []
        var visited: Set<String> = []
        func visit(_ goal: Goal, depth: Int) {
            guard visited.insert(goal.id).inserted else { return }
            rows.append(GoalRow(goal: goal, depth: depth))
            for child in children[goal.id] ?? [] {
                visit(child, depth: depth + 1)
            }
        }
        for goal in goals where parent(of: goal) == nil {
            visit(goal, depth: 0)
        }
        // Goals in a parent cycle are not under any root: each shows from its first member.
        for goal in goals where !visited.contains(goal.id) {
            visit(goal, depth: 0)
        }
        return rows
    }
}

// MARK: - Costs

/// "$12.34 of $50.00 · 25%", or "$0.05 · No budget".
struct CostLine: Equatable {
    let spent: String
    /// Nil when the company has no budget (0).
    let budget: String?
    let utilization: String?

    init(spent: String, budget: String?, utilization: String?) {
        self.spent = spent
        self.budget = budget
        self.utilization = utilization
    }

    init(_ summary: CostSummary) {
        spent = Self.dollars(summary.spendCents)
        if summary.budgetCents > 0 {
            budget = Self.dollars(summary.budgetCents)
            utilization = "\(Int(summary.utilizationPercent.rounded()))%"
        } else {
            budget = nil
            utilization = nil
        }
    }

    var text: String {
        guard let budget else { return "\(spent) · No budget" }
        guard let utilization else { return "\(spent) of \(budget)" }
        return "\(spent) of \(budget) · \(utilization)"
    }

    static func dollars(_ cents: Int) -> String {
        let sign = cents < 0 ? "-" : ""
        let value = abs(cents)
        let rest = value % 100
        return "\(sign)$\(value / 100).\(rest < 10 ? "0" : "")\(rest)"
    }
}

/// `GET /companies/:id/costs/summary` → `CostLine`.
@MainActor
@Observable
final class CostsModel {
    let store: AccountStore
    let accountID: UUID

    private(set) var state: LoadState<CostLine> = .loading

    init(store: AccountStore, accountID: UUID) {
        self.store = store
        self.accountID = accountID
    }

    func refresh() async {
        guard let companyId = selectedCompanyID(store, accountID) else { return }
        do {
            let summary = try await store.call(accountID) { try await $0.costSummary(companyId: companyId) }
            state = .loaded(CostLine(summary))
        } catch {
            state = isUnauthorizedError(error) ? .needsSignIn : .error(userMessage(for: error))
            store.log("Costs failed for account \(accountID): \(userMessage(for: error))")
        }
    }
}

// MARK: - Shared

@MainActor
func selectedCompanyID(_ store: AccountStore, _ accountID: UUID) -> String? {
    store.accounts.first { $0.id == accountID }?.selectedCompanyId
}
