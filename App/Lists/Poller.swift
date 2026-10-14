import Foundation

/// Calls `tick` every `interval` until the surrounding task is cancelled (the
/// screen's `.task` ends when the screen goes away). Tests inject `sleep`.
struct Poller {
    static let interval: Duration = .seconds(15)

    let sleep: @Sendable (Duration) async throws -> Void

    /// Sleeps with `Task.sleep`, which throws when the task is cancelled.
    static let live = Poller(sleep: { try await Task.sleep(for: $0) })

    func run(_ tick: @MainActor () async -> Void) async {
        while !Task.isCancelled {
            do {
                try await sleep(Self.interval)
            } catch {
                return
            }
            await tick()
        }
    }
}
