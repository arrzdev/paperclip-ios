import Foundation
import PaperclipAPI

// Scratch: signatures only, to prove the tests compile.

struct AgentRow: Identifiable, Equatable {
    let agent: Agent
    let liveRun: LiveRun?
    var id: String { agent.id }
}

@MainActor
@Observable
final class AgentsModel {
    private(set) var state: LoadState<[AgentRow]> = .loading
    init(store: AccountStore, accountID: UUID, poller: Poller = .live) {}
    func refresh() async {}
    func poll() async {}
    func runPolling() async {}
}

@MainActor
@Observable
final class AgentDetailModel {
    private(set) var state: LoadState<Agent> = .loading
    private(set) var liveRun: LiveRun?
    private(set) var actionError: String?
    private(set) var isSending = false
    init(store: AccountStore, accountID: UUID, agentID: String) {}
    var canPause: Bool { false }
    var canResume: Bool { false }
    func refresh() async {}
    func poll() async {}
    func pause() async {}
    func resume() async {}
}

@MainActor
@Observable
final class RunLogModel {
    static let pageBytes = 256_000
    private(set) var state: LoadState<[RunLogLine]> = .loading
    init(store: AccountStore, accountID: UUID, runID: String, isLive: Bool) {}
    var hasMore: Bool { false }
    func refresh() async {}
    func loadMore() async {}
    func poll() async {}
}

struct ActivityRow: Identifiable, Equatable {
    let id: String
    let actor: String
    let text: String
    let date: Date
    let taskRoute: TaskRoute?
}

@MainActor
@Observable
final class ActivityModel {
    static let limit = 100
    private(set) var state: LoadState<[ActivityRow]> = .loading
    init(store: AccountStore, accountID: UUID) {}
    func refresh() async {}
}

@MainActor
@Observable
final class ApprovalsHistoryModel {
    private(set) var state: LoadState<[Approval]> = .loading
    init(store: AccountStore, accountID: UUID) {}
    static func route(for approval: Approval) -> ApprovalRoute { ApprovalRoute(approvalID: "") }
    func refresh() async {}
}

struct GoalRow: Identifiable, Equatable {
    let goal: Goal
    let depth: Int
    var id: String { goal.id }
}

@MainActor
@Observable
final class GoalsModel {
    private(set) var state: LoadState<[GoalRow]> = .loading
    init(store: AccountStore, accountID: UUID) {}
    func refresh() async {}
}

struct CostLine: Equatable {
    let spent: String
    let budget: String?
    let utilization: String?
    var text: String { "" }
}

@MainActor
@Observable
final class CostsModel {
    private(set) var state: LoadState<CostLine> = .loading
    init(store: AccountStore, accountID: UUID) {}
    func refresh() async {}
}

enum WebLink: Hashable {
    case companySettings, secrets, toolConnections, plugins, skills, routines, orgChart, hireAgent
    case agent(urlKey: String)
    static let cut: [WebLink] = []
    var title: String { "" }
    func path(prefix: String) -> String { "" }
}

@MainActor
@Observable
final class MoreModel {
    private(set) var companyName: String?
    init(store: AccountStore, accountID: UUID) {}
    func refresh() async {}
    func url(for link: WebLink) -> URL? { nil }
}
