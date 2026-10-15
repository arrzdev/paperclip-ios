import Foundation
import PaperclipAPI
import Testing
@testable import PaperclipIOS

/// The Task detail composer (spec §4 C): text and one photo, the photo uploads
/// first and the comment links it; a failure keeps the draft and Retry
/// continues where it stopped. The draft is kept per task.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct CommentComposerTests {
    let commentsPath = "/api/issues/issue-1/comments"
    let uploadPath = "/api/companies/company-1/issues/issue-1/attachments"

    static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    static let photo = PendingImage(data: png, filename: "screenshot.png", contentType: "image/png")
    static let uploaded = #"{"id":"att-new","companyId":"company-1","issueId":"issue-1","issueCommentId":null,"contentType":"image/png","byteSize":8,"originalFilename":"screenshot.png","contentPath":"/api/attachments/att-new/content","createdAt":"2026-10-14T09:30:00.000Z"}"#
    static func created(_ body: String) -> String {
        #"{"id":"c-new","issueId":"issue-1","authorUserId":"user-1","authorAgentId":null,"authorType":"user","body":"\#(body)","createdAt":"2026-10-14T09:30:00.000Z"}"#
    }

    private func composer(
        _ server: StubServer,
        drafts: DraftStore = InMemoryDraftStore(),
        issueID: String = "issue-1",
        onSent: @escaping (IssueComment) -> Void = { _ in }
    ) throws -> (CommentComposer, AccountStore, UUID) {
        let (store, id) = try signedInStore(server)
        let composer = CommentComposer(
            store: store, accountID: id, companyID: "company-1", issueID: issueID, drafts: drafts, onSent: onSent
        )
        return (composer, store, id)
    }

    private func commentBodies(_ server: StubServer) -> [[String: Any]] {
        server.requests("POST", commentsPath).compactMap(jsonObject)
    }

    // MARK: Draft

    @Test func draftIsKeptPerTaskAndSurvivesLeavingTheScreen() throws {
        let server = StubServer()
        let drafts = InMemoryDraftStore()
        let (first, store, id) = try composer(server, drafts: drafts)
        first.text = "Half a reply"
        first.attach(Self.photo)

        // Leaving and coming back builds a new composer for the same account and task.
        let again = CommentComposer(
            store: store, accountID: id, companyID: "company-1", issueID: "issue-1", drafts: drafts, onSent: { _ in }
        )
        #expect(again.text == "Half a reply")
        #expect(again.image?.data == Self.png)
        #expect(again.image?.filename == "screenshot.png")

        // Another task has its own (empty) draft.
        let other = CommentComposer(
            store: store, accountID: id, companyID: "company-1", issueID: "issue-2", drafts: drafts, onSent: { _ in }
        )
        #expect(other.text == "")
        #expect(other.image == nil)
    }

    @Test func removingThePhotoUpdatesTheDraft() throws {
        let drafts = InMemoryDraftStore()
        let (composer, _, id) = try composer(StubServer(), drafts: drafts)
        composer.attach(Self.photo)
        composer.removeImage()

        #expect(composer.image == nil)
        #expect(drafts.draft(accountID: id, issueID: "issue-1")?.image == nil)
    }

    @Test func sendNeedsTextOrAPhoto() throws {
        let (composer, _, _) = try composer(StubServer())
        #expect(composer.canSend == false)
        composer.text = "   \n"
        #expect(composer.canSend == false)
        composer.text = "Ok"
        #expect(composer.canSend)
        composer.text = ""
        composer.attach(Self.photo)
        #expect(composer.canSend)
    }

    // MARK: Send

    @Test func sendTextPostsTheCommentAndClearsTheDraft() async throws {
        let server = StubServer()
        server.on("POST", commentsPath, StubServer.Response(status: 201, body: Self.created("Looks good")))
        let drafts = InMemoryDraftStore()
        var sent: [IssueComment] = []
        let (composer, _, id) = try composer(server, drafts: drafts, onSent: { sent.append($0) })
        composer.text = "  Looks good "

        await composer.send()

        let body = try #require(commentBodies(server).first)
        #expect(body["body"] as? String == "Looks good")
        #expect(body["attachmentIds"] == nil)
        #expect(server.requests("POST", uploadPath).isEmpty)
        #expect(sent.map(\.id) == ["c-new"])
        #expect(composer.text == "")
        #expect(composer.phase == .idle)
        #expect(drafts.draft(accountID: id, issueID: "issue-1") == nil)
    }

    @Test func photoUploadsFirstThenTheCommentLinksIt() async throws {
        let server = StubServer()
        server.on("POST", uploadPath, StubServer.Response(status: 201, body: Self.uploaded))
        server.on("POST", commentsPath, StubServer.Response(status: 201, body: Self.created("See this")))
        let (composer, _, _) = try composer(server)
        composer.text = "See this"
        composer.attach(Self.photo)

        await composer.send()

        let paths = server.allRequests.compactMap { $0.httpMethod == "POST" ? $0.url?.path : nil }
        #expect(paths == [uploadPath, commentsPath])
        let upload = try #require(server.requests("POST", uploadPath).first)
        #expect(upload.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data") == true)
        let body = try #require(commentBodies(server).first)
        #expect(body["attachmentIds"] as? [String] == ["att-new"])
        #expect(body["body"] as? String == "See this")
        #expect(composer.image == nil)
        #expect(composer.phase == .idle)
    }

    @Test func photoWithoutTextSendsTheDefaultBody() async throws {
        let server = StubServer()
        server.on("POST", uploadPath, StubServer.Response(status: 201, body: Self.uploaded))
        server.on("POST", commentsPath, StubServer.Response(status: 201, body: Self.created(CommentComposer.photoOnlyBody)))
        let (composer, _, _) = try composer(server)
        composer.attach(Self.photo)

        await composer.send()

        // The server needs a non-empty body.
        #expect(!CommentComposer.photoOnlyBody.isEmpty)
        #expect(commentBodies(server).first?["body"] as? String == CommentComposer.photoOnlyBody)
    }

    // MARK: Failure and retry

    @Test func failedUploadKeepsTheDraftAndRetrySendsIt() async throws {
        let server = StubServer()
        server.on("POST", uploadPath,
                  StubServer.Response(status: 500, body: JSON.unavailable),
                  StubServer.Response(status: 201, body: Self.uploaded))
        server.on("POST", commentsPath, StubServer.Response(status: 201, body: Self.created("See this")))
        let drafts = InMemoryDraftStore()
        let (composer, _, id) = try composer(server, drafts: drafts)
        composer.text = "See this"
        composer.attach(Self.photo)

        await composer.send()

        #expect(composer.phase == .failed(userMessage(for: APIError.server(status: 500, body: "Service unavailable"))))
        #expect(composer.text == "See this")
        #expect(composer.image?.data == Self.png)
        #expect(drafts.draft(accountID: id, issueID: "issue-1")?.text == "See this")
        #expect(drafts.draft(accountID: id, issueID: "issue-1")?.image?.data == Self.png)
        #expect(server.requests("POST", commentsPath).isEmpty)

        await composer.retry()

        #expect(server.requests("POST", uploadPath).count == 2)
        #expect(commentBodies(server).first?["attachmentIds"] as? [String] == ["att-new"])
        #expect(composer.phase == .idle)
        #expect(composer.text == "")
        #expect(drafts.draft(accountID: id, issueID: "issue-1") == nil)
    }

    @Test func failedCommentAfterUploadRetriesWithoutUploadingAgain() async throws {
        let server = StubServer()
        server.on("POST", uploadPath, StubServer.Response(status: 201, body: Self.uploaded))
        server.on("POST", commentsPath,
                  StubServer.Response(status: 503, body: JSON.unavailable),
                  StubServer.Response(status: 201, body: Self.created("See this")))
        let drafts = InMemoryDraftStore()
        let (composer, _, id) = try composer(server, drafts: drafts)
        composer.text = "See this"
        composer.attach(Self.photo)

        await composer.send()
        if case .failed = composer.phase {} else { Testing.Issue.record("expected a failed phase, got \(composer.phase)") }
        // The upload is remembered in the draft, so leaving the screen does not lose it.
        #expect(drafts.draft(accountID: id, issueID: "issue-1")?.image?.uploadedAttachmentId == "att-new")

        await composer.retry()

        #expect(server.requests("POST", uploadPath).count == 1)
        let bodies = commentBodies(server)
        #expect(bodies.count == 2)
        #expect(bodies.map { $0["attachmentIds"] as? [String] } == [["att-new"], ["att-new"]])
        // Same request id both times: the server does not post the comment twice.
        let ids = bodies.compactMap { $0["clientRequestId"] as? String }
        #expect(ids.count == 2)
        #expect(Set(ids).count == 1)
        #expect(composer.phase == .idle)
    }

    @Test func unauthorizedSendKeepsTheDraftAndSendsTheAccountToSignIn() async throws {
        let server = StubServer()
        server.on("POST", commentsPath, StubServer.Response(status: 401, body: JSON.unauthorized))
        let drafts = InMemoryDraftStore()
        let (composer, store, id) = try composer(server, drafts: drafts)
        composer.text = "Hello"

        await composer.send()

        #expect(store.route == .reSignIn(id))
        #expect(composer.text == "Hello")
        #expect(drafts.draft(accountID: id, issueID: "issue-1")?.text == "Hello")
    }

    @Test func noKeyOrImageBytesInTheLog() async throws {
        let server = StubServer()
        server.on("POST", uploadPath, StubServer.Response(status: 500, body: JSON.unavailable))
        let log = LogSink()
        let (store, id) = try signedInStore(server, log: log)
        let composer = CommentComposer(
            store: store, accountID: id, companyID: "company-1", issueID: "issue-1",
            drafts: InMemoryDraftStore(), onSent: { _ in }
        )
        composer.text = "secret plan"
        composer.attach(Self.photo)
        await composer.send()

        // The failure is logged, without the key, the draft text or the image.
        #expect(!log.lines.isEmpty)
        let text = log.lines.joined(separator: "\n")
        #expect(!text.contains(JSON.key))
        #expect(!text.contains("secret plan"))
        #expect(!text.contains(Self.png.base64EncodedString()))
    }
}

