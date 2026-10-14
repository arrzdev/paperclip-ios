import Foundation

// M1 endpoints (sign-in, inbox, Today, task detail with comments, read/archive).
// Paths are relative to `<server>/api`.

public extension APIClient {
    // MARK: Server

    /// `GET /api/health`. Public; used to check a typed server URL before sign-in.
    func health() async throws -> Health {
        try await send(.get, "/health")
    }

    // MARK: Sign-in (device flow)

    func createCliAuthChallenge(_ body: CreateCliAuthChallenge = CreateCliAuthChallenge()) async throws -> CliAuthChallenge {
        try await send(.post, "/cli-auth/challenges", body: body)
    }

    func cliAuthChallengeState(id: String, token: String) async throws -> CliAuthChallengeState {
        try await send(.get, "/cli-auth/challenges/\(segment(id))", query: [URLQueryItem(name: "token", value: token)])
    }

    /// The browser page where the user approves the challenge on this server.
    func approvalURL(for challenge: CliAuthChallenge) -> URL {
        challenge.approvalUrl ?? URL(string: server.baseURL.absoluteString + challenge.approvalPath)!
    }

    func me() async throws -> CliAuthMe {
        try await send(.get, "/cli-auth/me")
    }

    /// Revokes the key this client uses (sign-out).
    func revokeCurrentKey() async throws {
        _ = try await request(.post, "/cli-auth/revoke-current")
    }

    // MARK: Companies

    func companies() async throws -> [Company] {
        try await send(.get, "/companies")
    }

    func company(id: String) async throws -> Company {
        try await send(.get, "/companies/\(segment(id))")
    }

    func sidebarBadges(companyId: String) async throws -> SidebarBadges {
        try await send(.get, "/companies/\(segment(companyId))/sidebar-badges")
    }

    /// What needs the board now (requests, approvals, reviews, failed runs…).
    func attention(companyId: String) async throws -> AttentionFeed {
        try await send(.get, "/companies/\(segment(companyId))/attention")
    }

    func dashboard(companyId: String) async throws -> Dashboard {
        try await send(.get, "/companies/\(segment(companyId))/dashboard")
    }

    // MARK: Issues

    func issues(companyId: String, query: IssueListQuery = IssueListQuery()) async throws -> [Issue] {
        try await send(.get, "/companies/\(segment(companyId))/issues", query: query.queryItems)
    }

    /// `id` is the issue UUID or its identifier (`TUD-12`).
    func issue(id: String) async throws -> Issue {
        try await send(.get, "/issues/\(segment(id))")
    }

    func updateIssue(id: String, _ update: IssueUpdate) async throws -> Issue {
        try await send(.patch, "/issues/\(segment(id))", body: update)
    }

    /// Newest first. `limit` caps the count (Today's preview reads the latest few).
    func comments(issueId: String, limit: Int? = nil) async throws -> [IssueComment] {
        let query = limit.map { [URLQueryItem(name: "limit", value: String($0))] } ?? []
        return try await send(.get, "/issues/\(segment(issueId))/comments", query: query)
    }

    func addComment(issueId: String, _ comment: NewComment) async throws -> IssueComment {
        try await send(.post, "/issues/\(segment(issueId))/comments", body: comment)
    }

    func documents(issueId: String) async throws -> [IssueDocument] {
        try await send(.get, "/issues/\(segment(issueId))/documents")
    }

    func document(issueId: String, key: String) async throws -> IssueDocument {
        try await send(.get, "/issues/\(segment(issueId))/documents/\(segment(key))")
    }

    func attachments(issueId: String) async throws -> [Attachment] {
        try await send(.get, "/issues/\(segment(issueId))/attachments")
    }

    // MARK: Read / archive

    func markRead(issueId: String) async throws {
        _ = try await request(.post, "/issues/\(segment(issueId))/read")
    }

    func markUnread(issueId: String) async throws {
        _ = try await request(.delete, "/issues/\(segment(issueId))/read")
    }

    func archiveFromInbox(issueId: String) async throws {
        _ = try await request(.post, "/issues/\(segment(issueId))/inbox-archive")
    }

    func unarchiveFromInbox(issueId: String) async throws {
        _ = try await request(.delete, "/issues/\(segment(issueId))/inbox-archive")
    }
}
