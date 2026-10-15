import XCTest

/// Walks the main screens on fixture data (the app's `-uiTestFixtures` mode:
/// one fake account, no network) at default size, at the largest
/// accessibility text size and in dark mode. Each screen is kept as a
/// screenshot and runs the iOS 17 accessibility audit; an audit issue fails
/// the test, except issues inside the system tab bar and navigation bar,
/// which are listed in the "audit" attachment but not counted.
@MainActor
final class ScreenTourUITests: XCTestCase {
    func testDefaultSize() {
        tour(.standard)
    }

    func testLargestAccessibilityText() {
        tour(.largestText)
    }

    func testDarkMode() {
        tour(.dark)
    }

    // MARK: - Tour

    enum Variant: String {
        case standard = "default"
        case largestText = "ax5"
        case dark

        var launchArguments: [String] {
            switch self {
            case .standard:
                []
            case .largestText:
                ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
            case .dark:
                ["-uiTestDark"]
            }
        }
    }

    static let moreScreens = ["Agents", "Activity", "Approvals", "Goals", "Costs"]

    private func tour(_ variant: Variant) {
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestFixtures"] + variant.launchArguments
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30), "The signed-in home did not appear")

        var step = 0
        func check(_ screen: String) {
            step += 1
            waitUntilLoaded(app)
            keepScreenshot(app, name: "\(variant.rawValue)-\(step < 10 ? "0" : "")\(step)-\(screen)")
            audit(app, screen: "\(variant.rawValue) \(screen)")
        }

        check("Today")
        openTab("Inbox", in: app)
        check("Inbox")
        openTab("Tasks", in: app)
        check("Tasks")
        openTab("Me", in: app)
        check("Me-Accounts")
        for screen in Self.moreScreens {
            guard open(screen, in: app) else { continue }
            check("Me-More-\(screen)")
            goBack(app)
        }
    }

    // MARK: - Steps

    private func openTab(_ title: String, in app: XCUIApplication) {
        let button = app.tabBars.buttons[title]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "No \(title) tab")
        button.tap()
    }

    /// Taps the row labelled `title` (scrolling down to it) and waits for its screen.
    private func open(_ title: String, in app: XCUIApplication) -> Bool {
        let row = app.buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
        var swipes = 0
        while !(row.exists && row.isHittable), swipes < 12 {
            app.swipeUp()
            swipes += 1
        }
        guard row.exists, row.isHittable else {
            XCTFail("No \(title) row on the Me tab")
            return false
        }
        row.tap()
        let opened = app.navigationBars[title].waitForExistence(timeout: 10)
        XCTAssertTrue(opened, "\(title) did not open")
        return opened
    }

    private func goBack(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists { back.tap() }
    }

    /// Waits until no spinner shows (at most 10 s), then a short settle for animations.
    private func waitUntilLoaded(_ app: XCUIApplication) {
        let spinners = app.activityIndicators
        let deadline = Date().addingTimeInterval(10)
        while spinners.count > 0, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }

    // MARK: - Evidence

    private func keepScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Runs the accessibility audit; every issue goes into a text attachment.
    private func audit(_ app: XCUIApplication, screen: String) {
        let bars = [app.tabBars.firstMatch, app.navigationBars.firstMatch]
        let chrome: [CGRect] = bars.filter { $0.exists }.map { $0.frame }
        var lines: [String] = []
        do {
            try app.performAccessibilityAudit { issue in
                let element = issue.element
                let label = element.map { "'\($0.label)'" } ?? "no element"
                let inChrome = element.map { element in
                    element.exists && chrome.contains { $0.contains(element.frame) }
                } ?? false
                lines.append("\(inChrome ? "ignored (system bar)" : "FAILED"): \(issue.compactDescription) — \(label)")
                return inChrome
            }
        } catch {
            XCTFail("Accessibility audit could not run on \(screen): \(error)")
        }
        let text = lines.isEmpty ? "No issues." : lines.joined(separator: "\n")
        let attachment = XCTAttachment(string: text)
        attachment.name = "\(screen) audit"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
