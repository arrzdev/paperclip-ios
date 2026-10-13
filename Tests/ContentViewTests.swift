import XCTest
@testable import PaperclipIOS

final class ContentViewTests: XCTestCase {
    func testTitle() {
        XCTAssertEqual(ContentView.title, "Paperclip")
    }
}
