import PaperclipAPI
import SwiftUI

/// Root view: shows the screen for `AccountStore.route`.
struct ContentView: View {
    static let title = "Paperclip"
    static let pinLabel = "Paperclip \(PaperclipPin.version) (\(PaperclipPin.commit))"

    @Environment(AccountStore.self) private var store

    var body: some View {
        switch store.route {
        case .addServer:
            NavigationStack {
                SignInView(store: store)
                    .navigationTitle(Self.title)
            }
        case .reSignIn(let id):
            NavigationStack {
                SignInView(store: store, reauthenticating: id)
                    .navigationTitle("Sign in again")
                    .settingsButton()
            }
            .id(id)
        case .pickCompany(let id):
            NavigationStack {
                CompanyPickerView(store: store)
                    .settingsButton()
            }
            .id(id)
        case .home(let id):
            // Keyed by account and company: a switch reloads Today and goes back to its tab.
            HomeView(store: store, accountID: id)
                .id("\(id.uuidString)/\(store.currentAccount?.selectedCompanyId ?? "")")
        }
    }
}
