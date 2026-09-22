import AppKit
import AuthenticationServices

@MainActor
protocol BrowserAuthenticationSession: AnyObject {
    var prefersEphemeralWebBrowserSession: Bool { get set }
    var presentationContextProvider: (any ASWebAuthenticationPresentationContextProviding)? { get set }
    func start() -> Bool
    func cancel()
}

extension ASWebAuthenticationSession: BrowserAuthenticationSession {}

enum LoginBrowserMode { case standard, privateWindow }

/// The normal browser can reuse saved sign-ins while the CLI still owns an
/// independent credential directory, PKCE and HTTP callback. Private sessions
/// are an explicit fallback, not the default.
@MainActor
final class BrowserLoginLauncher: NSObject, ASWebAuthenticationPresentationContextProviding {
    typealias Completion = @Sendable (URL?, (any Error)?) -> Void
    typealias Factory = @MainActor (URL, @escaping Completion) -> any BrowserAuthenticationSession

    private let makeSession: Factory
    private let openURL: @MainActor (URL) -> Bool
    private var session: (any BrowserAuthenticationSession)?
    private var attemptID: UUID?
    private var anchor: NSWindow?

    init(openURL: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) },
         makeSession: @escaping Factory = { url, completion in
        if let executable = ChromiumLoginSession.installedBrowser(for: url) {
            return ChromiumLoginSession(url: url, executable: executable, completion: completion)
        }
        // No callback scheme: localhost redirects must reach the CLI's HTTP server,
        // rather than being intercepted by AuthenticationServices.
        return ASWebAuthenticationSession(url: url, callbackURLScheme: nil, completionHandler: completion)
    }) {
        self.openURL = openURL
        self.makeSession = makeSession
    }

    func open(_ url: URL, mode: LoginBrowserMode = .standard, control: OperationControl,
              failed: @escaping @MainActor (String) -> Void,
              cancelled: @escaping @MainActor () -> Void) {
        guard !control.cancelled else { return }
        close()
        guard url.scheme == "https", url.host != nil else {
            control.cancel()
            failed("The provider returned an invalid sign-in URL.")
            return
        }
        if mode == .standard {
            guard openURL(Self.accountSelectionURL(url)) else {
                control.cancel()
                failed("Could not open your browser. Check the default browser setting and try again.")
                return
            }
            return
        }
        let id = UUID()
        attemptID = id
        anchor = NSApp?.keyWindow ?? NSApp?.mainWindow
        if let parent = anchor?.sheetParent { anchor = parent }
        let session = makeSession(url) { [weak self] _, error in
            Task { @MainActor [weak self] in
                guard let self, self.attemptID == id else { return }
                self.close()
                control.cancel()
                if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    cancelled()
                } else {
                    failed("The sign-in window closed before sign-in completed. Please try again.")
                }
            }
        }
        self.session = session
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = true
        guard session.start() else {
            close()
            control.cancel()
            failed("Could not open a private sign-in window. Try again with the Accounts settings window open.")
            return
        }
    }

    static func accountSelectionURL(_ url: URL) -> URL {
        // Verified against the Codex 0.154.0 authorization flow: prompt=login
        // shows saved accounts plus 'Sign in with another account'. Claude does
        // not honor this parameter; its approval page has its own Switch account
        // link, which also changes the Claude website session.
        guard url.host == "auth.openai.com", url.path == "/oauth/authorize",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        // Preserve every other parameter byte-for-byte. Re-encoding queryItems
        // can turn an escaped '+' in OAuth state into a form-encoded space.
        var items = components.percentEncodedQuery?.split(separator: "&").map(String.init) ?? []
        items.removeAll { pair in
            let name = pair.split(separator: "=", maxSplits: 1).first.map(String.init) ?? ""
            return name.removingPercentEncoding == "prompt"
        }
        items.append("prompt=login")
        components.percentEncodedQuery = items.joined(separator: "&")
        return components.url ?? url
    }

    /// The normal browser is user-owned and never closed. Invalidate private
    /// callbacks before cancelling: dismissing a completed attempt must
    /// never cancel the CLI result or a later sign-in.
    func close() {
        attemptID = nil
        let previous = session
        session = nil
        previous?.cancel()
        anchor = nil
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        if let anchor { return anchor }
        let window = NSWindow()
        anchor = window
        return window
    }
}
