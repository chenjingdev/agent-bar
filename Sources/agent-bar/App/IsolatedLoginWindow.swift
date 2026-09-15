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
                    failed("분리된 로그인 창을 열 수 없습니다. 일반 브라우저로 전환하지 않았습니다.")
                }
            })
        session.prefersEphemeralWebBrowserSession = true
        session.presentationContextProvider = self
        self.session = session
        guard session.canStart && session.start() else {
            self.session = nil; activeID = nil; control.cancel()
            failed("macOS에서 분리된 인증 세션을 시작할 수 없습니다. 기존 브라우저 세션은 사용하지 않았습니다.")
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
