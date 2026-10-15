import Foundation
import PaperclipAPI

/// What Task detail shows once the task and its thread are loaded.
struct TaskDetail: Equatable {
    var issue: Issue
    /// Oldest first, like a chat.
    var comments: [IssueComment]
    var documents: [IssueDocument]
    var attachments: [Attachment]
}

/// Task detail: the task and its thread (required), documents, attachments,
/// live runs, agents and mark-read (extras: a failure never hides the task).
/// Pickers change the task at once and roll back on error. `poll()` refetches
/// the task and live runs and asks only for comments after the last one.
@MainActor
@Observable
final class TaskDetailModel {
    let store: AccountStore
    let accountID: UUID
    let issueID: String
    private let poller: Poller

    private(set) var state: LoadState<TaskDetail> = .loading
    /// Assignee picker options.
    private(set) var agents: [Agent] = []
    private(set) var liveRuns: [LiveRun] = []
    /// Set when a change failed and was rolled back.
    private(set) var actionError: String?

    /// Picker values shown while their change is on the way.
    private var pendingStatus: IssueStatus?
    private var pendingPriority: IssuePriority?
    private var pendingAssignee: IssueAssignee?

    @ObservationIgnored private var contentCache: [String: Data] = [:]

    init(store: AccountStore, accountID: UUID, issueID: String, poller: Poller = .live) {
        self.store = store
        self.accountID = accountID
        self.issueID = issueID
        self.poller = poller
    }

    /// Done ✓ and Re-open show only while the task waits for review or is done.
    static func showsReviewBar(for status: IssueStatus) -> Bool {
        status == .inReview || status == .done
    }

    var detail: TaskDetail? {
        if case .loaded(let detail) = state { return detail }
        return nil
    }

    var showsReviewBar: Bool {
        detail.map { Self.showsReviewBar(for: $0.issue.status) } ?? false
    }

    /// "Luis is working…" while an agent runs on the task.
    var liveRunText: String? {
        guard let run = liveRuns.first else { return nil }
        let name = run.agentName ?? agents.first { $0.id == run.agentId }?.name ?? "An agent"
        return "\(name) is working…"
    }

    var status: IssueStatus? {
        pendingStatus ?? detail?.issue.status
    }

    var priority: IssuePriority? {
        pendingPriority ?? detail?.issue.priority
    }

    var assignee: IssueAssignee? {
        if let pendingAssignee { return pendingAssignee }
        guard let issue = detail?.issue else { return nil }
        return IssueAssignee(agentId: issue.assigneeAgentId, userId: issue.assigneeUserId)
    }

    /// The signed-in user, for "Me" in the assignee picker and "You" in the thread.
    var myUserID: String? {
        account?.userId
    }

    /// Files sent with `comment` (photos show as thumbnails under it).
    func attachments(for comment: IssueComment) -> [Attachment] {
        detail?.attachments.filter { $0.issueCommentId == comment.id } ?? []
    }

    func authorName(for comment: IssueComment) -> String {
        if let agentID = comment.authorAgentId {
            return agents.first { $0.id == agentID }?.name ?? "Agent"
        }
        if let userID = comment.authorUserId, userID == myUserID {
            return "You"
        }
        return "User"
    }

    // MARK: - Load

    /// Full fetch (screen appears, pull to refresh). Marks the task read.
    func refresh() async {
        let issue: Issue
        let comments: [IssueComment]
        do {
            issue = try await store.call(accountID) { try await $0.issue(id: issueID) }
            comments = try await store.call(accountID) { try await $0.commentThread(issueId: issueID) }
        } catch {
            if case APIError.unauthorized = error {
                state = .needsSignIn
            } else {
                state = .error(userMessage(for: error))
            }
            store.log("Task detail failed for account \(accountID): \(userMessage(for: error))")
            return
        }

        let documents = await extra { try await $0.documents(issueId: issueID) } ?? []
        let attachments = await extra { try await $0.attachments(issueId: issueID) } ?? []
        liveRuns = await extra { try await $0.liveRuns(issueId: issueID) } ?? []
        let companyId = issue.companyId
        agents = await extra { try await $0.agents(companyId: companyId) } ?? []
        state = .loaded(TaskDetail(issue: issue, comments: comments, documents: documents, attachments: attachments))
        await markRead()
    }

    /// The task, live runs and comments after the last one. Before any load it
    /// is a full fetch. A failed poll keeps the task; a 401 ends in `needsSignIn`.
    func poll() async {
        guard detail != nil else {
            await refresh()
            return
        }
        do {
            let issue = try await store.call(accountID) { try await $0.issue(id: issueID) }
            update { $0.issue = issue }
        } catch {
            fail(polling: error)
            return
        }
        liveRuns = await extra { try await $0.liveRuns(issueId: issueID) } ?? liveRuns
        do {
            if try await fetchNewComments() > 0 {
                if let attachments = await extra({ try await $0.attachments(issueId: issueID) }) {
                    update { $0.attachments = attachments }
                }
                // The user is looking at the new reply: it is read.
                await markRead()
            }
        } catch {
            fail(polling: error)
        }
    }

