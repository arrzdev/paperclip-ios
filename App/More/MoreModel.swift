import Foundation
import PaperclipAPI

/// A page of the web UI for something the app leaves out ("Open in web"),
/// under the company's prefix: `/<prefix>/…`.
enum WebLink: Hashable {
    case companySettings, secrets, toolConnections, plugins, skills, routines, orgChart, hireAgent
    case agent(urlKey: String)

    /// Everything the app cuts, in the order the More section lists it.
    static let cut: [WebLink] = [
        .companySettings, .secrets, .toolConnections, .plugins, .skills, .routines, .orgChart, .hireAgent,
    ]

    var title: String {
        switch self {
        case .companySettings: "Company settings"
        case .secrets: "Secrets"
        case .toolConnections: "Tool connections"
        case .plugins: "Plugins"
        case .skills: "Skills"
        case .routines: "Routines"
        case .orgChart: "Org chart"
        case .hireAgent: "Hire an agent"
        case .agent: "Agent page"
        }
    }

    var systemImage: String {
        switch self {
        case .companySettings: "building.2"
        case .secrets: "key"
        case .toolConnections: "wrench.and.screwdriver"
        case .plugins: "puzzlepiece.extension"
        case .skills: "graduationcap"
        case .routines: "repeat"
        case .orgChart: "person.3"
        case .hireAgent: "person.badge.plus"
        case .agent: "person.crop.circle"
        }
    }

    func path(prefix: String) -> String {
        switch self {
        case .companySettings: "/\(prefix)/company/settings"
        case .secrets: "/\(prefix)/company/settings/secrets"
        case .toolConnections: "/\(prefix)/company/settings/tools"
        case .plugins: "/\(prefix)/company/settings/instance/plugins"
        case .skills: "/\(prefix)/skills/studio"
        case .routines: "/\(prefix)/routines"
        case .orgChart: "/\(prefix)/org"
        case .hireAgent: "/\(prefix)/agents/new"
        case .agent(let urlKey): "/\(prefix)/agents/\(urlKey)"
        }
    }
}

/// Me → More: the company (for its name and web prefix) and the "Open in
/// web" links. The screens under it build their own models from `store` and
/// `accountID`.
@MainActor
@Observable
final class MoreModel {
    let store: AccountStore
    let accountID: UUID

    private(set) var companyName: String?
    private var prefix: String?

    init(store: AccountStore, accountID: UUID) {
        self.store = store
        self.accountID = accountID
    }

    /// The company; a failure only hides the web links.
    func refresh() async {
        guard let companyId = store.accounts.first(where: { $0.id == accountID })?.selectedCompanyId else { return }
        do {
            let company = try await store.call(accountID) { try await $0.company(id: companyId) }
            companyName = company.name
            prefix = company.issuePrefix
        } catch {
            store.log("More company failed for account \(accountID): \(userMessage(for: error))")
        }
    }

    /// The page on this account's server; nil until the company prefix is known.
    func url(for link: WebLink) -> URL? {
        guard let prefix, !prefix.isEmpty,
              let base = store.accounts.first(where: { $0.id == accountID })?.server.baseURL.absoluteString
        else { return nil }
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        return URL(string: trimmed + link.path(prefix: prefix))
    }
}

/// A 401: `AccountStore.call` already sent the account to sign-in.
func isUnauthorizedError(_ error: Error) -> Bool {
    if case APIError.unauthorized = error { return true }
    return false
}
