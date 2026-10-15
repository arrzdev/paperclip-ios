import Foundation
import PaperclipAPI

// Scratch: signatures only, to prove the tests compile.
struct AccountSection: Identifiable, Equatable {
    var account: Account
    var companies: [Company]
    var errorMessage: String?
    var id: UUID { account.id }
}

@MainActor
@Observable
final class AccountsModel {
    let store: AccountStore
    private let poller: Poller
    private(set) var sections: [AccountSection] = []

    init(store: AccountStore, poller: Poller = .live) {
        self.store = store
        self.poller = poller
    }

    func badge(accountID: UUID, companyID: String) -> Int? { nil }
    func isCurrent(accountID: UUID, companyID: String) -> Bool { false }
    func refresh() async {}
    func poll() async {}
    func runPolling() async {}
    func switchTo(accountID: UUID, companyID: String) throws {}
    func signOut(_ id: UUID) async {}
    func remove(_ id: UUID) async throws {}
}
