import XCTest
@testable import PaperclipIOS

final class ContentViewTests: XCTestCase {
    func testTitle() {
        XCTAssertEqual(ContentView.title, "Paperclip")
    }

    func testShowsPinnedServerVersion() {
        XCTAssertEqual(ContentView.pinLabel, "Paperclip 2026.1005.0 (467125f)")
    }
}
