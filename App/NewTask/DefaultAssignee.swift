import Foundation
import PaperclipAPI

/// The last agent the user gave a task to, per account and company. Not a
/// secret, so it lives in a file, not the Keychain.
protocol DefaultAssigneeStore: AnyObject {
    func agentID(accountID: UUID, companyID: String) -> String?
    func setAgentID(_ agentID: String, accountID: UUID, companyID: String)
}

/// Defaults for tests and previews.
final class InMemoryDefaultAssigneeStore: DefaultAssigneeStore {
    private var ids: [String: String] = [:]

    func agentID(accountID: UUID, companyID: String) -> String? {
        ids[DefaultAssignee.key(accountID, companyID)]
    }

    func setAgentID(_ agentID: String, accountID: UUID, companyID: String) {
        ids[DefaultAssignee.key(accountID, companyID)] = agentID
    }
}

/// Defaults on disk: one JSON map `"<accountUUID>/<companyID>" → agentID` at
/// `fileURL`. A save that fails keeps the value in memory for this launch.
final class FileDefaultAssigneeStore: DefaultAssigneeStore {
    let fileURL: URL
    private var ids: [String: String]

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let ids = try? JSONDecoder().decode([String: String].self, from: data) {
            self.ids = ids
        } else {
            self.ids = [:]
        }
    }

    /// Application Support/default-assignees.json.
    static func live() -> FileDefaultAssigneeStore {
        let manager = FileManager.default
        let support = (try? manager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? manager.temporaryDirectory
        return FileDefaultAssigneeStore(fileURL: support.appendingPathComponent("default-assignees.json"))
    }

    func agentID(accountID: UUID, companyID: String) -> String? {
        ids[DefaultAssignee.key(accountID, companyID)]
    }

    func setAgentID(_ agentID: String, accountID: UUID, companyID: String) {
        ids[DefaultAssignee.key(accountID, companyID)] = agentID
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(ids)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            // Kept in memory: the default still works until the app quits.
        }
    }
}

enum DefaultAssignee {
    /// The stored agent while it is in `agents` and not terminated, else the
    /// first agent with role `ceo`, else nil.
    static func resolve(storedID: String?, agents: [Agent]) -> Agent? {
        let active = agents.filter { $0.status != "terminated" }
        if let storedID, let stored = active.first(where: { $0.id == storedID }) {
            return stored
        }
        return active.first { $0.role == "ceo" }
    }

    static func key(_ accountID: UUID, _ companyID: String) -> String {
        accountID.uuidString + "/" + companyID
    }
}
