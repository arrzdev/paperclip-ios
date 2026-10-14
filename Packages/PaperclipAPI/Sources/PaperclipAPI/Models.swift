import Foundation

// Models for the M1 endpoints of Paperclip 2026.1005.0.
// The server's OpenAPI spec types most responses as free-form objects, so these
// are hand-written from the route code. Unknown keys are ignored and every
// field the server may omit or null is optional.

// MARK: - Health

public struct Health: Decodable, Equatable, Sendable {
    public let status: String
    public let commit: String?
    public let deploymentMode: String?
}

// MARK: - CLI auth (device flow)

public enum CliAuthAccess: String, Codable, Sendable {
    case board
    case instanceAdminRequired = "instance_admin_required"
}

public struct CreateCliAuthChallenge: Encodable, Equatable, Sendable {
    public var command: String
    public var clientName: String?
    public var requestedAccess: CliAuthAccess
    public var requestedCompanyId: String?

    public init(
        command: String = "paperclip-ios sign-in",
        clientName: String? = "Paperclip iOS",
        requestedAccess: CliAuthAccess = .board,
        requestedCompanyId: String? = nil
    ) {
        self.command = command
        self.clientName = clientName
        self.requestedAccess = requestedAccess
        self.requestedCompanyId = requestedCompanyId
    }
}

/// Response of `POST /api/cli-auth/challenges`.
///
/// `boardApiToken` is the key the app keeps; it becomes valid once the user
/// approves the challenge in the browser at `approvalUrl`.
public struct CliAuthChallenge: Decodable, Equatable, Sendable {
    public let id: String
    public let token: String
    public let boardApiToken: String
    public let approvalPath: String
    public let approvalUrl: URL?
    public let pollPath: String
    public let expiresAt: Date
    public let suggestedPollIntervalMs: Int?
}

public enum CliAuthChallengeStatus: Codable, Hashable, Sendable {
    case pending, approved, cancelled, expired
    case unknown(String)

    private static let known: [(CliAuthChallengeStatus, String)] = [
        (.pending, "pending"),
        (.approved, "approved"),
        (.cancelled, "cancelled"),
        (.expired, "expired"),
    ]

    public init(rawValue: String) {
        self = Self.known.first { $0.1 == rawValue }?.0 ?? .unknown(rawValue)
    }

    public var rawValue: String {
        if case .unknown(let value) = self { return value }
        return Self.known.first { $0.0 == self }!.1
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Response of `GET /api/cli-auth/challenges/:id?token=…`.
public struct CliAuthChallengeState: Decodable, Equatable, Sendable {
    public let id: String
    public let status: CliAuthChallengeStatus
    public let approvedAt: Date?
    public let expiresAt: Date
}

public struct BoardUser: Decodable, Equatable, Sendable {
    public let id: String
    public let name: String?
    public let email: String?
}

/// Response of `GET /api/cli-auth/me`.
public struct CliAuthMe: Decodable, Equatable, Sendable {
    public let user: BoardUser?
    public let userId: String?
    public let isInstanceAdmin: Bool?
    public let companyIds: [String]
    public let source: String?
    public let keyId: String?
}

// MARK: - Companies

public struct Company: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let issuePrefix: String?
    public let status: String?
}

public struct SidebarBadges: Decodable, Equatable, Sendable {
    public let inbox: Int
    public let approvals: Int
    public let failedRuns: Int
    public let joinRequests: Int
}

// MARK: - Issues

// String enums decode leniently: values this client does not know map to
// `.unknown`, so a newer server adding one never breaks decoding.

public enum IssueStatus: Codable, Hashable, Sendable {
    case backlog, todo, inProgress, inReview, done, blocked, cancelled
    case unknown(String)

    private static let known: [(IssueStatus, String)] = [
        (.backlog, "backlog"),
        (.todo, "todo"),
        (.inProgress, "in_progress"),
        (.inReview, "in_review"),
        (.done, "done"),
        (.blocked, "blocked"),
        (.cancelled, "cancelled"),
    ]

    public init(rawValue: String) {
        self = Self.known.first { $0.1 == rawValue }?.0 ?? .unknown(rawValue)
    }

