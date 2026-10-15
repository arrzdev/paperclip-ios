import Foundation

/// The pause after the last keystroke before a search goes to the server. The
/// view runs the search from `.task(id: searchText)`, so a new keystroke
/// cancels the wait. Tests inject `sleep`.
struct SearchDebounce {
    static let delay: Duration = .milliseconds(300)

    let sleep: @Sendable (Duration) async throws -> Void

    /// Sleeps with `Task.sleep`, which throws when the task is cancelled.
    static let live = SearchDebounce(sleep: { try await Task.sleep(for: $0) })

    /// The text to send as `q`: trimmed, nil when blank.
    static func term(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// True once the pause has passed; false when the task was cancelled.
    func wait() async -> Bool {
        do {
            try await sleep(Self.delay)
        } catch {
            return false
        }
        return !Task.isCancelled
    }
}
