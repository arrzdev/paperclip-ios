import Foundation
import PaperclipAPI

/// A run's log in pages of `pageBytes` from the start. A line cut at a page
/// end is carried to the next page; "Load more" follows `nextOffset`; a live
/// run polls on from the end. A 404 means no output yet (`empty`). The log
/// text is never logged.
@MainActor
@Observable
final class RunLogModel {
    static let pageBytes = 256_000

    let store: AccountStore
    let accountID: UUID
    let runID: String
    let isLive: Bool

    private(set) var state: LoadState<[RunLogLine]> = .loading
    private(set) var isLoadingMore = false
    /// Set when "Load more" failed; the lines stay.
    private(set) var pageError: String?

    private var lines: [RunLogLine] = []
    /// The start of a line cut at the last page end.
    private var remainder = ""
    /// The byte offset after the last page read.
    private var endOffset = 0
    private var nextOffset: Int?

    init(store: AccountStore, accountID: UUID, runID: String, isLive: Bool) {
        self.store = store
        self.accountID = accountID
        self.runID = runID
        self.isLive = isLive
    }

    var hasMore: Bool { nextOffset != nil }

    /// Reads again from offset 0.
    func refresh() async {
        do {
            let page = try await fetch(offset: 0)
            lines = []
            remainder = ""
            endOffset = 0
            append(page, from: 0)
        } catch APIError.notFound {
            lines = []
            remainder = ""
            endOffset = 0
            nextOffset = nil
            state = .empty
        } catch {
            state = isUnauthorizedError(error) ? .needsSignIn : .error(userMessage(for: error))
            log(error, "Run log failed")
        }
    }

    /// The next page at `nextOffset`; a failure keeps the lines and sets `pageError`.
    func loadMore() async {
        guard let offset = nextOffset, !isLoadingMore else { return }
        isLoadingMore = true
        pageError = nil
        defer { isLoadingMore = false }
        do {
            append(try await fetch(offset: offset), from: offset)
        } catch {
            if isUnauthorizedError(error) {
                state = .needsSignIn
            } else {
                pageError = userMessage(for: error)
            }
            log(error, "Run log page failed")
        }
    }

    /// A live run: what was written after the end. A failure keeps the lines.
    func poll() async {
        guard isLive, !isLoadingMore, state != .needsSignIn else { return }
        guard case .loaded = state else {
            // Nothing yet (no output, or an error): read from the start.
            await refresh()
            return
        }
        let offset = nextOffset ?? endOffset
        do {
            append(try await fetch(offset: offset), from: offset)
        } catch APIError.notFound {
            return
        } catch {
            if isUnauthorizedError(error) { state = .needsSignIn }
            log(error, "Run log poll failed")
        }
    }

    // MARK: - Private

    private func fetch(offset: Int) async throws -> RunLog {
        try await store.call(accountID) { try await $0.runLog(runId: runID, offset: offset, limitBytes: Self.pageBytes) }
    }

    private func append(_ page: RunLog, from offset: Int) {
        let parsed = RunLog.parse(remainder + page.content)
        lines += parsed.lines
        remainder = parsed.remainder
        endOffset = offset + page.content.utf8.count
        nextOffset = page.nextOffset
        // A finished log has no more pages: a last line without a newline is complete.
        if !isLive, nextOffset == nil, !remainder.isEmpty {
            lines += RunLog.parse(remainder + "\n").lines
            remainder = ""
        }
        state = lines.isEmpty ? .empty : .loaded(lines)
    }

    /// Only the error text, never a line of the log.
    private func log(_ error: Error, _ context: String) {
        store.log("\(context) for account \(accountID): \(userMessage(for: error))")
    }
}
