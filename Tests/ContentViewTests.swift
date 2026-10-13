import XCTest
@testable import Paperclip

final class ContentViewTests: XCTestCase {
    func testTitle() {
        XCTAssertEqual(ContentView.title, "Paperclip")
    }
}
