import Foundation
import PaperclipAPI

/// The one way to open Approval detail: Today pushes this value and each tab's
/// `NavigationStack` has a `.navigationDestination(for: ApprovalRoute.self)`.
struct ApprovalRoute: Hashable {
    let approvalID: String
}

extension NeedsYouCard {
    /// Nil for cards that are not an approval.
    var approvalRoute: ApprovalRoute? { approvalID.map(ApprovalRoute.init(approvalID:)) }
}

extension ApprovalDecision {
    var title: String {
        switch self {
        case .approve: "Approve"
        case .reject: "Reject"
        case .requestRevision: "Ask for changes"
        }
    }
}

/// What Approval detail shows once the approval and its comments are loaded.
struct ApprovalDetail: Equatable {
    var approval: Approval
    /// Oldest first.
    var comments: [ApprovalComment]
}

/// Approval detail: the approval and its comments (required) and the agents
/// (an extra for names: a failure never hides the approval). Approve, Reject
/// and Ask for changes each send an optional note; the note is never logged.
@MainActor
@Observable
final class ApprovalDetailModel {
    let store: AccountStore
    let accountID: UUID
    let approvalID: String

    private(set) var state: LoadState<ApprovalDetail> = .loading
    /// Set when a decision or a comment failed.
    private(set) var actionError: String?
    private var agents: [Agent] = []

    init(store: AccountStore, accountID: UUID, approvalID: String) {
        self.store = store
        self.accountID = accountID
        self.approvalID = approvalID
    }

    var detail: ApprovalDetail? {
        if case .loaded(let detail) = state { return detail }
        return nil
    }

    /// Who asked: the agent's name, "You", "User" or "Agent"; nil before load.
    var requesterName: String? {
        guard let approval = detail?.approval else { return nil }
        return name(agentID: approval.requestedByAgentId, userID: approval.requestedByUserId)
    }

    /// The server's rules: Approve and Reject on `pending` or
    /// `revision_requested`, Ask for changes on `pending` only.
    var availableDecisions: [ApprovalDecision] {
        switch detail?.approval.status {
        case .pending?: [.approve, .reject, .requestRevision]
        case .revisionRequested?: [.approve, .reject]
        default: []
        }
    }

    func authorName(for comment: ApprovalComment) -> String {
        name(agentID: comment.authorAgentId, userID: comment.authorUserId) ?? "User"
    }

    /// Full fetch (screen appears, pull to refresh).
    func refresh() async {
        let approval: Approval
        let comments: [ApprovalComment]
        do {
            approval = try await store.call(accountID) { try await $0.approval(id: approvalID) }
            comments = try await store.call(accountID) { try await $0.approvalComments(approvalId: approvalID) }
        } catch {
            state = isUnauthorized(error) ? .needsSignIn : .error(userMessage(for: error))
            store.log("Approval detail failed for account \(accountID): \(userMessage(for: error))")
            return
        }
        let companyId = approval.companyId
        do {
            agents = try await store.call(accountID) { try await $0.agents(companyId: companyId) }
        } catch {
            store.log("Approval agents failed for account \(accountID): \(userMessage(for: error))")
        }
        state = .loaded(ApprovalDetail(approval: approval, comments: comments))
    }

    /// Sends `decision` with the trimmed note (none when blank) and shows the
    /// server's answer. False on error: the approval stays and `actionError`
    /// says why; a 401 ends in `needsSignIn`.
    func decide(_ decision: ApprovalDecision, note: String) async -> Bool {
        guard detail != nil else { return false }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentNote: String? = trimmed.isEmpty ? nil : trimmed
        actionError = nil
        do {
            let approval = try await store.call(accountID) {
                try await $0.decideApproval(id: self.approvalID, decision, note: sentNote)
            }
            update { $0.approval = approval }
            return true
        } catch {
            fail(error, context: "Approval decision failed")
            return false
        }
    }

    /// Posts the trimmed comment and appends it. False (and no request) when
    /// blank, false on error with `actionError`.
    func addComment(_ text: String) async -> Bool {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, detail != nil else { return false }
        actionError = nil
        do {
            let comment = try await store.call(accountID) {
                try await $0.addApprovalComment(approvalId: self.approvalID, body: body)
            }
            update { detail in
                if !detail.comments.contains(where: { $0.id == comment.id }) {
                    detail.comments.append(comment)
                }
            }
            return true
        } catch {
            fail(error, context: "Approval comment failed")
            return false
        }
    }

    func dismissActionError() {
        actionError = nil
    }

    // MARK: - Private

    private var myUserID: String? {
        store.accounts.first { $0.id == accountID }?.userId
    }

    private func name(agentID: String?, userID: String?) -> String? {
        if let agentID {
            return agents.first { $0.id == agentID }?.name ?? "Agent"
        }
        if let userID {
            return userID == myUserID ? "You" : "User"
        }
        return nil
    }

    private func update(_ change: (inout ApprovalDetail) -> Void) {
        guard var detail else { return }
        change(&detail)
        state = .loaded(detail)
    }

    /// Logs only the error text, never a note or a comment.
    private func fail(_ error: Error, context: String) {
        if isUnauthorized(error) {
            state = .needsSignIn
        } else {
            actionError = userMessage(for: error)
        }
        store.log("\(context) for account \(accountID): \(userMessage(for: error))")
    }

    private func isUnauthorized(_ error: Error) -> Bool {
        if case APIError.unauthorized = error { return true }
        return false
    }
}
