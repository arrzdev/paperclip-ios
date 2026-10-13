import Foundation
import PaperclipAPI

/// One Paperclip server the user signed in to. Stored as JSON in Application
/// Support; the API key is never part of it (it lives in the Keychain under `id`).
struct Account: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var server: ServerAddress
    var userId: String?
    var userName: String?
    var userEmail: String?
    var companyIds: [String]
    var selectedCompanyId: String?
    /// Counted from the approval time: the server does not report it.
    var keyExpiresAt: Date?
    /// Set on a 401, on sign-out and when the key is missing from the Keychain.
    var needsSignIn: Bool

    /// Board keys from the CLI device flow last 30 days by default.
    static let keyLifetime: TimeInterval = 30 * 24 * 60 * 60
    /// The account list warns this long before the key expires.
    static let expiryWarning: TimeInterval = 3 * 24 * 60 * 60

    enum KeyStatus: Equatable {
        case valid
        /// Expires within `expiryWarning`: show a warning and offer sign-in again.
        case expiresSoon(Date)
        case expired
        case needsSignIn
    }

    func keyStatus(now: Date) -> KeyStatus {
        // TODO: needsSignIn first, then expired (expiresAt <= now), then
        // expiresSoon (expiresAt - now <= expiryWarning), else valid.
        .valid
    }
}
