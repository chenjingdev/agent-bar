import Foundation
import Testing
@testable import agent_bar

struct ClaudeOAuthLauncherTests {
    @Test func onlyOfficialURLWithLoopbackCallbackIsAccepted() throws {
        let valid = "https://claude.ai/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A54321%2Fcallback"
        #expect(try ClaudeOAuthLauncher.validate(Data(valid.utf8)).host == "claude.ai")
        let current = "https://claude.com/cai/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A54321%2Fcallback"
        #expect(try ClaudeOAuthLauncher.validate(Data(current.utf8)).host == "claude.com")
        for invalid in [
            "https://example.test/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A54321%2Fcallback",
            "https://claude.ai/oauth/authorize?redirect_uri=https%3A%2F%2Fexample.test%2Fcallback",
            "https://claude.ai/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%2Fcallback",
            "not a url"
        ] { #expect(throws: AccountError.self) { try ClaudeOAuthLauncher.validate(Data(invalid.utf8)) } }
    }
    @Test func openerCapturesWithoutLaunchingBrowser() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentbar-opener-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let env = try ClaudeOAuthLauncher.environment(directory: directory)
        let raw = "https://claude.ai/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A54321%2Fcallback"
        let process = Process(); process.executableURL = URL(fileURLWithPath: try #require(env["BROWSER"]))
        process.arguments = [raw]; process.environment = env
        try process.run(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let file = URL(fileURLWithPath: try #require(env["AGENTBAR_OAUTH_URL_FILE"]))
        #expect(try String(contentsOf: file, encoding: .utf8) == raw)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
    @Test func installedClaudeUsesCapturedAutomaticCallback() throws {
        guard ProcessInfo.processInfo.environment["AGENTBAR_LIVE_AUTH_PROBE"] == "1" else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentbar-claude-live-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let control = OperationControl()
        #expect(throws: AccountError.self) {
            try ClaudeOAuthLauncher.login(directory: directory, control: control) { url in
                #expect(["claude.ai", "claude.com"].contains(url.host ?? ""))
                control.cancel()
            }
        }
        #expect(control.cancelled, "The installed Claude must call the capture helper; no shared browser is opened.")
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("agentbar-oauth-url").path))
    }
}
