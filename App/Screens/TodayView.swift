import PaperclipAPI
import SwiftUI

/// What needs me now: "Needs you" cards, "New replies" and the pulse line,
/// refreshed by polling while on screen. Open goes to the web UI until task
/// detail exists. Replies swipe like the Inbox: right marks read, left archives.
@MainActor
struct TodayView: View {
    @State private var model: TodayModel
    @Environment(\.openURL) private var openURL

    init(store: AccountStore, accountID: UUID) {
        _model = State(initialValue: TodayModel(store: store, accountID: accountID))
    }

    var body: some View {
        List {
            if case .loaded(let content) = model.state {
                if !content.needsYou.isEmpty {
                    Section {
                        ForEach(content.needsYou) { card in
                            NeedsYouCardView(card: card) { open(card.webPath) }
                        }
                    } header: {
                        SectionHeader(title: "Needs you", count: content.needsYou.count)
                    }
                }
                if !content.newReplies.isEmpty {
                    Section {
                        ForEach(content.newReplies) { row in
                            Button {
                                open(webPath(identifier: row.issue.identifier))
                            } label: {
                                ReplyRowView(row: row)
                            }
                            .buttonStyle(.plain)
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
        .overlay { overlay }
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
                if let pulse = model.pulse {
                    Text(pulse.text)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
            .animation(.snappy, value: model.undo)
            .animation(.snappy, value: model.actionError)
            .animation(.default, value: model.pulse)
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
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct NeedsYouCardView: View {
    let card: NeedsYouCard
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label(card.kind.title, systemImage: card.kind.systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                Spacer()
                if let identifier = card.identifier {
                    Text(identifier)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            Text(card.title)
                .font(.body.weight(.semibold))
                .lineLimit(2)
            if let detail = card.detail, !detail.isEmpty {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            if card.webPath != nil {
                Button("Open", action: onOpen)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ReplyRowView: View {
    let row: ReplyRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.issue.identifier ?? "")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(row.issue.lastExternalCommentAt ?? row.issue.updatedAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(row.issue.title)
                .font(.body.weight(.semibold))
                .lineLimit(2)
            if let preview = row.preview {
                Text(preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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
