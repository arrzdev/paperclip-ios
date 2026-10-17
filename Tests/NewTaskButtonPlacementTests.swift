import SwiftUI
import Testing
@testable import PaperclipIOS

struct NewTaskButtonPlacementTests {
    @Test(arguments: [DynamicTypeSize.xSmall, .large, .xxxLarge])
    func floatsUpToTheLargestStandardSize(_ size: DynamicTypeSize) {
        #expect(NewTaskButtonPlacement.at(size) == .floating)
    }

    @Test(arguments: [DynamicTypeSize.accessibility1, .accessibility3, .accessibility5])
    func inTheNavigationBarAtAccessibilitySizes(_ size: DynamicTypeSize) {
        #expect(NewTaskButtonPlacement.at(size) == .navigationBar)
    }
}
