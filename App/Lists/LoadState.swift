import Foundation

/// What a list screen shows. Every call goes through `AccountStore.call`, so a
/// 401 becomes `needsSignIn` (and the account goes to sign-in).
enum LoadState<Value: Equatable>: Equatable {
    case loading
    case loaded(Value)
    /// Loaded, but nothing to show (for the current filter).
    case empty
    /// User-facing text; never contains a key.
    case error(String)
    case needsSignIn
}
