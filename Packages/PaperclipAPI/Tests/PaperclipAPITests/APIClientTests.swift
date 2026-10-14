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
}
