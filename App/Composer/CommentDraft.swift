import Foundation

/// A photo waiting to be sent with a comment. `uploadedAttachmentId` is set
/// once the upload succeeded, so a retry does not upload it again.
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

/// What the composer holds for one task: text, at most one photo, and the
/// request id of a send that has not succeeded yet.
struct CommentDraft: Codable, Equatable {
    var text: String = ""
    var image: PendingImage?
    /// Kept until the send succeeds, so a retry never posts the comment twice.
    var clientRequestId: UUID?

    var isEmpty: Bool {
        text.isEmpty && image == nil && clientRequestId == nil
    }
}

/// Drafts per account and task. `save(nil, …)` removes the draft.
protocol DraftStore: AnyObject {
    func draft(accountID: UUID, issueID: String) -> CommentDraft?
    func save(_ draft: CommentDraft?, accountID: UUID, issueID: String)
}

/// Drafts for tests and previews.
final class InMemoryDraftStore: DraftStore {
    private var drafts: [String: CommentDraft] = [:]

    func draft(accountID: UUID, issueID: String) -> CommentDraft? {
        drafts[Self.key(accountID, issueID)]
    }

    func save(_ draft: CommentDraft?, accountID: UUID, issueID: String) {
        drafts[Self.key(accountID, issueID)] = draft
    }

    private static func key(_ accountID: UUID, _ issueID: String) -> String {
        accountID.uuidString + "/" + issueID
    }
}

/// Drafts on disk: one JSON file per account and task in `folder`. The file
/// name is the account id and the hex of the issue id, so no issue id can
/// leave the folder. Files are readable only after the first unlock.
final class FileDraftStore: DraftStore {
    let folder: URL

    init(folder: URL) {
        self.folder = folder
    }

    /// Application Support/drafts.
    static func live() -> FileDraftStore {
        let manager = FileManager.default
        let support = (try? manager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? manager.temporaryDirectory
        return FileDraftStore(folder: support.appendingPathComponent("drafts", isDirectory: true))
    }

    func draft(accountID: UUID, issueID: String) -> CommentDraft? {
        guard let data = try? Data(contentsOf: fileURL(accountID, issueID)) else { return nil }
        return try? JSONDecoder().decode(CommentDraft.self, from: data)
    }

    func save(_ draft: CommentDraft?, accountID: UUID, issueID: String) {
        let url = fileURL(accountID, issueID)
        guard let draft else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(draft)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            // A draft that cannot be saved stays in memory while the screen is open.
        }
    }

    private func fileURL(_ accountID: UUID, _ issueID: String) -> URL {
        let hex = Data(issueID.utf8).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent("\(accountID.uuidString)-\(hex).json", isDirectory: false)
    }
}
