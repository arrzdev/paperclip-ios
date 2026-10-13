import Foundation
import PaperclipAPI

/// User-facing text for an error from the API or the account store. The API
/// client already redacts the key it sent; callers that know other secrets
/// (the device-flow token) redact the result again.
func userMessage(for error: Error) -> String {
    switch error {
    case APIError.unauthorized:
        return "The server rejected the key. Sign in again."
    case APIError.notFound:
        return "The server does not know this request. Is it a Paperclip server?"
    case APIError.server(let status, let body):
        if let body, !body.isEmpty { return "Server error \(status): \(body)" }
        return "Server error \(status)."
    case APIError.decoding:
        return "The server sent an unexpected answer. Is it a Paperclip server?"
    case APIError.transport(let message):
        return "Could not reach the server: \(message)"
    case AccountStoreError.unknownAccount:
        return "This account no longer exists."
    default:
        return "Something went wrong: \(error.localizedDescription)"
    }
}
