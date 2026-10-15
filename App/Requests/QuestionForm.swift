import Foundation
import PaperclipAPI

/// The answers to an `ask_user_questions` request while the user fills the
/// form: options picked per question and the text of a free-text option or
/// "other". `answers` is what `POST …/respond` sends.
struct QuestionForm: Equatable {
    let questions: [InteractionQuestion]
    private var selections: [String: Set<String>] = [:]
    private var texts: [String: String] = [:]

    init(questions: [InteractionQuestion]) {
        self.questions = questions
    }

    func isSelected(_ optionID: String, in questionID: String) -> Bool {
        selections[questionID]?.contains(optionID) ?? false
    }

    /// Single choice: the option replaces the others and clears the text
    /// (unless it is the free-text option). Multi choice: toggles the option.
    mutating func select(_ optionID: String, in questionID: String) {
        guard let question = question(questionID),
              let option = question.options.first(where: { $0.id == optionID }) else { return }
        switch question.selectionMode {
        case .multi:
            var selected = selections[questionID] ?? []
            if selected.contains(optionID) {
                selected.remove(optionID)
            } else {
                selected.insert(optionID)
            }
            selections[questionID] = selected
        case .single, .unknown:
            selections[questionID] = [optionID]
            if option.freeText != true { texts[questionID] = "" }
        }
    }

    func text(for questionID: String) -> String {
        texts[questionID] ?? ""
    }

    /// In a single choice, text replaces the option picked.
    mutating func setText(_ text: String, for questionID: String) {
        guard let question = question(questionID) else { return }
        texts[questionID] = text
        if question.selectionMode != .multi, !trimmed(text).isEmpty {
            selections[questionID] = []
        }
    }

    /// A free-text option or "other" shows a text field.
    func showsTextField(_ question: InteractionQuestion) -> Bool {
        question.allowOther == true || question.options.contains { $0.freeText == true }
    }

    /// Required questions without an answer, in order.
    var missingQuestionIDs: [String] {
        let answered = Set(answers.map(\.questionId))
        return questions.filter { $0.required == true && !answered.contains($0.id) }.map(\.id)
    }

    var isValid: Bool {
        missingQuestionIDs.isEmpty
    }

    /// One answer per answered question, in question order. Option ids follow
    /// the question's order; the trimmed text goes as `otherText`, with the
    /// free-text option when the question has one.
    var answers: [InteractionAnswer] {
        questions.compactMap { question -> InteractionAnswer? in
            let typed = showsTextField(question) ? trimmed(self.text(for: question.id)) : ""
            let selected = selections[question.id] ?? []
            let optionIDs = question.options.filter { option in
                option.freeText == true ? !typed.isEmpty : selected.contains(option.id)
            }.map(\.id)
            guard !optionIDs.isEmpty || !typed.isEmpty else { return nil }
            return InteractionAnswer(questionId: question.id, optionIds: optionIDs, otherText: typed.isEmpty ? nil : typed)
        }
    }

    private func question(_ id: String) -> InteractionQuestion? {
        questions.first { $0.id == id }
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
