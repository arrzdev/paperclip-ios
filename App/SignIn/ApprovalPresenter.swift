import AuthenticationServices
import Foundation

/// Shows the server's approval page during device-flow sign-in.
@MainActor
protocol ApprovalPresenter: AnyObject {
    /// Opens `url` and returns when the user closes the page or `dismiss()` is called.
    func present(_ url: URL) async
    /// Closes the page because the flow saw the challenge end.
    func dismiss()
}

/// `ASWebAuthenticationSession` with no callback scheme: the approval page does
/// not redirect back to the app, so the flow polls and dismisses the sheet
/// itself. Not ephemeral, so the user's existing web session on that server
/// is reused.
@MainActor
final class WebAuthenticationApprovalPresenter: NSObject, ApprovalPresenter {
    func present(_ url: URL) async {
        // TODO
    }

    func dismiss() {
        // TODO
    }
}
