import Foundation
import PaperclipAPI
import Testing
@testable import PaperclipIOS

/// Agent detail → run log (`GET /heartbeat-runs/:id/log`): pages of NDJSON
/// lines, a line cut at a page end is kept for the next page, "Load more"
/// follows `nextOffset`, and a live run polls on from the end.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct RunLogModelTests {
    static let logPath = "/api/heartbeat-runs/run-1/log"

    static func line(_ seq: Int, _ text: String, stream: String = "stdout") -> String {
        #"{"ts":"2026-10-14T09:15:0\#(seq).000Z","stream":"\#(stream)","chunk":"\#(text)\n","seq":\#(seq)}"# + "\n"
    }

    /// The log response with `content` escaped as a JSON string.
    static func page(_ content: String, nextOffset: Int? = nil) -> String {
        var object: [String: Any] = ["runId": "run-1", "store": "local_file", "logRef": "company-1/agent-1/run-1.ndjson", "content": content]
        if let nextOffset { object["nextOffset"] = nextOffset }
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    private func texts(_ model: RunLogModel) -> [String] {
        if case .loaded(let lines) = model.state { return lines.map(\.text) }
        return []
    }

    private func offsets(_ server: StubServer) -> [String?] {
        server.requests("GET", Self.logPath).map { query($0)["offset"] }
    }

    @Test func refreshReadsFromTheStart() async throws {
        let server = StubServer()
        server.on("GET", Self.logPath, .ok(Self.page(Self.line(1, "Start") + Self.line(2, "Reading", stream: "stderr"))))
        let (store, id) = try signedInStore(server)
        let model = RunLogModel(store: store, accountID: id, runID: "run-1", isLive: false)

        await model.refresh()

        #expect(texts(model) == ["Start", "Reading"])
        if case .loaded(let lines) = model.state {
            #expect(lines.map(\.stream) == ["stdout", "stderr"])
        }
        #expect(!model.hasMore)
        let first = try #require(server.requests("GET", Self.logPath).first)
        #expect(query(first)["offset"] == nil || query(first)["offset"] == "0")
        #expect(query(first)["limitBytes"] == String(RunLogModel.pageBytes))
    }

    @Test func loadMoreFollowsNextOffsetAndJoinsACutLine() async throws {
        let firstContent = Self.line(1, "Start") + #"{"ts":"2026-10-14T09:15:02.000Z","stream":"stdout","chu"#
        let secondContent = #"nk":"Second\n","seq":2}"# + "\n" + Self.line(3, "Third")
        let server = StubServer()
        server.on("GET", Self.logPath, query: ["offset": "0"], .ok(Self.page(firstContent, nextOffset: 120)))
        server.on("GET", Self.logPath, query: ["offset": "120"], .ok(Self.page(secondContent)))
        server.on("GET", Self.logPath, .ok(Self.page(firstContent, nextOffset: 120)))
        let (store, id) = try signedInStore(server)
        let model = RunLogModel(store: store, accountID: id, runID: "run-1", isLive: false)

        await model.refresh()
        #expect(texts(model) == ["Start"])
        #expect(model.hasMore)

        await model.loadMore()

        #expect(offsets(server).last == "120")
        #expect(texts(model) == ["Start", "Second", "Third"])
        #expect(!model.hasMore)
    }

    @Test func aLiveRunPollsOnFromTheEnd() async throws {
        let firstContent = Self.line(1, "Start")
        let server = StubServer()
        server.on("GET", Self.logPath, query: ["offset": "0"], .ok(Self.page(firstContent)))
        server.on("GET", Self.logPath, .ok(Self.page(firstContent)))
        let end = firstContent.utf8.count
        server.on("GET", Self.logPath, query: ["offset": String(end)], .ok(Self.page(Self.line(2, "More"))))
        let (store, id) = try signedInStore(server)
        let model = RunLogModel(store: store, accountID: id, runID: "run-1", isLive: true)
        await model.refresh()

        await model.poll()

        #expect(offsets(server).last == String(end))
        #expect(texts(model) == ["Start", "More"])
    }

    @Test func aFinishedRunDoesNotPoll() async throws {
        let server = StubServer()
        server.on("GET", Self.logPath, .ok(Self.page(Self.line(1, "Start"))))
        let (store, id) = try signedInStore(server)
        let model = RunLogModel(store: store, accountID: id, runID: "run-1", isLive: false)
        await model.refresh()

        await model.poll()

        #expect(server.requests("GET", Self.logPath).count == 1)
    }

    @Test func noLogYetIsEmptyNotAnError() async throws {
        let server = StubServer()
        server.on("GET", Self.logPath, .init(status: 404, body: #"{"error":"Run log not found"}"#))
        let (store, id) = try signedInStore(server)
        let model = RunLogModel(store: store, accountID: id, runID: "run-1", isLive: true)

        await model.refresh()

        #expect(model.state == .empty)
    }

    @Test func aFailedPollKeepsTheLines() async throws {
        let server = StubServer()
        server.on("GET", Self.logPath, .ok(Self.page(Self.line(1, "Start"))), .init(status: 503, body: JSON.unavailable))
        let (store, id) = try signedInStore(server)
        let model = RunLogModel(store: store, accountID: id, runID: "run-1", isLive: true)
        await model.refresh()

        await model.poll()

        #expect(texts(model) == ["Start"])
    }

    @Test func a401SendsTheAccountToSignIn() async throws {
        let server = StubServer()
        server.on("GET", Self.logPath, .init(status: 401, body: JSON.unauthorized))
        let (store, id) = try signedInStore(server)
        let model = RunLogModel(store: store, accountID: id, runID: "run-1", isLive: false)

        await model.refresh()

        #expect(model.state == .needsSignIn)
        #expect(store.route == .reSignIn(id))
    }

    @Test func theLogTextIsNeverLogged() async throws {
        let log = LogSink()
        let server = StubServer()
        server.on("GET", Self.logPath, .ok(Self.page(Self.line(1, "secret-output-line"))), .init(status: 503, body: JSON.unavailable))
        let (store, id) = try signedInStore(server, log: log)
        let model = RunLogModel(store: store, accountID: id, runID: "run-1", isLive: true)

        await model.refresh()
        await model.poll()

        for line in log.lines {
            #expect(!line.contains("secret-output-line"))
        }
    }
}
