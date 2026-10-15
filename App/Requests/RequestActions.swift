import Foundation
import PaperclipAPI

/// An answer waiting for its undo toast to end.
struct PendingRequest: Equatable {
    enum Kind: Equatable {
        case accept
        case reject(reason: String?)
        case answer([InteractionAnswer])
    }

    let card: InteractionCard
    let kind: Kind

    var toastText: String {
        switch kind {
        case .accept: "Accepted"
        case .reject: "Rejected"
        case .answer: "Answer sent"
        }
    }
}

/// Accept, Reject and Answer for request cards, shared by Today and Task
/// detail. The card leaves at once and a 5 s undo toast shows; the request is
/// sent only when the toast ends, the screen goes away or another action
/// starts. Undo sends nothing. A failure brings the card back with `error`; a
/// 409 means it was already answered and the card stays gone. A reason or an
/// answer is never logged.
@MainActor
@Observable
final class RequestActions {
    static let undoWindow: Duration = .seconds(5)
    static let alreadyAnswered = "This request was already answered."

    private(set) var pending: PendingRequest?
    private(set) var error: String?
    /// A send got a 401; the owner shows sign-in.
    private(set) var needsSignIn = false

    private let store: AccountStore
    private let accountID: UUID
    private let sleep: @Sendable (Duration) async throws -> Void
    /// Cards answered, waiting in the toast, or answered elsewhere (409).
    private var hiddenIDs: Set<String> = []

    init(
        store: AccountStore,
        accountID: UUID,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.store = store
        self.accountID = accountID
        self.sleep = sleep
    }

    func isHidden(_ cardID: String) -> Bool {
        hiddenIDs.contains(cardID)
    }

    func accept(_ card: InteractionCard) async {
        await start(PendingRequest(card: card, kind: .accept))
    }

    /// False (and nothing changes) for a blank reason the request requires.
    /// A blank reason is not sent.
    func reject(_ card: InteractionCard, reason: String) async -> Bool {
        let text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if case .confirm(_, _, let required) = card.action, required, text.isEmpty { return false }
        await start(PendingRequest(card: card, kind: .reject(reason: text.isEmpty ? nil : text)))
        return true
    }

    /// False (and nothing changes) while the form misses a required answer.
    func answer(_ card: InteractionCard, form: QuestionForm) async -> Bool {
        guard form.isValid else { return false }
        await start(PendingRequest(card: card, kind: .answer(form.answers)))
        return true
    }

    /// Brings the card back; nothing is sent.
    func undo() {
        guard let pending else { return }
        hiddenIDs.remove(pending.card.id)
        self.pending = nil
    }

    /// Sends the pending answer now (toast ended, screen gone, next action).
    func sendPending() async {
        guard let sending = pending else { return }
        pending = nil
        let card = sending.card
        do {
            _ = try await store.call(accountID) { (client: APIClient) -> IssueInteraction in
                switch sending.kind {
                case .accept:
                    return try await client.acceptInteraction(issueId: card.issueID, interactionId: card.id)
                case .reject(let reason):
                    return try await client.rejectInteraction(issueId: card.issueID, interactionId: card.id, reason: reason)
                case .answer(let answers):
                    return try await client.respondToInteraction(issueId: card.issueID, interactionId: card.id, answers: answers)
                }
            }
        } catch {
            switch error {
            case APIError.unauthorized:
                hiddenIDs.remove(card.id)
                needsSignIn = true
            case APIError.server(let status, _) where status == 409:
                self.error = Self.alreadyAnswered
            default:
                hiddenIDs.remove(card.id)
                self.error = userMessage(for: error)
            }
            store.log("Request \(card.id) not sent for account \(accountID): \(userMessage(for: error))")
        }
    }

    /// Waits out the undo toast, then sends. Cancelled (undo, screen gone)
    /// before the end, it sends nothing.
    func runUndoTimer() async {
        guard let waiting = pending else { return }
        do {
            try await sleep(Self.undoWindow)
        } catch {
            return
        }
        guard pending == waiting else { return }
        await sendPending()
    }

    func dismissError() {
        error = nil
    }

    /// Sends any earlier pending answer first, then hides the card.
    private func start(_ request: PendingRequest) async {
        await sendPending()
        error = nil
        hiddenIDs.insert(request.card.id)
        pending = request
    }
}
