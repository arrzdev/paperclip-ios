import Foundation
import PaperclipAPI
import Testing
@testable import PaperclipIOS

/// Requests (issue thread interactions) answered from Today and Task detail
/// (spec §2 item 1, §4 A): inline Accept / Reject / Answer, a card that leaves
/// at once with a 5 s undo toast, and a request sent only when the toast ends.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct RequestActionsTests {
    let attentionPath = "/api/companies/company-1/attention"
    let interactionsPath = "/api/issues/issue-1/interactions"
    let acceptPath = "/api/issues/issue-1/interactions/att-1-subject/accept"
    let rejectPath = "/api/issues/issue-1/interactions/att-1-subject/reject"
    let respondPath = "/api/issues/issue-1/interactions/att-1-subject/respond"

    static func interaction(
        id: String = "att-1-subject",
        kind: String = "request_confirmation",
        status: String = "pending",
        payload: String = confirmPayload,
        createdAt: String = "2026-10-14T09:05:00.000Z"
    ) -> String {
        #"{"id":"\#(id)","companyId":"company-1","issueId":"issue-1","kind":"\#(kind)","status":"\#(status)","continuationPolicy":"wake_assignee","title":null,"summary":null,"createdByAgentId":"agent-1","createdByUserId":null,"payload":\#(payload),"result":null,"createdAt":"\#(createdAt)","updatedAt":"\#(createdAt)","resolvedAt":null}"#
    }

    static let confirmPayload = #"{"version":1,"prompt":"Send the plan to the board?","acceptLabel":"Send it","rejectLabel":null,"rejectRequiresReason":false,"allowDeclineReason":true}"#
    static let reasonRequiredPayload = #"{"version":1,"prompt":"Ship it?","rejectRequiresReason":true}"#
    static let questionsPayload = #"{"version":1,"title":"Launch","questions":[{"id":"q-store","prompt":"Which store first?","selectionMode":"single","required":true,"options":[{"id":"o-ios","label":"App Store"},{"id":"o-android","label":"Google Play"}]}]}"#

    static let requestItem = TodayModelTests.attentionItem(
        id: "att-1", sourceKind: "issue_thread_interaction", subjectKind: "interaction", title: "Approve the plan?",
        relatedIssueID: "issue-1", relatedIdentifier: "PAP-1", relatedTitle: "iOS plan", prompt: "Send the plan to the board?"
    )

    /// Today with one request on issue-1 and nothing else.
    private func makeServer(interactions: String? = nil) -> StubServer {
        let server = StubServer()
        server.on("GET", attentionPath, .ok(TodayModelTests.feed(Self.requestItem)))
        server.on("GET", companyIssuesPath, .ok("[]"))
        server.on("GET", "/api/companies/company-1/dashboard", .ok(TodayModelTests.dashboard))
        server.on("GET", "/api/companies/company-1/approvals", .ok("[]"))
        server.on("GET", interactionsPath, .ok(interactions ?? list(Self.interaction())))
        server.on("POST", acceptPath, .ok(Self.interaction(status: "accepted")))
        server.on("POST", rejectPath, .ok(Self.interaction(status: "rejected")))
        server.on("POST", respondPath, .ok(Self.interaction(status: "answered")))
        return server
    }

    private func today(_ server: StubServer, log: LogSink = LogSink()) async throws -> (TodayModel, AccountStore, UUID) {
        let (store, id) = try signedInStore(server, log: log)
        let model = TodayModel(store: store, accountID: id)
        await model.refresh()
        return (model, store, id)
    }

    private func cards(_ model: TodayModel) -> [NeedsYouCard] {
        if case .loaded(let content) = model.state { return content.needsYou }
        return []
    }

    private func request(_ model: TodayModel) throws -> InteractionCard {
        try #require(cards(model).first?.request)
    }

    private func sent(_ server: StubServer) -> [URLRequest] {
        server.allRequests.filter { $0.httpMethod == "POST" }
    }

    /// Decodes one interaction from test JSON (dates with fractional seconds).
    private func decodeInteraction(_ json: String) throws -> IssueInteraction {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            iso(try decoder.singleValueContainer().decode(String.self))
        }
        return try decoder.decode(IssueInteraction.self, from: Data(json.utf8))
    }

    // MARK: Cards

    @Test func aTodayRequestCardCarriesItsButtons() async throws {
        let server = makeServer()
        let (model, _, _) = try await today(server)

        let card = try request(model)
        #expect(card.id == "att-1-subject")
        #expect(card.issueID == "issue-1")
        #expect(card.identifier == "PAP-1")
        #expect(card.title == "iOS plan")
        #expect(card.prompt == "Send the plan to the board?")
        // The server's label when it sends one, else the default.
        #expect(card.action == .confirm(acceptLabel: "Send it", rejectLabel: "Reject", rejectRequiresReason: false))
        #expect(card.webPath == "/PAP/issues/PAP-1")
    }

    @Test func requestsAreFetchedOncePerTask() async throws {
        let second = TodayModelTests.attentionItem(
            id: "att-5", sourceKind: "issue_thread_interaction", subjectKind: "interaction", title: "Pick a store",
            relatedIssueID: "issue-1", relatedIdentifier: "PAP-1", relatedTitle: "iOS plan"
        )
        let server = makeServer(interactions: list(
            Self.interaction(),
            Self.interaction(id: "att-5-subject", kind: "ask_user_questions", payload: Self.questionsPayload)
        ))
        server.on("GET", attentionPath, .ok(TodayModelTests.feed(Self.requestItem, second)))
        let (model, _, _) = try await today(server)

        #expect(cards(model).compactMap(\.request).map(\.id) == ["att-1-subject", "att-5-subject"])
        #expect(server.requests("GET", interactionsPath).count == 1)
        guard case .answer(let questions) = cards(model)[1].request?.action else {
            Testing.Issue.record("expected an Answer card")
            return
        }
        #expect(questions.map(\.id) == ["q-store"])
    }

    @Test func aFailedRequestFetchLeavesAPlainCard() async throws {
        let server = makeServer()
        server.on("GET", interactionsPath, StubServer.Response(status: 500, body: JSON.unavailable))
        let (model, _, _) = try await today(server)

        #expect(cards(model).map(\.id) == ["att-1"])
        #expect(cards(model).first?.request == nil)
    }

    @Test func aRequestAnsweredElsewhereHasNoCard() async throws {
        let server = makeServer(interactions: list(Self.interaction(status: "accepted")))
        let (model, _, _) = try await today(server)

        #expect(model.state == .empty)
    }

    @Test func kindsTheAppCannotAnswerAreReadOnly() throws {
        let toolAction = #"{"version":1,"prompt":"Run deploy?","toolAction":{"version":1,"toolName":"deploy","risk":"destructive"}}"#
        let secret = #"{"version":1,"prompt":"Share the key?","secretProposal":{"version":1,"proposalId":"p-1"}}"#
        let unknownMode = #"{"version":1,"questions":[{"id":"q","prompt":"Rank them","selectionMode":"ranked","options":[{"id":"o","label":"A"}]}]}"#
        let tooMany = "{\"version\":1,\"questions\":[" + (1...21).map { number in
            #"{"id":"q\#(number)","prompt":"Q\#(number)","selectionMode":"single","options":[{"id":"o","label":"A"}]}"#
        }.joined(separator: ",") + "]}"
        let cases: [(String, String)] = [
            ("suggest_tasks", #"{"version":1,"tasks":[{"clientKey":"t1","title":"README"}]}"#),
            ("request_checkbox_confirmation", #"{"version":1,"prompt":"Pick","options":[]}"#),
            ("hologram_call", "{}"),
            ("request_confirmation", toolAction),
            ("request_confirmation", secret),
            ("request_confirmation", "{}"),
            ("ask_user_questions", unknownMode),
            ("ask_user_questions", tooMany),
            ("ask_user_questions", #"{"version":1,"questions":[]}"#),
        ]
        for (kind, payload) in cases {
            let interaction = try decodeInteraction(Self.interaction(kind: kind, payload: payload))
            let card = InteractionCard(interaction, identifier: "PAP-1", issueTitle: "iOS plan")
            #expect(card.action == .openInWeb, "\(kind) \(payload)")
            #expect(card.webPath == "/PAP/issues/PAP-1")
        }
    }

    // MARK: Accept, reject, answer with undo

    @Test func acceptHidesTheCardAndSendsOnlyWhenTheToastEnds() async throws {
        let server = makeServer()
        let (model, _, _) = try await today(server)
        let card = try request(model)

        await model.requests.accept(card)

        #expect(model.state == .empty)
        #expect(model.requests.pending?.card == card)
        #expect(model.requests.pending?.toastText == "Accepted")
        #expect(sent(server).isEmpty)

        await model.requests.sendPending()

        #expect(server.requests("POST", acceptPath).count == 1)
        #expect(server.requests("POST", acceptPath).first.flatMap(jsonObject)?.isEmpty == true)
        #expect(model.requests.pending == nil)
        #expect(model.requests.error == nil)
        #expect(model.state == .empty)
    }

    @Test func undoBringsTheCardBackAndSendsNothing() async throws {
        let server = makeServer()
        let (model, _, _) = try await today(server)
        let card = try request(model)

        await model.requests.accept(card)
        model.requests.undo()
        await model.requests.sendPending()

        #expect(sent(server).isEmpty)
        #expect(model.requests.pending == nil)
        #expect(cards(model).first?.request == card)
    }

    @Test func theToastEndsAfterFiveSecondsAndSends() async throws {
        let server = makeServer()
        let (store, id) = try signedInStore(server)
        let sleeper = TestSleeper(ticks: 1)
        let actions = RequestActions(store: store, accountID: id, sleep: { try await sleeper.sleep($0) })
        let card = InteractionCard(try decodeInteraction(Self.interaction()), identifier: "PAP-1", issueTitle: "iOS plan")

        await actions.accept(card)
        await actions.runUndoTimer()

        #expect(sleeper.durations == [.seconds(5)])
        #expect(server.requests("POST", acceptPath).count == 1)
        #expect(actions.pending == nil)
    }

    @Test func aCancelledTimerSendsNothing() async throws {
        let server = makeServer()
        let (store, id) = try signedInStore(server)
        // The first sleep throws, as when the toast's task is cancelled by undo.
        let sleeper = TestSleeper(ticks: 0)
        let actions = RequestActions(store: store, accountID: id, sleep: { try await sleeper.sleep($0) })
        let card = InteractionCard(try decodeInteraction(Self.interaction()), identifier: "PAP-1", issueTitle: "iOS plan")

        await actions.accept(card)
        await actions.runUndoTimer()

        #expect(sent(server).isEmpty)
        #expect(actions.pending?.card == card)
    }

    @Test func aSecondActionSendsTheFirstOne() async throws {
        let server = makeServer(interactions: list(
            Self.interaction(),
            Self.interaction(id: "att-5-subject", createdAt: "2026-10-14T09:06:00.000Z")
        ))
        let second = TodayModelTests.attentionItem(
            id: "att-5", sourceKind: "issue_thread_interaction", subjectKind: "interaction", title: "Again?",
            relatedIssueID: "issue-1", relatedIdentifier: "PAP-1", relatedTitle: "iOS plan"
        )
        server.on("GET", attentionPath, .ok(TodayModelTests.feed(Self.requestItem, second)))
        server.on("POST", "/api/issues/issue-1/interactions/att-5-subject/accept", .ok(Self.interaction(status: "accepted")))
        let (model, _, _) = try await today(server)
        let requests = cards(model).compactMap(\.request)

        await model.requests.accept(requests[0])
        await model.requests.accept(requests[1])

        #expect(server.requests("POST", acceptPath).count == 1)
        #expect(model.requests.pending?.card.id == "att-5-subject")
        #expect(model.state == .empty)
    }

    @Test func rejectSendsTheTrimmedReason() async throws {
        let server = makeServer()
        let (model, _, _) = try await today(server)

        let card = try request(model)
        #expect(await model.requests.reject(card, reason: "  Too early \n"))
        #expect(model.requests.pending?.toastText == "Rejected")
        await model.requests.sendPending()

        let body = try #require(server.requests("POST", rejectPath).first.flatMap(jsonObject))
        #expect(body as? [String: String] == ["reason": "Too early"])
    }

    @Test func rejectWithoutAReasonSendsNone() async throws {
        let server = makeServer()
        let (model, _, _) = try await today(server)

        let card = try request(model)
        #expect(await model.requests.reject(card, reason: "   "))
        await model.requests.sendPending()

        #expect(server.requests("POST", rejectPath).first.flatMap(jsonObject)?.isEmpty == true)
    }

    @Test func aRequiredReasonCannotBeBlank() async throws {
        let server = makeServer(interactions: list(Self.interaction(payload: Self.reasonRequiredPayload)))
        let (model, _, _) = try await today(server)
        let card = try request(model)
        #expect(card.action == .confirm(acceptLabel: "Accept", rejectLabel: "Reject", rejectRequiresReason: true))

        #expect(await model.requests.reject(card, reason: " ") == false)

        #expect(model.requests.pending == nil)
        #expect(cards(model).first?.request == card)
    }

    @Test func answerSendsTheFormAndAnInvalidFormStaysOpen() async throws {
        let server = makeServer(interactions: list(Self.interaction(kind: "ask_user_questions", payload: Self.questionsPayload)))
        let (model, _, _) = try await today(server)
        let card = try request(model)
        guard case .answer(let questions) = card.action else {
            Testing.Issue.record("expected an Answer card")
            return
        }
        var form = QuestionForm(questions: questions)

        #expect(await model.requests.answer(card, form: form) == false)
        #expect(model.requests.pending == nil)

        form.select("o-android", in: "q-store")
        #expect(await model.requests.answer(card, form: form))
        #expect(model.requests.pending?.toastText == "Answer sent")
        await model.requests.sendPending()

        let body = try #require(server.requests("POST", respondPath).first.flatMap(jsonObject))
        let answers = try #require(body["answers"] as? [[String: Any]])
        #expect(answers.count == 1)
        #expect(answers[0]["questionId"] as? String == "q-store")
        #expect(answers[0]["optionIds"] as? [String] == ["o-android"])
    }

    // MARK: Failures

    @Test func aFailedSendBringsTheCardBackWithTheError() async throws {
        let server = makeServer()
        server.on("POST", acceptPath, StubServer.Response(status: 500, body: JSON.unavailable))
        let (model, _, _) = try await today(server)
        let card = try request(model)

        await model.requests.accept(card)
        await model.requests.sendPending()

        #expect(cards(model).first?.request == card)
        #expect(model.requests.error == userMessage(for: APIError.server(status: 500, body: "Service unavailable")))
        #expect(model.requests.pending == nil)

        model.requests.dismissError()
        #expect(model.requests.error == nil)
    }

    @Test func aRequestAlreadyAnsweredStaysGone() async throws {
        let server = makeServer()
        server.on("POST", acceptPath, StubServer.Response(
            status: 409, body: #"{"error":"Interaction is no longer pending","code":"interaction_already_resolved"}"#
        ))
        let (model, _, _) = try await today(server)

        let card = try request(model)
        await model.requests.accept(card)
        await model.requests.sendPending()

        #expect(model.state == .empty)
        #expect(model.requests.error == RequestActions.alreadyAnswered)
        #expect(RequestActions.alreadyAnswered == "This request was already answered.")
    }

    @Test func unauthorizedSendsTheAccountToSignIn() async throws {
        let server = makeServer()
        server.on("POST", acceptPath, StubServer.Response(status: 401, body: JSON.unauthorized))
        let (model, store, id) = try await today(server)

        let card = try request(model)
        await model.requests.accept(card)
        await model.requests.sendPending()

        #expect(model.requests.needsSignIn)
        #expect(model.state == .needsSignIn)
        #expect(store.route == .reSignIn(id))
    }

    @Test func theReasonIsNeverLogged() async throws {
        let server = makeServer()
        server.on("POST", rejectPath, StubServer.Response(status: 500, body: JSON.unavailable))
        let log = LogSink()
        let (model, _, _) = try await today(server, log: log)

        let card = try request(model)
        _ = await model.requests.reject(card, reason: "secret-plan-details")
        await model.requests.sendPending()

        #expect(!log.lines.isEmpty)
        #expect(!log.lines.contains { $0.contains("secret-plan-details") })
    }

    // MARK: Task detail

    private func detailServer(interactions: String) -> StubServer {
        let server = StubServer()
        server.on("GET", "/api/issues/issue-1", .ok(TaskDetailModelTests.issue()))
        server.on("GET", "/api/issues/issue-1/comments", .ok(list(TaskDetailModelTests.c1, TaskDetailModelTests.c2)))
        server.on("GET", "/api/companies/company-1/agents", .ok(TaskDetailModelTests.agents))
        server.on("POST", "/api/issues/issue-1/read", .ok(#"{"ok":true}"#))
        server.on("GET", interactionsPath, .ok(interactions))
        server.on("POST", acceptPath, .ok(Self.interaction(status: "accepted")))
        return server
    }

    @Test func taskDetailShowsPendingRequestsInTheThreadByTime() async throws {
        // c-1 at 09:00, c-2 at 09:10; the request at 09:05; an answered one is not shown.
        let server = detailServer(interactions: list(
            Self.interaction(id: "old", status: "accepted", createdAt: "2026-10-14T08:00:00.000Z"),
            Self.interaction()
        ))
        let (store, id) = try signedInStore(server)
        let model = TaskDetailModel(store: store, accountID: id, issueID: "issue-1")
        await model.refresh()

        #expect(model.threadItems.map(\.id) == ["c-1", "att-1-subject", "c-2"])
        guard case .request(let card) = model.threadItems[1] else {
            Testing.Issue.record("expected a request in the thread")
            return
        }
        #expect(card.identifier == "PAP-1")
        #expect(card.action == .confirm(acceptLabel: "Send it", rejectLabel: "Reject", rejectRequiresReason: false))
    }

    @Test func taskDetailAcceptLeavesTheThreadAndPollFindsNewRequests() async throws {
        let server = detailServer(interactions: list(Self.interaction()))
        let (store, id) = try signedInStore(server)
        let model = TaskDetailModel(store: store, accountID: id, issueID: "issue-1")
        await model.refresh()
        guard case .request(let card) = model.threadItems[1] else {
            Testing.Issue.record("expected a request in the thread")
            return
        }

        await model.requests.accept(card)
        #expect(model.threadItems.map(\.id) == ["c-1", "c-2"])
        await model.requests.sendPending()
        #expect(server.requests("POST", acceptPath).count == 1)

        server.on("GET", interactionsPath, .ok(list(
            Self.interaction(status: "accepted"),
            Self.interaction(id: "new", kind: "ask_user_questions", payload: Self.questionsPayload,
                             createdAt: "2026-10-14T09:30:00.000Z")
        )))
        await model.poll()

        #expect(model.threadItems.map(\.id) == ["c-1", "c-2", "new"])
    }

    @Test func taskDetailRequestsFailureNeverHidesTheTask() async throws {
        let server = detailServer(interactions: "[]")
        server.on("GET", interactionsPath, StubServer.Response(status: 500, body: JSON.unavailable))
        let (store, id) = try signedInStore(server)
        let model = TaskDetailModel(store: store, accountID: id, issueID: "issue-1")
        await model.refresh()

        #expect(model.detail != nil)
        #expect(model.threadItems.map(\.id) == ["c-1", "c-2"])
    }

    @Test func taskDetailUnauthorizedSendGoesToSignIn() async throws {
        let server = detailServer(interactions: list(Self.interaction()))
        server.on("POST", acceptPath, StubServer.Response(status: 401, body: JSON.unauthorized))
        let (store, id) = try signedInStore(server)
        let model = TaskDetailModel(store: store, accountID: id, issueID: "issue-1")
        await model.refresh()
        guard case .request(let card) = model.threadItems[1] else {
            Testing.Issue.record("expected a request in the thread")
            return
        }

        await model.requests.accept(card)
        await model.requests.sendPending()

        #expect(model.state == .needsSignIn)
        #expect(store.route == .reSignIn(id))
    }
}
