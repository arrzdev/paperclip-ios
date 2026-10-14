import Testing
@testable import PaperclipIOS

/// Descriptions, documents and comments render their Markdown blocks.
struct MarkdownBlockTests {
    @Test func headingsParagraphsBulletsAndCode() {
        let source = """
        # Spec

        Hello **world**,
        second line.
        - one
        * two
        ```
          let x = 1
        ```
        ## Next
        """
        #expect(MarkdownBlock.parse(source) == [
            .heading(level: 1, text: "Spec"),
            .paragraph("Hello **world**,\nsecond line."),
            .bullet("one"),
            .bullet("two"),
            .code("  let x = 1"),
            .heading(level: 2, text: "Next"),
        ])
    }

    @Test func hashWithoutASpaceIsText() {
        #expect(MarkdownBlock.parse("#hashtag") == [.paragraph("#hashtag")])
        #expect(MarkdownBlock.parse("") == [])
    }

    @Test func unclosedFenceStillShowsTheCode() {
        #expect(MarkdownBlock.parse("```\nlet x = 1") == [.code("let x = 1")])
    }
}
