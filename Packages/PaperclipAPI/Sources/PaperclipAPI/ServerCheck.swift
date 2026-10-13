import Foundation

/// The Paperclip release this client is built and tested against.
public enum PaperclipPin {
    public static let version = "2026.1005.0"
    public static let commit = "467125f"
}

/// Result of checking a typed server URL with `GET /api/health`.
public enum ServerCheck: Equatable, Sendable {
    /// Healthy and running the pinned commit.
    case ok(commit: String)
    /// Healthy but on another commit (or no commit reported): the app warns and lets the user continue.
    case versionMismatch(serverCommit: String?)
    /// Reachable but `status` is not `ok`.
    case unhealthy(status: String)

    public init(health: Health) {
        guard health.status == "ok" else {
            self = .unhealthy(status: health.status)
            return
        }
        if let commit = health.commit, Self.matchesPin(commit) {
            self = .ok(commit: commit)
        } else {
            self = .versionMismatch(serverCommit: health.commit)
        }
    }

    public var canSignIn: Bool {
        if case .unhealthy = self { return false }
        return true
    }

    /// Short or full SHA, compared on the shorter length.
    static func matchesPin(_ commit: String, pin: String = PaperclipPin.commit) -> Bool {
        let a = commit.lowercased(), b = pin.lowercased()
        let length = min(a.count, b.count)
        guard length >= 7 else { return false }
        return a.prefix(length) == b.prefix(length)
    }
}

public extension APIClient {
    func checkServer() async throws -> ServerCheck {
        ServerCheck(health: try await health())
    }
}
