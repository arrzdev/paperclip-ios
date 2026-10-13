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
        guard let id = store.currentAccountID else {
            companies = []
            errorMessage = userMessage(for: AccountStoreError.unknownAccount)
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            companies = try await store.call(id) { try await $0.companies() }
            errorMessage = nil
            if companies.count == 1, let only = companies.first, selectedCompanyId == nil {
                try store.selectCompany(only.id, for: id)
            }
        } catch {
            companies = []
            errorMessage = userMessage(for: error)
            store.log("Company list failed for account \(id): \(errorMessage ?? "")")
        }
    }

    func select(_ company: Company) throws {
        guard let id = store.currentAccountID else { throw AccountStoreError.unknownAccount }
        try store.selectCompany(company.id, for: id)
    }
}
