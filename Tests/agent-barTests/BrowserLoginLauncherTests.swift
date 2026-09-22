import AppKit
import AuthenticationServices
import Testing
@testable import agent_bar

@MainActor
struct BrowserLoginLauncherTests {
    @Test func normalBrowserIsDefaultAndRequestsCodexAccountChoice() throws {
        let url = try #require(URL(string: "https://auth.openai.com/oauth/authorize?state=fixture&code_challenge=challenge"))
        var opened: URL?
        let launcher = BrowserLoginLauncher(openURL: { opened = $0; return true }, makeSession: { _, _ in
            Issue.record("Normal sign-in must not create a private browser session")
            return FixtureBrowserSession()
        })
        let control = OperationControl()
        launcher.open(url, control: control, failed: { _ in Issue.record("Unexpected failure") }, cancelled: {})
        #expect(opened?.absoluteString == url.absoluteString + "&prompt=login")
        launcher.close()
        #expect(!control.cancelled)
    }

    @Test func accountChoicePreservesEncodedOAuthParameters() throws {
        let preserved = "state=a%2Bb%26c%3Dd&code_challenge=fixture%2Fvalue&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback&scope=openid%20email"
        let url = try #require(URL(string: "https://auth.openai.com/oauth/authorize?prompt=none&\(preserved)&p%72ompt=consent"))
        let result = BrowserLoginLauncher.accountSelectionURL(url)
        #expect(URLComponents(url: result, resolvingAgainstBaseURL: false)?.percentEncodedQuery == preserved + "&prompt=login")
        #expect(BrowserLoginLauncher.accountSelectionURL(result) == result)
    }

    @Test func claudeKeepsItsOfficialAccountSwitchFlow() throws {
        let url = try #require(URL(string: "https://claude.com/cai/oauth/authorize?state=fixture&login_hint=fixture%40example.test"))
        #expect(BrowserLoginLauncher.accountSelectionURL(url) == url)
    }

    @Test func normalBrowserFailureCancelsCLI() throws {
        let control = OperationControl()
        var error: String?
        let launcher = BrowserLoginLauncher(openURL: { _ in false })
        launcher.open(try #require(URL(string: "https://auth.openai.com/oauth/authorize")), control: control,
                      failed: { error = $0 }, cancelled: {})
        #expect(control.cancelled && error != nil)
    }

    @Test func cancelledNormalLoginNeverOpensBrowser() throws {
        let control = OperationControl(); control.cancel()
        let launcher = BrowserLoginLauncher(openURL: { _ in Issue.record("Unexpected browser"); return true })
        launcher.open(try #require(URL(string: "https://claude.com/cai/oauth/authorize")), control: control,
                      failed: { _ in Issue.record("Unexpected failure") }, cancelled: {})
    }

    @Test func usesFreshPrivateSessionAndLeavesCLICallbackAlone() async throws {
        let url = try #require(URL(string: "https://claude.ai/oauth/authorize"))
        let control = OperationControl()
        let session = FixtureBrowserSession()
        let launcher = BrowserLoginLauncher(makeSession: { received, completion in
            #expect(received == url)
            session.completion = completion
            return session
        })
        launcher.open(url, mode: .privateWindow, control: control, failed: { _ in Issue.record("Unexpected failure") },
                      cancelled: { Issue.record("Unexpected cancellation") })
        #expect(session.started && session.prefersEphemeralWebBrowserSession)
        #expect(session.presentationContextProvider === launcher)
        #expect(!control.cancelled)
        launcher.close()
        await Task.yield()
        #expect(session.wasCancelled && !control.cancelled)
    }

    @Test func cancelledLoginNeverOpensBrowser() throws {
        let control = OperationControl(); control.cancel()
        let launcher = BrowserLoginLauncher(makeSession: { _, _ in Issue.record("Unexpected browser"); return FixtureBrowserSession() })
        launcher.open(try #require(URL(string: "https://claude.ai/oauth/authorize")), mode: .privateWindow, control: control,
                      failed: { _ in Issue.record("Unexpected failure") }, cancelled: {})
    }

    @Test func browserFailureCancelsLoginAndReportsAnError() throws {
        let control = OperationControl()
        let session = FixtureBrowserSession(); session.canStart = false
        let launcher = BrowserLoginLauncher(makeSession: { _, _ in session })
        var error: String?
        launcher.open(try #require(URL(string: "https://auth.openai.com/oauth/authorize")), mode: .privateWindow, control: control,
                      failed: { error = $0 }, cancelled: {})
        #expect(control.cancelled && error != nil && session.wasCancelled)
    }

    @Test func closingWindowCancelsCLI() async throws {
        let control = OperationControl()
        let session = FixtureBrowserSession()
        let launcher = BrowserLoginLauncher(makeSession: { _, completion in session.completion = completion; return session })
        var cancelled = false
        launcher.open(try #require(URL(string: "https://claude.ai/oauth/authorize")), mode: .privateWindow, control: control,
                      failed: { _ in Issue.record("Unexpected failure") }, cancelled: { cancelled = true })
        session.cancel()
        for _ in 0..<10 where !cancelled { await Task.yield() }
        #expect(control.cancelled && cancelled)
    }

    @Test func lateCancellationCannotCancelNextAttempt() async throws {
        var sessions: [FixtureBrowserSession] = []
        let launcher = BrowserLoginLauncher(makeSession: { _, completion in
            let session = FixtureBrowserSession(); session.completion = completion
            sessions.append(session); return session
        })
        let url = try #require(URL(string: "https://claude.ai/oauth/authorize"))
        let first = OperationControl(), second = OperationControl()
        launcher.open(url, mode: .privateWindow, control: first, failed: { _ in Issue.record("Unexpected failure") }, cancelled: {})
        launcher.close()
        launcher.open(url, mode: .privateWindow, control: second, failed: { _ in Issue.record("Unexpected failure") }, cancelled: {})
        await Task.yield()
        #expect(sessions.count == 2 && sessions[0] !== sessions[1])
        #expect(!first.cancelled && !second.cancelled && !sessions[1].wasCancelled)
        launcher.close()
    }

    @Test func rejectsNonWebURLBeforeOpeningAnything() throws {
        let control = OperationControl()
        let launcher = BrowserLoginLauncher(makeSession: { _, _ in Issue.record("Unexpected browser"); return FixtureBrowserSession() })
        launcher.open(try #require(URL(string: "file:///tmp/login")), mode: .privateWindow, control: control, failed: { _ in }, cancelled: {})
        #expect(control.cancelled)
    }
}

@MainActor
private final class FixtureBrowserSession: BrowserAuthenticationSession {
    var prefersEphemeralWebBrowserSession = false
    weak var presentationContextProvider: (any ASWebAuthenticationPresentationContextProviding)?
    var completion: BrowserLoginLauncher.Completion?
    var canStart = true
    var started = false
    var wasCancelled = false
    func start() -> Bool { started = true; return canStart }
    func cancel() {
        wasCancelled = true
        completion?(nil, ASWebAuthenticationSessionError(.canceledLogin))
    }
}
