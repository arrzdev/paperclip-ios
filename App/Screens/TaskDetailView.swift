import PaperclipAPI
import QuickLook
import SwiftUI
import UIKit

/// One task: title, pickers for status, assignee and priority, description and
/// documents, attachments, the thread oldest first, the review bar and the
/// composer. Refreshed by polling while on screen.
@MainActor
struct TaskDetailView: View {
    @State private var model: TaskDetailModel
    @State private var showsReopen = false
    @State private var previewURL: URL?
    @State private var requestSheet: RequestSheet?
    @Environment(\.openURL) private var openURL
    /// Built once the task is loaded (the upload needs its company).
    @State private var composer: CommentComposer?

    init(store: AccountStore, accountID: UUID, issueID: String) {
        _model = State(initialValue: TaskDetailModel(store: store, accountID: accountID, issueID: issueID))
    }

    var body: some View {
        List {
            if let detail = model.detail {
                header(detail.issue)
                pickers
                texts(detail)
                if !detail.attachments.isEmpty {
                    Section("Attachments") {
                        ForEach(detail.attachments) { attachment in
                            Button {
                                open(attachment)
                            } label: {
                                AttachmentRow(attachment: attachment)
                            }
                        }
                    }
                }
                thread
            }
        }
        .listStyle(.insetGrouped)
        .animation(.default, value: model.threadItems.map(\.id))
        .overlay { overlay }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .refreshable { await model.refresh() }
        .task {
            await model.refresh()
            await model.runPolling()
        }
        .navigationTitle(model.detail?.issue.identifier ?? "Task")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsReopen) {
            ReopenSheet(model: model)
        }
        .quickLookPreview($previewURL)
        .requestSheet($requestSheet, actions: model.requests)
        .sendsPendingRequests(model.requests)
        .onChange(of: model.detail?.issue.id, initial: true) { _, _ in
            makeComposer()
        }
    }

    private func makeComposer() {
        guard composer == nil, let issue = model.detail?.issue else { return }
        let model = model
        composer = CommentComposer(
            store: model.store, accountID: model.accountID, companyID: issue.companyId, issueID: issue.id,
            drafts: FileDraftStore.live(),
            onSent: { comment in
                model.insertComment(comment)
                // A sent photo shows under its comment.
                Task { await model.reloadAttachments() }
            }
        )
    }

    // MARK: Sections

    private func header(_ issue: Issue) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(issue.title)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
                if let text = model.liveRunText {
                    Label(text, systemImage: "bolt.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .symbolEffect(.pulse)
                        .transition(.opacity)
                }
            }
            .padding(.vertical, 2)
            .animation(.default, value: model.liveRunText)
        }
    }

    private var pickers: some View {
        Section {
            Picker("Status", selection: Binding(
                get: { model.status ?? .todo },
                set: { value in Task { await model.setStatus(value) } }
            )) {
                ForEach(statusOptions, id: \.self) { status in
                    Text(status.label).tag(status)
                }
            }
            Picker("Assignee", selection: Binding(
                get: { model.assignee ?? .nobody },
                set: { value in Task { await model.setAssignee(value) } }
            )) {
                ForEach(assigneeOptions, id: \.value) { option in
                    Text(option.title).tag(option.value)
                }
            }
            Picker("Priority", selection: Binding(
                get: { model.priority ?? .medium },
                set: { value in Task { await model.setPriority(value) } }
            )) {
                ForEach(priorityOptions, id: \.self) { priority in
                    Text(priority.label).tag(priority)
                }
            }
        }
        .pickerStyle(.menu)
    }

    @ViewBuilder
    private func texts(_ detail: TaskDetail) -> some View {
        let description = detail.issue.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !description.isEmpty || !detail.documents.isEmpty {
            Section {
                if !description.isEmpty {
                    DisclosureGroup("Description") {
                        MarkdownText(source: description)
                            .padding(.vertical, 4)
                    }
                }
                ForEach(detail.documents) { document in
                    DisclosureGroup {
                        MarkdownText(source: document.body ?? "")
                            .padding(.vertical, 4)
                    } label: {
                        Label(document.title ?? document.key, systemImage: "doc.text")
                    }
                }
            }
        }
    }

    /// Comments and pending requests, oldest first.
    private var thread: some View {
        Section("Thread") {
            let items = model.threadItems
            if items.isEmpty {
                Text("No comments yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                switch item {
                case .comment(let comment):
                    CommentRow(
                        author: model.authorName(for: comment),
                        comment: comment,
                        attachments: model.attachments(for: comment),
                        model: model,
                        onOpen: open
                    )
                case .request(let card):
                    RequestRow(card: card, actions: model.requests, onSheet: { requestSheet = $0 }) {
                        if let url = model.webURL(for: card.webPath) { openURL(url) }
                    }
                }
            }
        }
    }

    /// The action error, the review bar and the composer.
    private var bottomBar: some View {
        VStack(spacing: 8) {
            if let message = model.actionError, !showsReopen {
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
            if model.showsReviewBar {
                ButtonRow(spacing: 12) {
                    Button {
                        model.dismissActionError()
                        showsReopen = true
                    } label: {
                        Label("Re-open", systemImage: "arrow.uturn.backward")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button {
                        Task { await model.markDone() }
                    } label: {
                        Text("Done ✓")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.status == .done)
                }
                .controlSize(.large)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let composer {
                ComposerBar(composer: composer)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background {
            if model.showsReviewBar || composer != nil {
                Rectangle().fill(.bar).ignoresSafeArea()
            }
        }
        .animation(.snappy, value: model.actionError)
        .animation(.snappy, value: model.requests.error)
        .animation(.snappy, value: model.requests.pending)
        .animation(.snappy, value: model.showsReviewBar)
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
                Label("Could not load the task", systemImage: "exclamationmark.triangle")
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

    // MARK: Options

    private var statusOptions: [IssueStatus] {
        let known: [IssueStatus] = [.backlog, .todo, .inProgress, .inReview, .blocked, .done, .cancelled]
        guard let current = model.status, !known.contains(current) else { return known }
        return known + [current]
    }

    private var priorityOptions: [IssuePriority] {
        let known: [IssuePriority] = [.critical, .high, .medium, .low]
        guard let current = model.priority, !known.contains(current) else { return known }
        return known + [current]
    }

    private struct AssigneeOption {
        let value: IssueAssignee
        let title: String
    }

    /// Unassigned, Me, then the company's agents; the current assignee stays
    /// selectable even when it is none of those.
    private var assigneeOptions: [AssigneeOption] {
        var options = [AssigneeOption(value: .nobody, title: "Unassigned")]
        if let me = model.myUserID {
            options.append(AssigneeOption(value: .user(me), title: "Me"))
        }
        options += model.agents.map { AssigneeOption(value: .agent($0.id), title: $0.name) }
        if let current = model.assignee, !options.contains(where: { $0.value == current }) {
            switch current {
            case .agent: options.append(AssigneeOption(value: current, title: "Another agent"))
            case .user: options.append(AssigneeOption(value: current, title: "Another user"))
            case .nobody: break
            }
        }
        return options
    }

    private func open(_ attachment: Attachment) {
        Task {
            if let url = await model.previewFile(for: attachment) {
                previewURL = url
            }
        }
    }
}

// MARK: - Rows

private struct CommentRow: View {
    let author: String
    let comment: IssueComment
    let attachments: [Attachment]
    let model: TaskDetailModel
    let onOpen: (Attachment) -> Void

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
            if !comment.body.isEmpty {
                MarkdownText(source: comment.body)
            }
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments) { attachment in
                            Button {
                                onOpen(attachment)
                            } label: {
                                AttachmentThumbnail(attachment: attachment, model: model)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// A photo sent with a comment, loaded through `attachmentContent`.
private struct AttachmentThumbnail: View {
    let attachment: Attachment
    let model: TaskDetailModel
    @State private var image: UIImage?
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 88

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if attachment.isImage {
                ProgressView()
            } else {
                Image(systemName: "doc")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: 8))
        .accessibilityLabel(attachment.originalFilename ?? "Attachment")
        .task(id: attachment.id) {
            guard attachment.isImage, image == nil, let data = await model.content(of: attachment) else { return }
            image = UIImage(data: data)
        }
    }
}

private struct AttachmentRow: View {
    let attachment: Attachment

    var body: some View {
        AdaptiveRow {
            Label(attachment.originalFilename ?? "Attachment", systemImage: attachment.isImage ? "photo" : "doc")
                .lineLimit(2)
        } trailing: {
            if let size = attachment.byteSize {
                Text(Int64(size), format: .byteCount(style: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Re-open

/// Re-open needs a comment: Send stays disabled while it is blank.
private struct ReopenSheet: View {
    let model: TaskDetailModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var isSending = false
    @FocusState private var isFocused: Bool

    private var isBlank: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 140)
                        .focused($isFocused)
                } footer: {
                    Text("Say what is missing. The task goes back to To do.")
                }
                if let message = model.actionError {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("Re-open")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSending {
                        ProgressView()
                    } else {
                        Button("Send") { send() }
                            .disabled(isBlank)
                    }
                }
            }
            .onAppear { isFocused = true }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(isSending)
    }

    private func send() {
        isSending = true
        Task {
            let reopened = await model.reopen(comment: text)
            isSending = false
            if reopened { dismiss() }
        }
    }
}

// MARK: - Markdown

/// Markdown blocks (headings, lists, code) with inline Markdown in each.
struct MarkdownText: View {
    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownBlock.parse(source).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    Text(Self.inline(text))
                        .font(level == 1 ? .title3.weight(.semibold) : .headline)
                case .paragraph(let text):
                    Text(Self.inline(text))
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        Text(Self.inline(text))
                    }
                case .code(let text):
                    Text(text)
                        .font(.footnote.monospaced())
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: .rect(cornerRadius: 6))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

// MARK: - Labels

extension IssuePriority {
    var label: String {
        switch self {
        case .critical: "Critical"
        case .high: "High"
        case .medium: "Medium"
        case .low: "Low"
        case .unknown(let value): value.capitalized
        }
    }
}

extension Attachment {
    var isImage: Bool {
        contentType?.hasPrefix("image/") ?? false
    }
}
