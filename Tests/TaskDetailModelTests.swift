import Foundation
import PaperclipAPI
import Testing
@testable import PaperclipIOS

/// Task detail (spec §3, §4 B.3, §5 wireframe): the task, its thread, documents
/// and attachments, native pickers that change it at once and roll back on
/// error, the review bar, re-open with a comment, mark read on open, the
/// live-run line and polling for new comments.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct TaskDetailModelTests {
    let issuePath = "/api/issues/issue-1"
    let commentsPath = "/api/issues/issue-1/comments"
    let documentsPath = "/api/issues/issue-1/documents"
    let attachmentsPath = "/api/issues/issue-1/attachments"
    let liveRunsPath = "/api/issues/issue-1/live-runs"
    let readPath = "/api/issues/issue-1/read"
    let agentsPath = "/api/companies/company-1/agents"

    static func comment(_ id: String, body: String, at createdAt: String, agent: Bool = true) -> String {
        let author = agent
            ? #""authorUserId":null,"authorAgentId":"agent-1","authorType":"agent""#
            : #""authorUserId":"user-1","authorAgentId":null,"authorType":"user""#
        return #"{"id":"\#(id)","issueId":"issue-1",\#(author),"body":"\#(body)","createdAt":"\#(createdAt)"}"#
    }

    static let c1 = comment("c-1", body: "Spec ready for review.", at: "2026-10-14T09:00:00.000Z")
    static let c2 = comment("c-2", body: "Looks good, go.", at: "2026-10-14T09:10:00.000Z", agent: false)
    static let c3 = comment("c-3", body: "Merged.", at: "2026-10-14T09:20:00.000Z")

    static let document = ##"[{"id":"doc-1","companyId":"company-1","issueId":"issue-1","key":"product-spec","title":"Product spec","format":"markdown","body":"# Spec\n\nHello","latestRevisionNumber":3,"createdAt":"2026-10-14T08:00:00.000Z","updatedAt":"2026-10-14T08:30:00.000Z"}]"##
    static let attachment = #"[{"id":"att-1","companyId":"company-1","issueId":"issue-1","issueCommentId":"c-2","contentType":"image/png","byteSize":8,"originalFilename":"screenshot.png","contentPath":"/api/attachments/att-1/content","createdAt":"2026-10-14T09:10:00.000Z"}]"#
    static let agents = #"[{"id":"agent-1","companyId":"company-1","name":"Luis","role":"ceo","title":"CEO","status":"running"},{"id":"agent-2","companyId":"company-1","name":"Marta","role":"cto","title":"CTO","status":"idle"}]"#
    static func liveRun(agentName: String) -> String {
        #"[{"id":"run-1","status":"running","agentId":"agent-1","agentName":"\#(agentName)","startedAt":"2026-10-14T09:15:00.000Z","createdAt":"2026-10-14T09:15:00.000Z"}]"#
    }

    static func issue(status: String = "in_review", updatedAt: String = "2026-10-14T09:10:00.000Z") -> String {
        issueJSON(id: "issue-1", title: "paperclip-ios: product spec", status: status, updatedAt: updatedAt)
    }

    /// Every call of the screen answered; override what a test needs.
    private func makeServer(status: String = "in_review", comments: String? = nil, liveRuns: String = "[]") -> StubServer {
        let server = StubServer()
        server.on("GET", issuePath, .ok(Self.issue(status: status)))
        server.on("GET", commentsPath, .ok(comments ?? list(Self.c1, Self.c2)))
        server.on("GET", documentsPath, .ok(Self.document))
        server.on("GET", attachmentsPath, .ok(Self.attachment))
        server.on("GET", liveRunsPath, .ok(liveRuns))
        server.on("GET", agentsPath, .ok(Self.agents))
        server.on("POST", readPath, .ok(#"{"ok":true}"#))
        return server
    }

    private func detail(_ server: StubServer, poller: Poller = .live) throws -> (TaskDetailModel, AccountStore, UUID) {
        let (store, id) = try signedInStore(server)
        return (TaskDetailModel(store: store, accountID: id, issueID: "issue-1", poller: poller), store, id)
    }

    /// Decodes a model from test JSON (dates with fractional seconds).
    private func decodeModel<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            iso(try decoder.singleValueContainer().decode(String.self))
        }
        return try decoder.decode(type, from: Data(json.utf8))
    }

    private func loaded(_ model: TaskDetailModel) -> TaskDetail? {
        if case .loaded(let detail) = model.state { return detail }
        return nil
    }

    private func patches(_ server: StubServer) -> [[String: Any]] {
        server.requests("PATCH", issuePath).compactMap(jsonObject)
    }

    // MARK: Navigation

    @Test func everyListOpensTaskDetailByIssueID() throws {
        #expect(TaskRoute(issueID: "issue-1") == TaskRoute(issueID: "issue-1"))
        #expect(TaskRoute(issueID: "issue-1") != TaskRoute(issueID: "issue-2"))

        let issue = try decodeModel(PaperclipAPI.Issue.self, Self.issue())
        #expect(InboxRow(issue: issue, isUnread: true).route == TaskRoute(issueID: "issue-1"))
        #expect(ReplyRow(issue: issue, preview: nil).route == TaskRoute(issueID: "issue-1"))

        let card = NeedsYouCard(id: "att-1", kind: .interaction, title: "Approve?", identifier: "PAP-1",
                                detail: nil, issueID: "issue-1", webPath: "/PAP/issues/PAP-1")
        #expect(card.route == TaskRoute(issueID: "issue-1"))
        // An approval without an issue has no task to open.
        let approval = NeedsYouCard(id: "att-2", kind: .approval, title: "Hire", identifier: nil,
                                    detail: nil, issueID: nil, webPath: "/PAP/approvals/a")
        #expect(approval.route == nil)
    }

    // MARK: Load

    @Test func startsLoading() throws {
        let (model, _, _) = try detail(makeServer())
        #expect(model.state == .loading)
        #expect(model.showsReviewBar == false)
        #expect(model.liveRunText == nil)
    }

    @Test func refreshLoadsTheTaskThreadDocumentsAndAttachments() async throws {
        let server = makeServer()
        let (model, _, _) = try detail(server)
        await model.refresh()

        let detail = try #require(loaded(model))
        #expect(detail.issue.title == "paperclip-ios: product spec")
        #expect(detail.issue.status == .inReview)
        // Oldest first, like a chat.
        #expect(detail.comments.map(\.id) == ["c-1", "c-2"])
        #expect(query(server.requests("GET", commentsPath).last)["order"] == "asc")
        #expect(detail.documents.map(\.key) == ["product-spec"])
        #expect(detail.documents.first?.body == "# Spec\n\nHello")
        #expect(detail.attachments.map(\.id) == ["att-1"])
        // A photo belongs to the comment it was sent with.
        #expect(model.attachments(for: detail.comments[1]).map(\.id) == ["att-1"])
        #expect(model.attachments(for: detail.comments[0]).isEmpty)
        // Assignee picker options.
        #expect(model.agents.map(\.name) == ["Luis", "Marta"])
    }

    @Test func openingMarksTheTaskRead() async throws {
        let server = makeServer()
        let (model, _, _) = try detail(server)
        await model.refresh()

        #expect(server.requests("POST", readPath).count == 1)
        #expect(server.requests("POST", readPath).first?.value(forHTTPHeaderField: "Authorization") == "Bearer \(JSON.key)")
    }

    @Test func taskErrorShowsAMessage() async throws {
        let server = makeServer()
        server.on("GET", issuePath, StubServer.Response(status: 500, body: JSON.unavailable))
        let (model, _, _) = try detail(server)
        await model.refresh()

        #expect(model.state == .error(userMessage(for: APIError.server(status: 500, body: "Service unavailable"))))
        #expect(server.requests("POST", readPath).isEmpty)
    }

    @Test func unauthorizedSendsTheAccountToSignIn() async throws {
        let server = makeServer()
        server.on("GET", issuePath, StubServer.Response(status: 401, body: JSON.unauthorized))
        let (model, store, id) = try detail(server)
        await model.refresh()

        #expect(model.state == .needsSignIn)
        #expect(store.route == .reSignIn(id))
    }

    @Test func extrasThatFailDoNotHideTheTask() async throws {
        // Documents, attachments, live runs, agents and mark-read are extras:
        // the task and its thread still show when one of them fails.
        let server = makeServer()
        for path in [documentsPath, attachmentsPath, liveRunsPath, agentsPath] {
            server.on("GET", path, StubServer.Response(status: 500, body: JSON.unavailable))
        }
        server.on("POST", readPath, StubServer.Response(status: 500, body: JSON.unavailable))
        let (model, _, _) = try detail(server)
        await model.refresh()

        let detail = try #require(loaded(model))
        #expect(detail.comments.map(\.id) == ["c-1", "c-2"])
        #expect(detail.documents.isEmpty)
        #expect(detail.attachments.isEmpty)
        #expect(model.agents.isEmpty)
    }

    // MARK: Live run

    @Test func liveRunLineNamesTheWorkingAgent() async throws {
        let (model, _, _) = try detail(makeServer(liveRuns: Self.liveRun(agentName: "Luis")))
        await model.refresh()
        #expect(model.liveRunText == "Luis is working…")

        let (idle, _, _) = try detail(makeServer())
        await idle.refresh()
        #expect(idle.liveRunText == nil)
    }

    // MARK: Pickers

    @Test func statusPickerSendsThePatchAndKeepsTheServerAnswer() async throws {
        let server = makeServer(status: "todo")
        server.on("PATCH", issuePath, .ok(Self.issue(status: "in_progress", updatedAt: "2026-10-14T09:30:00.000Z")))
        let (model, _, _) = try detail(server)
        await model.refresh()

        await model.setStatus(.inProgress)

        #expect(patches(server).count == 1)
        #expect(patches(server).first?["status"] as? String == "in_progress")
        #expect(patches(server).first?.keys.sorted() == ["status"])
        #expect(loaded(model)?.issue.status == .inProgress)
        #expect(loaded(model)?.issue.updatedAt == iso("2026-10-14T09:30:00.000Z"))
        #expect(model.actionError == nil)
    }

    @Test func statusPickerRollsBackOnError() async throws {
        let server = makeServer(status: "todo")
        server.on("PATCH", issuePath, StubServer.Response(status: 500, body: JSON.unavailable))
        let (model, _, _) = try detail(server)
        await model.refresh()

        await model.setStatus(.blocked)

        #expect(loaded(model)?.issue.status == .todo)
        #expect(model.actionError == userMessage(for: APIError.server(status: 500, body: "Service unavailable")))
        model.dismissActionError()
        #expect(model.actionError == nil)
    }

    @Test func priorityPickerRollsBackOnError() async throws {
        let server = makeServer()
        server.on("PATCH", issuePath, StubServer.Response(status: 422, body: #"{"error":"Invalid priority"}"#))
        let (model, _, _) = try detail(server)
        await model.refresh()

        await model.setPriority(.critical)

        #expect(patches(server).first?["priority"] as? String == "critical")
        #expect(loaded(model)?.issue.priority == .medium)
        #expect(model.actionError == userMessage(for: APIError.server(status: 422, body: "Invalid priority")))
    }

    @Test func assigneePickerSendsTheAgentAndClearsTheUser() async throws {
        let server = makeServer()
        let reassigned = Self.issue().replacingOccurrences(of: #""assigneeAgentId":null"#, with: #""assigneeAgentId":"agent-2""#)
        server.on("PATCH", issuePath, .ok(reassigned))
        let (model, _, _) = try detail(server)
        await model.refresh()
        #expect(model.assignee == .nobody)

        await model.setAssignee(.agent("agent-2"))

        let sent = try #require(patches(server).first)
        #expect(sent["assigneeAgentId"] as? String == "agent-2")
        #expect(sent["assigneeUserId"] is NSNull)
        #expect(model.assignee == .agent("agent-2"))
    }

    @Test func assigneePickerRollsBackOnError() async throws {
        let server = makeServer()
        server.on("PATCH", issuePath, StubServer.Response(status: 500, body: JSON.unavailable))
        let (model, _, _) = try detail(server)
        await model.refresh()

        await model.setAssignee(.agent("agent-2"))

        #expect(model.assignee == .nobody)
        #expect(model.actionError != nil)
    }

    @Test func pickerUnauthorizedSendsTheAccountToSignIn() async throws {
        let server = makeServer()
        server.on("PATCH", issuePath, StubServer.Response(status: 401, body: JSON.unauthorized))
        let (model, store, id) = try detail(server)
        await model.refresh()

        await model.setStatus(.done)

        #expect(model.state == .needsSignIn)
        #expect(store.route == .reSignIn(id))
    }

    // MARK: Review bar

    static let reviewBarCases: [(IssueStatus, Bool)] = [
        (.inReview, true), (.done, true),
        (.backlog, false), (.todo, false), (.inProgress, false), (.blocked, false), (.cancelled, false),
        (.unknown("paused"), false),
    ]

    @Test(arguments: TaskDetailModelTests.reviewBarCases)
    func reviewBarOnlyOnInReviewAndDone(status: IssueStatus, shows: Bool) {
        #expect(TaskDetailModel.showsReviewBar(for: status) == shows)
    }

    @Test func reviewBarFollowsTheLoadedStatus() async throws {
        let (review, _, _) = try detail(makeServer(status: "in_review"))
        await review.refresh()
        #expect(review.showsReviewBar)

        let (working, _, _) = try detail(makeServer(status: "in_progress"))
        await working.refresh()
        #expect(working.showsReviewBar == false)
    }

    @Test func looksGoodMarksTheTaskDone() async throws {
        let server = makeServer(status: "in_review")
        server.on("PATCH", issuePath, .ok(Self.issue(status: "done")))
        let (model, _, _) = try detail(server)
        await model.refresh()

        await model.markDone()

        #expect(patches(server).first?.keys.sorted() == ["status"])
        #expect(patches(server).first?["status"] as? String == "done")
        #expect(loaded(model)?.issue.status == .done)
        // Done keeps the bar: the user can still re-open.
        #expect(model.showsReviewBar)
    }

    @Test func reopenRequiresAComment() async throws {
        let server = makeServer(status: "done")
        let (model, _, _) = try detail(server)
        await model.refresh()

        #expect(await model.reopen(comment: "") == false)
        #expect(await model.reopen(comment: "  \n ") == false)
        #expect(server.requests("PATCH", issuePath).isEmpty)
        #expect(loaded(model)?.issue.status == .done)
    }

    @Test func reopenSetsTodoWithTheCommentAndShowsIt() async throws {
        let server = makeServer(status: "done")
        server.on("PATCH", issuePath, .ok(Self.issue(status: "todo", updatedAt: "2026-10-14T09:40:00.000Z")))
        let reopenComment = Self.comment("c-4", body: "Not yet: the icon is blurry.", at: "2026-10-14T09:40:00.000Z", agent: false)
        server.on("GET", commentsPath, query: ["after": "c-2"], .ok(list(reopenComment)))
        let (model, _, _) = try detail(server)
        await model.refresh()

        #expect(await model.reopen(comment: "  Not yet: the icon is blurry. ") == true)

        let sent = try #require(patches(server).first)
        #expect(sent.keys.sorted() == ["comment", "status"])
        #expect(sent["status"] as? String == "todo")
        #expect(sent["comment"] as? String == "Not yet: the icon is blurry.")
        #expect(loaded(model)?.issue.status == .todo)
        #expect(model.showsReviewBar == false)
        // The re-open comment shows in the thread without a full reload.
        #expect(loaded(model)?.comments.map(\.id) == ["c-1", "c-2", "c-4"])
    }

    @Test func reopenFailureKeepsTheSheetOpen() async throws {
        let server = makeServer(status: "done")
        server.on("PATCH", issuePath, StubServer.Response(status: 500, body: JSON.unavailable))
        let (model, _, _) = try detail(server)
        await model.refresh()

        #expect(await model.reopen(comment: "Not yet") == false)
        #expect(loaded(model)?.issue.status == .done)
        #expect(model.actionError != nil)
    }

    // MARK: Thread updates

    @Test func sentCommentShowsOnceEvenWhenThePollReturnsItToo() async throws {
        let server = makeServer()
        // The poll races the send: it returns the comment the composer just added.
        server.on("GET", commentsPath, query: ["after": "c-3"], .ok(list(Self.c3)))
        let (model, _, _) = try detail(server)
        await model.refresh()

        let sent = try decodeModel(IssueComment.self, Self.c3)
        model.insertComment(sent)
        #expect(loaded(model)?.comments.map(\.id) == ["c-1", "c-2", "c-3"])

        await model.poll()
        #expect(loaded(model)?.comments.map(\.id) == ["c-1", "c-2", "c-3"])
    }

    // MARK: Polling

    @Test func pollAsksOnlyForCommentsAfterTheLastOne() async throws {
        let server = makeServer(liveRuns: "[]")
        server.on("GET", commentsPath, query: ["after": "c-2"], .ok(list(Self.c3)))
        let (model, _, _) = try detail(server)
        await model.refresh()
        server.on("GET", liveRunsPath, .ok(Self.liveRun(agentName: "Marta")))
        server.on("GET", issuePath, .ok(Self.issue(status: "done", updatedAt: "2026-10-14T09:20:00.000Z")))

        await model.poll()

        let request = try #require(server.requests("GET", commentsPath).last)
        #expect(query(request)["after"] == "c-2")
        #expect(query(request)["order"] == "asc")
        let detail = try #require(loaded(model))
        #expect(detail.comments.map(\.id) == ["c-1", "c-2", "c-3"])
        #expect(detail.issue.status == .done)
        #expect(model.liveRunText == "Marta is working…")
        // The user is looking at the new reply: it is read.
        #expect(server.requests("POST", readPath).count == 2)
    }

    @Test func pollWithoutNewCommentsDoesNotMarkReadAgain() async throws {
        let server = makeServer()
        server.on("GET", commentsPath, query: ["after": "c-2"], .ok("[]"))
        let (model, _, _) = try detail(server)
        await model.refresh()

        await model.poll()

        #expect(server.requests("POST", readPath).count == 1)
        #expect(loaded(model)?.comments.map(\.id) == ["c-1", "c-2"])
    }

    @Test func failedPollKeepsTheTaskOnScreen() async throws {
        let server = makeServer()
        let (model, _, _) = try detail(server)
        await model.refresh()
        server.on("GET", issuePath, StubServer.Response(status: 503, body: JSON.unavailable))

        await model.poll()

        #expect(loaded(model)?.comments.map(\.id) == ["c-1", "c-2"])
    }

    @Test func pollUnauthorizedSendsTheAccountToSignIn() async throws {
        let server = makeServer()
        let (model, store, id) = try detail(server)
        await model.refresh()
        server.on("GET", issuePath, StubServer.Response(status: 401, body: JSON.unauthorized))

        await model.poll()

        #expect(model.state == .needsSignIn)
        #expect(store.route == .reSignIn(id))
    }

    @Test func pollingTicksEveryFifteenSeconds() async throws {
        let server = makeServer()
        server.on("GET", commentsPath, query: ["after": "c-2"], .ok("[]"))
        let sleeper = TestSleeper(ticks: 2)
        let (model, _, _) = try detail(server, poller: Poller(sleep: { try await sleeper.sleep($0) }))
        await model.refresh()

        await model.runPolling()

        #expect(sleeper.durations == [.seconds(15), .seconds(15), .seconds(15)])
        #expect(server.requests("GET", issuePath).count == 3)
    }
}
