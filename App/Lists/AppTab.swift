import Foundation

/// The tab bar of the home screen. Task detail is a pushed screen, not a tab.
enum AppTab: CaseIterable {
    case today, inbox, tasks, me

    var title: String {
        switch self {
        case .today: "Today"
        case .inbox: "Inbox"
        case .tasks: "Tasks"
        case .me: "Me"
        }
    }

    var systemImage: String {
        switch self {
        case .today: "sun.max"
        case .inbox: "tray"
        case .tasks: "checklist"
        case .me: "person.crop.circle"
        }
    }
}
