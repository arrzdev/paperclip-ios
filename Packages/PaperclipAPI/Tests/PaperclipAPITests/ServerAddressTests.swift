import Foundation
import Testing
@testable import PaperclipAPI

struct ServerAddressTests {
    @Test func addsHTTPSAndStripsTrailingSlashAndAPI() throws {
        #expect(try ServerAddress("paperclip.test").baseURL.absoluteString == "https://paperclip.test")
        #expect(try ServerAddress("  https://paperclip.test/api/ ").baseURL.absoluteString == "https://paperclip.test")
        #expect(try ServerAddress("https://paperclip.test:8443/sub/").baseURL.absoluteString == "https://paperclip.test:8443/sub")
    }

    @Test(arguments: [
        ("   ", ServerAddress.ValidationError.empty),
        ("http://paperclip.test", .insecureScheme),
        ("ftp://paperclip.test", .invalid),
        ("https://paperclip.test/?a=1", .invalid),
    ])
    func rejectsBadInput(input: String, expected: ServerAddress.ValidationError) {
        #expect(throws: expected) { try ServerAddress(input) }
    }

    @Test func allowsPlainHTTPOnLoopbackOnly() throws {
        #expect(try ServerAddress("http://localhost:3100").baseURL.absoluteString == "http://localhost:3100")
    }

    @Test func apiURLKeepsBasePathAndEncodesQuery() throws {
        let server = try ServerAddress("https://paperclip.test/sub")
        let url = server.apiURL(path: "/issues/PAP-1", query: [URLQueryItem(name: "token", value: "a+b c")])
        #expect(url.absoluteString == "https://paperclip.test/sub/api/issues/PAP-1?token=a%2Bb%20c")
    }

    @Test func storageKeyAndDisplayName() throws {
        #expect(try ServerAddress("https://Paperclip.TEST").storageKey == "https://paperclip.test")
        #expect(try ServerAddress("https://paperclip.test/sub").displayName == "paperclip.test/sub")
    }
}

struct ServerCheckTests {
    @Test func pinnedCommitMatchesShortAndFullSHA() {
        let full = "467125fafb47a8520856504fecc48d6e32055db1"
        #expect(ServerCheck(health: Health(status: "ok", commit: full, deploymentMode: nil)) == .ok(commit: full))
        #expect(ServerCheck(health: Health(status: "ok", commit: "467125f", deploymentMode: nil)) == .ok(commit: "467125f"))
    }

    @Test func otherCommitWarnsButAllowsSignIn() {
        let check = ServerCheck(health: Health(status: "ok", commit: "abcdef1234", deploymentMode: nil))
        #expect(check == .versionMismatch(serverCommit: "abcdef1234"))
        #expect(check.canSignIn)
        #expect(ServerCheck(health: Health(status: "ok", commit: nil, deploymentMode: nil)) == .versionMismatch(serverCommit: nil))
        #expect(ServerCheck(health: Health(status: "ok", commit: "4671", deploymentMode: nil)) == .versionMismatch(serverCommit: "4671"))
    }

    @Test func unhealthyBlocksSignIn() {
        let check = ServerCheck(health: Health(status: "degraded", commit: "467125f", deploymentMode: nil))
        #expect(check == .unhealthy(status: "degraded"))
        #expect(!check.canSignIn)
    }
}

struct LenientEnumTests {
    @Test func unknownValuesRoundTrip() throws {
        let data = Data(#"["in_progress","triage"]"#.utf8)
        let statuses = try JSONDecoder().decode([IssueStatus].self, from: data)
        #expect(statuses == [.inProgress, .unknown("triage")])
        #expect(try JSONEncoder().encode(statuses) == data)
    }
}
