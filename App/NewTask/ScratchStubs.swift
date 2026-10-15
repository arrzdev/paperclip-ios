// SCRATCH: signature-only stubs to prove the tests compile. Not for merge.
import Foundation
import PaperclipAPI

protocol DefaultAssigneeStore: AnyObject {
    func agentID(accountID: UUID, companyID: String) -> String?
    func setAgentID(_ agentID: String, accountID: UUID, companyID: String)
}

final class InMemoryDefaultAssigneeStore: DefaultAssigneeStore {
    func agentID(accountID: UUID, companyID: String) -> String? { nil }
    func setAgentID(_ agentID: String, accountID: UUID, companyID: String) {}
}

final class FileDefaultAssigneeStore: DefaultAssigneeStore {
    let fileURL: URL
    init(fileURL: URL) { self.fileURL = fileURL }
    static func live() -> FileDefaultAssigneeStore { FileDefaultAssigneeStore(fileURL: URL(fileURLWithPath: "/dev/null")) }
    func agentID(accountID: UUID, companyID: String) -> String? { nil }
    func setAgentID(_ agentID: String, accountID: UUID, companyID: String) {}
}

enum DefaultAssignee {
    static func resolve(storedID: String?, agents: [Agent]) -> Agent? { nil }
}

struct NewTaskText: Equatable {
    let title: String
    let description: String?
}

extension NewTaskText {
    init(_ text: String) { self.init(title: "", description: "x") }
}

@MainActor
@Observable
final class NewTaskModel {
    static func draftKey(companyID: String) -> String { "" }

    private(set) var phase: SendPhase = .idle
    private(set) var agents: [Agent] = []
    private(set) var projects: [Project] = []
    private(set) var assignee: Agent?
    private(set) var project: Project?
    private(set) var loadError: String?
    private(set) var needsSignIn = false
    private(set) var createdIssue: Issue?
    var text: String = ""
    private(set) var image: PendingImage?

    init(store: AccountStore, accountID: UUID, companyID: String, drafts: DraftStore, defaults: DefaultAssigneeStore) {}

    var placeholder: String { "" }
    var isBusy: Bool { false }
    var canSend: Bool { false }
    func load() async {}
    func selectAssignee(_ agent: Agent) {}
    func selectProject(_ project: Project?) {}
    func attach(_ image: PendingImage) {}
    func removeImage() {}
    func send() async {}
    func retry() async {}
    func openedCreatedIssue() {}
}
