import PaperclipAPI
import SwiftUI

/// Stands in for the inbox until it exists: shows the selected company.
@MainActor
struct HomePlaceholderView: View {
    let accountID: UUID

    @Environment(AccountStore.self) private var store
    @State private var companyName: String?

    var body: some View {
        ContentUnavailableView {
            Label(companyName ?? ContentView.title, systemImage: "paperclip")
        } description: {
            if let account = store.accounts.first(where: { $0.id == accountID }) {
                Text("Signed in to \(account.server.displayName). The inbox comes in a later version.")
            }
        }
        .navigationTitle(companyName ?? ContentView.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: selectedCompanyId) {
            await loadCompanyName()
        }
    }

    private var selectedCompanyId: String? {
        store.accounts.first { $0.id == accountID }?.selectedCompanyId
    }

    private func loadCompanyName() async {
        guard let companyId = selectedCompanyId else { return }
        do {
            companyName = try await store.call(accountID) { try await $0.company(id: companyId).name }
        } catch {
            store.log("Company name failed for account \(accountID): \(userMessage(for: error))")
        }
    }
}
