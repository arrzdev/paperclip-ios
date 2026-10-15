import PaperclipAPI
import SwiftUI

/// Threads the user touched, in three segments, refreshed by polling while on screen.
/// Swipe right marks read / unread, swipe left archives; both can be undone.
/// A row opens Task detail.
@MainActor
struct InboxView: View {
    @State private var model: InboxModel
    private let onNewTask: (() -> Void)?

    init(store: AccountStore, accountID: UUID, onNewTask: (() -> Void)? = nil) {
        _model = State(initialValue: InboxModel(store: store, accountID: accountID))
        self.onNewTask = onNewTask
    }

    var body: some View {
        List {
            // In the list, not pinned above it: a top bar over a list leaves
            // the large title blurred under the scroll-edge effect (iOS 26).
            Picker("Segment", selection: $model.segment) {
                ForEach(InboxSegment.allCases, id: \.self) { segment in
                    Text("\(segment.title) \(model.count(segment))").tag(segment)
                }
            }
            .pickerStyle(.segmented)
            .listRowSeparator(.hidden)
            if case .loaded(let rows) = model.state {
                ForEach(rows) { row in
                    NavigationLink(value: row.route) {
                        InboxRowView(row: row)
                    }
                        .swipeActions(edge: .leading) {
                            Button {
                                Task { await model.toggleRead(row) }
                            } label: {
                                if row.isUnread {
                                    Label("Read", systemImage: "envelope.open")
                                } else {
                                    Label("Unread", systemImage: "envelope.badge")
                                }
                            }
                            .tint(.blue)
                        }
                        .swipeActions(edge: .trailing) {
                            Button {
                                Task { await model.archive(row) }
                            } label: {
                                Label("Archive", systemImage: "archivebox")
                            }
                            .tint(.indigo)
                        }
                }
            }
        }
        .listStyle(.plain)
        .animation(.default, value: model.state)
        .overlay { overlay }
        .newTaskButton(onNewTask)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                if let message = model.actionError {
                    ActionErrorBanner(message: message) { model.dismissActionError() }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if let undo = model.undo {
                    UndoToast(undo: undo) {
                        Task { await model.undoLast() }
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
            .animation(.snappy, value: model.undo)
            .animation(.snappy, value: model.actionError)
        }
        .task(id: model.undo) {
            guard let undo = model.undo else { return }
            let wait = max(0, undo.expiresAt.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(wait))
            model.clearExpiredUndo()
        }
        .searchable(text: $model.searchText, prompt: "Search the inbox")
        .task(id: model.searchText) { await model.search() }
        .refreshable { await model.refresh() }
        .task {
            await model.refresh()
            await model.runPolling()
        }
        .searchableListTitle(AppTab.inbox.title)
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

/// "Marked as read · Undo" at the bottom of a list (Inbox, Today).
struct UndoToast: View {
    let undo: InboxUndo
    let onUndo: () -> Void

    var body: some View {
        HStack {
            Text(undo.action.title)
                .font(.subheadline)
            Spacer()
            Button("Undo", action: onUndo)
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: .capsule)
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
    }
}

/// Why a swipe action was rolled back.
struct ActionErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(.footnote)
            Spacer(minLength: 0)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
            }
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
    }
}

private struct InboxRowView: View {
    let row: InboxRow
    @ScaledMetric(relativeTo: .caption) private var dotSize: CGFloat = 8

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle()
                .fill(.tint)
                .frame(width: dotSize, height: dotSize)
                .opacity(row.isUnread ? 1 : 0)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                AdaptiveRow {
                    Text(row.issue.identifier ?? "")
                        .font(.caption.monospaced())
                        .foregroundStyle(Color.secondaryText)
                } trailing: {
                    Text(row.issue.lastActivityAt ?? row.issue.updatedAt, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(Color.secondaryText)
                }
                Text(row.issue.title)
                    .font(row.isUnread ? .body.weight(.semibold) : .body)
                    .lineLimit(2)
                Text(row.issue.status.label)
                    .font(.caption)
                    .foregroundStyle(Color.secondaryText)
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
