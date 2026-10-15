import PaperclipAPI
import SwiftUI

/// One approval: title, requester, status, the payload summary, the comments
/// oldest first, a comment field and the decision buttons. Each decision opens
/// a sheet with an optional note.
@MainActor
struct ApprovalDetailView: View {
    @State private var model: ApprovalDetailModel
    @State private var decision: ApprovalDecision?
    @State private var comment = ""
    @State private var isSendingComment = false
    @FocusState private var isCommentFocused: Bool

    init(store: AccountStore, accountID: UUID, approvalID: String) {
        _model = State(initialValue: ApprovalDetailModel(store: store, accountID: accountID, approvalID: approvalID))
    }

    var body: some View {
        List {
            if let detail = model.detail {
                header(detail.approval)
                if !detail.approval.summaryFields.isEmpty {
                    Section("Summary") {
                        ForEach(detail.approval.summaryFields, id: \.label) { field in
                            LabeledContent(field.label) {
                                Text(field.value)
                                    .multilineTextAlignment(.trailing)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                if let note = detail.approval.decisionNote, !note.isEmpty {
                    Section("Decision note") {
                        Text(note)
                            .textSelection(.enabled)
                    }
                }
                Section("Comments") {
                    if detail.comments.isEmpty {
                        Text("No comments yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(detail.comments) { comment in
                        ApprovalCommentRow(author: model.authorName(for: comment), comment: comment)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .animation(.default, value: model.detail)
        .overlay { overlay }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .refreshable { await model.refresh() }
        .task { await model.refresh() }
        .navigationTitle("Approval")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: Binding(
            get: { decision != nil },
            set: { if !$0 { decision = nil } }
        )) {
            if let decision {
                DecisionSheet(decision: decision, model: model)
            }
        }
    }

    private func header(_ approval: Approval) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(approval.title)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
                if let requester = model.requesterName {
                    Text("Requested by \(requester) · \(approval.createdAt, format: .relative(presentation: .named))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Label(approval.status.label, systemImage: approval.status.systemImage)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tint)
            }
            .padding(.vertical, 2)
        }
    }

    /// The action error, the decision buttons and the comment field.
    private var bottomBar: some View {
        VStack(spacing: 8) {
            if let message = model.actionError, decision == nil {
                ActionErrorBanner(message: message) { model.dismissActionError() }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if !model.availableDecisions.isEmpty {
                ButtonRow {
                    ForEach(model.availableDecisions, id: \.self) { option in
                        decisionButton(option)
                    }
                }
                .controlSize(.large)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if model.detail != nil {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Comment", text: $comment, axis: .vertical)
                        .lineLimit(1...5)
                        .focused($isCommentFocused)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.background, in: .rect(cornerRadius: 18))
                    Button {
                        sendComment()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title)
                    }
                    .disabled(isSendingComment || comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Send comment")
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background {
            if model.detail != nil {
                Rectangle().fill(.bar).ignoresSafeArea()
            }
        }
        .animation(.snappy, value: model.actionError)
        .animation(.snappy, value: model.availableDecisions)
    }

    @ViewBuilder
    private func decisionButton(_ option: ApprovalDecision) -> some View {
        let button = Button {
            model.dismissActionError()
            decision = option
        } label: {
            Text(option.title)
                .frame(maxWidth: .infinity)
        }
        switch option {
        case .approve: button.buttonStyle(.borderedProminent)
        case .reject: button.buttonStyle(.bordered).tint(.red)
        case .requestRevision: button.buttonStyle(.bordered)
        }
    }

    private func sendComment() {
        isSendingComment = true
        Task {
            if await model.addComment(comment) {
                comment = ""
                isCommentFocused = false
            }
            isSendingComment = false
        }
    }

    @ViewBuilder
    private var overlay: some View {
        switch model.state {
        case .loading:
            ProgressView()
        case .loaded, .empty:
            EmptyView()
        case .error(let message):
            ContentUnavailableView {
                Label("Could not load the approval", systemImage: "exclamationmark.triangle")
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

private struct ApprovalCommentRow: View {
    let author: String
    let comment: ApprovalComment

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AdaptiveRow {
                Text(author)
                    .font(.subheadline.weight(.semibold))
            } trailing: {
                Text(comment.createdAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            MarkdownText(source: comment.body)
        }
        .padding(.vertical, 4)
    }
}

/// Approve, Reject or Ask for changes with an optional note. Stays open on
/// error so the note is not lost; the note is never logged.
@MainActor
private struct DecisionSheet: View {
    let decision: ApprovalDecision
    let model: ApprovalDetailModel
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var isSending = false
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                if let title = model.detail?.approval.title {
                    Section {
                        Text(title)
                            .font(.headline)
                    }
                }
                Section {
                    TextField("Note (optional)", text: $note, axis: .vertical)
                        .lineLimit(3...8)
                        .focused($isFocused)
                } footer: {
                    Text("The requester reads it if you add one.")
                }
                if let message = model.actionError {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(decision.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(decision.title) { send() }
                        .disabled(isSending)
                }
            }
            .onAppear { isFocused = true }
        }
        .presentationDetents([.medium, .large])
    }

    private func send() {
        isSending = true
        Task {
            if await model.decide(decision, note: note) { dismiss() }
            isSending = false
        }
    }
}

extension ApprovalStatus {
    var label: String {
        switch self {
        case .pending: "Pending"
        case .revisionRequested: "Changes asked"
        case .approved: "Approved"
        case .rejected: "Rejected"
        case .cancelled: "Cancelled"
        case .unknown(let value): value.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    var systemImage: String {
        switch self {
        case .pending: "hourglass"
        case .revisionRequested: "arrow.uturn.backward"
        case .approved: "checkmark.seal"
        case .rejected: "xmark.seal"
        case .cancelled, .unknown: "minus.circle"
        }
    }
}
