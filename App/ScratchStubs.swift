import Foundation
import PaperclipAPI

// Scratch: signatures only, to prove the tests compile. Not for merge.

struct TaskRoute: Hashable {
    let issueID: String
}

extension InboxRow {
    var route: TaskRoute { TaskRoute(issueID: "") }
}

extension ReplyRow {
    var route: TaskRoute { TaskRoute(issueID: "") }
}

extension NeedsYouCard {
    var route: TaskRoute? { nil }
}

struct TaskDetail: Equatable {
    var issue: Issue
    var comments: [IssueComment]
    var documents: [IssueDocument]
    var attachments: [Attachment]
}

@MainActor
@Observable
final class TaskDetailModel {
    let store: AccountStore
    let accountID: UUID
    let issueID: String
    private let poller: Poller

    private(set) var state: LoadState<TaskDetail> = .error("stub")
    private(set) var agents: [Agent] = [Agent]()
    private(set) var liveRuns: [LiveRun] = []
    private(set) var actionError: String?

    init(store: AccountStore, accountID: UUID, issueID: String, poller: Poller = .live) {
        self.store = store
        self.accountID = accountID
        self.issueID = issueID
        self.poller = poller
    }

    static func showsReviewBar(for status: IssueStatus) -> Bool { false }

    var showsReviewBar: Bool { true }
    var liveRunText: String? { "stub" }
    var assignee: IssueAssignee? { nil }

    func attachments(for comment: IssueComment) -> [Attachment] { [] }
    func refresh() async {}
    func poll() async {}
    func runPolling() async {}
    func setStatus(_ status: IssueStatus) async {}
    func setPriority(_ priority: IssuePriority) async {}
    func setAssignee(_ assignee: IssueAssignee) async {}
    func markDone() async {}
    func reopen(comment: String) async -> Bool { true }
    func insertComment(_ comment: IssueComment) {}
    func dismissActionError() {}
}

struct PendingImage: Codable, Equatable {
    var data: Data
    var filename: String
    var contentType: String
    var uploadedAttachmentId: String?

    init(data: Data, filename: String, contentType: String) {
        self.data = data
        self.filename = filename
        self.contentType = contentType
    }
}

struct CommentDraft: Codable, Equatable {
    var text: String = ""
    var image: PendingImage?
}

protocol DraftStore: AnyObject {
    func draft(accountID: UUID, issueID: String) -> CommentDraft?
    func save(_ draft: CommentDraft?, accountID: UUID, issueID: String)
}

final class InMemoryDraftStore: DraftStore {
    func draft(accountID: UUID, issueID: String) -> CommentDraft? { nil }
    func save(_ draft: CommentDraft?, accountID: UUID, issueID: String) {}
}

final class FileDraftStore: DraftStore {
    let folder: URL
    init(folder: URL) { self.folder = folder }
    func draft(accountID: UUID, issueID: String) -> CommentDraft? { nil }
    func save(_ draft: CommentDraft?, accountID: UUID, issueID: String) {}
}

enum SendPhase: Equatable {
    case idle
    case uploading(progress: Double)
    case sending
    case failed(String)
}

@MainActor
@Observable
final class CommentComposer {
    static let photoOnlyBody = ""

    var text: String = "stub"
    private(set) var image: PendingImage?
    private(set) var phase: SendPhase = .sending

    init(
        store: AccountStore, accountID: UUID, companyID: String, issueID: String,
        drafts: DraftStore, onSent: @escaping (IssueComment) -> Void
    ) {}

    var canSend: Bool { true }
    func attach(_ image: PendingImage) {}
    func removeImage() {}
    func send() async {}
    func retry() async {}
}
