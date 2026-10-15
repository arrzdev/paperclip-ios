import Foundation
import PaperclipAPI
@testable import PaperclipIOS

// Helpers for the list screens (Inbox, Today): a signed-in account with a
// selected company, issue JSON in the 2026.1005.0 list shape, query checks.

let companyIssuesPath = "/api/companies/company-1/issues"

/// A store signed in to `server` as `user-1` with `company-1` selected.
@MainActor
func signedInStore(_ server: StubServer, log: LogSink = LogSink()) throws -> (store: AccountStore, accountID: UUID) {
    let store = makeStore(log: log)
    let account = try store.saveSignIn(
        server: server.address, me: try decodeMe(), apiKey: JSON.key, approvedAt: iso(JSON.approvedAt)
    )
    try store.selectCompany("company-1", for: account.id)
    return (store, account.id)
}

/// One issue as `GET /api/companies/:id/issues?touchedByUserId=me` returns it
/// (only the fields the app reads; the server sends many more).
func issueJSON(
    id: String,
    title: String? = nil,
    status: String = "todo",
    assigneeUserId: String? = nil,
    createdByUserId: String? = nil,
    projectId: String? = nil,
    unread: Bool? = nil,
    updatedAt: String = "2026-10-14T09:00:00.000Z",
    lastActivityAt: String? = nil,
    lastExternalCommentAt: String? = nil,
    completedAt: String? = nil
) -> String {
    func text(_ value: String?) -> String { value.map { "\"" + $0 + "\"" } ?? "null" }
    let number = id.split(separator: "-").last.map(String.init) ?? "1"
    return """
    {"id":"\(id)","companyId":"company-1","identifier":"PAP-\(number)","title":\(text(title ?? "Task \(id)")),\
    "description":null,"status":"\(status)","priority":"medium","assigneeAgentId":null,\
    "assigneeUserId":\(text(assigneeUserId)),"createdByAgentId":null,"createdByUserId":\(text(createdByUserId)),\
    "projectId":\(text(projectId)),"parentId":null,"createdAt":"2026-10-01T08:00:00.000Z","updatedAt":"\(updatedAt)",\
    "completedAt":\(text(completedAt)),"lastActivityAt":\(text(lastActivityAt ?? updatedAt)),\
    "myLastTouchAt":null,"lastExternalCommentAt":\(text(lastExternalCommentAt)),\
    "isUnreadForMe":\(unread.map { $0 ? "true" : "false" } ?? "null")}
    """
}

func list(_ items: String...) -> String {
    "[" + items.joined(separator: ",") + "]"
}

/// Query items of a recorded request, by name (last value wins).
func query(_ request: URLRequest?) -> [String: String] {
    guard let url = request?.url,
          let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return [:] }
    var result: [String: String] = [:]
    for item in items {
        result[item.name] = item.value ?? ""
    }
    return result
}

/// A `sleep` for pollers: records each duration and lets `ticks` sleeps pass,
/// then throws `CancellationError` as a cancelled `.task` would.
final class TestSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Duration] = []
    private let ticks: Int

    init(ticks: Int) {
        self.ticks = ticks
    }

    var durations: [Duration] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func sleep(_ duration: Duration) async throws {
        let count: Int = {
            lock.lock(); defer { lock.unlock() }
            recorded.append(duration)
            return recorded.count
        }()
        if count > ticks { throw CancellationError() }
        await Task.yield()
    }
}
