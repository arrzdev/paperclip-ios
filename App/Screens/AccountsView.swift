import PaperclipAPI
import SwiftUI

/// Settings: the servers signed in to (switch, add, remove, sign in again)
/// and the current account's company.
@MainActor
struct AccountsView: View {
    @Environment(AccountStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var signInSheet: SignInSheet?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section("Servers") {
                ForEach(store.accounts) { account in
                    AccountRow(
                        account: account,
                        isCurrent: account.id == store.currentAccountID,
                        onSelect: { select(account.id) },
                        onSignInAgain: { signInSheet = .reSignIn(account.id) }
                    )
                }
                .onDelete(perform: remove)

                Button("Add server", systemImage: "plus") {
                    signInSheet = .add
                }
            }

            if let account = store.currentAccount, !account.needsSignIn {
                Section("Current server") {
                    NavigationLink("Company") {
                        CompanyPickerView(store: store)
                    }
                    Button("Sign out", role: .destructive) {
                        Task { await store.signOut(account.id) }
                    }
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Text(ContentView.pinLabel)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .sheet(item: $signInSheet) { sheet in
            NavigationStack {
                SignInView(store: store, reauthenticating: sheet.accountID) {
                    signInSheet = nil
                }
                .navigationTitle(sheet.accountID == nil ? "Add server" : "Sign in again")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { signInSheet = nil }
                    }
                }
            }
        }
    }

    private func select(_ id: UUID) {
        do {
            try store.select(id)
            errorMessage = nil
        } catch {
            errorMessage = userMessage(for: error)
        }
    }

    private func remove(_ offsets: IndexSet) {
        let ids = offsets.map { store.accounts[$0].id }
        Task {
            for id in ids {
                do {
                    try await store.remove(id)
                } catch {
                    errorMessage = userMessage(for: error)
                }
            }
        }
    }
}

private enum SignInSheet: Identifiable {
    case add
    case reSignIn(UUID)

    var id: String {
        switch self {
        case .add: "add"
        case .reSignIn(let id): id.uuidString
        }
    }

    var accountID: UUID? {
        if case .reSignIn(let id) = self { return id }
        return nil
    }
}

private struct AccountRow: View {
    let account: Account
    let isCurrent: Bool
    let onSelect: () -> Void
    let onSignInAgain: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onSelect) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.server.displayName)
                        if let user = account.userName ?? account.userEmail {
                            Text(user)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if isCurrent {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.tint)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let warning = keyWarning {
                HStack {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Sign in again", action: onSignInAgain)
                        .font(.footnote)
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    private var keyWarning: String? {
        switch account.keyStatus(now: Date()) {
        case .valid:
            return nil
        case .expiresSoon(let date):
            return "Key expires \(date.formatted(.relative(presentation: .named)))"
        case .expired:
            return "Key expired"
        case .needsSignIn:
            return "Signed out"
        }
    }
}

/// Adds the Settings button and sheet to a top-level screen.
private struct SettingsButton: ViewModifier {
    @State private var isShowingSettings = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") {
                        isShowingSettings = true
                    }
                }
            }
            .sheet(isPresented: $isShowingSettings) {
                NavigationStack {
                    AccountsView()
                }
            }
    }
}

extension View {
    @MainActor
    func settingsButton() -> some View {
        modifier(SettingsButton())
    }
}
