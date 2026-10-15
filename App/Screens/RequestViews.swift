import PaperclipAPI
import SwiftUI

/// The sheet a request button opens. Owned by the screen, not the row, so the
/// row can leave the list (the card hides at once) while the sheet closes.
enum RequestSheet: Identifiable {
    case reject(InteractionCard)
    case answer(InteractionCard, [InteractionQuestion])

    var id: String {
        switch self {
        case .reject(let card): "reject-\(card.id)"
        case .answer(let card, _): "answer-\(card.id)"
        }
    }
}

/// Accept / Reject, Answer or Open in web for one request card.
@MainActor
struct RequestButtons: View {
    let card: InteractionCard
    let actions: RequestActions
    let onSheet: (RequestSheet) -> Void
    let onOpenInWeb: () -> Void

    var body: some View {
        ButtonRow {
            switch card.action {
            case .confirm(let acceptLabel, let rejectLabel, _):
                Button(acceptLabel) {
                    Task { await actions.accept(card) }
                }
                .buttonStyle(.borderedProminent)
                Button(rejectLabel) {
                    onSheet(.reject(card))
                }
                .buttonStyle(.bordered)
            case .answer(let questions):
                Button("Answer") {
                    onSheet(.answer(card, questions))
                }
                .buttonStyle(.borderedProminent)
            case .openInWeb:
                Button(action: onOpenInWeb) {
                    Label("Open in web", systemImage: "safari")
                }
                .buttonStyle(.bordered)
                .disabled(card.webPath == nil)
            }
        }
        .controlSize(.small)
    }
}

/// A pending request in the Task detail thread.
@MainActor
struct RequestRow: View {
    let card: InteractionCard
    let actions: RequestActions
    let onSheet: (RequestSheet) -> Void
    let onOpenInWeb: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AdaptiveRow {
                Label("Request", systemImage: "questionmark.bubble")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
            } trailing: {
                Text(card.createdAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(Color.secondaryText)
            }
            if let prompt = card.prompt {
                Text(prompt)
                    .font(.body.weight(.semibold))
                    .textSelection(.enabled)
            }
            if case .answer(let questions) = card.action {
                Text(questions.count == 1 ? "1 question" : "\(questions.count) questions")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondaryText)
            }
            if let details = card.details {
                DisclosureGroup("Details") {
                    MarkdownText(source: details)
                        .padding(.vertical, 4)
                }
                .font(.subheadline)
            }
            RequestButtons(card: card, actions: actions, onSheet: onSheet, onOpenInWeb: onOpenInWeb)
        }
        .padding(.vertical, 4)
    }
}

/// Reject with an optional reason; Reject stays disabled while a required
/// reason is blank.
@MainActor
struct RejectRequestSheet: View {
    let card: InteractionCard
    let actions: RequestActions
    @Environment(\.dismiss) private var dismiss
    @State private var reason = ""
    @FocusState private var isFocused: Bool

    private var rejectLabel: String {
        if case .confirm(_, let label, _) = card.action { return label }
        return "Reject"
    }

    private var isRequired: Bool {
        if case .confirm(_, _, let required) = card.action { return required }
        return false
    }

    private var canSend: Bool {
        !isRequired || !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                if let prompt = card.prompt {
                    Section {
                        Text(prompt)
                    }
                }
                Section {
                    TextField(isRequired ? "Reason" : "Reason (optional)", text: $reason, axis: .vertical)
                        .lineLimit(3...8)
                        .focused($isFocused)
                } footer: {
                    Text(isRequired ? "Say why. The agent reads it." : "The agent reads it if you add one.")
                }
            }
            .navigationTitle(rejectLabel)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(rejectLabel) { send() }
                        .disabled(!canSend)
                }
            }
            .onAppear { isFocused = true }
        }
        .presentationDetents([.medium, .large])
    }

    private func send() {
        Task {
            if await actions.reject(card, reason: reason) { dismiss() }
        }
    }
}

