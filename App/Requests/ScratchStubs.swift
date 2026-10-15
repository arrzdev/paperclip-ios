import Foundation
import PaperclipAPI

// Scratch only: signatures without behaviour, to prove the tests compile.

enum RequestAction: Equatable {
    case confirm(acceptLabel: String, rejectLabel: String, rejectRequiresReason: Bool)
    case answer([InteractionQuestion])
    case openInWeb
}

struct InteractionCard: Equatable, Identifiable {
    let id: String
    let issueID: String
    let identifier: String?
    let title: String
    let prompt: String?
    let details: String?
    let createdAt: Date
    let action: RequestAction
    let webPath: String?

    init(_ interaction: IssueInteraction, identifier: String?, issueTitle: String?) {
        id = ""
        issueID = ""
        self.identifier = nil
        title = ""
        prompt = nil
        details = nil
        createdAt = .distantPast
        action = .openInWeb
        webPath = nil
    }
}

struct QuestionForm: Equatable {
    let questions: [InteractionQuestion]

    init(questions: [InteractionQuestion]) {
        self.questions = questions
    }

    func isSelected(_ optionID: String, in questionID: String) -> Bool { false }
    mutating func select(_ optionID: String, in questionID: String) {}
    func text(for questionID: String) -> String { "x" }
    mutating func setText(_ text: String, for questionID: String) {}
    func showsTextField(_ question: InteractionQuestion) -> Bool { false }
    var missingQuestionIDs: [String] { [] }
    var isValid: Bool { false }
    var answers: [InteractionAnswer] { [] }
}

struct PendingRequest: Equatable {
    enum Kind: Equatable {
        case accept
        case reject(reason: String?)
        case answer([InteractionAnswer])
    }

    let card: InteractionCard
    let kind: Kind

    var toastText: String { "" }
}

@MainActor
@Observable
final class RequestActions {
    static let undoWindow: Duration = .seconds(5)
    static let alreadyAnswered = ""

    private(set) var pending: PendingRequest?
    private(set) var error: String?
    private(set) var needsSignIn = false

    init(
        store: AccountStore,
        accountID: UUID,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {}

    func isHidden(_ cardID: String) -> Bool { false }
    func accept(_ card: InteractionCard) async {}
    func reject(_ card: InteractionCard, reason: String) async -> Bool { false }
    func answer(_ card: InteractionCard, form: QuestionForm) async -> Bool { false }
    func undo() {}
    func sendPending() async {}
    func runUndoTimer() async {}
    func dismissError() {}
}

enum ThreadItem: Equatable, Identifiable {
    case comment(IssueComment)
    case request(InteractionCard)

    var id: String {
        switch self {
        case .comment(let comment): comment.id
        case .request(let card): card.id
        }
    }
}

extension TodayModel {
    var requests: RequestActions { RequestActions(store: store, accountID: accountID) }
}

extension TaskDetailModel {
    var requests: RequestActions { RequestActions(store: store, accountID: accountID) }
    var threadItems: [ThreadItem] { [] }
}

extension NeedsYouCard {
    var request: InteractionCard? { nil }
    var approvalID: String? { nil }
    var approvalRoute: ApprovalRoute? { nil }
}

struct ApprovalRoute: Hashable {
    let approvalID: String
}

struct ApprovalDetail: Equatable {
    var approval: Approval
    var comments: [ApprovalComment]
}

extension ApprovalDecision {
    var title: String { "" }
}

@MainActor
@Observable
final class ApprovalDetailModel {
    private(set) var state: LoadState<ApprovalDetail> = .loading
    private(set) var actionError: String?

    init(store: AccountStore, accountID: UUID, approvalID: String) {}

    var requesterName: String? { nil }
    var availableDecisions: [ApprovalDecision] { [] }
    func authorName(for comment: ApprovalComment) -> String { "" }
    func refresh() async {}
    func decide(_ decision: ApprovalDecision, note: String) async -> Bool { false }
    func addComment(_ text: String) async -> Bool { false }
    func dismissActionError() {}
}
