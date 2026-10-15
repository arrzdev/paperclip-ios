#if DEBUG
import Foundation
import PaperclipAPI

/// UI-test mode, Debug builds only: launched with `-uiTestFixtures`, the app
/// is signed in to one fake account on `paperclip.test` and every request is
/// answered from the recorded fixtures bundled as `Fixtures/` (no network).
/// `-uiTestDark` forces dark mode.
enum FixtureMode {
    static let argument = "-uiTestFixtures"
    static let darkArgument = "-uiTestDark"
    static let apiKey = "pcp_board_TEST"

    static var isOn: Bool {
        ProcessInfo.processInfo.arguments.contains(argument)
    }

    static var prefersDark: Bool {
        isOn && ProcessInfo.processInfo.arguments.contains(darkArgument)
    }

    /// A store with a fresh accounts file, keys in memory, the fake account
    /// signed in with its first company selected.
    @MainActor
    static func makeStore() -> AccountStore {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("uitest-accounts-\(UUID().uuidString).json")
        let store = AccountStore(
            fileURL: fileURL,
            credentials: InMemoryCredentialStore(),
            makeClient: { server, apiKey in APIClient(server: server, apiKey: apiKey, session: FixtureMode.session) }
        )
        do {
            let me = try JSONDecoder().decode(CliAuthMe.self, from: FixtureRoutes.data(named: "cli-auth-me"))
            let account = try store.saveSignIn(
                server: try ServerAddress("paperclip.test"), me: me, apiKey: Self.apiKey, approvedAt: Date()
            )
            try store.selectCompany(me.companyIds.first, for: account.id)
        } catch {
            store.log("UI-test mode: could not sign in the fake account: \(error)")
        }
        return store
    }

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        return URLSession(configuration: configuration)
    }()
}

/// What the fixture server answers for one request.
enum FixtureRoute: Equatable {
    /// A fixture file, by name without `.json`.
    case file(String)
    /// The first element of a list fixture (one company out of `companies`).
    case first(String)
    /// A single-object fixture wrapped in a list (`comment` as a thread).
    case list(String)
    /// Literal JSON.
    case json(String)
    case notFound
}

enum FixtureRoutes {
    /// Maps a request to a fixture. Paths may start with `/api`.
    static func route(method: String, path: String, query: [String: String]) -> FixtureRoute {
        var parts = path.split(separator: "/").map(String.init)
        if parts.first == "api" { parts.removeFirst() }

        if method != "GET" {
            if parts.count == 3, parts[0] == "agents", parts[2] == "pause" { return .file("agent-paused") }
            if parts.count == 3, parts[0] == "agents", parts[2] == "resume" { return .file("agent") }
            return .json("{}")
        }

        switch parts.count {
        case 1:
            if parts[0] == "health" { return .file("health") }
            if parts[0] == "companies" { return .file("companies") }
        case 2:
            switch parts[0] {
            case "cli-auth" where parts[1] == "me": return .file("cli-auth-me")
            case "companies": return .first("companies")
            case "issues": return .file("issue")
            case "agents": return .file("agent")
            case "approvals": return .file("approval")
            default: break
            }
        case 3:
            switch (parts[0], parts[2]) {
            case ("companies", "sidebar-badges"): return .file("sidebar-badges")
            case ("companies", "attention"): return .file("attention")
            case ("companies", "dashboard"): return .file("dashboard")
            case ("companies", "agents"): return .file("agents")
            case ("companies", "live-runs"): return .file("company-live-runs")
            case ("companies", "activity"): return .file("activity")
            case ("companies", "goals"): return .file("goals")
            case ("companies", "projects"): return .file("projects")
            case ("companies", "approvals"): return .file("approvals")
            case ("companies", "issues"):
                let inbox = query["touchedByUserId"] != nil || query["unreadForUserId"] != nil
                return .file(inbox ? "inbox-issues" : "issues")
            case ("issues", "comments"):
                // A poll for comments after the newest one finds nothing new.
                return query["after"] != nil ? .json("[]") : .list("comment")
            case ("issues", "interactions"): return .file("interactions")
            case ("issues", "live-runs"): return .file("live-runs")
            case ("issues", "documents"), ("issues", "attachments"): return .json("[]")
            case ("heartbeat-runs", "log"): return .file("run-log")
            case ("approvals", "comments"): return .file("approval-comments")
            default: break
            }
        case 4:
            if parts[0] == "companies", parts[2] == "costs", parts[3] == "summary" { return .file("costs-summary") }
        default:
            break
        }
        return .notFound
    }

    /// Status and body for a route. A missing fixture is a 404.
    static func response(for route: FixtureRoute) -> (status: Int, body: Data) {
        do {
            switch route {
            case .file(let name):
                return (200, try data(named: name))
            case .first(let name):
                let list = try JSONSerialization.jsonObject(with: data(named: name)) as? [Any]
                guard let first = list?.first else { return notFound }
                return (200, try JSONSerialization.data(withJSONObject: first))
            case .list(let name):
                let object = try JSONSerialization.jsonObject(with: data(named: name))
                return (200, try JSONSerialization.data(withJSONObject: [object]))
            case .json(let text):
                return (200, Data(text.utf8))
            case .notFound:
                return notFound
            }
        } catch {
            return notFound
        }
    }

    static func data(named name: String) throws -> Data {
        guard let url = folder?.appendingPathComponent("\(name).json") else { throw FixtureError.missing(name) }
        return try Data(contentsOf: url)
    }

    private static let folder: URL? = Bundle.main.url(forResource: "Fixtures", withExtension: nil)

    private static let notFound = (status: 404, body: Data(#"{"error":"Not found"}"#.utf8))
}

enum FixtureError: Error, Equatable {
    case missing(String)
}

/// Answers every request from `FixtureRoutes`.
final class FixtureURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        var query: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        let route = FixtureRoutes.route(method: request.httpMethod ?? "GET", path: url.path, query: query)
        let (status, body) = FixtureRoutes.response(for: route)
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )
        if let response {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
#endif
