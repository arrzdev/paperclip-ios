import Foundation
import PaperclipAPI
import Testing
@testable import PaperclipIOS

/// The native form behind **Answer** (spec §4 A.3): a picker for a single
/// choice, toggles for several, a text field for free text, and the answers
/// `POST …/respond` sends.
@MainActor
struct QuestionFormTests {
    /// Which store (single, required), which languages (multi, optional), app
    /// name (free text, required), anything else (single, optional, allows other).
    static let questionsJSON = #"""
    [{"id":"q-store","prompt":"Which store first?","selectionMode":"single","required":true,
      "options":[{"id":"o-ios","label":"App Store"},{"id":"o-android","label":"Google Play"}]},
     {"id":"q-langs","prompt":"Which languages?","selectionMode":"multi","required":false,
      "options":[{"id":"o-en","label":"English"},{"id":"o-pt","label":"Portuguese"}]},
     {"id":"q-name","prompt":"App name?","selectionMode":"single","required":true,
      "options":[{"id":"o-name","label":"Name","freeText":true}]},
     {"id":"q-notes","prompt":"Anything else?","selectionMode":"single","required":false,"allowOther":true,
      "options":[{"id":"o-none","label":"Nothing"}]}]
    """#

    private func form() throws -> QuestionForm {
        let questions = try JSONDecoder().decode([InteractionQuestion].self, from: Data(Self.questionsJSON.utf8))
        return QuestionForm(questions: questions)
    }

    @Test func aNewFormMissesTheRequiredQuestions() throws {
        let form = try form()
        #expect(form.missingQuestionIDs == ["q-store", "q-name"])
        #expect(!form.isValid)
        #expect(form.answers.isEmpty)
    }

    @Test func aSingleChoiceKeepsOnlyTheLastOption() throws {
        var form = try form()
        form.select("o-ios", in: "q-store")
        form.select("o-android", in: "q-store")
        #expect(form.isSelected("o-android", in: "q-store"))
        #expect(!form.isSelected("o-ios", in: "q-store"))
    }

    @Test func aMultiChoiceTogglesEachOption() throws {
        var form = try form()
        form.select("o-en", in: "q-langs")
        form.select("o-pt", in: "q-langs")
        form.select("o-en", in: "q-langs")
        #expect(!form.isSelected("o-en", in: "q-langs"))
        #expect(form.isSelected("o-pt", in: "q-langs"))
    }

    @Test func aFreeTextQuestionNeedsText() throws {
        var form = try form()
        form.select("o-ios", in: "q-store")
        form.setText("   ", for: "q-name")
        #expect(form.missingQuestionIDs == ["q-name"])

        form.setText("Paperclip", for: "q-name")
        #expect(form.text(for: "q-name") == "Paperclip")
        #expect(form.missingQuestionIDs.isEmpty)
        #expect(form.isValid)
    }

    @Test func answersHaveOneEntryPerAnsweredQuestionInOrder() throws {
        var form = try form()
        form.select("o-ios", in: "q-store")
        form.select("o-pt", in: "q-langs")
        form.select("o-en", in: "q-langs")
        form.setText("  Paperclip ", for: "q-name")

        // The unanswered optional question is not sent; text is trimmed and
        // goes with the free-text option.
        #expect(form.answers == [
            InteractionAnswer(questionId: "q-store", optionIds: ["o-ios"]),
            InteractionAnswer(questionId: "q-langs", optionIds: ["o-en", "o-pt"]),
            InteractionAnswer(questionId: "q-name", optionIds: ["o-name"], otherText: "Paperclip"),
        ])
    }

    @Test func otherTextReplacesTheOptionOfASingleChoice() throws {
        var form = try form()
        form.select("o-none", in: "q-notes")
        form.setText("Ship on Friday", for: "q-notes")
        #expect(!form.isSelected("o-none", in: "q-notes"))
        #expect(form.answers.last == InteractionAnswer(questionId: "q-notes", optionIds: [], otherText: "Ship on Friday"))

        // Picking the option again clears the text.
        form.select("o-none", in: "q-notes")
        #expect(form.text(for: "q-notes") == "")
        #expect(form.answers.last == InteractionAnswer(questionId: "q-notes", optionIds: ["o-none"]))
    }

    @Test func onlyQuestionsWithAFreeTextOptionOrOtherShowATextField() throws {
        let form = try form()
        #expect(form.questions.map(form.showsTextField) == [false, false, true, true])
    }
}
