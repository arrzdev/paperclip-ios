import AuthenticationServices
import Foundation
import UIKit

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
    private var session: ASWebAuthenticationSession?
    private var finished: CheckedContinuation<Void, Never>?

    func present(_ url: URL) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            MainActor.assumeIsolated {
                self.start(url, continuation)
            }
        }
    }

    func dismiss() {
        // `cancel()` does not reliably call the completion handler; end `present` here.
        session?.cancel()
        finish()
    }

    private func start(_ url: URL, _ continuation: CheckedContinuation<Void, Never>) {
        finish()
        finished = continuation
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { [weak self] _, _ in
            let presenter = self
            Task { @MainActor in presenter?.finish() }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        self.session = session
        if !session.start() {
            finish()
        }
    }

    private func finish() {
        session = nil
        finished?.resume()
        finished = nil
    }
}

extension WebAuthenticationApprovalPresenter: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { () -> ASPresentationAnchor in
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            if let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) {
                return window
            }
            if let scene = scenes.first {
                return UIWindow(windowScene: scene)
            }
            return ASPresentationAnchor()
        }
    }
}
