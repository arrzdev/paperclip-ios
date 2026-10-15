import Foundation
import PaperclipAPI
import Testing
@testable import PaperclipIOS

/// The default assignee of a new task (spec §6.1): the last agent the user gave
/// a task to, per account (server) and company; first use and a gone agent
/// fall back to the company CEO.
@MainActor
@Suite
struct DefaultAssigneeTests {
    static let agentsJSON = #"[{"id":"agent-1","companyId":"company-1","name":"Luis","role":"ceo","title":"CEO","status":"running"},{"id":"agent-2","companyId":"company-1","name":"Marta","role":"cto","title":"CTO","status":"idle"},{"id":"agent-3","companyId":"company-1","name":"Old","role":"engineer","title":null,"status":"terminated"}]"#

    static func agents(_ json: String = agentsJSON) throws -> [Agent] {
        try JSONDecoder().decode([Agent].self, from: Data(json.utf8))
    }

    // MARK: Resolve

    @Test func firstUseIsTheCompanyCEO() throws {
        #expect(DefaultAssignee.resolve(storedID: nil, agents: try Self.agents())?.id == "agent-1")
    }

    @Test func theStoredAgentWins() throws {
        #expect(DefaultAssignee.resolve(storedID: "agent-2", agents: try Self.agents())?.id == "agent-2")
    }

    @Test func aStoredAgentThatNoLongerExistsFallsBackToTheCEO() throws {
        let agents = try Self.agents()
        #expect(DefaultAssignee.resolve(storedID: "agent-gone", agents: agents)?.id == "agent-1")
        // A terminated agent is gone too.
        #expect(DefaultAssignee.resolve(storedID: "agent-3", agents: agents)?.id == "agent-1")
    }

    @Test func noCEOAndNothingStoredMeansNoDefault() throws {
        let agents = try Self.agents(#"[{"id":"agent-2","name":"Marta","role":"cto","status":"idle"}]"#)
        #expect(DefaultAssignee.resolve(storedID: nil, agents: agents) == nil)
        #expect(DefaultAssignee.resolve(storedID: "agent-gone", agents: agents) == nil)
        #expect(DefaultAssignee.resolve(storedID: nil, agents: []) == nil)
    }

    // MARK: Store

    @Test func inMemoryStoreKeepsOneDefaultPerAccountAndCompany() {
        let store = InMemoryDefaultAssigneeStore()
        let first = UUID()
        let second = UUID()
        #expect(store.agentID(accountID: first, companyID: "company-1") == nil)

        store.setAgentID("agent-2", accountID: first, companyID: "company-1")

        #expect(store.agentID(accountID: first, companyID: "company-1") == "agent-2")
        #expect(store.agentID(accountID: first, companyID: "company-2") == nil)
        #expect(store.agentID(accountID: second, companyID: "company-1") == nil)

        store.setAgentID("agent-9", accountID: first, companyID: "company-1")
        #expect(store.agentID(accountID: first, companyID: "company-1") == "agent-9")
    }

    @Test func fileStoreSurvivesARestartAndKeepsAccountsApart() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("default-assignees.json")
        let first = UUID()
        let second = UUID()

        let store = FileDefaultAssigneeStore(fileURL: file)
        store.setAgentID("agent-2", accountID: first, companyID: "company-1")
        store.setAgentID("agent-5", accountID: second, companyID: "company-1")
        store.setAgentID("agent-7", accountID: first, companyID: "company-2")

        let reopened = FileDefaultAssigneeStore(fileURL: file)
        #expect(reopened.agentID(accountID: first, companyID: "company-1") == "agent-2")
        #expect(reopened.agentID(accountID: second, companyID: "company-1") == "agent-5")
        #expect(reopened.agentID(accountID: first, companyID: "company-2") == "agent-7")
        #expect(reopened.agentID(accountID: second, companyID: "company-2") == nil)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func fileStoreThatCannotSaveStillAnswersForThisLaunch() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try makeUnwritable(folder)
        let store = FileDefaultAssigneeStore(fileURL: folder.appendingPathComponent("default-assignees.json"))
        let account = UUID()

        store.setAgentID("agent-2", accountID: account, companyID: "company-1")

        #expect(store.agentID(accountID: account, companyID: "company-1") == "agent-2")
    }
}

/// First line = title, the rest = description (spec §4 D).
@Suite
struct NewTaskTextTests {
    @Test func oneLineIsOnlyATitle() {
        #expect(NewTaskText("Fix the login") == NewTaskText(title: "Fix the login", description: nil))
    }

    @Test func theRestIsTheDescription() {
        let text = NewTaskText("Fix the login\nIt fails on iOS 17.\nSee the photo.")
        #expect(text.title == "Fix the login")
        #expect(text.description == "It fails on iOS 17.\nSee the photo.")
    }

    @Test func blankLinesAndSpacesAroundAreDropped() {
        let text = NewTaskText("\n\n   Fix the login   \n\n  Details here  \n\n")
        #expect(text.title == "Fix the login")
        #expect(text.description == "Details here")
    }

    @Test func blankLinesAfterTheTitleAreNoDescription() {
        #expect(NewTaskText("Fix the login\n \n\n").description == nil)
    }

    @Test func emptyTextHasAnEmptyTitle() {
        #expect(NewTaskText("  \n ").title == "")
        #expect(NewTaskText("").description == nil)
    }
}
