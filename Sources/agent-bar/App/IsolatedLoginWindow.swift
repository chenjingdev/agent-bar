import AppKit
import AuthenticationServices

/// OAuth runs in a fresh, system-managed browser session. Completion still belongs
/// to the CLI's loopback listener; AgentBar never handles authorization codes.
@MainActor
final class IsolatedLoginWindow: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = IsolatedLoginWindow()
    private var session: ASWebAuthenticationSession?
    private var activeID: UUID?

    func open(_ url: URL, control: OperationControl, failed: @escaping @MainActor (String) -> Void) {
        finish()
        guard !control.cancelled else { return }
        SettingsWindowController.shared.show(accounts: true)
        let id = UUID(); activeID = id
        // The CLI owns an HTTP loopback callback. A nil custom scheme lets that
        // navigation reach the CLI. We dismiss the browser after CLI completion.
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil,
            completionHandler: Self.completionOnMainActor { [weak self] error in
                guard let self, self.activeID == id else { return }
                self.session = nil; self.activeID = nil
                control.cancel()
                if let error, (error as NSError).code != ASWebAuthenticationSessionError.canceledLogin.rawValue {
                    failed("Could not open the isolated login window. No shared-browser fallback was used.")
                }
            })
        session.prefersEphemeralWebBrowserSession = true
        session.presentationContextProvider = self
        self.session = session
        guard session.canStart && session.start() else {
            self.session = nil; activeID = nil; control.cancel()
            failed("macOS could not start an isolated authentication session. The existing browser session was not used.")
            return
        }
    }
    // AuthenticationServices invokes its Objective-C completion on an XPC queue.
    // Construct a Sendable callback outside MainActor isolation before hopping back.
    nonisolated static func completionOnMainActor(
        _ completion: @escaping @MainActor @Sendable (Error?) -> Void
    ) -> @Sendable (URL?, Error?) -> Void {
        { _, error in
            Task { @MainActor in completion(error) }
        }
    }

    func finish() {
        activeID = nil
        let previous = session; session = nil
        previous?.cancel()
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        SettingsWindowController.shared.presentationWindow
    }
}
