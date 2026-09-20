import Foundation
import Testing
@testable import agent_bar

@MainActor
struct BrowserLoginLauncherTests {
    @Test func opensBrowserWithoutCancellingCLICallback() throws {
        let url = try #require(URL(string: "https://claude.ai/oauth/authorize"))
        let control = OperationControl()
        var opened: URL?
        var error: String?
        BrowserLoginLauncher.open(url, control: control, openURL: { opened = $0; return true }, failed: { error = $0 })
        #expect(opened == url && !control.cancelled && error == nil)
    }
    @Test func cancelledLoginNeverOpensBrowser() throws {
        let control = OperationControl(); control.cancel()
        var opened = false
        BrowserLoginLauncher.open(try #require(URL(string: "https://claude.ai/oauth/authorize")), control: control,
            openURL: { _ in opened = true; return true }, failed: { _ in Issue.record("Unexpected failure") })
        #expect(!opened)
    }
    @Test func browserFailureCancelsLoginAndReportsAnError() throws {
        let control = OperationControl()
        var error: String?
        BrowserLoginLauncher.open(try #require(URL(string: "https://auth.openai.com/oauth/authorize")), control: control,
            openURL: { _ in false }, failed: { error = $0 })
        #expect(control.cancelled && error != nil)
    }
    @Test func rejectsNonWebURLBeforeOpeningAnything() throws {
        let control = OperationControl()
        var opened = false
        BrowserLoginLauncher.open(try #require(URL(string: "file:///tmp/login")), control: control,
            openURL: { _ in opened = true; return true }, failed: { _ in })
        #expect(control.cancelled && !opened)
    }
}