/// The native form for `ask_user_questions`: a picker for a single choice,
/// toggles for several, a text field for free text or "other". Send stays
/// disabled until every required question has an answer.
@MainActor
struct AnswerRequestSheet: View {
    let card: InteractionCard
    let actions: RequestActions
    @Environment(\.dismiss) private var dismiss
    @State private var form: QuestionForm

    init(card: InteractionCard, questions: [InteractionQuestion], actions: RequestActions) {
        self.card = card
        self.actions = actions
        _form = State(initialValue: QuestionForm(questions: questions))
    }

    var body: some View {
        NavigationStack {
            Form {
                if let prompt = card.prompt {
                    Section {
                        Text(prompt)
                            .font(.headline)
                    }
                }
                ForEach(form.questions, id: \.id) { question in
                    Section {
                        if question.selectionMode == .multi {
                            toggles(question)
                        } else {
                            picker(question)
                        }
                        if form.showsTextField(question) {
                            TextField(textFieldLabel(question), text: Binding(
                                get: { form.text(for: question.id) },
                                set: { form.setText($0, for: question.id) }
                            ), axis: .vertical)
                            .lineLimit(1...5)
                        }
                    } header: {
                        Text(question.required == true ? "\(question.prompt) *" : question.prompt)
                            .textCase(nil)
                    } footer: {
                        if let help = question.helpText {
                            Text(help)
                        }
                    }
                }
            }
            .navigationTitle("Answer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { send() }
                        .disabled(!form.isValid)
                }
            }
        }
    }

    private func choices(_ question: InteractionQuestion) -> [QuestionOption] {
        question.options.filter { $0.freeText != true }
    }

    @ViewBuilder
    private func picker(_ question: InteractionQuestion) -> some View {
        let options = choices(question)
        if !options.isEmpty {
            Picker(question.prompt, selection: Binding<String?>(
                get: { options.first { form.isSelected($0.id, in: question.id) }?.id },
                set: { id in
                    if let id { form.select(id, in: question.id) }
                }
            )) {
                ForEach(options, id: \.id) { option in
                    OptionLabel(option: option).tag(Optional(option.id))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }

    private func toggles(_ question: InteractionQuestion) -> some View {
        ForEach(choices(question), id: \.id) { option in
            Toggle(isOn: Binding(
                get: { form.isSelected(option.id, in: question.id) },
                set: { _ in form.select(option.id, in: question.id) }
            )) {
                OptionLabel(option: option)
            }
        }
    }

    private func textFieldLabel(_ question: InteractionQuestion) -> String {
        question.options.first { $0.freeText == true }?.label ?? "Other"
    }

    private func send() {
        Task {
            if await actions.answer(card, form: form) { dismiss() }
        }
    }
}

private struct OptionLabel: View {
    let option: QuestionOption

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(option.label)
            if let description = option.description, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(Color.secondaryText)
            }
        }
    }
}

/// "Accepted · Undo" while the answer waits to be sent.
@MainActor
struct RequestUndoToast: View {
    let pending: PendingRequest
    let onUndo: () -> Void

    var body: some View {
        HStack {
            Text(pending.toastText)
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

@MainActor
extension View {
    /// Presents the reject or answer sheet of the screen's request cards.
    func requestSheet(_ sheet: Binding<RequestSheet?>, actions: RequestActions) -> some View {
        self.sheet(item: sheet) { item in
            switch item {
            case .reject(let card):
                RejectRequestSheet(card: card, actions: actions)
            case .answer(let card, let questions):
                AnswerRequestSheet(card: card, questions: questions, actions: actions)
            }
        }
    }

    /// Sends the pending answer when its 5 s toast ends or the screen goes away.
    func sendsPendingRequests(_ actions: RequestActions) -> some View {
        self
            .task(id: actions.pending) { await actions.runUndoTimer() }
            .onDisappear { Task { await actions.sendPending() } }
    }
}
