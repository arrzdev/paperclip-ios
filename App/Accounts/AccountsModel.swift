import Foundation
import PaperclipAPI

/// One server in Me → Accounts: its account (user, key state) and companies.
struct AccountSection: Equatable, Identifiable {
    let account: Account
    /// Empty while loading, when the list failed and when the account needs sign-in.
    let companies: [Company]
    /// User-facing text when the company list failed; never contains a key.
    let errorMessage: String?

    var id: UUID { account.id }
}

/// Me → Accounts and the quick switcher: every server with its user and
/// companies, and a "Needs you" badge per account and company
/// (`SidebarBadges.inbox`). Each server is asked with its own key through
/// `AccountStore.call`, so a 401 marks only that account; an account that
/// needs sign-in is never called.
@MainActor
@Observable
final class AccountsModel {
    let store: AccountStore
    private let poller: Poller

    private(set) var sections: [AccountSection] = []
    private(set) var isRefreshing = false

    private var companies: [UUID: [Company]] = [:]
    private var errors: [UUID: String] = [:]
    private var badges: [UUID: [String: Int]] = [:]

    init(store: AccountStore, poller: Poller = .live) {
        self.store = store
        self.poller = poller
    }

    /// The "Needs you" count, nil until loaded or when the account needs sign-in.
    func badge(accountID: UUID, companyID: String) -> Int? {
        guard isSignedIn(accountID) else { return nil }
        return badges[accountID]?[companyID]
    }

    func isCurrent(accountID: UUID, companyID: String) -> Bool {
        store.currentAccountID == accountID && store.currentAccount?.selectedCompanyId == companyID
    }

    /// The current account's selected company, once its list is loaded.
    var currentCompany: Company? {
        guard let account = store.currentAccount, let companyID = account.selectedCompanyId else { return nil }
        return companies[account.id]?.first { $0.id == companyID }
    }

    /// Companies and badges of every signed-in account.
    func refresh() async {
        isRefreshing = true
        rebuild()
        for account in store.accounts where !account.needsSignIn {
            await loadCompanies(account.id)
        }
        isRefreshing = false
        rebuild()
    }

    /// Badges only; a failed badge keeps the last count.
    func poll() async {
        for account in store.accounts where !account.needsSignIn {
            await loadBadges(account.id)
        }
        rebuild()
    }

    /// Polls every `Poller.interval` until the calling task is cancelled.
    func runPolling() async {
        await poller.run { await self.poll() }
    }

    /// Selects the company for that account, then the account (both persisted).
    func switchTo(accountID: UUID, companyID: String) throws {
        defer { rebuild() }
        try store.selectCompany(companyID, for: accountID)
        try store.select(accountID)
    }

    /// Revokes and deletes the key; the server stays in the list to sign in again.
    func signOut(_ id: UUID) async {
        await store.signOut(id)
        rebuild()
    }

    func remove(_ id: UUID) async throws {
        defer { rebuild() }
        try await store.remove(id)
    }

    // MARK: - Private

    private func isSignedIn(_ id: UUID) -> Bool {
        store.accounts.contains { $0.id == id && !$0.needsSignIn }
    }

    private func loadCompanies(_ id: UUID) async {
        do {
            companies[id] = try await store.call(id) { try await $0.companies() }
            errors[id] = nil
        } catch {
            companies[id] = nil
            if case APIError.unauthorized = error {
                errors[id] = nil
            } else {
                let message = userMessage(for: error)
                errors[id] = message
                store.log("Account \(id): company list failed: \(message)")
            }
            return
        }
        await loadBadges(id)
    }

    private func loadBadges(_ id: UUID) async {
        for company in companies[id] ?? [] {
            // A 401 on an earlier company signed the account out: stop calling it.
            guard isSignedIn(id) else { return }
            do {
                let result = try await store.call(id) { try await $0.sidebarBadges(companyId: company.id) }
                // Same count: no write, so the list is not redrawn every poll.
                if badges[id]?[company.id] != result.inbox {
                    badges[id, default: [:]][company.id] = result.inbox
                }
            } catch {
                store.log("Account \(id): badge failed for company \(company.id)")
            }
        }
    }

    /// Sections from `store.accounts`; forgets what belongs to removed or signed-out accounts.
    /// Writes only what changed: every write redraws the list.
    private func rebuild() {
        let signedIn = Set(store.accounts.filter { !$0.needsSignIn }.map(\.id))
        let keptCompanies = companies.filter { signedIn.contains($0.key) }
        if keptCompanies != companies { companies = keptCompanies }
        let keptErrors = errors.filter { signedIn.contains($0.key) }
        if keptErrors != errors { errors = keptErrors }
        let keptBadges = badges.filter { signedIn.contains($0.key) }
        if keptBadges != badges { badges = keptBadges }
        let newSections = store.accounts.map { account in
            AccountSection(
                account: account,
                companies: companies[account.id] ?? [],
                errorMessage: errors[account.id]
            )
        }
        if newSections != sections { sections = newSections }
    }
}
