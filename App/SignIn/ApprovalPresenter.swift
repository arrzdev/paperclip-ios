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
    private let slot = PresentationSlot()

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
        session = nil
        slot.endCurrent()
    }

    private func start(_ url: URL, _ continuation: CheckedContinuation<Void, Never>) {
        session?.cancel()
        let id = slot.begin { continuation.resume() }
        // The handler names its own presentation, so a late call from an
        // earlier session cannot end this one.
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { [weak self] _, _ in
            let presenter = self
            Task { @MainActor in presenter?.finish(id) }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        self.session = session
        if !session.start() {
            finish(id)
        }
    }

    private func finish(_ id: Int) {
        if slot.end(id) {
            session = nil
        }
    }
}

/// The one `present` call in flight. Each presentation has an id, so only
/// its own completion can end it.
@MainActor
final class PresentationSlot {
    private var nextID = 0
    private var current: (id: Int, end: () -> Void)?

    /// Starts a presentation and ends the one before it. Returns its id.
    func begin(onEnd: @escaping () -> Void) -> Int {
        endCurrent()
        nextID += 1
        current = (nextID, onEnd)
        return nextID
    }

    /// Ends presentation `id` if it is still the current one. Returns false
    /// if it already ended or a newer one replaced it.
    @discardableResult
    func end(_ id: Int) -> Bool {
        guard let current, current.id == id else { return false }
        self.current = nil
        current.end()
        return true
    }

    func endCurrent() {
        guard let current else { return }
        self.current = nil
        current.end()
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
