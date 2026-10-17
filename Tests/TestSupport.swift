import Foundation
import PaperclipAPI
@testable import PaperclipIOS

// MARK: - Stub server

/// A fake Paperclip server for one test, reached through `StubURLProtocol`.
/// Each instance has its own host, so suites can run in parallel.
final class StubServer: @unchecked Sendable {
    struct Response {
        var status: Int = 200
        var body: String = "{}"

        static func ok(_ body: String) -> Response {
            Response(body: body)
        }
    }

    let address: ServerAddress
    private let lock = NSLock()
    private var routes: [String: [Response]] = [:]
    private var queryRoutes: [(key: String, match: [String: String], responses: [Response])] = []
    private var recorded: [URLRequest] = []

    init() {
        let host = "s" + UUID().uuidString.prefix(8).lowercased() + ".paperclip.test"
        address = try! ServerAddress("https://" + host)
        StubURLProtocol.register(self, host: host)
    }

    var host: String {
        address.baseURL.host ?? ""
    }

    /// Responses are served in order; the last one repeats.
    func on(_ method: String, _ path: String, _ responses: [Response]) {
        lock.lock(); defer { lock.unlock() }
        routes[method + " " + path] = responses
    }

    func on(_ method: String, _ path: String, _ responses: Response...) {
        on(method, path, responses)
    }

    /// Like `on`, but only for requests whose query has every `match` item.
    /// The route with the most matching items wins over less specific ones and
    /// over the path-only route.
    func on(_ method: String, _ path: String, query match: [String: String], _ responses: Response...) {
        lock.lock(); defer { lock.unlock() }
        let key = method + " " + path
        queryRoutes.removeAll { $0.key == key && $0.match == match }
        queryRoutes.append((key, match, responses))
    }

    var allRequests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func requests(_ method: String, _ path: String) -> [URLRequest] {
        allRequests.filter { $0.httpMethod == method && $0.url?.path == path }
    }

    func response(for request: URLRequest) -> Response {
        lock.lock(); defer { lock.unlock() }
        recorded.append(request)
        let key = (request.httpMethod ?? "GET") + " " + (request.url?.path ?? "")
        let items = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        let sent = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
        let candidates = queryRoutes.indices.filter { index in
            queryRoutes[index].key == key && queryRoutes[index].match.allSatisfy { sent[$0.key] == $0.value }
        }
        if let index = candidates.max(by: { queryRoutes[$0].match.count < queryRoutes[$1].match.count }),
           let first = queryRoutes[index].responses.first {
            if queryRoutes[index].responses.count > 1 {
                queryRoutes[index].responses.removeFirst()
            }
            return first
        }
        guard var queue = routes[key], let first = queue.first else {
            return Response(status: 404, body: #"{"error":"Not found"}"#)
        }
        if queue.count > 1 {
            queue.removeFirst()
            routes[key] = queue
        }
        return first
    }
}

final class StubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var servers: [String: StubServer] = [:]

    static func register(_ server: StubServer, host: String) {
        lock.lock(); defer { lock.unlock() }
        servers[host] = server
    }

