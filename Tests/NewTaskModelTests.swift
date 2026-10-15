import Foundation
import PaperclipAPI
import Testing
@testable import PaperclipIOS

/// The New task sheet and the Today "Message <name>…" bar (spec §4 D): one
/// text field, one photo, an assignee chip (default: the last agent the user
/// gave a task to, first use the CEO) and an optional project chip.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct NewTaskModelTests {
    let agentsPath = "/api/companies/company-1/agents"
    let projectsPath = "/api/companies/company-1/projects"
    let uploadPath = "/api/companies/company-1/issues/issue-9/attachments"

    static let projects = #"[{"id":"project-1","companyId":"company-1","name":"Mobile app","status":"in_progress","archivedAt":null},{"id":"project-2","companyId":"company-1","name":"Website","status":"planned","archivedAt":null}]"#
    static let created = issueJSON(id: "issue-9", title: "Fix the login")
    static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    static let photo = PendingImage(data: png, filename: "screenshot.png", contentType: "image/png")
    static let uploaded = #"{"id":"att-new","companyId":"company-1","issueId":"issue-9","issueCommentId":null,"contentType":"image/png","byteSize":8,"originalFilename":"screenshot.png","contentPath":"/api/attachments/att-new/content","createdAt":"2026-10-14T09:30:00.000Z"}"#

    struct Setup {
        let model: NewTaskModel
        let store: AccountStore
        let accountID: UUID
        let drafts: InMemoryDraftStore
        let defaults: InMemoryDefaultAssigneeStore
    }

    /// A server with the agents of `DefaultAssigneeTests` and two projects.
    private func makeServer() -> StubServer {
        let server = StubServer()
        server.on("GET", agentsPath, .ok(DefaultAssigneeTests.agentsJSON))
        server.on("GET", projectsPath, .ok(Self.projects))
        return server
    }

    private func setup(
        _ server: StubServer,
        drafts: InMemoryDraftStore = InMemoryDraftStore(),
        defaults: InMemoryDefaultAssigneeStore = InMemoryDefaultAssigneeStore(),
        log: LogSink = LogSink()
    ) throws -> Setup {
        let (store, id) = try signedInStore(server, log: log)
        let model = NewTaskModel(store: store, accountID: id, companyID: "company-1", drafts: drafts, defaults: defaults)
        return Setup(model: model, store: store, accountID: id, drafts: drafts, defaults: defaults)
    }

    private func createBodies(_ server: StubServer) -> [[String: Any]] {
        server.requests("POST", companyIssuesPath).compactMap(jsonObject)
    }

    private func expectFailed(_ phase: SendPhase) {
        if case .failed = phase { return }
        Testing.Issue.record("expected a failed phase, got \(phase)")
    }

    // MARK: Default assignee

    @Test func firstUseAssignsTheCEO() async throws {
        let s = try setup(makeServer())
        await s.model.load()

        #expect(s.model.assignee?.id == "agent-1")
        #expect(s.model.placeholder == "Message Luis…")
        // The chip lists only agents that can take work.
        #expect(s.model.agents.map(\.id) == ["agent-1", "agent-2"])
        // Project chip: default none, the company's projects to pick from.
        #expect(s.model.project == nil)
        #expect(s.model.projects.map(\.name) == ["Mobile app", "Website"])
    }

    @Test func theLastAgentGivenATaskIsTheDefault() async throws {
        let defaults = InMemoryDefaultAssigneeStore()
        let s = try setup(makeServer(), defaults: defaults)
        defaults.setAgentID("agent-2", accountID: s.accountID, companyID: "company-1")

        await s.model.load()

        #expect(s.model.assignee?.id == "agent-2")
        #expect(s.model.placeholder == "Message Marta…")
    }

    @Test func aDeletedDefaultFallsBackToTheCEO() async throws {
        let defaults = InMemoryDefaultAssigneeStore()
        let s = try setup(makeServer(), defaults: defaults)
        defaults.setAgentID("agent-gone", accountID: s.accountID, companyID: "company-1")

        await s.model.load()

        #expect(s.model.assignee?.id == "agent-1")
    }

    @Test func anotherCompanyHasItsOwnDefault() async throws {
        let defaults = InMemoryDefaultAssigneeStore()
        let s = try setup(makeServer(), defaults: defaults)
        defaults.setAgentID("agent-2", accountID: s.accountID, companyID: "company-2")

        await s.model.load()

        #expect(s.model.assignee?.id == "agent-1")
    }

    @Test func noAssigneeMeansNoSend() async throws {
        let server = makeServer()
        server.on("GET", agentsPath, .ok(#"[{"id":"agent-2","name":"Marta","role":"cto","status":"idle"}]"#))
        let s = try setup(server)
        await s.model.load()
        s.model.text = "Fix the login"

        #expect(s.model.assignee == nil)
        #expect(s.model.placeholder == "New task…")
        #expect(s.model.canSend == false)

        s.model.selectAssignee(try #require(s.model.agents.first))
        #expect(s.model.canSend)
    }

    @Test func agentsThatFailToLoadShowAnErrorAndNoAssignee() async throws {
        let server = makeServer()
        server.on("GET", agentsPath, StubServer.Response(status: 503, body: JSON.unavailable))
        let s = try setup(server)
        await s.model.load()

        #expect(s.model.assignee == nil)
        #expect(s.model.loadError != nil)
        #expect(s.model.needsSignIn == false)
    }

    @Test func projectsThatFailToLoadOnlyEmptyTheProjectChip() async throws {
        let server = makeServer()
        server.on("GET", projectsPath, StubServer.Response(status: 503, body: JSON.unavailable))
        let s = try setup(server)
        await s.model.load()

        #expect(s.model.projects.isEmpty)
        #expect(s.model.assignee?.id == "agent-1")
        #expect(s.model.loadError == nil)
    }

    // MARK: Send

    @Test func sendCreatesATodoTaskAndOpensIt() async throws {
        let server = makeServer()
        server.on("POST", companyIssuesPath, StubServer.Response(status: 201, body: Self.created))
        let s = try setup(server)
        await s.model.load()
        s.model.text = "Fix the login\nIt fails on iOS 17."
        s.model.selectProject(try #require(s.model.projects.first))

        #expect(s.model.canSend)
        await s.model.send()

        let body = try #require(createBodies(server).first)
        #expect(body["title"] as? String == "Fix the login")
        #expect(body["description"] as? String == "It fails on iOS 17.")
        #expect(body["status"] as? String == "todo")
        #expect(body["assigneeAgentId"] as? String == "agent-1")
        #expect(body["projectId"] as? String == "project-1")
        #expect(body["idempotencyKey"] as? String != nil)
        #expect(body["priority"] == nil)
        #expect(body["assigneeUserId"] == nil)
        // Opens the new task; the draft is gone.
        #expect(s.model.createdIssue?.id == "issue-9")
        #expect(s.model.phase == .idle)
        #expect(s.model.text == "")
        #expect(s.drafts.draft(accountID: s.accountID, issueID: NewTaskModel.draftKey(companyID: "company-1")) == nil)
        #expect(server.requests("POST", uploadPath).isEmpty)

        s.model.openedCreatedIssue()
        #expect(s.model.createdIssue == nil)
    }

    @Test func theTitleIsRequired() async throws {
        let s = try setup(makeServer())
        await s.model.load()

        #expect(s.model.canSend == false)
        s.model.text = "  \n \n"
        #expect(s.model.canSend == false)
        // A photo alone is no task.
        s.model.attach(Self.photo)
        #expect(s.model.canSend == false)
        s.model.text = "See the photo"
        #expect(s.model.canSend)
    }

    @Test func changingTheChipUpdatesTheDefaultOnlyAfterASuccessfulSend() async throws {
        let server = makeServer()
        server.on("POST", companyIssuesPath,
                  StubServer.Response(status: 503, body: JSON.unavailable),
                  StubServer.Response(status: 201, body: Self.created))
        let s = try setup(server)
        await s.model.load()
        s.model.text = "Fix the login"
        s.model.selectAssignee(try #require(s.model.agents.first(where: { $0.id == "agent-2" })))

        // Picking is not giving a task.
        #expect(s.defaults.agentID(accountID: s.accountID, companyID: "company-1") == nil)

        await s.model.send()
        expectFailed(s.model.phase)
        #expect(s.defaults.agentID(accountID: s.accountID, companyID: "company-1") == nil)

        await s.model.retry()
        #expect(s.model.phase == .idle)
        #expect(s.defaults.agentID(accountID: s.accountID, companyID: "company-1") == "agent-2")
        #expect(createBodies(server).map { $0["assigneeAgentId"] as? String } == ["agent-2", "agent-2"])
    }

    @Test func sendFailureKeepsTheDraftAndRetryReusesTheIdempotencyKey() async throws {
        let server = makeServer()
        server.on("POST", companyIssuesPath,
                  StubServer.Response(status: 503, body: JSON.unavailable),
                  StubServer.Response(status: 201, body: Self.created))
        let s = try setup(server)
        await s.model.load()
        s.model.text = "Fix the login\nDetails"
        s.model.attach(Self.photo)

        await s.model.send()

        expectFailed(s.model.phase)
        #expect(s.model.text == "Fix the login\nDetails")
        #expect(s.model.image?.data == Self.png)
        #expect(s.model.createdIssue == nil)
        let saved = s.drafts.draft(accountID: s.accountID, issueID: NewTaskModel.draftKey(companyID: "company-1"))
        #expect(saved?.text == "Fix the login\nDetails")
        // Nothing to attach the photo to yet.
        #expect(server.requests("POST", uploadPath).isEmpty)

        server.on("POST", uploadPath, StubServer.Response(status: 201, body: Self.uploaded))
        await s.model.retry()

        let keys = createBodies(server).compactMap { $0["idempotencyKey"] as? String }
        #expect(keys.count == 2)
        // Same key both times: the server never creates the task twice.
        #expect(Set(keys).count == 1)
        #expect(s.model.createdIssue?.id == "issue-9")
    }

    @Test func thePhotoUploadsToTheNewTaskAfterItIsCreated() async throws {
        let server = makeServer()
        server.on("POST", companyIssuesPath, StubServer.Response(status: 201, body: Self.created))
        server.on("POST", uploadPath, StubServer.Response(status: 201, body: Self.uploaded))
        let s = try setup(server)
        await s.model.load()
        s.model.text = "Fix the login"
        s.model.attach(Self.photo)

        await s.model.send()

        let posts = server.allRequests.filter { $0.httpMethod == "POST" }.map { $0.url?.path ?? "" }
        #expect(posts == [companyIssuesPath, uploadPath])
        let upload = try #require(server.requests("POST", uploadPath).first)
        #expect(upload.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data") == true)
        #expect(s.model.createdIssue?.id == "issue-9")
        #expect(s.model.image == nil)
        #expect(s.model.phase == .idle)
    }

    @Test func aFailedPhotoUploadRetriesOnlyTheUpload() async throws {
        let server = makeServer()
        server.on("POST", companyIssuesPath, StubServer.Response(status: 201, body: Self.created))
        server.on("POST", uploadPath,
                  StubServer.Response(status: 500, body: JSON.unavailable),
                  StubServer.Response(status: 201, body: Self.uploaded))
        let defaults = InMemoryDefaultAssigneeStore()
        let s = try setup(server, defaults: defaults)
        await s.model.load()
        s.model.text = "Fix the login"
        s.model.attach(Self.photo)

        await s.model.send()

        // The task exists: the default moves, the photo waits for Retry.
        expectFailed(s.model.phase)
        #expect(s.model.createdIssue == nil)
        #expect(s.model.image?.data == Self.png)
        #expect(defaults.agentID(accountID: s.accountID, companyID: "company-1") == "agent-1")

        await s.model.retry()

        #expect(server.requests("POST", companyIssuesPath).count == 1)
        #expect(server.requests("POST", uploadPath).count == 2)
        #expect(s.model.createdIssue?.id == "issue-9")
        #expect(s.model.phase == .idle)
    }

    @Test func unauthorizedSendKeepsTheDraftAndSendsTheAccountToSignIn() async throws {
        let server = makeServer()
        server.on("POST", companyIssuesPath, StubServer.Response(status: 401, body: JSON.unauthorized))
        let s = try setup(server)
        await s.model.load()
        s.model.text = "Fix the login"

        await s.model.send()

        #expect(s.model.needsSignIn)
        #expect(s.store.route == .reSignIn(s.accountID))
        #expect(s.model.text == "Fix the login")
        #expect(s.model.createdIssue == nil)
        #expect(s.defaults.agentID(accountID: s.accountID, companyID: "company-1") == nil)
    }

    @Test func unauthorizedLoadSendsTheAccountToSignIn() async throws {
        let server = makeServer()
        server.on("GET", agentsPath, StubServer.Response(status: 401, body: JSON.unauthorized))
        let s = try setup(server)
        await s.model.load()

        #expect(s.model.needsSignIn)
        #expect(s.store.route == .reSignIn(s.accountID))
    }

    // MARK: Draft

    @Test func theDraftIsKeptPerAccountAndCompany() async throws {
        let server = makeServer()
        let drafts = InMemoryDraftStore()
        let s = try setup(server, drafts: drafts)
        s.model.text = "Half a task"
        s.model.attach(Self.photo)

        // Closing the sheet and opening it again builds a new model.
        let again = NewTaskModel(
            store: s.store, accountID: s.accountID, companyID: "company-1", drafts: drafts, defaults: s.defaults
        )
        #expect(again.text == "Half a task")
        #expect(again.image?.filename == "screenshot.png")

        let otherCompany = NewTaskModel(
            store: s.store, accountID: s.accountID, companyID: "company-2", drafts: drafts, defaults: s.defaults
        )
        #expect(otherCompany.text == "")
        #expect(otherCompany.image == nil)
    }

    @Test func noKeyDraftOrImageBytesInTheLog() async throws {
        let server = makeServer()
        server.on("POST", companyIssuesPath, StubServer.Response(status: 503, body: JSON.unavailable))
        let log = LogSink()
        let s = try setup(server, log: log)
        await s.model.load()
        s.model.text = "secret plan\nmore secret detail"
        s.model.attach(Self.photo)

        await s.model.send()

        #expect(!log.lines.isEmpty)
        let text = log.lines.joined(separator: "\n")
        #expect(!text.contains(JSON.key))
        #expect(!text.contains("secret plan"))
        #expect(!text.contains("more secret detail"))
        #expect(!text.contains(Self.png.base64EncodedString()))
    }
}
