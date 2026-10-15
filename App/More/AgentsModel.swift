import Foundation
import PaperclipAPI

/// The one way to open Agent detail: the Agents list pushes this value and
/// each tab's `NavigationStack` has a `.navigationDestination(for: AgentRoute.self)`.
struct AgentRoute: Hashable {
    let agentID: String
}

/// The one way to open a run's log, from Agents or Agent detail. `issueID`
/// is the task the run works on (opens with `TaskRoute`).
struct RunLogRoute: Hashable {
    let runID: String
    let isLive: Bool
    var issueID: String?
}

/// An agent of the company and its newest live run, if any.
struct AgentRow: Identifiable, Equatable {
    let agent: Agent
    let liveRun: LiveRun?
    var id: String { agent.id }
}

extension AgentStatus {
    var label: String {
        switch self {
        case .active: "Active"
        case .idle: "Idle"
        case .running: "Running"
        case .paused: "Paused"
        case .error: "Error"
        case .pendingApproval: "Pending approval"
        case .terminated: "Terminated"
        case .unknown(let value): value.isEmpty ? "Unknown" : value.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

/// Me → More → Agents: the company's agents (terminated left out) with their
/// live run. Live runs are an extra: a failure only loses the runs. Polled
/// every 15 s while the screen is open; a failed poll keeps the rows.
@MainActor
@Observable
final class AgentsModel {
    let store: AccountStore
    let accountID: UUID
    private let poller: Poller

    private(set) var state: LoadState<[AgentRow]> = .loading
    private var agents: [Agent] = []
    private var runs: [LiveRun] = []

    init(store: AccountStore, accountID: UUID, poller: Poller = .live) {
        self.store = store
        self.accountID = accountID
        self.poller = poller
    }

    /// Full fetch (screen appears, pull to refresh).
    func refresh() async {
        do {
            agents = try await fetchAgents()
        } catch {
            state = isUnauthorizedError(error) ? .needsSignIn : .error(userMessage(for: error))
            store.log("Agents failed for account \(accountID): \(userMessage(for: error))")
            return
        }
        runs = await fetchRuns() ?? []
        publish()
    }

    /// Agents and runs again; a failure keeps what is on screen.
    func poll() async {
        guard case .loaded = state else {
            // Nothing on screen yet (empty or an error): try a full fetch.
            if state != .needsSignIn { await refresh() }
            return
        }
        do {
            agents = try await fetchAgents()
        } catch {
            if isUnauthorizedError(error) { state = .needsSignIn }
            store.log("Agents poll failed for account \(accountID): \(userMessage(for: error))")
            return
        }
        runs = await fetchRuns() ?? runs
        publish()
    }

    /// Polls every `Poller.interval` until the calling task is cancelled.
    func runPolling() async {
        await poller.run { await self.poll() }
    }

    // MARK: - Private

    private var companyID: String? {
        store.accounts.first { $0.id == accountID }?.selectedCompanyId
    }

    private func fetchAgents() async throws -> [Agent] {
        guard let companyId = companyID else { throw AccountStoreError.unknownAccount }
        let all = try await store.call(accountID) { try await $0.agents(companyId: companyId) }
        return all.filter { $0.agentStatus != .terminated }
    }

    private func fetchRuns() async -> [LiveRun]? {
        guard let companyId = companyID else { return nil }
        do {
            return try await store.call(accountID) { try await $0.companyLiveRuns(companyId: companyId) }
        } catch {
            store.log("Agents live runs failed for account \(accountID): \(userMessage(for: error))")
            return nil
        }
    }

    private func publish() {
        let rows = agents.map { agent in
            AgentRow(agent: agent, liveRun: runs.first { $0.agentId == agent.id })
        }
        state = rows.isEmpty ? .empty : .loaded(rows)
    }
}

/// Agent detail: the agent (required) and its live run (an extra). Pause
/// unless paused, terminated or pending approval; Resume only when paused.
/// The server's answer replaces the agent; an error keeps it and shows why.
@MainActor
@Observable
final class AgentDetailModel {
    let store: AccountStore
    let accountID: UUID
    let agentID: String

    private(set) var state: LoadState<Agent> = .loading
    private(set) var liveRun: LiveRun?
    /// Set when Pause or Resume failed (the server's reason).
    private(set) var actionError: String?
    private(set) var isSending = false

    init(store: AccountStore, accountID: UUID, agentID: String) {
        self.store = store
        self.accountID = accountID
        self.agentID = agentID
    }

    var agent: Agent? {
        if case .loaded(let agent) = state { return agent }
        return nil
    }

    var canPause: Bool {
        guard let status = agent?.agentStatus else { return false }
        return status != .paused && status != .terminated && status != .pendingApproval
    }

    var canResume: Bool {
        agent?.agentStatus == .paused
    }

    /// Full fetch (screen appears, pull to refresh).
    func refresh() async {
        do {
            let agent = try await store.call(accountID) { try await $0.agent(id: agentID) }
            state = .loaded(agent)
        } catch {
            state = isUnauthorizedError(error) ? .needsSignIn : .error(userMessage(for: error))
            store.log("Agent detail failed for account \(accountID): \(userMessage(for: error))")
            return
        }
        liveRun = await fetchRuns()?.first { $0.agentId == agentID }
    }

    /// The agent and its run again; a failure keeps what is on screen.
    func poll() async {
        guard agent != nil else {
            await refresh()
            return
        }
        do {
            let agent = try await store.call(accountID) { try await $0.agent(id: agentID) }
            state = .loaded(agent)
        } catch {
            if isUnauthorizedError(error) { state = .needsSignIn }
            store.log("Agent detail poll failed for account \(accountID): \(userMessage(for: error))")
            return
        }
        if let runs = await fetchRuns() {
            liveRun = runs.first { $0.agentId == agentID }
        }
    }

    func pause() async {
        guard canPause else { return }
        await send("Pause") { try await $0.pauseAgent(id: self.agentID) }
    }

    func resume() async {
        guard canResume else { return }
        await send("Resume") { try await $0.resumeAgent(id: self.agentID) }
    }

    func dismissActionError() {
        actionError = nil
    }

    // MARK: - Private

    private func send(_ action: String, _ operation: (APIClient) async throws -> Agent) async {
        guard !isSending else { return }
        isSending = true
        actionError = nil
        defer { isSending = false }
        do {
            let agent = try await store.call(accountID, operation)
            state = .loaded(agent)
            if let runs = await fetchRuns() {
                liveRun = runs.first { $0.agentId == agentID }
            }
        } catch {
            if isUnauthorizedError(error) {
                state = .needsSignIn
            } else {
                actionError = userMessage(for: error)
            }
            store.log("\(action) agent failed for account \(accountID): \(userMessage(for: error))")
        }
    }

    /// The company's live runs, newest first; nil when the fetch failed.
    private func fetchRuns() async -> [LiveRun]? {
        guard let companyId = store.accounts.first(where: { $0.id == accountID })?.selectedCompanyId else { return nil }
        do {
            return try await store.call(accountID) { try await $0.companyLiveRuns(companyId: companyId) }
        } catch {
            store.log("Agent live run failed for account \(accountID): \(userMessage(for: error))")
            return nil
        }
    }
}
