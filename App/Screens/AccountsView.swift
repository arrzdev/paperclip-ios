import PaperclipAPI
import SwiftUI

/// Me → Accounts (also the Settings sheet): every server with its user and
/// companies, a ✓ on the current company and its "Needs you" badge. Tap a
/// company to switch; swipe a server to sign out or remove it.
@MainActor
struct AccountsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: AccountsModel
    @State private var signInSheet: SignInSheet?
    @State private var errorMessage: String?
    private let title: String
    /// False in the Me tab, where there is no sheet to close.
    private let showsDoneButton: Bool
    /// Me → More (the Me tab only).
    private let more: MoreModel?

    init(model: AccountsModel, title: String = "Settings", showsDoneButton: Bool = true, more: MoreModel? = nil) {
        _model = State(initialValue: model)
        self.title = title
        self.showsDoneButton = showsDoneButton
        self.more = more
    }

    var body: some View {
        List {
            ForEach(model.sections) { section in
                Section {
                    AccountRow(
                        account: section.account,
                        onSignInAgain: { signInSheet = .reSignIn(section.account.id) }
                    )
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Remove", systemImage: "trash", role: .destructive) {
                            remove(section.account.id)
                        }
                        if !section.account.needsSignIn {
                            Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right") {
                                Task { await model.signOut(section.account.id) }
                            }
                            .tint(.orange)
                        }
                    }
                    CompanyRows(model: model, section: section, onSwitch: switchTo)
                } header: {
                    ServerHeader(name: section.account.server.displayName)
                }
            }

            Section {
                Button {
                    signInSheet = .add
                } label: {
                    RowLabel("Add server", systemImage: "plus")
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }

            if let more {
                MoreSection(model: more)
            }

            Section {
                Text(ContentView.pinLabel)
                    .font(.footnote)
                    .foregroundStyle(Color.secondaryText)
            }
        }
        .navigationTitle(title)
        .toolbar {
            if showsDoneButton {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            await model.refresh()
            await model.runPolling()
        }
        .refreshable {
            await model.refresh()
        }
        .sheet(item: $signInSheet, onDismiss: {
            Task { await model.refresh() }
        }) { sheet in
            NavigationStack {
                SignInView(store: model.store, reauthenticating: sheet.accountID) {
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

    private func switchTo(_ accountID: UUID, _ companyID: String) {
        do {
            try model.switchTo(accountID: accountID, companyID: companyID)
            errorMessage = nil
        } catch {
            errorMessage = userMessage(for: error)
        }
    }

    private func remove(_ id: UUID) {
        Task {
            do {
                try await model.remove(id)
                errorMessage = nil
            } catch {
                errorMessage = userMessage(for: error)
            }
        }
    }
}

/// The quick switcher, opened from the company button on Today: the companies
/// of every signed-in server. A switch closes the sheet.
@MainActor
struct AccountSwitcherSheet: View {
    let model: AccountsModel
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.sections.filter { !$0.account.needsSignIn }) { section in
                    Section {
                        CompanyRows(model: model, section: section, onSwitch: switchTo)
                    } header: {
                        ServerHeader(name: section.account.server.displayName)
                    } footer: {
                        if let user = section.account.userName ?? section.account.userEmail {
                            SectionTitle(user)
                        }
                    }
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Switch company")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                await model.refresh()
                await model.runPolling()
            }
            .refreshable {
                await model.refresh()
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func switchTo(_ accountID: UUID, _ companyID: String) {
        do {
            try model.switchTo(accountID: accountID, companyID: companyID)
            dismiss()
        } catch {
            errorMessage = userMessage(for: error)
        }
    }
}

/// The company button on Today: "<Company> ▾". Tap or long-press opens the switcher.
struct CompanySwitcherButton: View {
    let companyName: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(companyName ?? "Company")
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .accessibilityHidden(true)
            }
        }
        .simultaneousGesture(LongPressGesture().onEnded { _ in action() })
        .accessibilityShowsLargeContentViewer()
        .accessibilityLabel(companyName.map { "Company: \($0)" } ?? "Company")
        .accessibilityHint("Switches company or server")
    }
}

/// A server's companies (tap to switch), or why there are none.
private struct CompanyRows: View {
    let model: AccountsModel
    let section: AccountSection
    let onSwitch: (UUID, String) -> Void

    var body: some View {
        let accountID = section.account.id
        if let error = section.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.red)
        } else if section.companies.isEmpty, !section.account.needsSignIn, model.isRefreshing {
            ProgressView()
                .frame(maxWidth: .infinity)
        }
        ForEach(section.companies) { company in
            CompanyRow(
                company: company,
                isCurrent: model.isCurrent(accountID: accountID, companyID: company.id),
                badge: model.badge(accountID: accountID, companyID: company.id),
                action: { onSwitch(accountID, company.id) }
            )
        }
    }
}

private struct CompanyRow: View {
    let company: Company
    let isCurrent: Bool
    let badge: Int?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(company.name)
                Spacer()
                if let badge, badge > 0 {
                    Text("\(badge)")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.badge))
                        .accessibilityLabel("\(badge) need you")
                }
                if isCurrent {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityHint(isCurrent ? "" : "Switches to this company")
    }
}

/// A server's host as a section header; VoiceOver reads "Server <host>".
private struct ServerHeader: View {
    let name: String

    var body: some View {
        SectionTitle(name)
            .accessibilityLabel("Server \(name)")
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

/// The user signed in to a server, with the key-expiry warning and "Sign in again".
private struct AccountRow: View {
    let account: Account
    let onSignInAgain: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RowLabel(account.userName ?? account.userEmail ?? "Signed in", systemImage: "person.crop.circle", tintsIcon: false)
                .foregroundStyle(Color.secondaryText)

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
    @Environment(AccountStore.self) private var store
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
                    AccountsView(model: AccountsModel(store: store))
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
