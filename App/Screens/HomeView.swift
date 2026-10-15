import SwiftUI

/// The signed-in home: Today · Inbox · Tasks · Me.
@MainActor
struct HomeView: View {
    let accountID: UUID

    @Environment(AccountStore.self) private var store
    @State private var selection: AppTab = .today

    var body: some View {
        TabView(selection: $selection) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                NavigationStack {
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
    }

    @ViewBuilder
    private func screen(for tab: AppTab) -> some View {
        switch tab {
        case .today:
            TodayView(store: store, accountID: accountID)
        case .inbox:
            InboxView(store: store, accountID: accountID)
        case .tasks:
            ComingSoonView(tab: tab, message: "The task list comes in a later version.")
        case .me:
            AccountsView(title: tab.title, showsDoneButton: false)
        }
    }
}

/// A tab that has no content yet.
private struct ComingSoonView: View {
    let tab: AppTab
    let message: String

    var body: some View {
        ContentUnavailableView(tab.title, systemImage: tab.systemImage, description: Text(message))
            .navigationTitle(tab.title)
    }
}
