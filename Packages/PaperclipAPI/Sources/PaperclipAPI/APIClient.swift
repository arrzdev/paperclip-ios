import Foundation

public enum APIError: Error, Equatable, Sendable {
    /// 401: the board API key is missing, expired or revoked. Send the user to
    /// sign-in for this server; never retry with the same key.
    case unauthorized
    case notFound
    /// Any other non-2xx response, with the server's `error` message when present.
    case server(status: Int, body: String?)
    case decoding(String)
    case transport(String)
}

/// HTTP client for one Paperclip server. Requests carry the board API key as a
/// bearer token when one is set.
public struct APIClient: Sendable {
    public let server: ServerAddress
    public let apiKey: String?
    private let session: URLSession

    public init(server: ServerAddress, apiKey: String? = nil, session: URLSession = .shared) {
        self.server = server
        self.apiKey = apiKey
        self.session = session
    }

    /// The same server with another key (after sign-in or sign-out).
    public func with(apiKey: String?) -> APIClient {
        APIClient(server: server, apiKey: apiKey, session: session)
    }

    // MARK: - Request plumbing

    enum Method: String {
        case get = "GET", post = "POST", patch = "PATCH", delete = "DELETE"
    }

    struct Empty: Decodable {}

    func request(
        _ method: Method,
        _ path: String,
        query: [URLQueryItem] = [],
        body: (any Encodable)? = nil,
        accept: String = "application/json"
    ) async throws -> Data {
        var request = URLRequest(url: server.apiURL(path: path, query: query))
        request.httpMethod = method.rawValue
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try PaperclipDate.encoder.encode(body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.transport(redact(error.localizedDescription, query: query))
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError.transport("Not an HTTP response")
        }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401:
            throw APIError.unauthorized
        case 404:
            throw APIError.notFound
        default:
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
            throw APIError.server(status: http.statusCode, body: message.map { redact($0, query: query) })
        }
    }

    func send<T: Decodable>(
        _ method: Method,
        _ path: String,
        query: [URLQueryItem] = [],
        body: (any Encodable)? = nil,
        as type: T.Type = T.self
    ) async throws -> T {
        let data = try await request(method, path, query: query, body: body)
        do {
            return try PaperclipDate.decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(redact("\(method.rawValue) \(path): \(error)", query: query))
        }
    }

    /// Removes the API key and the device-flow token from text that goes into an
    /// `APIError`, in case a server or the system echoes them back.
    func redact(_ text: String, query: [URLQueryItem]) -> String {
        let secrets = ([apiKey] + query.filter { $0.name == "token" }.map(\.value)).compactMap { $0 }
        var text = text
        for secret in secrets where !secret.isEmpty {
            text = text.replacingOccurrences(of: secret, with: "<redacted>")
            if let encoded = secret.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
                text = text.replacingOccurrences(of: encoded, with: "<redacted>")
            }
        }
        return text
    }

    private struct ErrorBody: Decodable {
        let error: String?
    }
}

/// Encodes a path segment (issue ids, document keys) so it cannot change the route.
func segment(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? value
}
