import Foundation
import Testing
@testable import PaperclipAPI

/// Serialized: the URL protocol stub is shared by every request in the process.
@Suite(.serialized)
struct APIClientTests {
    let client: APIClient

    init() throws {
        client = APIClient(
            server: try ServerAddress("https://paperclip.test"),
            apiKey: "pcp_board_TEST",
            session: StubURLProtocol.session()
        )
    }

    private func stub(_ name: String, status: Int = 200) throws {
        let body = try fixture(name)
        StubURLProtocol.respond { _ in .init(status: status, body: body) }
    }

    private func jsonBody(_ request: URLRequest?) throws -> [String: Any] {
        let data = try #require(request?.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func healthCheckAgainstPinnedCommit() async throws {
        try stub("health")
        let check = try await client.with(apiKey: nil).checkServer()
        #expect(check == .ok(commit: "467125fafb47a8520856504fecc48d6e32055db1"))
        let request = try #require(StubURLProtocol.lastRequest)
        #expect(request.url?.absoluteString == "https://paperclip.test/api/health")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func deviceFlowChallengeAndPoll() async throws {
        try stub("cli-auth-challenge", status: 201)
        let challenge = try await client.with(apiKey: nil).createCliAuthChallenge()
        let request = StubURLProtocol.lastRequest
        #expect(request?.httpMethod == "POST")
        #expect(request?.url?.path == "/api/cli-auth/challenges")
        let body = try jsonBody(request)
        #expect(body["clientName"] as? String == "Paperclip iOS")
        #expect(body["requestedAccess"] as? String == "board")
        #expect(challenge.boardApiToken == "pcp_board_TEST")
        #expect(client.approvalURL(for: challenge).host == "paperclip.test")

        try stub("cli-auth-challenge-state")
        let state = try await client.cliAuthChallengeState(id: challenge.id, token: challenge.token)
        #expect(state.status == .approved)
        #expect(
            StubURLProtocol.lastRequest?.url?.absoluteString
                == "https://paperclip.test/api/cli-auth/challenges/0b6a3c1e-5f1d-4c7e-9a2b-3d4e5f6a7b8c?token=challenge-secret%2Bfixture"
        )
    }

    @Test func approvalURLFallsBackToServerWhenServerSendsNone() throws {
        let json = #"{"id":"c1","token":"t","boardApiToken":"k","approvalPath":"/cli-auth/c1?token=t","approvalUrl":null,"pollPath":"/cli-auth/challenges/c1","expiresAt":"2026-10-13T22:31:01Z"}"#
        let challenge = try PaperclipDate.decoder.decode(CliAuthChallenge.self, from: Data(json.utf8))
        #expect(client.approvalURL(for: challenge).absoluteString == "https://paperclip.test/cli-auth/c1?token=t")
    }

    @Test func meSendsBearerKey() async throws {
        try stub("cli-auth-me")
        let me = try await client.me()
        #expect(me.companyIds == ["company-1"])
        #expect(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer pcp_board_TEST")
    }

    @Test func revokeCurrentKeyPostsWithBearerKey() async throws {
        try stub("revoke-current")
        try await client.revokeCurrentKey()
        let request = try #require(StubURLProtocol.lastRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://paperclip.test/api/cli-auth/revoke-current")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer pcp_board_TEST")
    }

    @Test func companiesList() async throws {
        try stub("companies")
        let companies = try await client.companies()
        let request = try #require(StubURLProtocol.lastRequest)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://paperclip.test/api/companies")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer pcp_board_TEST")

        #expect(companies.map(\.id) == ["company-1", "company-2"])
        #expect(companies[0].name == "Fixture Co")
        #expect(companies[0].issuePrefix == "PAP")
        #expect(companies[1].status == "paused")
    }

    @Test func issueDetailByIdentifier() async throws {
        try stub("issue")
        let issue = try await client.issue(id: "PAP-12")
        let request = try #require(StubURLProtocol.lastRequest)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://paperclip.test/api/issues/PAP-12")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer pcp_board_TEST")

        #expect(issue.identifier == "PAP-12")
        #expect(issue.companyId == "company-1")
        #expect(issue.title == "Fixture task")
        #expect(issue.status == .inProgress)
        #expect(issue.priority == .high)
        #expect(issue.parentId != nil)
        // The detail response has no lastActivityAt; it stays optional.
        #expect(issue.lastActivityAt == nil)
    }

    @Test func inboxQueryAndLenientIssueDecoding() async throws {
        try stub("issues")
        var query = IssueListQuery.inbox
        query.status = [.todo, .inProgress]
        query.updatedSince = Date(timeIntervalSince1970: 0)
        let issues = try await client.issues(companyId: "company-1", query: query)

        let url = try #require(StubURLProtocol.lastRequest?.url)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(url.path == "/api/companies/company-1/issues")
        #expect(items.contains(URLQueryItem(name: "touchedByUserId", value: "me")))
        #expect(items.contains(URLQueryItem(name: "status", value: "todo,in_progress")))
        #expect(items.contains(URLQueryItem(name: "updatedSince", value: "1970-01-01T00:00:00.000Z")))

        #expect(issues.count == 2)
        #expect(issues[0].identifier == "PAP-12")
        #expect(issues[0].status == .inProgress)
        #expect(issues[1].status == .unknown("triage"))
        #expect(issues[1].priority == .unknown("urgent"))
    }

    @Test func tasksTabQuerySendsAssigneeSearchAndPage() async throws {
        try stub("issues")
        var query = IssueListQuery()
        query.status = [.done]
        query.assigneeAgentId = "00000000-0000-4000-8000-000000000002"
        query.assigneeUserId = "me"
        query.search = "login page"
        query.limit = 50
        query.offset = 100
        _ = try await client.issues(companyId: "company-1", query: query)

        let url = try #require(StubURLProtocol.lastRequest?.url)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.contains(URLQueryItem(name: "status", value: "done")))
        #expect(items.contains(URLQueryItem(name: "assigneeAgentId", value: "00000000-0000-4000-8000-000000000002")))
        #expect(items.contains(URLQueryItem(name: "assigneeUserId", value: "me")))
        #expect(items.contains(URLQueryItem(name: "q", value: "login page")))
        #expect(items.contains(URLQueryItem(name: "limit", value: "50")))
        #expect(items.contains(URLQueryItem(name: "offset", value: "100")))
        #expect(url.absoluteString.contains("q=login%20page"))
    }

    @Test func emptyQuerySendsNoAssigneeOrOffset() async throws {
        try stub("issues")
        _ = try await client.issues(companyId: "company-1", query: IssueListQuery())

        let url = try #require(StubURLProtocol.lastRequest?.url)
        #expect(url.query == nil || url.query == "")
    }

    @Test func inboxHidesArchivedAndDecodesReadStateForTheSignedInUser() async throws {
        try stub("inbox-issues")
        let issues = try await client.issues(companyId: "company-1", query: .inbox)

        let url = try #require(StubURLProtocol.lastRequest?.url)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.contains(URLQueryItem(name: "touchedByUserId", value: "me")))
        #expect(items.contains(URLQueryItem(name: "inboxArchivedByUserId", value: "me")))

        #expect(issues.count == 2)
        #expect(issues[0].isUnreadForMe == true)
        #expect(issues[0].lastExternalCommentAt == PaperclipDate.parse("2026-10-08T12:42:48.568Z"))
        #expect(issues[0].myLastTouchAt == PaperclipDate.parse("2026-10-08T10:00:00.000Z"))
        #expect(issues[0].createdByUserId == nil)
        #expect(issues[1].isUnreadForMe == false)
        #expect(issues[1].createdByUserId == "user-1")
        #expect(issues[1].completedAt == PaperclipDate.parse("2026-10-05T16:25:56.507Z"))
    }

    @Test func readStateIsOptionalOutsideTheInbox() async throws {
        // Lists without a user filter carry no per-user fields.
        try stub("issues")
        let issues = try await client.issues(companyId: "company-1")
        #expect(issues[0].isUnreadForMe == nil)
        #expect(issues[0].lastExternalCommentAt == nil)
        #expect(issues[0].completedAt == PaperclipDate.parse("2026-10-08T12:41:38.075Z"))
    }

    @Test func updateIssueSendsOnlySetFields() async throws {
        let list = try #require(JSONSerialization.jsonObject(with: try fixture("issues")) as? [Any])
        let body = try JSONSerialization.data(withJSONObject: list[0])
        StubURLProtocol.respond { _ in .init(body: body) }

        _ = try await client.updateIssue(id: "PAP-12", IssueUpdate(status: .done, comment: "Done"))
        let request = StubURLProtocol.lastRequest
        #expect(request?.httpMethod == "PATCH")
        #expect(request?.url?.path == "/api/issues/PAP-12")
        let sent = try jsonBody(request)
        #expect(sent.keys.sorted() == ["comment", "status"])
        #expect(sent["status"] as? String == "done")
    }

    @Test func addCommentAndReadArchive() async throws {
        try stub("comment", status: 201)
        let comment = try await client.addComment(issueId: "PAP-12", NewComment(body: "Looks good"))
        #expect(comment.body == "Looks good")
        let sent = try jsonBody(StubURLProtocol.lastRequest)
        #expect(sent["body"] as? String == "Looks good")

        StubURLProtocol.respond { _ in .init() }
        try await client.markRead(issueId: "PAP-12")
        #expect(StubURLProtocol.lastRequest?.httpMethod == "POST")
        #expect(StubURLProtocol.lastRequest?.url?.path == "/api/issues/PAP-12/read")
        try await client.unarchiveFromInbox(issueId: "PAP-12")
        #expect(StubURLProtocol.lastRequest?.httpMethod == "DELETE")
        #expect(StubURLProtocol.lastRequest?.url?.path == "/api/issues/PAP-12/inbox-archive")
    }

    @Test func sidebarBadges() async throws {
        try stub("sidebar-badges")
        let badges = try await client.sidebarBadges(companyId: "company-1")
        #expect(badges.inbox == 3)
    }

    @Test func attentionFeedDecodesCardsAndUnknownKinds() async throws {
        try stub("attention")
        let feed = try await client.attention(companyId: "company-1")
        let request = try #require(StubURLProtocol.lastRequest)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://paperclip.test/api/companies/company-1/attention")

        #expect(feed.items.map(\.id) == ["att-1", "att-2", "att-3", "att-4"])
        let interaction = feed.items[0]
        #expect(interaction.sourceKind == .issueThreadInteraction)
        #expect(interaction.subject.kind == "interaction")
        #expect(interaction.subject.title == "Approve the plan?")
        #expect(interaction.relatedIssue?.id == "00000000-0000-4000-8000-0000000000a1")
        #expect(interaction.relatedIssue?.identifier == "PAP-12")
        #expect(interaction.relatedIssue?.href == "/PAP/issues/PAP-12")
        #expect(interaction.detail?.kind == "confirmation")
        #expect(interaction.detail?.promptExcerpt == "Send the plan to the board?")
        #expect(interaction.whyNow == "Waiting for your answer")
        #expect(interaction.activityAt == PaperclipDate.parse("2026-10-14T09:30:00.000Z"))

        #expect(feed.items[1].sourceKind == .approval)
        #expect(feed.items[1].relatedIssue == nil)
        #expect(feed.items[1].detail?.summaryExcerpt == "Designer for the landing page")
        #expect(feed.items[2].sourceKind == .failedRun)
        // A newer server's kinds decode instead of failing the whole feed.
        #expect(feed.items[3].sourceKind == .unknown("brand_new_kind"))
        #expect(feed.items[3].detail?.kind == "brand_new_detail")
    }

    @Test func dashboardCounts() async throws {
        try stub("dashboard")
        let dashboard = try await client.dashboard(companyId: "company-1")
        #expect(StubURLProtocol.lastRequest?.url?.absoluteString == "https://paperclip.test/api/companies/company-1/dashboard")
        #expect(dashboard.agents.running == 3)
        #expect(dashboard.agents.active == 5)
        #expect(dashboard.tasks.blocked == 2)
        #expect(dashboard.tasks.inProgress == 4)
        #expect(dashboard.pendingApprovals == 1)
    }

    @Test func latestCommentsWithLimit() async throws {
        let comment = try fixture("comment")
        let body = Data("[".utf8) + comment + Data("]".utf8)
        StubURLProtocol.respond { _ in .init(body: body) }

        let comments = try await client.comments(issueId: "PAP-12", limit: 5)

        #expect(StubURLProtocol.lastRequest?.url?.absoluteString == "https://paperclip.test/api/issues/PAP-12/comments?limit=5")
        #expect(comments.map(\.body) == ["Looks good"])
        #expect(comments[0].authorUserId == "user-1")
    }

    @Test func errorsMapToAPIError() async throws {
        StubURLProtocol.respond { _ in .init(status: 401, body: Data(#"{"error":"Unauthorized"}"#.utf8)) }
        await #expect(throws: APIError.unauthorized) { try await client.me() }

        StubURLProtocol.respond { _ in .init(status: 404, body: Data(#"{"error":"Issue not found"}"#.utf8)) }
        await #expect(throws: APIError.notFound) { try await client.issue(id: "PAP-404") }

        StubURLProtocol.respond { _ in .init(status: 403, body: Data(#"{"error":"Board authentication required"}"#.utf8)) }
        await #expect(throws: APIError.server(status: 403, body: "Board authentication required")) {
            try await client.markRead(issueId: "PAP-12")
        }
    }

    @Test func errorDescriptionsNeverContainKeyOrToken() async throws {
        let client = self.client
        let token = "challenge-secret+fixture"
        let secrets = ["pcp_board_TEST", token, "challenge-secret%2Bfixture"]
        // Worst case: the server or the system echoes the secrets back.
        let echo = Data(#"{"error":"Bad key pcp_board_TEST for token challenge-secret+fixture"}"#.utf8)
        let failures: [StubURLProtocol.Stub] = [
            .init(status: 401, body: echo),
            .init(status: 404, body: echo),
            .init(status: 500, body: echo),
            .init(status: 200, body: Data(#"{"id":"pcp_board_TEST"}"#.utf8)),
            .init(error: URLError(.notConnectedToInternet, userInfo: [NSLocalizedDescriptionKey: "Offline: pcp_board_TEST"])),
        ]
        // Each call is checked for the secrets it sends: the key always, the token only on the poll.
        let calls: [(secrets: [String], run: () async throws -> Void)] = [
            (["pcp_board_TEST"], { _ = try await client.me() }),
            (secrets, { _ = try await client.cliAuthChallengeState(id: "c1", token: token) }),
        ]
        var seen: [String] = []
        for failure in failures {
            StubURLProtocol.respond { _ in failure }
            for call in calls {
                do {
                    try await call.run()
                    Testing.Issue.record("expected the call to fail")
                } catch {
                    let apiError = try #require(error as? APIError)
                    let text = String(describing: apiError) + String(reflecting: apiError) + apiError.localizedDescription
                    for secret in call.secrets {
                        #expect(!text.contains(secret), "\(apiError) contains a secret")
                    }
                    seen.append(String(describing: apiError).components(separatedBy: "(")[0])
                }
            }
        }
        // Every APIError case was produced at least once.
        #expect(Set(seen) == ["unauthorized", "notFound", "server", "decoding", "transport"])
    }

    @Test func pathSegmentsAreEncoded() async throws {
        StubURLProtocol.respond { _ in .init(body: Data("[]".utf8)) }
        _ = try await client.comments(issueId: "a/b")
        #expect(StubURLProtocol.lastRequest?.url?.absoluteString == "https://paperclip.test/api/issues/a%2Fb/comments")
    }

    // MARK: - Task detail

    private func queryItems(_ request: URLRequest?) -> [String: String] {
        guard let url = request?.url,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return [:] }
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
    }

    @Test func commentThreadIsOldestFirstAndPagesAfterACommentId() async throws {
        let comment = try fixture("comment")
        let body = Data("[".utf8) + comment + Data("]".utf8)
        StubURLProtocol.respond { _ in .init(body: body) }

        // Full thread: every comment, oldest first.
        let thread = try await client.commentThread(issueId: "PAP-12")
        var request = try #require(StubURLProtocol.lastRequest)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/api/issues/PAP-12/comments")
        #expect(queryItems(request) == ["order": "asc"])
        #expect(thread.map(\.body) == ["Looks good"])

        // Delta: only comments newer than the last one on screen.
        _ = try await client.commentThread(issueId: "PAP-12", after: "00000000-0000-4000-8000-000000000025")
        request = try #require(StubURLProtocol.lastRequest)
        #expect(queryItems(request) == ["order": "asc", "after": "00000000-0000-4000-8000-000000000025"])
    }

    @Test func liveRunsNameTheWorkingAgent() async throws {
        try stub("live-runs")
        let runs = try await client.liveRuns(issueId: "PAP-12")
        #expect(StubURLProtocol.lastRequest?.url?.absoluteString == "https://paperclip.test/api/issues/PAP-12/live-runs")
        #expect(runs.count == 1)
        #expect(runs[0].id == "00000000-0000-4000-8000-000000000030")
        #expect(runs[0].agentId == "00000000-0000-4000-8000-000000000007")
        #expect(runs[0].agentName == "Fixture Agent")
        #expect(runs[0].status == "running")
        #expect(runs[0].startedAt == PaperclipDate.parse("2026-10-13T22:28:24.651Z"))
    }

    @Test func agentsForTheAssigneePicker() async throws {
        try stub("agents")
        let agents = try await client.agents(companyId: "company-1")
        #expect(StubURLProtocol.lastRequest?.url?.absoluteString == "https://paperclip.test/api/companies/company-1/agents")
        #expect(agents.map(\.name) == ["Fixture Agent", "Fixture CEO"])
        #expect(agents[1].id == "00000000-0000-4000-8000-000000000008")
        #expect(agents[1].role == "ceo")
        #expect(agents[1].title == "CEO")
        #expect(agents[0].status == "running")
    }

    @Test func assigneeChangeSendsBothFieldsSoTheOtherOneClears() async throws {
        let list = try #require(JSONSerialization.jsonObject(with: try fixture("issues")) as? [Any])
        let body = try JSONSerialization.data(withJSONObject: list[0])
        StubURLProtocol.respond { _ in .init(body: body) }

        _ = try await client.updateIssue(id: "PAP-12", IssueUpdate(assignee: .agent("agent-1")))
        var sent = try jsonBody(StubURLProtocol.lastRequest)
        #expect(sent.keys.sorted() == ["assigneeAgentId", "assigneeUserId"])
        #expect(sent["assigneeAgentId"] as? String == "agent-1")
        #expect(sent["assigneeUserId"] is NSNull)

        _ = try await client.updateIssue(id: "PAP-12", IssueUpdate(assignee: .user("user-1")))
        sent = try jsonBody(StubURLProtocol.lastRequest)
        #expect(sent["assigneeAgentId"] is NSNull)
        #expect(sent["assigneeUserId"] as? String == "user-1")

        _ = try await client.updateIssue(id: "PAP-12", IssueUpdate(assignee: .nobody))
        sent = try jsonBody(StubURLProtocol.lastRequest)
        #expect(sent.keys.sorted() == ["assigneeAgentId", "assigneeUserId"])
        #expect(sent["assigneeAgentId"] is NSNull)
        #expect(sent["assigneeUserId"] is NSNull)

        // Without an assignee change neither field is sent.
        _ = try await client.updateIssue(id: "PAP-12", IssueUpdate(priority: .low))
        sent = try jsonBody(StubURLProtocol.lastRequest)
        #expect(sent.keys.sorted() == ["priority"])
    }

    @Test func attachmentContentIsRawBytes() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        StubURLProtocol.respond { _ in .init(body: png) }
        let data = try await client.attachmentContent(id: "00000000-0000-4000-8000-000000000040")
        #expect(data == png)
        let request = try #require(StubURLProtocol.lastRequest)
        #expect(request.url?.absoluteString == "https://paperclip.test/api/attachments/00000000-0000-4000-8000-000000000040/content")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer pcp_board_TEST")
    }

    @Test func attachmentsCarryTheCommentTheyBelongTo() async throws {
        let json = #"[{"id":"att-1","companyId":"company-1","issueId":"issue-1","issueCommentId":"comment-1","contentType":"image/png","byteSize":8,"originalFilename":"screenshot.png","contentPath":"/api/attachments/att-1/content","createdAt":"2026-10-13T22:33:15.169Z"}]"#
        StubURLProtocol.respond { _ in .init(body: Data(json.utf8)) }
        let attachments = try await client.attachments(issueId: "PAP-12")
        #expect(attachments.map(\.issueCommentId) == ["comment-1"])
        #expect(attachments[0].contentType == "image/png")
    }

    // MARK: - Photo comments

    @Test func uploadAttachmentIsMultipartWithTheFileField() async throws {
        try stub("attachment", status: 201)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let attachment = try await client.uploadAttachment(
            companyId: "company-1", issueId: "issue-1",
            AttachmentUpload(data: png, filename: "screenshot.png", contentType: "image/png")
        )

        #expect(attachment.id == "00000000-0000-4000-8000-000000000040")
        #expect(attachment.contentType == "image/png")
        #expect(attachment.contentPath == "/api/attachments/00000000-0000-4000-8000-000000000040/content")

        let request = try #require(StubURLProtocol.lastRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://paperclip.test/api/companies/company-1/issues/issue-1/attachments")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer pcp_board_TEST")
        let contentType = try #require(request.value(forHTTPHeaderField: "Content-Type"))
        #expect(contentType.hasPrefix("multipart/form-data; boundary="))
        let boundary = String(contentType.dropFirst("multipart/form-data; boundary=".count))
        #expect(!boundary.isEmpty)

        // One part, field "file", with the name, type and bytes; then the closing boundary.
        let body = try #require(request.httpBody)
        let head = Data((
            "--\(boundary)\r\n"
            + "Content-Disposition: form-data; name=\"file\"; filename=\"screenshot.png\"\r\n"
            + "Content-Type: image/png\r\n\r\n"
        ).utf8)
        #expect(body == head + png + Data("\r\n--\(boundary)--\r\n".utf8))
    }

    @Test func uploadAttachmentErrorsMapToAPIError() async throws {
        StubURLProtocol.respond { _ in
            .init(status: 422, body: Data(#"{"error":"Attachment is larger than the 10 MB limit"}"#.utf8))
        }
        await #expect(throws: APIError.server(status: 422, body: "Attachment is larger than the 10 MB limit")) {
            _ = try await client.uploadAttachment(
                companyId: "company-1", issueId: "issue-1",
                AttachmentUpload(data: Data([1]), filename: "big.jpg", contentType: "image/jpeg")
            )
        }
    }

    @Test func commentLinksUploadedAttachments() async throws {
        try stub("comment", status: 201)
        let requestID = UUID()
        _ = try await client.addComment(
            issueId: "issue-1",
            NewComment(body: "See screenshot", attachmentIds: ["att-1"], clientRequestId: requestID)
        )
        let sent = try jsonBody(StubURLProtocol.lastRequest)
        #expect(sent["attachmentIds"] as? [String] == ["att-1"])
        #expect(sent["clientRequestId"] as? String == requestID.uuidString.lowercased())
    }

    // MARK: - Requests (issue thread interactions)

    @Test func interactionsDecodeKindsPayloadsAndUnknownValues() async throws {
        try stub("interactions")
        let interactions = try await client.interactions(issueId: "PAP-12")
        let request = try #require(StubURLProtocol.lastRequest)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://paperclip.test/api/issues/PAP-12/interactions")

        #expect(interactions.count == 6)
        let confirmation = interactions[0]
        #expect(confirmation.id == "00000000-0000-4000-8000-0000000000b1")
        #expect(confirmation.issueId == "00000000-0000-4000-8000-0000000000a1")
        #expect(confirmation.kind == .requestConfirmation)
        #expect(confirmation.status == .pending)
        #expect(confirmation.createdByAgentId == "agent-1")
        #expect(confirmation.createdAt == PaperclipDate.parse("2026-10-14T09:05:00.000Z"))
        #expect(confirmation.resolvedAt == nil)
        #expect(confirmation.payload.prompt == "Send the plan to the board?")
        #expect(confirmation.payload.acceptLabel == "Send it")
        #expect(confirmation.payload.rejectLabel == "Not yet")
        #expect(confirmation.payload.rejectRequiresReason == false)
        #expect(confirmation.payload.detailsMarkdown == "The plan is in the **plan** document.")
        #expect(confirmation.payload.hasToolAction == false)
        #expect(confirmation.payload.hasSecretProposal == false)

        let questions = interactions[1]
        #expect(questions.kind == .askUserQuestions)
        #expect(questions.payload.title == "Two questions about the launch")
        #expect(questions.payload.submitLabel == "Send answers")
        let asked = try #require(questions.payload.questions)
        #expect(asked.map(\.id) == ["q-store", "q-langs", "q-name"])
        #expect(asked[0].prompt == "Which store first?")
        #expect(asked[0].selectionMode == .single)
        #expect(asked[0].required == true)
        #expect(asked[0].options.map(\.label) == ["App Store", "Google Play"])
        #expect(asked[0].options[1].description == "Needs a developer account")
        #expect(asked[1].selectionMode == .multi)
        #expect(asked[1].required == false)
        #expect(asked[2].options.first?.freeText == true)

        // Kinds, statuses and payloads this client does not know decode instead of failing.
        #expect(interactions[2].kind == .suggestTasks)
        #expect(interactions[3].kind == .unknown("hologram_call"))
        #expect(interactions[3].payload.prompt == nil)
        #expect(interactions[3].payload.questions == nil)
        #expect(interactions[4].status == .accepted)
        #expect(interactions[4].resolvedAt == PaperclipDate.parse("2026-10-14T08:40:00.000Z"))
        #expect(interactions[5].status == .unknown("teleported"))
    }

    @Test func aMalformedPayloadFieldDoesNotFailTheList() async throws {
        let json = #"[{"id":"i-1","companyId":"company-1","issueId":"issue-1","kind":"ask_user_questions","status":"pending","payload":{"version":1,"prompt":42,"questions":"not a list"},"result":null,"createdAt":"2026-10-14T09:00:00.000Z","updatedAt":"2026-10-14T09:00:00.000Z","resolvedAt":null}]"#
        StubURLProtocol.respond { _ in .init(body: Data(json.utf8)) }
        let interactions = try await client.interactions(issueId: "issue-1")
        #expect(interactions.count == 1)
        #expect(interactions[0].payload.prompt == nil)
        #expect(interactions[0].payload.questions == nil)
    }

    @Test func confirmationWithAToolActionOrSecretIsFlagged() async throws {
        let json = #"[{"id":"i-1","companyId":"company-1","issueId":"issue-1","kind":"request_confirmation","status":"pending","payload":{"version":1,"prompt":"Run the deploy tool?","toolAction":{"version":1,"toolName":"deploy","risk":"destructive"}},"createdAt":"2026-10-14T09:00:00.000Z","updatedAt":"2026-10-14T09:00:00.000Z","resolvedAt":null},{"id":"i-2","companyId":"company-1","issueId":"issue-1","kind":"request_confirmation","status":"pending","payload":{"version":1,"prompt":"Share the key?","secretProposal":{"version":1,"proposalId":"p-1"}},"createdAt":"2026-10-14T09:00:00.000Z","updatedAt":"2026-10-14T09:00:00.000Z","resolvedAt":null}]"#
        StubURLProtocol.respond { _ in .init(body: Data(json.utf8)) }
        let interactions = try await client.interactions(issueId: "issue-1")
        #expect(interactions[0].payload.hasToolAction)
        #expect(!interactions[0].payload.hasSecretProposal)
        #expect(interactions[1].payload.hasSecretProposal)
    }

    @Test func acceptPostsAnEmptyBody() async throws {
        try stub("interaction-accepted")
        let accepted = try await client.acceptInteraction(
            issueId: "00000000-0000-4000-8000-0000000000a1", interactionId: "00000000-0000-4000-8000-0000000000b1"
        )
        let request = try #require(StubURLProtocol.lastRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString
            == "https://paperclip.test/api/issues/00000000-0000-4000-8000-0000000000a1/interactions/00000000-0000-4000-8000-0000000000b1/accept")
        #expect(try jsonBody(request).isEmpty)
        #expect(accepted.status == .accepted)
        #expect(accepted.resolvedAt == PaperclipDate.parse("2026-10-14T09:30:00.000Z"))
    }

    @Test func rejectSendsTheReasonOnlyWhenThereIsOne() async throws {
        try stub("interaction-accepted")
        _ = try await client.rejectInteraction(issueId: "issue-1", interactionId: "i-1", reason: "Too early")
        var request = try #require(StubURLProtocol.lastRequest)
        #expect(request.url?.path == "/api/issues/issue-1/interactions/i-1/reject")
        #expect(try jsonBody(request) as? [String: String] == ["reason": "Too early"])

        _ = try await client.rejectInteraction(issueId: "issue-1", interactionId: "i-1", reason: nil)
        request = try #require(StubURLProtocol.lastRequest)
        #expect(try jsonBody(request).isEmpty)
    }

    @Test func respondSendsOneAnswerPerQuestion() async throws {
        try stub("interaction-accepted")
        _ = try await client.respondToInteraction(issueId: "issue-1", interactionId: "i-2", answers: [
            InteractionAnswer(questionId: "q-store", optionIds: ["o-ios"]),
            InteractionAnswer(questionId: "q-langs", optionIds: ["o-en", "o-pt"]),
            InteractionAnswer(questionId: "q-name", optionIds: ["o-name"], otherText: "Paperclip"),
        ])
        let request = try #require(StubURLProtocol.lastRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/issues/issue-1/interactions/i-2/respond")
        let body = try jsonBody(request)
        #expect(body.keys.sorted() == ["answers"])
        let answers = try #require(body["answers"] as? [[String: Any]])
        #expect(answers.map { $0["questionId"] as? String } == ["q-store", "q-langs", "q-name"])
        #expect(answers[1]["optionIds"] as? [String] == ["o-en", "o-pt"])
        // No otherText key unless there is text.
        #expect(answers[0].keys.sorted() == ["optionIds", "questionId"])
        #expect(answers[2]["otherText"] as? String == "Paperclip")
    }

    @Test func anAlreadyAnsweredRequestIsAConflict() async throws {
        StubURLProtocol.respond { _ in
            .init(status: 409, body: Data(#"{"error":"Interaction is no longer pending","code":"interaction_already_resolved"}"#.utf8))
        }
        await #expect(throws: APIError.server(status: 409, body: "Interaction is no longer pending")) {
            _ = try await client.acceptInteraction(issueId: "issue-1", interactionId: "i-1")
        }
    }

    // MARK: - Approvals

    @Test func pendingApprovalsDecodeTypesStatusesAndPayloads() async throws {
        try stub("approvals")
        let approvals = try await client.approvals(companyId: "company-1", status: .pending)
        let request = try #require(StubURLProtocol.lastRequest)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://paperclip.test/api/companies/company-1/approvals?status=pending")

        #expect(approvals.count == 3)
        let hire = approvals[0]
        #expect(hire.id == "00000000-0000-4000-8000-0000000000e1")
        #expect(hire.type == .hireAgent)
        #expect(hire.status == .pending)
        #expect(hire.requestedByAgentId == "agent-1")
        #expect(hire.requestedByUserId == nil)
        #expect(hire.createdAt == PaperclipDate.parse("2026-10-14T08:00:00.000Z"))
        #expect(hire.payload["name"] == .string("Designer"))
        #expect(hire.payload["budgetMonthlyCents"] == .number(5000))
        #expect(hire.payload["desiredSkills"] == .array([.string("figma"), .string("copy")]))
        #expect(hire.payload["metadata"] == .null)
        #expect(hire.payload["missing"] == nil)

        #expect(approvals[1].type == .requestBoardApproval)
        #expect(approvals[1].requestedByUserId == "user-2")
        // A newer server's types and statuses decode instead of failing the list.
        #expect(approvals[2].type == .unknown("summon_dragon"))
        #expect(approvals[2].status == .unknown("pondering"))
    }

    @Test func approvalsWithoutAStatusAskForAll() async throws {
        StubURLProtocol.respond { _ in .init(body: Data("[]".utf8)) }
        _ = try await client.approvals(companyId: "company-1")
        #expect(StubURLProtocol.lastRequest?.url?.absoluteString == "https://paperclip.test/api/companies/company-1/approvals")
    }

    @Test func approvalTitleFollowsTheServerRule() async throws {
        try stub("approvals")
        let approvals = try await client.approvals(companyId: "company-1", status: .pending)
        // payload.title ?? summary ?? recommendedAction ?? type with spaces.
        #expect(approvals[1].title == "Renew the domain")
        #expect(approvals[0].title == "Product Designer")
        #expect(approvals[0].payload["title"] == .string("Product Designer"))
        #expect(approvals[2].title == "summon dragon")
        let summaryOnly = #"{"id":"a-1","companyId":"company-1","type":"approve_ceo_strategy","status":"pending","payload":{"summary":"Focus on iOS"},"createdAt":"2026-10-14T08:00:00.000Z","updatedAt":"2026-10-14T08:00:00.000Z"}"#
        #expect(try PaperclipDate.decoder.decode(Approval.self, from: Data(summaryOnly.utf8)).title == "Focus on iOS")
        let empty = #"{"id":"a-2","companyId":"company-1","type":"approve_ceo_strategy","status":"pending","payload":{},"createdAt":"2026-10-14T08:00:00.000Z","updatedAt":"2026-10-14T08:00:00.000Z"}"#
        #expect(try PaperclipDate.decoder.decode(Approval.self, from: Data(empty.utf8)).title == "approve ceo strategy")
    }

    @Test func approvalSummaryListsTheSimpleFieldsWithReadableLabels() async throws {
        try stub("approval")
        let approval = try await client.approval(id: "00000000-0000-4000-8000-0000000000e1")
        #expect(StubURLProtocol.lastRequest?.url?.absoluteString
            == "https://paperclip.test/api/approvals/00000000-0000-4000-8000-0000000000e1")

        // Sorted by key; objects, nulls and empty values are left out; lists are joined.
        #expect(approval.summaryFields == [
            ApprovalField(label: "Adapter type", value: "claude_local"),
            ApprovalField(label: "Budget monthly cents", value: "5000"),
            ApprovalField(label: "Capabilities", value: "Wireframes and UI specs"),
            ApprovalField(label: "Desired skills", value: "figma, copy"),
            ApprovalField(label: "Icon", value: "pen"),
            ApprovalField(label: "Name", value: "Designer"),
            ApprovalField(label: "Reports to", value: "agent-1"),
            ApprovalField(label: "Role", value: "designer"),
            ApprovalField(label: "Title", value: "Product Designer"),
        ])
    }

    @Test func approvalSummaryShowsYesNoAndDecimals() throws {
        let json = #"{"id":"a-1","companyId":"company-1","type":"request_board_approval","status":"pending","requestedByAgentId":null,"requestedByUserId":null,"payload":{"urgent":true,"ratio":0.5,"blank":""},"decisionNote":null,"decidedAt":null,"createdAt":"2026-10-14T08:00:00.000Z","updatedAt":"2026-10-14T08:00:00.000Z"}"#
        let approval = try PaperclipDate.decoder.decode(Approval.self, from: Data(json.utf8))
        #expect(approval.summaryFields == [
            ApprovalField(label: "Ratio", value: "0.5"),
            ApprovalField(label: "Urgent", value: "Yes"),
        ])
    }

    @Test func approvalCommentsAreOldestFirstAndANewOnePosts() async throws {
        try stub("approval-comments")
        let comments = try await client.approvalComments(approvalId: "a-1")
        #expect(StubURLProtocol.lastRequest?.url?.absoluteString == "https://paperclip.test/api/approvals/a-1/comments")
        #expect(comments.map(\.body) == ["We need a designer for the landing page.", "What is the budget?"])
        #expect(comments[0].authorAgentId == "agent-1")
        #expect(comments[1].authorUserId == "user-1")

        try stub("approval-comment", status: 201)
        let added = try await client.addApprovalComment(approvalId: "a-1", body: "Fine by me.")
        let request = try #require(StubURLProtocol.lastRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/approvals/a-1/comments")
        #expect(try jsonBody(request) as? [String: String] == ["body": "Fine by me."])
        #expect(added.body == "Fine by me.")
    }

    @Test func decisionsPostToTheirRouteWithAnOptionalNote() async throws {
        try stub("approval-approved")
        let approved = try await client.decideApproval(id: "a-1", .approve, note: "Welcome aboard")
        var request = try #require(StubURLProtocol.lastRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/approvals/a-1/approve")
        #expect(try jsonBody(request) as? [String: String] == ["decisionNote": "Welcome aboard"])
        #expect(approved.status == .approved)
        #expect(approved.decisionNote == "Welcome aboard")
        #expect(approved.decidedAt == PaperclipDate.parse("2026-10-14T10:00:00.000Z"))

        _ = try await client.decideApproval(id: "a-1", .reject, note: nil)
        request = try #require(StubURLProtocol.lastRequest)
        #expect(request.url?.path == "/api/approvals/a-1/reject")
        #expect(try jsonBody(request).isEmpty)

        _ = try await client.decideApproval(id: "a-1", .requestRevision, note: "Smaller budget")
        request = try #require(StubURLProtocol.lastRequest)
        #expect(request.url?.path == "/api/approvals/a-1/request-revision")
    }

    @Test func aDecisionOnADecidedApprovalIsRejected() async throws {
        StubURLProtocol.respond { _ in
            .init(status: 422, body: Data(#"{"error":"Only pending approvals can request revision"}"#.utf8))
        }
        await #expect(throws: APIError.server(status: 422, body: "Only pending approvals can request revision")) {
            _ = try await client.decideApproval(id: "a-1", .requestRevision, note: nil)
        }
    }

    // MARK: New task

    @Test func createIssueSendsOnlyTheSheetFields() async throws {
        try stub("issue", status: 201)
        let issue = try await client.createIssue(companyId: "company-1", NewIssue(
            title: "Fix the login",
            description: "Steps:\n1. Open the app",
            assigneeAgentId: "00000000-0000-4000-8000-000000000008",
            projectId: "00000000-0000-4000-8000-000000000004",
            idempotencyKey: "key-1"
        ))
        let request = try #require(StubURLProtocol.lastRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://paperclip.test/api/companies/company-1/issues")
        let body = try jsonBody(request)
        #expect(body["title"] as? String == "Fix the login")
        #expect(body["description"] as? String == "Steps:\n1. Open the app")
        #expect(body["status"] as? String == "todo")
        #expect(body["assigneeAgentId"] as? String == "00000000-0000-4000-8000-000000000008")
        #expect(body["projectId"] as? String == "00000000-0000-4000-8000-000000000004")
        #expect(body["idempotencyKey"] as? String == "key-1")
        // No priority, labels, blockers or user assignee from the sheet.
        #expect(Set(body.keys) == ["title", "description", "status", "assigneeAgentId", "projectId", "idempotencyKey"])
        #expect(issue.id == "00000000-0000-4000-8000-0000000000a1")
        #expect(issue.identifier == "PAP-12")
    }

    @Test func createIssueLeavesOutEmptyOptionalFields() async throws {
        try stub("issue", status: 201)
        _ = try await client.createIssue(companyId: "company-1", NewIssue(
            title: "Only a title", description: nil, assigneeAgentId: "agent-1", projectId: nil, idempotencyKey: "key-2"
        ))
        let body = try jsonBody(StubURLProtocol.lastRequest)
        #expect(Set(body.keys) == ["title", "status", "assigneeAgentId", "idempotencyKey"])
    }

    @Test func createIssueReplayIsTheSameIssue() async throws {
        // The server answers 200 (not 201) when the idempotency key replays an earlier create.
        try stub("issue", status: 200)
        let issue = try await client.createIssue(companyId: "company-1", NewIssue(
            title: "Again", description: nil, assigneeAgentId: nil, projectId: nil, idempotencyKey: "key-1"
        ))
        #expect(issue.identifier == "PAP-12")
    }

    @Test func projectsForTheProjectChip() async throws {
        try stub("projects")
        let projects = try await client.projects(companyId: "company-1")
        #expect(StubURLProtocol.lastRequest?.url?.absoluteString == "https://paperclip.test/api/companies/company-1/projects")
        #expect(projects.map(\.name) == ["Mobile app", "Website"])
        #expect(projects.map(\.id) == ["00000000-0000-4000-8000-000000000004", "00000000-0000-4000-8000-000000000040"])
        #expect(projects.first?.status == "in_progress")
        // An unknown status is kept as text, never a decoding error.
        #expect(projects.last?.status == "some_new_status")
        #expect(projects.allSatisfy { $0.archivedAt == nil })
    }
}
