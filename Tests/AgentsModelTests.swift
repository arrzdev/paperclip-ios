import Foundation
import PaperclipAPI
import Testing
@testable import PaperclipIOS

/// Me → More → Agents (spec §3, board decision §6.3): the company's agents with
/// status and live run, and agent detail with pause / resume.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AgentsModelTests {
    static let agentsPath = "/api/companies/company-1/agents"
    static let liveRunsPath = "/api/companies/company-1/live-runs"
    static let agentPath = "/api/agents/agent-1"

    static func agent(
        _ id: String,
        name: String,
        status: String,
        pauseReason: String? = nil,
        urlKey: String? = nil
    ) -> String {
        func text(_ value: String?) -> String { value.map { "\"" + $0 + "\"" } ?? "null" }
        return #"{"id":"\#(id)","companyId":"company-1","name":"\#(name)","role":"engineer","title":"Engineer","status":"\#(status)","pauseReason":\#(text(pauseReason)),"pausedAt":null,"lastHeartbeatAt":"2026-10-14T09:00:00.000Z","urlKey":\#(text(urlKey))}"#
    }

    static func run(_ id: String, agentID: String, status: String = "running", issueID: String? = "issue-9") -> String {
        func text(_ value: String?) -> String { value.map { "\"" + $0 + "\"" } ?? "null" }
        return #"{"id":"\#(id)","companyId":"company-1","status":"\#(status)","agentId":"\#(agentID)","agentName":"Agent","startedAt":"2026-10-14T09:15:00.000Z","createdAt":"2026-10-14T09:15:00.000Z","issueId":\#(text(issueID))}"#
    }

    static let threeAgents = list(
        agent("agent-1", name: "Ada", status: "running", urlKey: "ada"),
        agent("agent-2", name: "Bob", status: "paused", pauseReason: "manual"),
        agent("agent-3", name: "Old", status: "terminated")
    )

    private func listServer() -> StubServer {
        let server = StubServer()
        server.on("GET", Self.agentsPath, .ok(Self.threeAgents))
        server.on("GET", Self.liveRunsPath, .ok(list(Self.run("run-1", agentID: "agent-1"))))
        return server
    }

    private func rows(_ model: AgentsModel) -> [AgentRow] {
        if case .loaded(let rows) = model.state { return rows }
        return []
    }

    // MARK: List

    @Test func listsAgentsWithStatusAndLiveRunTerminatedLeftOut() async throws {
        let server = listServer()
        let (store, id) = try signedInStore(server)
        let model = AgentsModel(store: store, accountID: id, poller: Poller(sleep: TestSleeper(ticks: 0).sleep))

        await model.refresh()

        let rows = rows(model)
        #expect(rows.map(\.agent.name) == ["Ada", "Bob"])
        #expect(rows.map(\.agent.agentStatus) == [.running, .paused])
        #expect(rows.first?.liveRun?.id == "run-1")
        #expect(rows.first?.liveRun?.issueId == "issue-9")
        #expect(rows.last?.liveRun == nil)
        #expect(rows.map(\.id) == ["agent-1", "agent-2"])
    }

    @Test func failedLiveRunsOnlyLoseTheRuns() async throws {
        let server = listServer()
        server.on("GET", Self.liveRunsPath, .init(status: 503, body: JSON.unavailable))
        let (store, id) = try signedInStore(server)
        let model = AgentsModel(store: store, accountID: id, poller: Poller(sleep: TestSleeper(ticks: 0).sleep))

        await model.refresh()

        #expect(rows(model).map(\.agent.name) == ["Ada", "Bob"])
        #expect(rows(model).allSatisfy { $0.liveRun == nil })
    }

    @Test func failedAgentsIsAnError() async throws {
        let server = listServer()
        server.on("GET", Self.agentsPath, .init(status: 503, body: JSON.unavailable))
        let (store, id) = try signedInStore(server)
        let model = AgentsModel(store: store, accountID: id, poller: Poller(sleep: TestSleeper(ticks: 0).sleep))

        await model.refresh()

        guard case .error(let message) = model.state else {
            Testing.Issue.record("expected an error, got \(model.state)")
            return
        }
        #expect(message.contains("503"))
    }

    @Test func onlyTerminatedAgentsIsEmpty() async throws {
        let server = listServer()
        server.on("GET", Self.agentsPath, .ok(list(Self.agent("agent-3", name: "Old", status: "terminated"))))
        let (store, id) = try signedInStore(server)
        let model = AgentsModel(store: store, accountID: id, poller: Poller(sleep: TestSleeper(ticks: 0).sleep))

        await model.refresh()

        #expect(model.state == .empty)
    }

    @Test func a401SendsTheAccountToSignIn() async throws {
        let server = listServer()
        server.on("GET", Self.agentsPath, .init(status: 401, body: JSON.unauthorized))
        let (store, id) = try signedInStore(server)
        let model = AgentsModel(store: store, accountID: id, poller: Poller(sleep: TestSleeper(ticks: 0).sleep))

        await model.refresh()

        #expect(model.state == .needsSignIn)
        #expect(store.route == .reSignIn(id))
    }

    @Test func pollUpdatesRunsAndAFailedPollKeepsTheRows() async throws {
        let server = listServer()
        server.on("GET", Self.liveRunsPath,
                  .ok(list(Self.run("run-1", agentID: "agent-1"))),
                  .ok(list(Self.run("run-2", agentID: "agent-2"))))
        let (store, id) = try signedInStore(server)
        let model = AgentsModel(store: store, accountID: id, poller: Poller(sleep: TestSleeper(ticks: 0).sleep))
        await model.refresh()

        await model.poll()
        #expect(rows(model).first?.liveRun == nil)
        #expect(rows(model).last?.liveRun?.id == "run-2")

        server.on("GET", Self.agentsPath, .init(status: 503, body: JSON.unavailable))
        await model.poll()
        #expect(rows(model).map(\.agent.name) == ["Ada", "Bob"])
    }

    @Test func runPollingPollsEveryInterval() async throws {
        let server = listServer()
        let (store, id) = try signedInStore(server)
        let sleeper = TestSleeper(ticks: 2)
        let model = AgentsModel(store: store, accountID: id, poller: Poller(sleep: sleeper.sleep))
        await model.refresh()

        await model.runPolling()

        #expect(sleeper.durations == [Poller.interval, Poller.interval, Poller.interval])
        #expect(server.requests("GET", Self.agentsPath).count == 3)
    }

    // MARK: Detail

    private func detailServer(status: String = "running") -> StubServer {
        let server = StubServer()
        server.on("GET", Self.agentPath, .ok(Self.agent("agent-1", name: "Ada", status: status, urlKey: "ada")))
        server.on("GET", Self.liveRunsPath, .ok(list(
            Self.run("run-1", agentID: "agent-1"),
            Self.run("run-2", agentID: "agent-2")
        )))
        return server
    }

    private func loadedAgent(_ model: AgentDetailModel) -> Agent? {
        if case .loaded(let agent) = model.state { return agent }
        return nil
    }

    @Test func detailLoadsTheAgentAndItsOwnLiveRun() async throws {
        let server = detailServer()
        let (store, id) = try signedInStore(server)
        let model = AgentDetailModel(store: store, accountID: id, agentID: "agent-1")

        await model.refresh()

        #expect(loadedAgent(model)?.name == "Ada")
        #expect(model.liveRun?.id == "run-1")
        #expect(model.canPause)
        #expect(!model.canResume)
    }

    @Test func aFailedLiveRunFetchNeverHidesTheAgent() async throws {
        let server = detailServer()
        server.on("GET", Self.liveRunsPath, .init(status: 503, body: JSON.unavailable))
        let (store, id) = try signedInStore(server)
        let model = AgentDetailModel(store: store, accountID: id, agentID: "agent-1")

        await model.refresh()

        #expect(loadedAgent(model)?.name == "Ada")
        #expect(model.liveRun == nil)
    }

    @Test func aMissingAgentIsAnError() async throws {
        let server = detailServer()
        server.on("GET", Self.agentPath, .init(status: 404, body: #"{"error":"Agent not found"}"#))
        let (store, id) = try signedInStore(server)
        let model = AgentDetailModel(store: store, accountID: id, agentID: "agent-1")

        await model.refresh()

        if case .error = model.state {} else { Testing.Issue.record("expected an error, got \(model.state)") }
    }

    @Test func pauseAndResumeFollowTheStatus() async throws {
        let cases: [(String, Bool, Bool)] = [
            ("active", true, false), ("idle", true, false), ("running", true, false), ("error", true, false),
            ("paused", false, true), ("terminated", false, false), ("pending_approval", false, false),
        ]
        for (status, canPause, canResume) in cases {
            let server = detailServer(status: status)
            let (store, id) = try signedInStore(server)
            let model = AgentDetailModel(store: store, accountID: id, agentID: "agent-1")
            await model.refresh()
            #expect(model.canPause == canPause, "pause on \(status)")
            #expect(model.canResume == canResume, "resume on \(status)")
        }
    }

    @Test func nothingToPauseBeforeTheAgentLoads() throws {
        let (store, id) = try signedInStore(StubServer())
        let model = AgentDetailModel(store: store, accountID: id, agentID: "agent-1")
        #expect(!model.canPause)
        #expect(!model.canResume)
    }

    @Test func pausePostsAndShowsTheServerAgent() async throws {
        let server = detailServer()
        server.on("POST", "/api/agents/agent-1/pause", .ok(Self.agent("agent-1", name: "Ada", status: "paused", pauseReason: "manual")))
        let (store, id) = try signedInStore(server)
        let model = AgentDetailModel(store: store, accountID: id, agentID: "agent-1")
        await model.refresh()

        await model.pause()

        #expect(server.requests("POST", "/api/agents/agent-1/pause").count == 1)
        #expect(loadedAgent(model)?.agentStatus == .paused)
        #expect(loadedAgent(model)?.pauseReason == "manual")
        #expect(model.canResume)
        #expect(!model.canPause)
        #expect(model.actionError == nil)
        #expect(!model.isSending)
    }

    @Test func resumePostsAndShowsTheServerAgent() async throws {
        let server = detailServer(status: "paused")
        server.on("POST", "/api/agents/agent-1/resume", .ok(Self.agent("agent-1", name: "Ada", status: "idle")))
        let (store, id) = try signedInStore(server)
        let model = AgentDetailModel(store: store, accountID: id, agentID: "agent-1")
        await model.refresh()

        await model.resume()

        #expect(server.requests("POST", "/api/agents/agent-1/resume").count == 1)
        #expect(loadedAgent(model)?.agentStatus == .idle)
        #expect(model.canPause)
    }

    @Test func aRefusedResumeKeepsTheAgentAndShowsTheServerReason() async throws {
        let server = detailServer(status: "paused")
        server.on("POST", "/api/agents/agent-1/resume",
                  .init(status: 409, body: #"{"error":"Repair this agent's reporting chain before resuming it"}"#))
        let (store, id) = try signedInStore(server)
        let model = AgentDetailModel(store: store, accountID: id, agentID: "agent-1")
        await model.refresh()

        await model.resume()

        #expect(loadedAgent(model)?.agentStatus == .paused)
        #expect(model.actionError?.contains("reporting chain") == true)
        #expect(!model.isSending)
    }

    @Test func aPauseThatIsNotAllowedSendsNothing() async throws {
        let server = detailServer(status: "terminated")
        let (store, id) = try signedInStore(server)
        let model = AgentDetailModel(store: store, accountID: id, agentID: "agent-1")
        await model.refresh()

        await model.pause()
        await model.resume()

        #expect(server.requests("POST", "/api/agents/agent-1/pause").isEmpty)
        #expect(server.requests("POST", "/api/agents/agent-1/resume").isEmpty)
    }

    @Test func a401OnPauseSendsTheAccountToSignIn() async throws {
        let server = detailServer()
        server.on("POST", "/api/agents/agent-1/pause", .init(status: 401, body: JSON.unauthorized))
        let (store, id) = try signedInStore(server)
        let model = AgentDetailModel(store: store, accountID: id, agentID: "agent-1")
        await model.refresh()

        await model.pause()

        #expect(model.state == .needsSignIn)
        #expect(store.route == .reSignIn(id))
    }

    @Test func pollRefetchesTheAgentAndItsRun() async throws {
        let server = detailServer()
        server.on("GET", Self.liveRunsPath, .ok(list(Self.run("run-1", agentID: "agent-1"))), .ok("[]"))
        let (store, id) = try signedInStore(server)
        let model = AgentDetailModel(store: store, accountID: id, agentID: "agent-1")
        await model.refresh()

        await model.poll()

        #expect(server.requests("GET", Self.agentPath).count == 2)
        #expect(model.liveRun == nil)
        #expect(loadedAgent(model)?.name == "Ada")
    }
}
