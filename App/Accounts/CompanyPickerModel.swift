import Foundation
import PaperclipAPI

/// Lists the current account's companies (`GET /api/companies`) and saves the choice.
@MainActor
@Observable
final class CompanyPickerModel {
    let store: AccountStore
    private(set) var companies: [Company] = []
    private(set) var isLoading = false
    /// User-facing text; never contains a key.
    private(set) var errorMessage: String?

    init(store: AccountStore) {
        self.store = store
    }

    var selectedCompanyId: String? {
        store.currentAccount?.selectedCompanyId
    }

    /// Loads through `AccountStore.call`, so a 401 sends the account to sign-in.
    /// With exactly one company and none selected, selects it.
    func load() async {
        // TODO
    }

    func select(_ company: Company) throws {
        throw NotImplemented() // TODO
    }
}
