import XCTest

/// Walks the main screens on fixture data (the app's `-uiTestFixtures` mode:
/// one fake account, no network) at default size, at the largest
/// accessibility text size and in dark mode. Each screen is kept as a
/// screenshot and runs the iOS 17 accessibility audit. Every issue is listed
/// in the screen's "audit" attachment. An issue fails the test unless
/// `AccessibilityBaseline.json` lists its kind for that screen (the kinds
/// already known there; the audit's exact findings vary between runs, so it
/// holds kinds, not counts). Fixing a kind on a screen removes it there; a new
/// kind on a screen fails. Dynamic Type support does not depend on the
/// variant and the audit reports it unevenly between them, so that kind,
/// known for a screen in one variant, is known in all of them. An element
/// partly under the tab bar, the navigation bar or Today's message bar (or
/// off screen) is judged against the bar's glass, not its own background: its
/// contrast issues are listed as "covered" and do not count. Its other issues
/// (clipping, labels, Dynamic Type) count as usual.
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
        // Audit the new tab, not the last frames of the old one.
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10), "\(title) did not open")
    }

    /// Taps the row labelled `title` (scrolling down, then back up, to it) and waits for its screen.
    private func open(_ title: String, in app: XCUIApplication) -> Bool {
        let row = app.buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
        var swipes = 0
        while !(row.exists && row.isHittable), swipes < 24 {
            if swipes < 12 { app.swipeUp() } else { app.swipeDown() }
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
    /// A timed-out audit is retried once.
    private func audit(_ app: XCUIApplication, screen: String) {
        let known = Self.knownKinds(for: screen)
        var lines: [String] = []
        for attempt in 1...2 {
            lines = []
            do {
                let covers = coveringFrames(app)
                let messageBar = messageBarFrame(app)
                let barLabels = barElementLabels(app)
                let screenFrame = app.windows.firstMatch.frame
                try app.performAccessibilityAudit { issue in
                    let kind = issue.compactDescription
                    let label = issue.element.map { "'\($0.label)'" } ?? "no element"
                    if Self.backgroundKinds.contains(kind),
                       let element = issue.element, !barLabels.contains(element.label),
                       Self.isCovered(element.frame, screen: screenFrame, by: covers, keeping: messageBar) {
                        lines.append("covered: \(kind) — \(label)")
                        return true
                    }
                    let isKnown = known.contains(kind)
                    lines.append("\(isKnown ? "known" : "NEW"): \(kind) — \(label)")
                    return isKnown
                }
                break
            } catch {
                if attempt == 2 {
                    XCTFail("Accessibility audit could not run on \(screen): \(error)")
                } else {
                    RunLoop.current.run(until: Date().addingTimeInterval(2))
                }
            }
        }
        let attachment = XCTAttachment(string: lines.isEmpty ? "No issues." : lines.joined(separator: "\n"))
        attachment.name = "\(screen) audit"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The audit's kinds that judge an element against its background (the
    /// last one: it could not tell the background). Only these can be covered.
    static let backgroundKinds: Set<String> = ["Contrast failed", "Contrast nearly passed", "Potentially inaccessible text"]

    /// How far the tab bar's scroll-edge blur reaches into the content
    /// (less than the 16 pt gap above it of the floating +).
    static let edgeEffect: CGFloat = 8

    /// The bars content scrolls under: the tab bar with its edge blur, the
    /// navigation bar, and Today's message bar.
    private func coveringFrames(_ app: XCUIApplication) -> [CGRect] {
        var frames: [CGRect] = []
        let tabBar = app.tabBars.firstMatch
        if tabBar.exists {
            frames.append(tabBar.frame.insetBy(dx: 0, dy: -Self.edgeEffect))
        }
        let navigationBar = app.navigationBars.firstMatch
        if navigationBar.exists {
            frames.append(navigationBar.frame)
        }
        if let messageBar = messageBarFrame(app) {
            frames.append(messageBar)
        }
        return frames
    }

    /// Today's message bar, from just above its text field down; nil elsewhere.
    private func messageBarFrame(_ app: XCUIApplication) -> CGRect? {
        let message = app.textFields.matching(NSPredicate(format: "placeholderValue BEGINSWITH %@", "Message")).firstMatch
        guard message.exists else { return nil }
        let field = message.frame
        let top = field.minY - 16
        return CGRect(x: 0, y: top, width: app.windows.firstMatch.frame.width, height: field.maxY + 16 - top)
    }

    /// Labels (and placeholders) of the navigation and tab bars' own
    /// elements: title, buttons, search field, tabs. Those are judged, never
    /// counted as covered.
    private func barElementLabels(_ app: XCUIApplication) -> Set<String> {
        var labels: Set<String> = []
        for bar in [app.tabBars.firstMatch, app.navigationBars.firstMatch] where bar.exists {
            for element in bar.descendants(matching: .any).allElementsBoundByIndex {
                if !element.label.isEmpty { labels.insert(element.label) }
                if let placeholder = element.placeholderValue, !placeholder.isEmpty { labels.insert(placeholder) }
            }
        }
        return labels
    }

    /// Off screen, or under a bar (or its edge blur), even in part. The
    /// navigation and tab bars' own elements are left out by the caller;
    /// anything inside the message bar is its own and is judged.
    static func isCovered(_ frame: CGRect, screen: CGRect, by covers: [CGRect], keeping messageBar: CGRect?) -> Bool {
        guard !frame.isEmpty else { return false }
        if let messageBar, messageBar.contains(frame) { return false }
        if !screen.isEmpty, !screen.contains(frame) { return true }
        return covers.contains { $0.intersects(frame) }
    }

    /// The audit's kind for text that does not follow the text size.
    static let dynamicTypeKind = "Dynamic Type font sizes are partially unsupported"

    /// The kinds known for `screen` ("<variant> <screen>"): its own, plus
    /// the Dynamic Type kind when any variant of the same screen lists it.
    static func knownKinds(for screen: String) -> Set<String> {
        var known = Set(baseline[screen] ?? [])
        let name = screenName(screen)
        let dynamicTypeKnown = baseline.contains { key, kinds in
            screenName(key) == name && kinds.contains(dynamicTypeKind)
        }
        if dynamicTypeKnown { known.insert(dynamicTypeKind) }
        return known
    }

    /// "Me-Accounts" for "dark Me-Accounts".
    static func screenName(_ screen: String) -> String {
        guard let space = screen.firstIndex(of: " ") else { return screen }
        return String(screen[screen.index(after: space)...])
    }

    /// Known audit issue kinds per screen ("<variant> <screen>").
    static let baseline: [String: [String]] = {
        guard let url = Bundle(for: ScreenTourUITests.self).url(forResource: "AccessibilityBaseline", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let baseline = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { return [:] }
        return baseline
    }()
}
