import PaperclipAPI
import SwiftUI

/// The company's tasks by project, with status and assignee pickers and a
/// server search. Pages of 50 with a "Load more" row. A row opens Task detail.
/// A look-up screen: refreshed on appear, on a filter change and by pull to
/// refresh, never polled.
@MainActor
struct TasksView: View {
    @State private var model: TasksModel
    private let onNewTask: (() -> Void)?

    init(store: AccountStore, accountID: UUID, onNewTask: (() -> Void)? = nil) {
        _model = State(initialValue: TasksModel(store: store, accountID: accountID))
        self.onNewTask = onNewTask
    }

    var body: some View {
        List {
            // In the list, not pinned above it: a top bar over a list leaves
            // the large title blurred under the scroll-edge effect (iOS 26).
            Section {
                filterBar
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            if case .loaded(let sections) = model.state {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.issues, id: \.id) { issue in
                            NavigationLink(value: TaskRoute(issueID: issue.id)) {
                                TaskRowView(issue: issue)
                            }
                        }
                    } header: {
                        SectionTitle(section.title)
                    }
                }
                if model.hasMore {
                    Section {
                        loadMoreRow
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .animation(.default, value: model.state)
        .overlay { overlay }
        .newTaskButton(onNewTask)
        // Always shown: a list scrolled a little leaves the hiding drawer
        // a sliver too small to tap.
        .searchable(text: $model.searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search tasks")
        .task(id: model.searchText) { await model.search() }
        .refreshable { await model.refresh() }
        .task(id: Filters(status: model.status, assignee: model.assignee)) {
            // Runs on appear and again on every filter change, cancelling the older fetch.
            await model.refresh()
        }
        .navigationTitle(AppTab.tasks.title)
    }

    private struct Filters: Equatable {
        let status: TaskStatusFilter
        let assignee: TaskAssigneeFilter
    }

    /// Side by side, or stacked when large text does not fit.
    private var filterBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                filterPickers
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 0) {
                filterPickers
            }
        }
        .pickerStyle(.menu)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var filterPickers: some View {
        Picker("Status", selection: $model.status) {
            ForEach(TaskStatusFilter.allCases, id: \.self) { filter in
                Text(filter.title).tag(filter)
            }
        }
        Picker("Assignee", selection: $model.assignee) {
            ForEach(model.assigneeOptions, id: \.self) { option in
                Text(model.assigneeTitle(option)).tag(option)
            }
        }
    }

    private var loadMoreRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                Task { await model.loadMore() }
            } label: {
                HStack {
                    Text(model.pageError == nil ? "Load more" : "Try again")
                    Spacer()
                    if model.isLoadingMore {
                        ProgressView()
                    }
                }
            }
            .disabled(model.isLoadingMore)
            if let message = model.pageError {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Color.secondaryText)
            }
        }
    }

    @ViewBuilder
    private var overlay: some View {
        switch model.state {
        case .loading:
            ProgressView()
        case .loaded:
            EmptyView()
        case .empty:
            if model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView(
                    "No tasks", systemImage: "checklist",
                    description: Text("No task matches these filters.")
                )
            } else {
                ContentUnavailableView.search(text: model.searchText)
            }
        case .error(let message):
            ContentUnavailableView {
                Label("Could not load the tasks", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") {
                    Task { await model.refresh() }
                }
            }
        case .needsSignIn:
            ContentUnavailableView(
                "Sign in again",
                systemImage: "person.crop.circle.badge.exclamationmark",
                description: Text("The server rejected the key for this account.")
            )
        }
    }
}

private struct TaskRowView: View {
    let issue: Issue

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            AdaptiveRow {
                Text(issue.identifier ?? "")
                    .font(.caption.monospaced())
                    .foregroundStyle(Color.secondaryText)
            } trailing: {
                Text(issue.status.label)
                    .font(.caption)
                    .foregroundStyle(Color.secondaryText)
            }
            Text(issue.title)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
