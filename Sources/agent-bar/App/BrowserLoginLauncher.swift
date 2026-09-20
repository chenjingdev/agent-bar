import AppKit

/// The default browser owns its existing sign-in session. The isolated CLI
/// still owns PKCE, the loopback callback, and per-account credential storage.
@MainActor
enum BrowserLoginLauncher {
    static func open(_ url: URL, control: OperationControl,
                     openURL: (URL) -> Bool = { NSWorkspace.shared.open($0) },
                     failed: (String) -> Void) {
        guard !control.cancelled else { return }
        guard url.scheme == "https", url.host != nil else {
            control.cancel()
            failed("The provider returned an invalid sign-in URL.")
            return
        }
        guard openURL(url) else {
            control.cancel()
            failed("Could not open the default browser. Check your default browser setting and try again.")
            return
        }
    }
}
