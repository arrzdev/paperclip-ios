import XCTest

/// Today on fixture data: the pulse line, the floating + and the message bar
/// never sit on top of a card, and the last card scrolls above the bar and the
/// tab bar. Checked at the largest accessibility text size and in dark mode,
/// with a screenshot of each state.
@MainActor
final class TodayLayoutUITests: XCTestCase {
    func testTodayLayoutAtLargestText() {
        let app = launch(.largestText)
        let pulse = app.staticTexts["today.pulse"]
        let detail = app.staticTexts["Send the plan to the board?"]
        let title = app.staticTexts["Fixture task"].firstMatch
        let plus = app.buttons["New task"]
        let bar = app.otherElements["today.messageBar"]
        for element in [pulse, detail, title, plus, bar] {
            XCTAssertTrue(element.waitForExistence(timeout: 10), "Missing \(element)")
        }
        keepScreenshot(app, name: "ax5-today-top")

        assertApart(pulse, detail, "The pulse overlaps the request text")
        assertApart(plus, title, "The + covers the task title")
        assertApart(plus, pulse, "The + covers the pulse")
        assertApart(bar, title, "The message bar covers the task title")

        assertLastCardAboveBar(app, bar: bar, plus: plus)
        keepScreenshot(app, name: "ax5-today-end")
    }

    func testTodayLayoutInDarkMode() {
        let app = launch(.dark)
        let pulse = app.staticTexts["today.pulse"]
        let unknown = app.staticTexts["Unknown status from a newer server"].firstMatch
        let bar = app.otherElements["today.messageBar"]
        for element in [pulse, unknown, bar] {
            XCTAssertTrue(element.waitForExistence(timeout: 10), "Missing \(element)")
        }
        keepScreenshot(app, name: "dark-today-top")

        assertApart(pulse, unknown, "The pulse overlaps the task title")
        assertApart(pulse, bar, "The pulse overlaps the message bar")

        assertLastCardAboveBar(app, bar: bar, plus: app.buttons["New task"])
        keepScreenshot(app, name: "dark-today-end")
    }

    // MARK: - Steps

    private func launch(_ variant: ScreenTourUITests.Variant) -> XCUIApplication {
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestFixtures"] + variant.launchArguments
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30), "The signed-in home did not appear")
        return app
    }

    /// Scrolls to the end of the list, then checks that the last row ends
    /// above the message bar and the +, and the bar above the tab bar.
    private func assertLastCardAboveBar(_ app: XCUIApplication, bar: XCUIElement, plus: XCUIElement) {
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10), "No Today list")
        var previous = CGRect.null
        for _ in 0..<15 {
            list.swipeUp()
            let cells = list.cells
            let last = cells.element(boundBy: max(0, cells.count - 1)).frame
            if last == previous { break }
            previous = last
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let cells = list.cells
        XCTAssertGreaterThan(cells.count, 0, "The Today list has no rows")
        let last = cells.element(boundBy: cells.count - 1).frame
        XCTAssertLessThanOrEqual(last.maxY, bar.frame.minY + 0.5, "The message bar covers the last card: \(last) vs \(bar.frame)")
        if plus.exists {
            XCTAssertLessThanOrEqual(last.maxY, plus.frame.minY + 0.5, "The + covers the last card: \(last) vs \(plus.frame)")
        }
        let tabBar = app.tabBars.firstMatch.frame
        XCTAssertLessThanOrEqual(bar.frame.maxY, tabBar.minY + 0.5, "The tab bar covers the message bar: \(bar.frame) vs \(tabBar)")
    }

    private func assertApart(_ first: XCUIElement, _ second: XCUIElement, _ message: String) {
        let a = first.frame
        let b = second.frame
        XCTAssertFalse(a.intersects(b), "\(message): \(a) vs \(b)")
    }

    private func keepScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
