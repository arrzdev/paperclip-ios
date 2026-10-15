import Foundation
import PaperclipAPI

/// What a request card lets the user do in the app.
enum RequestAction: Equatable, Sendable {
    /// Accept / Reject; Reject asks for a reason, required when the flag is set.
    case confirm(acceptLabel: String, rejectLabel: String, rejectRequiresReason: Bool)
    /// Answer opens a `QuestionForm` with these questions.
    case answer([InteractionQuestion])
    /// A kind or payload the app cannot answer: Open in web.
    case openInWeb
}

/// A pending request on a task, as a card in Today or in the Task detail thread.
struct InteractionCard: Equatable, Identifiable, Sendable {
    /// Most questions the native form shows; more open in the web UI.
    static let maxQuestions = 20

    let id: String
    let issueID: String
    let identifier: String?
    /// The task's title.
    let title: String
    let prompt: String?
    /// Markdown.
    let details: String?
    let createdAt: Date
    let action: RequestAction
    /// The task in the web UI, for Open in web.
    let webPath: String?

    init(_ interaction: IssueInteraction, identifier: String?, issueTitle: String?) {
        let payload = interaction.payload
        id = interaction.id
        issueID = interaction.issueId
        self.identifier = identifier
        title = issueTitle ?? interaction.title ?? ""
        prompt = nonBlank(payload.prompt) ?? nonBlank(payload.title) ?? nonBlank(interaction.summary)
        details = nonBlank(payload.detailsMarkdown)
        createdAt = interaction.createdAt
        action = Self.action(for: interaction)
        webPath = PaperclipIOS.webPath(identifier: identifier)
    }

    /// `.confirm` for a plain confirmation (no tool to run, no secret to share),
    /// `.answer` for up to 20 single or multi questions, else `.openInWeb`.
    private static func action(for interaction: IssueInteraction) -> RequestAction {
        let payload = interaction.payload
        switch interaction.kind {
        case .requestConfirmation:
            guard nonBlank(payload.prompt) != nil, !payload.hasToolAction, !payload.hasSecretProposal else {
                return .openInWeb
            }
            return .confirm(
                acceptLabel: nonBlank(payload.acceptLabel) ?? "Accept",
                rejectLabel: nonBlank(payload.rejectLabel) ?? "Reject",
                rejectRequiresReason: payload.rejectRequiresReason ?? false
            )
        case .askUserQuestions:
            guard let questions = payload.questions, !questions.isEmpty, questions.count <= maxQuestions,
                  questions.allSatisfy(isAnswerable) else {
                return .openInWeb
            }
            return .answer(questions)
        default:
            return .openInWeb
        }
    }

    private static func isAnswerable(_ question: InteractionQuestion) -> Bool {
        switch question.selectionMode {
        case .single, .multi:
            return !question.options.isEmpty || question.allowOther == true
        case .unknown:
            return false
        }
    }
}

private func nonBlank(_ text: String?) -> String? {
    guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return text
}

/// One row of the Task detail thread: a comment or a pending request, by time.
enum ThreadItem: Equatable, Identifiable {
    case comment(IssueComment)
    case request(InteractionCard)

    var id: String {
        switch self {
        case .comment(let comment): comment.id
        case .request(let card): card.id
        }
    }

    var createdAt: Date {
        switch self {
        case .comment(let comment): comment.createdAt
        case .request(let card): card.createdAt
        }
    }
}
