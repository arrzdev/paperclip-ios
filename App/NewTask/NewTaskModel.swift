import Foundation
import PaperclipAPI

/// The New task sheet and the Today "Message <name>…" bar: one text field
/// (first line = title), one photo, an assignee (default: the last agent the
/// user gave a task to, first use the CEO) and an optional project.
///
/// Send creates the task with the draft's `clientRequestId` as its
/// `idempotencyKey` (a retry replays, never a second task), saves the default
/// assignee, uploads the photo to the new task (once), then sets
/// `createdIssue`. A failure keeps the draft; Retry continues where the send
/// stopped. Never logs the text or the photo.
@MainActor
@Observable
final class NewTaskModel {
    /// The draft slot of the New task sheet in the `DraftStore`, one per company.
    static func draftKey(companyID: String) -> String {
        "new-task/" + companyID
    }

    let accountID: UUID
    let companyID: String

    private(set) var phase: SendPhase = .idle
    /// Agents that can take work (terminated ones left out).
    private(set) var agents: [Agent] = []
    private(set) var projects: [Project] = []
    private(set) var assignee: Agent?
    /// Nil = no project.
    private(set) var project: Project?
    /// Set when the agents could not be loaded.
    private(set) var loadError: String?
    private(set) var needsSignIn = false
    /// The task the last send created; the view opens it, then calls `openedCreatedIssue()`.
    private(set) var createdIssue: Issue?

    private var draft: CommentDraft
    /// Created by a send whose photo upload failed: Retry uploads only.
    private var pendingIssue: Issue?

    private let store: AccountStore
    private let drafts: DraftStore
    private let defaults: DefaultAssigneeStore

    init(store: AccountStore, accountID: UUID, companyID: String, drafts: DraftStore, defaults: DefaultAssigneeStore) {
        self.store = store
        self.accountID = accountID
        self.companyID = companyID
        self.drafts = drafts
        self.defaults = defaults
        self.draft = drafts.draft(accountID: accountID, issueID: Self.draftKey(companyID: companyID)) ?? CommentDraft()
    }

    var text: String {
        get { draft.text }
        set {
            draft.text = newValue
            persist()
        }
    }

    var image: PendingImage? {
        draft.image
    }

    /// "Message Luis…", or "New task…" with no assignee.
    var placeholder: String {
        assignee.map { "Message \($0.name)…" } ?? "New task…"
    }

    var isBusy: Bool {
        switch phase {
        case .uploading, .sending: true
        case .idle, .failed: false
        }
    }

    /// A title and an assignee, and no send on the way. A photo alone is no task.
    var canSend: Bool {
        !isBusy && assignee != nil && !NewTaskText(draft.text).title.isEmpty
    }

    /// Agents (required for the assignee) and projects (a failure only empties the chip).
    func load() async {
        let companyID = self.companyID
        do {
            let all = try await store.call(accountID) { try await $0.agents(companyId: companyID) }
            agents = all.filter { $0.status != "terminated" }
            loadError = nil
            if let current = assignee, agents.contains(where: { $0.id == current.id }) {
                // Keep what the user picked.
            } else {
                let stored = defaults.agentID(accountID: accountID, companyID: companyID)
                assignee = DefaultAssignee.resolve(storedID: stored, agents: agents)
            }
        } catch {
            if case APIError.unauthorized = error {
                needsSignIn = true
                return
            }
            agents = []
            assignee = nil
            loadError = userMessage(for: error)
            store.log("New task agents failed for account \(accountID): \(userMessage(for: error))")
        }

        do {
            projects = try await store.call(accountID) { try await $0.projects(companyId: companyID) }
            if let current = project, !projects.contains(where: { $0.id == current.id }) {
                project = nil
            }
        } catch {
            if case APIError.unauthorized = error {
                needsSignIn = true
                return
            }
            projects = []
            project = nil
            store.log("New task projects failed for account \(accountID): \(userMessage(for: error))")
        }
    }

    /// Picking is not giving a task: the default changes only once a task is created.
    func selectAssignee(_ agent: Agent) {
        assignee = agent
    }

    func selectProject(_ project: Project?) {
        self.project = project
    }

    func attach(_ image: PendingImage) {
        draft.image = image
        persist()
    }

    func removeImage() {
        draft.image = nil
        persist()
    }

    func send() async {
        guard canSend, let assignee else { return }
        do {
            let issue = try await createIfNeeded(assignee: assignee)
            if let image = draft.image {
                try await upload(image, to: issue)
            }
            pendingIssue = nil
            draft = CommentDraft()
            persist()
            phase = .idle
            createdIssue = issue
        } catch {
            if case APIError.unauthorized = error { needsSignIn = true }
            phase = .failed(userMessage(for: error))
            store.log("New task send failed for account \(accountID): \(userMessage(for: error))")
        }
    }

    /// Continues a failed send: a created task is not created again and an
    /// uploaded photo is not uploaded again.
    func retry() async {
        await send()
    }

    func openedCreatedIssue() {
        createdIssue = nil
    }

    // MARK: - Private

    private func createIfNeeded(assignee: Agent) async throws -> Issue {
        if let pendingIssue { return pendingIssue }
        let key = draft.clientRequestId ?? UUID()
        draft.clientRequestId = key
        persist()

        phase = .sending
        let text = NewTaskText(draft.text)
        let newIssue = NewIssue(
            title: text.title,
            description: text.description,
            assigneeAgentId: assignee.id,
            projectId: project?.id,
            idempotencyKey: key.uuidString
        )
        let companyID = self.companyID
        let issue = try await store.call(accountID) { try await $0.createIssue(companyId: companyID, newIssue) }
        // The task was given: this agent is the default from now on.
        defaults.setAgentID(assignee.id, accountID: accountID, companyID: companyID)
        pendingIssue = issue
        return issue
    }

    private func upload(_ image: PendingImage, to issue: Issue) async throws {
        if image.uploadedAttachmentId != nil { return }
        phase = .uploading(progress: 0)
        let file = AttachmentUpload(data: image.data, filename: image.filename, contentType: image.contentType)
        let companyID = self.companyID
        let issueID = issue.id
        let attachment = try await store.call(accountID) { client in
            try await client.uploadAttachment(companyId: companyID, issueId: issueID, file) { fraction in
                Task { @MainActor in self.uploadProgressed(fraction) }
            }
        }
        if draft.image?.data == image.data {
            draft.image?.uploadedAttachmentId = attachment.id
            persist()
        }
    }

    private func uploadProgressed(_ fraction: Double) {
        guard case .uploading = phase else { return }
        phase = .uploading(progress: min(max(fraction, 0), 1))
    }

    private func persist() {
        drafts.save(draft.isEmpty ? nil : draft, accountID: accountID, issueID: Self.draftKey(companyID: companyID))
    }
}