    public var rawValue: String {
        if case .unknown(let value) = self { return value }
        return Self.known.first { $0.0 == self }!.1
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum IssuePriority: Codable, Hashable, Sendable {
    case critical, high, medium, low
    case unknown(String)

    private static let known: [(IssuePriority, String)] = [
        (.critical, "critical"),
        (.high, "high"),
        (.medium, "medium"),
        (.low, "low"),
    ]

    public init(rawValue: String) {
        self = Self.known.first { $0.1 == rawValue }?.0 ?? .unknown(rawValue)
    }

    public var rawValue: String {
        if case .unknown(let value) = self { return value }
        return Self.known.first { $0.0 == self }!.1
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct Issue: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let companyId: String
    public let identifier: String?
    public let title: String
    public let description: String?
    public let status: IssueStatus
    public let priority: IssuePriority
    public let assigneeAgentId: String?
    public let assigneeUserId: String?
    public let createdByUserId: String?
    public let projectId: String?
    public let parentId: String?
    public let createdAt: Date
    public let updatedAt: Date
    public let completedAt: Date?
    public let lastActivityAt: Date?
    // Per-user read state: sent only when the list is filtered by a user
    // (`touchedByUserId`, `unreadForUserId`, …), so nil elsewhere.
    public let isUnreadForMe: Bool?
    public let lastExternalCommentAt: Date?
    public let myLastTouchAt: Date?
}

/// Who a task is assigned to. A change sends both assignee fields, one of
/// them null, so the server clears the other one.
public enum IssueAssignee: Hashable, Sendable {
    case agent(String)
    case user(String)
    case nobody

    public init(agentId: String?, userId: String?) {
        if let agentId {
            self = .agent(agentId)
        } else if let userId {
            self = .user(userId)
        } else {
            self = .nobody
        }
    }
}

/// Fields the app can change with `PATCH /api/issues/:id`. Nil fields are not sent.
public struct IssueUpdate: Encodable, Equatable, Sendable {
    public var title: String?
    public var status: IssueStatus?
    public var priority: IssuePriority?
    public var assignee: IssueAssignee?
    public var comment: String?

    public init(
        title: String? = nil,
        status: IssueStatus? = nil,
        priority: IssuePriority? = nil,
        assignee: IssueAssignee? = nil,
        comment: String? = nil
    ) {
        self.title = title
        self.status = status
        self.priority = priority
        self.assignee = assignee
        self.comment = comment
    }

    private enum CodingKeys: String, CodingKey {
        case title, status, priority, assigneeAgentId, assigneeUserId, comment
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encodeIfPresent(priority, forKey: .priority)
        try container.encodeIfPresent(comment, forKey: .comment)
        switch assignee {
        case .none:
            break
        case .agent(let id):
            try container.encode(id, forKey: .assigneeAgentId)
            try container.encodeNil(forKey: .assigneeUserId)
        case .user(let id):
            try container.encodeNil(forKey: .assigneeAgentId)
            try container.encode(id, forKey: .assigneeUserId)
        case .nobody:
            try container.encodeNil(forKey: .assigneeAgentId)
            try container.encodeNil(forKey: .assigneeUserId)
        }
    }
}

/// Query for `GET /api/companies/:id/issues`. `"me"` is accepted for the user filters.
public struct IssueListQuery: Equatable, Sendable {
    public var status: [IssueStatus] = []
    public var assigneeUserId: String?
    public var touchedByUserId: String?
    public var unreadForUserId: String?
    public var inboxArchivedByUserId: String?
    public var projectId: String?
    public var search: String?
    public var updatedSince: Date?
    public var limit: Int?

    public init() {}

    /// Issues the signed-in user touched and has not archived (the web inbox "Mine").
    public static var inbox: IssueListQuery {
        var query = IssueListQuery()
        query.touchedByUserId = "me"
        query.inboxArchivedByUserId = "me"
        return query
    }

    var queryItems: [URLQueryItem] {
        var items: [URLQueryItem] = []
        if !status.isEmpty {
            items.append(URLQueryItem(name: "status", value: status.map(\.rawValue).joined(separator: ",")))
        }
        let pairs: [(String, String?)] = [
            ("assigneeUserId", assigneeUserId),
            ("touchedByUserId", touchedByUserId),
            ("unreadForUserId", unreadForUserId),
            ("inboxArchivedByUserId", inboxArchivedByUserId),
            ("projectId", projectId),
            ("q", search),
            ("updatedSince", updatedSince.map(PaperclipDate.format)),
            ("limit", limit.map(String.init)),
        ]
        for (name, value) in pairs {
            if let value { items.append(URLQueryItem(name: name, value: value)) }
        }
        return items
    }
}

public struct IssueComment: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let issueId: String
    public let body: String
    public let authorType: String?
    public let authorAgentId: String?
    public let authorUserId: String?
    public let createdAt: Date
}

public struct NewComment: Encodable, Equatable, Sendable {
    public var body: String
    public var attachmentIds: [String]?
    public var clientRequestId: String

    public init(body: String, attachmentIds: [String]? = nil, clientRequestId: UUID = UUID()) {
        self.body = body
        self.attachmentIds = attachmentIds
        self.clientRequestId = clientRequestId.uuidString.lowercased()
    }
}

public struct IssueDocument: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let key: String
    public let title: String?
    public let format: String?
    public let body: String?
    public let latestRevisionNumber: Int?
    public let updatedAt: Date
}

public struct Attachment: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    /// The comment the file was sent with; nil for a file on the task itself.
    public let issueCommentId: String?
    public let originalFilename: String?
    public let contentType: String?
    public let byteSize: Int?
    public let contentPath: String?
    public let createdAt: Date?
}

/// A queued or running agent run on a task (`GET /api/issues/:id/live-runs`).
public struct LiveRun: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let status: String
    public let agentId: String
    public let agentName: String?
    public let startedAt: Date?
    public let createdAt: Date?
}

