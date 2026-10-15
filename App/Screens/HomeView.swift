import SwiftUI

/// The signed-in home: Today · Inbox · Tasks · Me. Owns one `NewTaskModel`
/// for the account's company, shared by the New task sheet (floating + on
/// Today, Inbox and Tasks) and the Today message bar. A created task opens in
/// the current tab. `ContentView` keys it by account and company, so a switch
/// builds a new one: Today reloads and the Today tab is selected.
@MainActor
struct HomeView: View {
    let store: AccountStore
    let accountID: UUID

    /// Me → Accounts and the quick switcher opened from the Today title.
    @State private var accounts: AccountsModel
    @State private var showsSwitcher = false
    @State private var selection: AppTab = .today
    @State private var paths: [AppTab: NavigationPath] = [:]
    @State private var newTask: NewTaskModel?
    @State private var showsNewTask = false

    init(store: AccountStore, accountID: UUID) {
        self.store = store
        self.accountID = accountID
        _accounts = State(initialValue: AccountsModel(store: store))
    }

    var body: some View {
        TabView(selection: $selection) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                NavigationStack(path: path(for: tab)) {
                    screen(for: tab)
                        .navigationDestination(for: TaskRoute.self) { route in
                            TaskDetailView(store: store, accountID: accountID, issueID: route.issueID)
                        }
                        .navigationDestination(for: ApprovalRoute.self) { route in
                            ApprovalDetailView(store: store, accountID: accountID, approvalID: route.approvalID)
                        }
                }
                .tabItem { Label(tab.title, systemImage: tab.systemImage) }
                .tag(tab)
            }
        }
        .sheet(isPresented: $showsNewTask) {
            if let newTask {
                NewTaskSheet(model: newTask)
            }
        }
        .task(id: companyID) {
            await makeNewTask()
        }
        .task {
            // The company name for the Today title.
            await accounts.refresh()
        }
        .onChange(of: newTask?.createdIssue?.id) { _, issueID in
            guard let issueID else { return }
            showsNewTask = false
            paths[selection, default: NavigationPath()].append(TaskRoute(issueID: issueID))
            newTask?.openedCreatedIssue()
        }
        .onChange(of: newTask?.needsSignIn) { _, needsSignIn in
            // `AccountStore.call` already sent the account to sign-in; close the sheet on the way.
            if needsSignIn == true { showsNewTask = false }
        }
    }

    @ViewBuilder
    private func screen(for tab: AppTab) -> some View {
        switch tab {
        case .today:
            TodayView(store: store, accountID: accountID, newTask: newTask, onNewTask: openNewTask)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        CompanySwitcherButton(companyName: accounts.currentCompany?.name) {
                            showsSwitcher = true
                        }
                    }
                }
                .sheet(isPresented: $showsSwitcher) {
                    AccountSwitcherSheet(model: accounts)
                }
        case .inbox:
            InboxView(store: store, accountID: accountID, onNewTask: openNewTask)
        case .tasks:
            TasksView(store: store, accountID: accountID, onNewTask: openNewTask)
        case .me:
            AccountsView(model: accounts, title: tab.title, showsDoneButton: false)
        }
    }

    private var companyID: String? {
        store.accounts.first { $0.id == accountID }?.selectedCompanyId
    }

    /// Nil until the model exists, so the + shows only when it can work.
    private var openNewTask: (() -> Void)? {
        guard newTask != nil else { return nil }
        return { showsNewTask = true }
    }

    private func path(for tab: AppTab) -> Binding<NavigationPath> {
        Binding(
            get: { paths[tab] ?? NavigationPath() },
            set: { paths[tab] = $0 }
        )
    }

    /// One model per company: a company switch builds a new one with that company's draft.
    private func makeNewTask() async {
        guard let companyID else {
            newTask = nil
            return
        }
        if newTask?.companyID != companyID {
            newTask = NewTaskModel(
                store: store, accountID: accountID, companyID: companyID,
                drafts: FileDraftStore.live(), defaults: FileDefaultAssigneeStore.live()
            )
        }
        await newTask?.load()
    }
}
