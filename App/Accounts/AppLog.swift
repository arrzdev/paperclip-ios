import Foundation
import os

/// The app's one log path. A message must never contain an API key or a
/// device-flow token; tests capture every line to prove it.
struct AppLog: Sendable {
    let write: @Sendable (String) -> Void

    init(_ write: @escaping @Sendable (String) -> Void) {
        self.write = write
    }

    func callAsFunction(_ message: String) {
        write(message)
    }

    static let system = AppLog { message in
        Logger(subsystem: "dev.tudu.paperclip", category: "app").info("\(message, privacy: .public)")
    }
}
