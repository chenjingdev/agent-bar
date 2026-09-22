import Foundation
import Testing
@testable import agent_bar

@MainActor
struct ChromiumLoginSessionTests {
    @Test func installedBrowserKeepsCookiesIsolatedAndDeliversLoopbackCallback() async throws {
        guard ProcessInfo.processInfo.environment["AGENTBAR_LIVE_BROWSER_PROBE"] == "1" else { return }
        let browser = try #require(ChromiumLoginSession.installedBrowser(for: URL(string: "https://claude.ai")!))
        let script = """
        from http.server import HTTPServer, BaseHTTPRequestHandler
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def do_GET(self):
                if self.path == '/start':
                    print('START ' + ('shared' if self.headers.get('Cookie') else 'clean'), flush=True)
                    self.send_response(302)
                    self.send_header('Set-Cookie', 'agentbar_fixture=1; Path=/; SameSite=Lax')
                    self.send_header('Location', '/callback')
                    self.end_headers()
                elif self.path == '/callback':
                    print('CALLBACK ' + ('present' if 'agentbar_fixture=1' in self.headers.get('Cookie', '') else 'missing'), flush=True)
                    self.send_response(200)
                    self.end_headers()
                    self.wfile.write(b'AgentBar local sign-in test complete. This window will close.')
                else:
                    self.send_response(404)
                    self.end_headers()
        server = HTTPServer(('127.0.0.1', 0), Handler)
        print(server.server_port, flush=True)
        server.serve_forever()
        """
        let server = try ProcessSession(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", script],
            environment: ["PATH": "/usr/bin:/bin"], directory: FileManager.default.temporaryDirectory)
        defer { server.stop() }
        let control = OperationControl()
        let port = try await Task.detached { String(decoding: try server.line(until: Date().addingTimeInterval(5), control: control), as: UTF8.self) }.value
        let url = try #require(URL(string: "http://127.0.0.1:\(port)/start"))
        for _ in 0..<2 {
            let session = ChromiumLoginSession(url: url, executable: browser, completion: { _, _ in })
            #expect(session.start())
            defer { session.cancel() }
            let events = try await Task.detached {
                try (0..<2).map { _ in String(decoding: try server.line(until: Date().addingTimeInterval(20), control: control), as: UTF8.self) }
            }.value
            #expect(events == ["START clean", "CALLBACK present"])
            session.cancel()
            for _ in 0..<150 where FileManager.default.fileExists(atPath: session.profileDirectory.path) {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(!FileManager.default.fileExists(atPath: session.profileDirectory.path))
        }
    }

    @Test func attemptsHaveSeparateProfilesAndDoNotReuseExistingIncognitoWindows() throws {
        let url = try #require(URL(string: "https://claude.ai/oauth/authorize?fixture=1"))
        let browser = URL(fileURLWithPath: "/fixture/browser")
        let first = ChromiumLoginSession(url: url, executable: browser, completion: { _, _ in })
        let second = ChromiumLoginSession(url: url, executable: browser, completion: { _, _ in })
        #expect(first.profileDirectory != second.profileDirectory)
        #expect(first.arguments.contains("--user-data-dir=\(first.profileDirectory.path)"))
        #expect(first.arguments.contains("--incognito"))
        #expect(first.arguments.last == url.absoluteString)
    }

    @Test func browserExitNotifiesCancellationAndRemovesTemporaryProfile() async throws {
        let url = try #require(URL(string: "https://claude.ai/oauth/authorize"))
        let finished = CompletionFlag()
        let session = ChromiumLoginSession(url: url, executable: URL(fileURLWithPath: "/usr/bin/true")) { _, error in
            if error != nil { finished.set() }
        }
        #expect(session.start())
        for _ in 0..<100 {
            if finished.value && !FileManager.default.fileExists(atPath: session.profileDirectory.path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(finished.value)
        #expect(!FileManager.default.fileExists(atPath: session.profileDirectory.path))
    }
}

private final class CompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return completed }
    func set() { lock.lock(); completed = true; lock.unlock() }
}
