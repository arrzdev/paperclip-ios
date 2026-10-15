import PaperclipAPI
import SwiftUI

/// What needs me now: "Needs you" cards, "New replies" and the pulse line,
/// refreshed by polling while on screen. Open and a reply row push Task detail;
/// a card without a task opens the web UI. Replies swipe like the Inbox: right
/// marks read, left archives. The pulse is the list's first row, so it scrolls
/// with the cards and never sits on top of one. The bottom bar gives a new task
/// to the default assignee; the + beside it opens the New task sheet. Both sit
/// in the bottom safe area, so the list ends above them and they never cover a
/// card; from the accessibility text sizes up they grow no further than AX1.
@MainActor
struct TodayView: View {
    @State private var model: TodayModel
    @State private var requestSheet: RequestSheet?
    @Environment(\.openURL) private var openURL
    /// The "Message <name>…" bar; nil until the account's company is known.
    private let newTask: NewTaskModel?
    private let onNewTask: (() -> Void)?

    init(store: AccountStore, accountID: UUID, newTask: NewTaskModel? = nil, onNewTask: (() -> Void)? = nil) {
        _model = State(initialValue: TodayModel(store: store, accountID: accountID))
        self.newTask = newTask
        self.onNewTask = onNewTask
    }

    var body: some View {
        List {
            if let pulse = model.pulse {
                Section {
                    Text(pulse.text)
                        .font(.footnote)
                        .foregroundStyle(Color.secondaryText)
                        .monospacedDigit()
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .accessibilityIdentifier("today.pulse")
                }
                .transition(.opacity)
            }
            if case .loaded(let content) = model.state {
                if !content.needsYou.isEmpty {
                    Section {
                        ForEach(content.needsYou) { card in
                            NeedsYouCardView(
                                card: card, actions: model.requests,
                                onSheet: { requestSheet = $0 },
                                onOpen: { open($0) }
                            )
                        }
                    } header: {
                        SectionHeader(title: "Needs you", count: content.needsYou.count)
                    }
                }
                if !content.newReplies.isEmpty {
                    Section {
                        ForEach(content.newReplies) { row in
                            NavigationLink(value: row.route) {
                                ReplyRowView(row: row)
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    Task { await model.markRead(row) }
                                } label: {
                                    Label("Read", systemImage: "envelope.open")
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
                    } header: {
                        SectionHeader(title: "New replies", count: content.newReplies.count)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .animation(.default, value: model.state)
        .animation(.default, value: model.pulse)
        .requestSheet($requestSheet, actions: model.requests)
        .sendsPendingRequests(model.requests)
        .overlay { overlay }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                if let message = model.actionError {
                    ActionErrorBanner(message: message) { model.dismissActionError() }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if let message = model.requests.error {
                    ActionErrorBanner(message: message) { model.requests.dismissError() }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if let pending = model.requests.pending {
                    RequestUndoToast(pending: pending) { model.requests.undo() }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if let undo = model.undo {
                    UndoToast(undo: undo) {
                        Task { await model.undoLast() }
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if newTask != nil || onNewTask != nil {
                    HStack(alignment: .bottom, spacing: 8) {
                        if let newTask {
                            MessageBar(model: newTask)
                                .accessibilityElement(children: .contain)
                                .accessibilityIdentifier("today.messageBar")
                        } else {
                            Spacer()
                        }
                        if let onNewTask {
                            NewTaskFloatingButton(action: onNewTask)
                        }
                    }
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
            .animation(.snappy, value: model.undo)
            .animation(.snappy, value: model.actionError)
            .animation(.snappy, value: model.requests.error)
            .animation(.snappy, value: model.requests.pending)
        }
        .task(id: model.undo) {
            guard let undo = model.undo else { return }
            let wait = max(0, undo.expiresAt.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(wait))
            model.clearExpiredUndo()
        }
        .refreshable { await model.refresh() }
        .task {
            await model.refresh()
            await model.runPolling()
        }
        .navigationTitle(AppTab.today.title)
    }

    @ViewBuilder
    private var overlay: some View {
        switch model.state {
        case .loading:
            ProgressView()
        case .loaded:
            EmptyView()
        case .empty:
            ContentUnavailableView(TodayModel.emptyMessage, systemImage: "checkmark.circle")
        case .error(let message):
            ContentUnavailableView {
                Label("Could not load Today", systemImage: "exclamationmark.triangle")
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

    private func open(_ path: String?) {
        if let url = model.webURL(for: path) { openURL(url) }
    }
}

private struct SectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Text("\(count)")
                .monospacedDigit()
        }
        .foregroundStyle(Color.secondaryText)
        .accessibilityElement(children: .combine)
    }
}

private struct NeedsYouCardView: View {
    let card: NeedsYouCard
    let actions: RequestActions
    let onSheet: (RequestSheet) -> Void
    /// Opens a web path on the account's server.
    let onOpen: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AdaptiveRow {
                Label(card.kind.title, systemImage: card.kind.systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
            } trailing: {
                if let identifier = card.identifier {
                    Text(identifier)
                        .font(.caption.monospaced())
                        .foregroundStyle(Color.secondaryText)
                }
            }
            Text(card.title)
                .font(.body.weight(.semibold))
                .lineLimit(2)
            if let detail = card.detail, !detail.isEmpty {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(Color.secondaryText)
                    .lineLimit(3)
            }
            ButtonRow {
                if let request = card.request {
                    RequestButtons(card: request, actions: actions, onSheet: onSheet) { onOpen(request.webPath) }
                }
                if let route = card.route {
                    NavigationLink("Open", value: route)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else if let route = card.approvalRoute {
                    NavigationLink("Open", value: route)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else if card.webPath != nil {
                    Button("Open") { onOpen(card.webPath) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }
}

private struct ReplyRowView: View {
    let row: ReplyRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            AdaptiveRow {
                Text(row.issue.identifier ?? "")
                    .font(.caption.monospaced())
                    .foregroundStyle(Color.secondaryText)
            } trailing: {
                Text(row.issue.lastExternalCommentAt ?? row.issue.updatedAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(Color.secondaryText)
            }
            Text(row.issue.title)
                .font(.body.weight(.semibold))
                .lineLimit(2)
            if let preview = row.preview {
                Text(preview)
                    .font(.subheadline)
                    .foregroundStyle(Color.secondaryText)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

private extension NeedsYouCard.Kind {
    var title: String {
        switch self {
        case .interaction: "Request"
        case .approval: "Approval"
        case .review: "Review"
        case .assignedTask: "Your task"
        }
    }

    var systemImage: String {
        switch self {
        case .interaction: "questionmark.bubble"
        case .approval: "checkmark.seal"
        case .review: "eye"
        case .assignedTask: "person.crop.circle"
        }
    }
}
