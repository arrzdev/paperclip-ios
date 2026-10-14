import PaperclipAPI
import SwiftUI

/// Threads the user touched, in three segments, refreshed by polling while on screen.
@MainActor
struct InboxView: View {
    @State private var model: InboxModel

    init(store: AccountStore, accountID: UUID) {
        _model = State(initialValue: InboxModel(store: store, accountID: accountID))
    }

    var body: some View {
        List {
            if case .loaded(let rows) = model.state {
                ForEach(rows) { row in
                    InboxRowView(row: row)
                }
            }
        }
        .listStyle(.plain)
        .overlay { overlay }
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("Segment", selection: $model.segment) {
                ForEach(InboxSegment.allCases, id: \.self) { segment in
                    Text("\(segment.title) \(model.count(segment))").tag(segment)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .searchable(text: $model.searchText, prompt: "Title or ID")
        .refreshable { await model.refresh() }
        .task {
            await model.refresh()
            await model.runPolling()
        }
        .navigationTitle(AppTab.inbox.title)
    }

    @ViewBuilder
    private var overlay: some View {
        switch model.state {
        case .loading:
            ProgressView()
        case .loaded:
            EmptyView()
        case .empty:
            if model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: "tray", description: Text(emptyMessage))
            } else {
                ContentUnavailableView.search(text: model.searchText)
            }
        case .error(let message):
            ContentUnavailableView {
                Label("Could not load the inbox", systemImage: "exclamationmark.triangle")
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

    private var emptyTitle: String {
        switch model.segment {
        case .unread: "All caught up"
        case .mine: "Nothing of yours"
        case .all: "No threads"
        }
    }

    private var emptyMessage: String {
        switch model.segment {
        case .unread: "No thread has news for you."
        case .mine: "No thread is assigned to you or created by you."
        case .all: "Threads you take part in show up here."
        }
    }
}

private struct InboxRowView: View {
    let row: InboxRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle()
                .fill(.tint)
                .frame(width: 8, height: 8)
                .opacity(row.isUnread ? 1 : 0)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(row.issue.identifier ?? "")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(row.issue.lastActivityAt ?? row.issue.updatedAt, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(row.issue.title)
                    .font(row.isUnread ? .body.weight(.semibold) : .body)
                    .lineLimit(2)
                Text(row.issue.status.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityValue(row.isUnread ? "Unread" : "")
    }
}

extension IssueStatus {
    /// Short label for lists.
    var label: String {
        switch self {
        case .backlog: "Backlog"
        case .todo: "To do"
        case .inProgress: "In progress"
        case .inReview: "In review"
        case .done: "Done"
        case .blocked: "Blocked"
        case .cancelled: "Cancelled"
        case .unknown(let value): value.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
