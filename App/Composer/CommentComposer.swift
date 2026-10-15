import Foundation
import PaperclipAPI

/// Where a send is.
enum SendPhase: Equatable {
    case idle
    case uploading(progress: Double)
    case sending
    case failed(String)
}

/// The Task detail composer: text and one photo. The draft is saved on every
/// change. Send uploads the photo first (once), then posts the comment with
/// its `attachmentIds` and the draft's `clientRequestId`. A failure keeps the
/// draft; Retry continues where the send stopped. Never logs the draft.
@MainActor
@Observable
final class CommentComposer {
    /// The server needs a non-empty body; a photo alone gets this one.
    static let photoOnlyBody = "Photo attached."

    private(set) var phase: SendPhase = .idle
    private var draft: CommentDraft

    private let store: AccountStore
    private let accountID: UUID
    private let companyID: String
    private let issueID: String
    private let drafts: DraftStore
    private let onSent: (IssueComment) -> Void

    init(
        store: AccountStore, accountID: UUID, companyID: String, issueID: String,
        drafts: DraftStore, onSent: @escaping (IssueComment) -> Void
    ) {
        self.store = store
        self.accountID = accountID
        self.companyID = companyID
        self.issueID = issueID
        self.drafts = drafts
        self.onSent = onSent
        self.draft = drafts.draft(accountID: accountID, issueID: issueID) ?? CommentDraft()
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

    var isBusy: Bool {
        switch phase {
        case .uploading, .sending: true
        case .idle, .failed: false
        }
    }

    var canSend: Bool {
        !isBusy && (!trimmedText.isEmpty || draft.image != nil)
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
        guard canSend else { return }
        let requestID = draft.clientRequestId ?? UUID()
        draft.clientRequestId = requestID
        persist()

        do {
            var attachmentIds: [String]?
            if let image = draft.image {
                let attachmentId = try await upload(image)
                attachmentIds = [attachmentId]
            }
            phase = .sending
            let text = trimmedText
            let comment = NewComment(
                body: text.isEmpty ? Self.photoOnlyBody : text,
                attachmentIds: attachmentIds,
                clientRequestId: requestID
            )
            let issueID = self.issueID
            let created = try await store.call(accountID) { try await $0.addComment(issueId: issueID, comment) }
            draft = CommentDraft()
            persist()
            phase = .idle
            onSent(created)
        } catch {
            phase = .failed(userMessage(for: error))
            store.log("Comment send failed for account \(accountID): \(userMessage(for: error))")
        }
    }

    /// Continues a failed send: an uploaded photo is not uploaded again and
    /// the comment keeps its request id.
    func retry() async {
        await send()
    }

    // MARK: - Private

    private var trimmedText: String {
        draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The attachment id of `image`, uploading it first when needed.
    private func upload(_ image: PendingImage) async throws -> String {
        if let id = image.uploadedAttachmentId { return id }
        phase = .uploading(progress: 0)
        let file = AttachmentUpload(data: image.data, filename: image.filename, contentType: image.contentType)
        let companyID = self.companyID
        let issueID = self.issueID
        let attachment = try await store.call(accountID) { client in
            try await client.uploadAttachment(companyId: companyID, issueId: issueID, file) { fraction in
                Task { @MainActor in self.uploadProgressed(fraction) }
            }
        }
        // Remember the upload in the draft, so leaving the screen does not lose it.
        if draft.image?.data == image.data {
            draft.image?.uploadedAttachmentId = attachment.id
            persist()
        }
        return attachment.id
    }

    private func uploadProgressed(_ fraction: Double) {
        guard case .uploading = phase else { return }
        phase = .uploading(progress: min(max(fraction, 0), 1))
    }

    private func persist() {
        drafts.save(draft.isEmpty ? nil : draft, accountID: accountID, issueID: issueID)
    }
}