    /// Polls every `Poller.interval` until the calling task is cancelled.
    func runPolling() async {
        await poller.run { await self.poll() }
    }

    // MARK: - Changes

    func setStatus(_ status: IssueStatus) async {
        guard status != detail?.issue.status else { return }
        pendingStatus = status
        await change(IssueUpdate(status: status))
        pendingStatus = nil
    }

    func setPriority(_ priority: IssuePriority) async {
        guard priority != detail?.issue.priority else { return }
        pendingPriority = priority
        await change(IssueUpdate(priority: priority))
        pendingPriority = nil
    }

    /// Sends both assignee fields, one null, so the server clears the other.
    func setAssignee(_ assignee: IssueAssignee) async {
        guard assignee != self.assignee else { return }
        pendingAssignee = assignee
        await change(IssueUpdate(assignee: assignee))
        pendingAssignee = nil
    }

    /// "Done ✓" on the review bar.
    func markDone() async {
        await change(IssueUpdate(status: .done))
    }

    /// Back to `todo` with a comment saying why, in one `PATCH`. False (and no
    /// request) for a blank comment, false on error so the sheet stays open.
    func reopen(comment: String) async -> Bool {
        let text = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, detail != nil else { return false }
        guard await change(IssueUpdate(status: .todo, comment: text)) else { return false }
        // The re-open comment shows without a full reload.
        _ = try? await fetchNewComments()
        return true
    }

    /// A comment the composer just sent. Shown once, even when a poll returns it too.
    func insertComment(_ comment: IssueComment) {
        update { detail in
            if !detail.comments.contains(where: { $0.id == comment.id }) {
                detail.comments.append(comment)
            }
        }
    }

    /// Refetches the attachments, so a photo just sent shows under its comment.
    func reloadAttachments() async {
        if let attachments = await extra({ try await $0.attachments(issueId: issueID) }) {
            update { $0.attachments = attachments }
        }
    }

    func dismissActionError() {
        actionError = nil
    }

    /// An attachment's bytes, cached while the screen is open. Nil on error.
    func content(of attachment: Attachment) async -> Data? {
        if let cached = contentCache[attachment.id] { return cached }
        let id = attachment.id
        guard let data = await extra({ try await $0.attachmentContent(id: id) }) else { return nil }
        contentCache[id] = data
        return data
    }

    /// The attachment as a local file for Quick Look, in the temporary folder.
    /// Nil (and `actionError`) when it cannot be loaded.
    func previewFile(for attachment: Attachment) async -> URL? {
        guard let data = await content(of: attachment) else {
            actionError = "Could not open \(attachment.originalFilename ?? "the file")."
            return nil
        }
        // Only the last path component of the server's name, never a path.
        let name = attachment.originalFilename.map { URL(fileURLWithPath: $0).lastPathComponent } ?? attachment.id
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent(attachment.id, isDirectory: true)
        let file = folder.appendingPathComponent(name.isEmpty ? attachment.id : name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            return file
        } catch {
            actionError = "Could not open \(attachment.originalFilename ?? "the file")."
            return nil
        }
    }

    // MARK: - Private

    private var account: Account? {
        store.accounts.first { $0.id == accountID }
    }

    /// Sends `fields` and keeps the server's answer. On error nothing changes
    /// and `actionError` says why; a 401 ends in `needsSignIn`.
    @discardableResult
    private func change(_ fields: IssueUpdate) async -> Bool {
        actionError = nil
        do {
            let issue = try await store.call(accountID) { try await $0.updateIssue(id: self.issueID, fields) }
            update { $0.issue = issue }
            return true
        } catch {
            if case APIError.unauthorized = error {
                state = .needsSignIn
            } else {
                actionError = userMessage(for: error)
            }
            store.log("Task change failed for account \(accountID): \(userMessage(for: error))")
            return false
        }
    }

    /// Appends the comments after the last one on screen; returns how many are new.
    private func fetchNewComments() async throws -> Int {
        let lastID = detail?.comments.last?.id
        let fetched = try await store.call(accountID) {
            try await $0.commentThread(issueId: issueID, after: lastID)
        }
        var added = 0
        update { detail in
            let known = Set(detail.comments.map(\.id))
            for comment in fetched where !known.contains(comment.id) {
                detail.comments.append(comment)
                added += 1
            }
        }
        return added
    }

    private func markRead() async {
        _ = await extra { try await $0.markRead(issueId: issueID) }
    }

    /// A call whose failure the screen shows without (nil). A 401 still marks
    /// the account through `AccountStore.call`; the next poll shows sign-in.
    private func extra<T>(_ operation: (APIClient) async throws -> T) async -> T? {
        do {
            return try await store.call(accountID, operation)
        } catch {
            store.log("Task detail extra failed for account \(accountID): \(userMessage(for: error))")
            return nil
        }
    }

    private func update(_ change: (inout TaskDetail) -> Void) {
        guard var detail else { return }
        change(&detail)
        state = .loaded(detail)
    }

    private func fail(polling error: Error) {
        if case APIError.unauthorized = error {
            state = .needsSignIn
        } else {
            store.log("Task detail poll failed for account \(accountID): \(userMessage(for: error))")
        }
    }
}
