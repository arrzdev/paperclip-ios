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

    /// The whole thread oldest first, or only the comments after `commentId`.
    func commentThread(issueId: String, after commentId: String? = nil) async throws -> [IssueComment] {
        var query = [URLQueryItem(name: "order", value: "asc")]
        if let commentId { query.append(URLQueryItem(name: "after", value: commentId)) }
        return try await send(.get, "/issues/\(segment(issueId))/comments", query: query)
    }

    func liveRuns(issueId: String) async throws -> [LiveRun] {
        try await send(.get, "/issues/\(segment(issueId))/live-runs")
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

    /// The file's bytes (`GET /api/attachments/:id/content`).
    func attachmentContent(id: String) async throws -> Data {
        try await request(.get, "/attachments/\(segment(id))/content", accept: "*/*")
    }

    /// Multipart upload, field `file`. `progress` gets the sent fraction (0…1).
    func uploadAttachment(
        companyId: String,
        issueId: String,
        _ file: AttachmentUpload,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Attachment {
        let boundary = "paperclip-" + UUID().uuidString
        var data = Data()
        data.append(Data((
            "--\(boundary)\r\n"
            + "Content-Disposition: form-data; name=\"file\"; filename=\"\(quoted(file.filename))\"\r\n"
            + "Content-Type: \(file.contentType)\r\n\r\n"
        ).utf8))
        data.append(file.data)
        data.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let body = try await request(
            .post, "/companies/\(segment(companyId))/issues/\(segment(issueId))/attachments",
            rawBody: RawBody(data: data, contentType: "multipart/form-data; boundary=\(boundary)"),
            delegate: progress.map { UploadProgress($0) as any URLSessionTaskDelegate }
        )
        do {
            return try PaperclipDate.decoder.decode(Attachment.self, from: body)
        } catch {
            throw APIError.decoding("POST attachments: \(error)")
        }
    }

    // MARK: Agents

    func agents(companyId: String) async throws -> [Agent] {
        try await send(.get, "/companies/\(segment(companyId))/agents")
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

public extension APIClient {
    // MARK: Requests (issue thread interactions)

    /// Every request on the task, resolved ones included, oldest first.
    func interactions(issueId: String) async throws -> [IssueInteraction] {
        try await send(.get, "/issues/\(segment(issueId))/interactions")
    }

    func acceptInteraction(issueId: String, interactionId: String) async throws -> IssueInteraction {
        try await send(.post, interactionPath(issueId, interactionId, "accept"), body: EmptyBody())
    }

    /// `reason` is not sent when nil.
    func rejectInteraction(issueId: String, interactionId: String, reason: String?) async throws -> IssueInteraction {
        try await send(.post, interactionPath(issueId, interactionId, "reject"), body: RejectBody(reason: reason))
    }

    func respondToInteraction(issueId: String, interactionId: String, answers: [InteractionAnswer]) async throws -> IssueInteraction {
        try await send(.post, interactionPath(issueId, interactionId, "respond"), body: RespondBody(answers: answers))
    }

    // MARK: Approvals

    /// The server does not sort this list.
    func approvals(companyId: String, status: ApprovalStatus? = nil) async throws -> [Approval] {
        let query = status.map { [URLQueryItem(name: "status", value: $0.rawValue)] } ?? []
        return try await send(.get, "/companies/\(segment(companyId))/approvals", query: query)
    }

    func approval(id: String) async throws -> Approval {
        try await send(.get, "/approvals/\(segment(id))")
    }

    /// Oldest first.
    func approvalComments(approvalId: String) async throws -> [ApprovalComment] {
        try await send(.get, "/approvals/\(segment(approvalId))/comments")
    }

    func addApprovalComment(approvalId: String, body: String) async throws -> ApprovalComment {
        try await send(.post, "/approvals/\(segment(approvalId))/comments", body: CommentBody(body: body))
    }

    /// `note` goes as `decisionNote`; not sent when nil. The server records who decided.
    func decideApproval(id: String, _ decision: ApprovalDecision, note: String?) async throws -> Approval {
        try await send(.post, "/approvals/\(segment(id))/\(decision.pathComponent)", body: DecisionBody(decisionNote: note))
    }

    private func interactionPath(_ issueId: String, _ interactionId: String, _ action: String) -> String {
        "/issues/\(segment(issueId))/interactions/\(segment(interactionId))/\(action)"
    }
}

private struct EmptyBody: Encodable {}

private struct RejectBody: Encodable {
    let reason: String?
}

private struct RespondBody: Encodable {
    let answers: [InteractionAnswer]
}

private struct CommentBody: Encodable {
    let body: String
}

private struct DecisionBody: Encodable {
    let decisionNote: String?
}

/// A file name safe inside a quoted multipart header.
private func quoted(_ name: String) -> String {
    name.replacingOccurrences(of: "\\", with: "_")
        .replacingOccurrences(of: "\"", with: "_")
        .replacingOccurrences(of: "\r", with: "_")
        .replacingOccurrences(of: "\n", with: "_")
}

/// Reports upload progress of one request.
private final class UploadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let report: @Sendable (Double) -> Void

    init(_ report: @escaping @Sendable (Double) -> Void) {
        self.report = report
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64, totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        report(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}
