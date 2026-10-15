import SwiftUI
import Testing
@testable import PaperclipIOS

struct SearchableListTitleTests {
    @Test(arguments: [DynamicTypeSize.xSmall, .large, .xxxLarge])
    func largeTitleUpToTheLargestStandardSize(_ size: DynamicTypeSize) {
        #expect(!SearchableListTitle.isInline(at: size))
    }

    @Test(arguments: [DynamicTypeSize.accessibility1, .accessibility3, .accessibility5])
    func inlineTitleAtAccessibilitySizes(_ size: DynamicTypeSize) {
        #expect(SearchableListTitle.isInline(at: size))
    }
}