    private static func server(for host: String) -> StubServer? {
        lock.lock(); defer { lock.unlock() }
        return servers[host]
    }

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var recorded = request
        // URLSession moves the body into a stream; keep it readable for assertions.
        if recorded.httpBody == nil, let stream = request.httpBodyStream {
            recorded.httpBody = Self.read(stream)
        }
        guard let server = Self.server(for: request.url?.host ?? "") else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let stub = server.response(for: recorded)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(stub.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

let stubClients: ClientFactory = { server, apiKey in
    APIClient(server: server, apiKey: apiKey, session: StubURLProtocol.session)
}

// MARK: - Recorded responses (2026.1005.0 shapes, scrubbed)

enum JSON {
    static let key = "pcp_board_TEST"
    static let token = "challenge-secret+fixture"
    static let pinnedCommit = "467125fafb47a8520856504fecc48d6e32055db1"

    static let healthOK = #"{"status":"ok","version":"2026.1005.0","commit":"467125fafb47a8520856504fecc48d6e32055db1","deploymentMode":"authenticated"}"#
    static let healthOtherCommit = #"{"status":"ok","version":"2026.1101.0","commit":"9f8e7d6c5b4a","deploymentMode":"authenticated"}"#
    static let healthDegraded = #"{"status":"degraded","commit":"467125f"}"#

    static func challenge(host: String, expiresAt: String) -> String {
        #"{"id":"c1","token":"challenge-secret+fixture","boardApiToken":"pcp_board_TEST","approvalPath":"/cli-auth/c1?token=challenge-secret%2Bfixture","approvalUrl":"https://\#(host)/cli-auth/c1?token=challenge-secret%2Bfixture","pollPath":"/cli-auth/challenges/c1","expiresAt":"\#(expiresAt)","suggestedPollIntervalMs":1000}"#
    }

    static func state(_ status: String, approvedAt: String? = nil) -> String {
        let approved = approvedAt.map { "\"" + $0 + "\"" } ?? "null"
        return #"{"id":"c1","status":"\#(status)","approvedAt":\#(approved),"expiresAt":"2026-10-13T22:31:01.003Z"}"#
    }

    static let approvedAt = "2026-10-13T22:22:10.500Z"
    static let pending = state("pending")
    static let approved = state("approved", approvedAt: approvedAt)

    static let me = #"{"user":{"id":"user-1","name":"Board","email":"board@paperclip.test"},"userId":"user-1","isInstanceAdmin":true,"companyIds":["company-1","company-2"],"memberships":[],"source":"board_key","keyId":"key-1"}"#
    static let companies = #"[{"id":"company-1","name":"Acme","issuePrefix":"ACM","status":"active"},{"id":"company-2","name":"Globex","issuePrefix":"GLX","status":"active"}]"#
    static let oneCompany = #"[{"id":"company-1","name":"Acme","issuePrefix":"ACM","status":"active"}]"#
    static let unauthorized = #"{"error":"Unauthorized"}"#
    static let revoked = #"{"revoked":true}"#
    static let unavailable = #"{"error":"Service unavailable"}"#
    static let invalidToken = #"{"error":"Invalid token"}"#
}

func decodeMe(_ json: String = JSON.me) throws -> CliAuthMe {
    try JSONDecoder().decode(CliAuthMe.self, from: Data(json.utf8))
}

func iso(_ text: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: text)!
}

func jsonObject(_ request: URLRequest) -> [String: Any]? {
    guard let body = request.httpBody else { return nil }
    return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
}

func tempAccountsFile() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("accounts-\(UUID().uuidString).json")
}

/// An accounts file whose folder is a regular file, so every save throws.
func unwritableAccountsFile() -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("accounts-\(UUID().uuidString)")
    try? makeUnwritable(folder)
    return folder.appendingPathComponent("accounts.json")
}

/// Replaces `folder` with a regular file: creating the folder, and so saving into it, then fails.
func makeUnwritable(_ folder: URL) throws {
    if FileManager.default.fileExists(atPath: folder.path) {
        try FileManager.default.removeItem(at: folder)
    }
    try Data().write(to: folder)
}

// MARK: - Fakes

/// In-memory Keychain whose writes can be made to fail.
final class TestCredentialStore: CredentialStore, @unchecked Sendable {
    struct WriteFailed: Error {}

    private let lock = NSLock()
    private var keys: [UUID: String] = [:]
    private var failing = false

    var failsWrites: Bool {
        get { lock.lock(); defer { lock.unlock() }; return failing }
        set { lock.lock(); defer { lock.unlock() }; failing = newValue }
    }

    func apiKey(for account: UUID) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return keys[account]
    }

    func setAPIKey(_ key: String?, for account: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        if failing { throw WriteFailed() }
        keys[account] = key
    }

    var storedKeyCount: Int {
        lock.lock(); defer { lock.unlock() }
        return keys.count
    }
}

/// Captures every log line.
final class LogSink: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var log: AppLog {
        AppLog { self.append($0) }
    }

    var lines: [String] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    private func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(line)
    }
}

/// Set once by an observation `onChange`.
final class ChangeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock(); defer { lock.unlock() }
        value = true
    }
}

/// A clock that moves only when the code under test sleeps.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) {
        current = start
    }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func sleep(_ duration: Duration) async throws {
        let parts = duration.components
        advance(by: Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
        await Task.yield()
    }

    private func advance(by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}

/// The approval page. `.staysOpen` waits for the flow to dismiss it;
/// `.userCloses` returns at once, as when the user closes the sheet.
@MainActor
final class FakeApproval: ApprovalPresenter {
    enum Behavior {
        case staysOpen
        case userCloses
    }

    let behavior: Behavior
    private(set) var presented: [URL] = []
    private(set) var dismissed = false
    private var waiting: CheckedContinuation<Void, Never>?

    init(_ behavior: Behavior) {
        self.behavior = behavior
    }

    func present(_ url: URL) async {
        presented.append(url)
        if behavior == .userCloses || dismissed { return }
        await withCheckedContinuation { continuation in
            MainActor.assumeIsolated { self.waiting = continuation }
        }
    }

    func dismiss() {
        dismissed = true
        waiting?.resume()
        waiting = nil
    }
}

@MainActor
func makeStore(
    file: URL = tempAccountsFile(),
    credentials: InMemoryCredentialStore = InMemoryCredentialStore(),
    log: LogSink = LogSink()
) -> AccountStore {
    AccountStore(fileURL: file, credentials: credentials, makeClient: stubClients, log: log.log)
}
