import Foundation

/// The base URL of one Paperclip server, as typed by the user at sign-in.
///
/// The app never ships a default server: every address comes from user input
/// and is normalized here (scheme added, trailing `/` and `/api` removed).
public struct ServerAddress: Hashable, Codable, Sendable {
    public let baseURL: URL

    public enum ValidationError: Error, Equatable, Sendable {
        case empty
        case invalid
        case insecureScheme
    }

    public init(_ input: String) throws {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ValidationError.empty }
        if !text.contains("://") { text = "https://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        if text.lowercased().hasSuffix("/api") { text.removeLast(4) }
        while text.hasSuffix("/") { text.removeLast() }

        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty,
              components.query == nil, components.fragment == nil,
              let url = components.url
        else { throw ValidationError.invalid }

        switch scheme {
        case "https":
            break
        case "http" where Self.isLoopback(host):
            break
        case "http":
            throw ValidationError.insecureScheme
        default:
            throw ValidationError.invalid
        }
        baseURL = url
    }

    /// Stable key for per-server storage (Keychain account, settings entry).
    public var storageKey: String {
        baseURL.absoluteString.lowercased()
    }

    /// Display form without scheme, e.g. `paperclip.example.com`.
    public var displayName: String {
        var text = baseURL.absoluteString
        if let range = text.range(of: "://") { text = String(text[range.upperBound...]) }
        return text
    }

    func apiURL(path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = components.percentEncodedPath + "/api" + path
        components.queryItems = query.isEmpty ? nil : query
        // URLComponents leaves "+" as is; servers read it as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    private static func isLoopback(_ host: String) -> Bool {
        ["localhost", "127.0.0.1", "::1"].contains(host.lowercased())
    }
}