// MARK: - Agents

/// An agent of a company (`GET /api/companies/:id/agents`), for the assignee picker.
public struct Agent: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let role: String?
    public let title: String?
    public let status: String?
}

// MARK: - Attention (what needs the board)

public enum AttentionSourceKind: Codable, Hashable, Sendable {
    case approval, decision, issueThreadInteraction, joinRequest, recoveryAction
    case productivityReview, blockerAttention, review, failedRun, budgetAlert, agentErrorAlert
    case unknown(String)

    private static let known: [(AttentionSourceKind, String)] = [
        (.approval, "approval"),
        (.decision, "decision"),
        (.issueThreadInteraction, "issue_thread_interaction"),
        (.joinRequest, "join_request"),
        (.recoveryAction, "recovery_action"),
        (.productivityReview, "productivity_review"),
        (.blockerAttention, "blocker_attention"),
        (.review, "review"),
        (.failedRun, "failed_run"),
        (.budgetAlert, "budget_alert"),
        (.agentErrorAlert, "agent_error_alert"),
    ]

    public init(rawValue: String) {
        self = Self.known.first { $0.1 == rawValue }?.0 ?? .unknown(rawValue)
    }

    public var rawValue: String {
        if case .unknown(let value) = self { return value }
        return Self.known.first { $0.0 == self }!.1
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// What an attention item is about (an interaction, an approval, a run…) or
/// the issue it belongs to. `href` is a path in the web UI.
public struct AttentionSubject: Decodable, Equatable, Sendable {
    public let kind: String
    public let id: String
    public let title: String?
    public let identifier: String?
    public let status: String?
    public let href: String?
}

/// Kind-specific extras; only the excerpts the app shows are decoded.
public struct AttentionDetail: Decodable, Equatable, Sendable {
    public let kind: String
    public let promptExcerpt: String?
    public let summaryExcerpt: String?
    public let questionCount: Int?
    public let firstQuestionText: String?
}

public struct AttentionItem: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let sourceKind: AttentionSourceKind
    public let subject: AttentionSubject
    public let relatedIssue: AttentionSubject?
    public let whyNow: String?
    public let activityAt: Date?
    public let detail: AttentionDetail?
}

/// Response of `GET /api/companies/:id/attention`.
public struct AttentionFeed: Decodable, Equatable, Sendable {
    public let items: [AttentionItem]
}

// MARK: - Dashboard

/// Response of `GET /api/companies/:id/dashboard` (the counts the app shows).
public struct Dashboard: Decodable, Equatable, Sendable {
    public struct Agents: Decodable, Equatable, Sendable {
        public let active: Int
        public let running: Int
        public let paused: Int
        public let error: Int
    }

    public struct Tasks: Decodable, Equatable, Sendable {
        public let open: Int
        public let inProgress: Int
        public let blocked: Int
        public let done: Int
    }

    public let agents: Agents
    public let tasks: Tasks
    public let pendingApprovals: Int?
}
