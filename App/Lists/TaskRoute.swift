import Foundation

/// The one way to open Task detail: every list pushes this value and each
/// tab's `NavigationStack` has a `.navigationDestination(for: TaskRoute.self)`.
struct TaskRoute: Hashable {
    let issueID: String
}

extension InboxRow {
    var route: TaskRoute { TaskRoute(issueID: issue.id) }
}

extension ReplyRow {
    var route: TaskRoute { TaskRoute(issueID: issue.id) }
}

extension NeedsYouCard {
    /// Nil when the card has no issue (an approval on its own).
    var route: TaskRoute? { issueID.map(TaskRoute.init(issueID:)) }
}