/// Drafts on disk: one file per account and task, removed when the draft is cleared.
@MainActor
@Suite
struct FileDraftStoreTests {
    @Test func draftRoundTripsAcrossInstances() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let account = UUID()
        var draft = CommentDraft()
        draft.text = "Half a reply"
        draft.image = PendingImage(data: Data([1, 2, 3]), filename: "photo.jpg", contentType: "image/jpeg")
        draft.image?.uploadedAttachmentId = "att-1"

        FileDraftStore(folder: folder).save(draft, accountID: account, issueID: "issue-1")

        let reopened = FileDraftStore(folder: folder)
        #expect(reopened.draft(accountID: account, issueID: "issue-1") == draft)
        #expect(reopened.draft(accountID: account, issueID: "issue-2") == nil)
        #expect(reopened.draft(accountID: UUID(), issueID: "issue-1") == nil)

        reopened.save(nil, accountID: account, issueID: "issue-1")
        #expect(FileDraftStore(folder: folder).draft(accountID: account, issueID: "issue-1") == nil)
    }

    @Test func issueIDCannotEscapeTheFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let account = UUID()
        var draft = CommentDraft()
        draft.text = "x"
        FileDraftStore(folder: folder).save(draft, accountID: account, issueID: "../../escape")

        let files = FileManager.default.enumerator(atPath: folder.path)?.allObjects as? [String] ?? []
        #expect(!files.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().appendingPathComponent("escape.json").path))
        #expect(FileDraftStore(folder: folder).draft(accountID: account, issueID: "../../escape")?.text == "x")
    }
}
