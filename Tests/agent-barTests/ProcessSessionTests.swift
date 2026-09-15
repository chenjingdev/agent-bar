import Foundation
import Testing
@testable import agent_bar

struct ProcessSessionTests {
    @Test func sendingToExitedProcessThrowsInsteadOfTerminatingApp() throws {
        let session = try ProcessSession(executable: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [], environment: [:], directory: FileManager.default.temporaryDirectory)
        defer { session.stop() }
        _ = try session.collect(until: Date().addingTimeInterval(5), control: OperationControl())
        #expect(session.exitStatus == 0)
        #expect(throws: (any Error).self) { try session.send(["method": "initialized"]) }
    }

    @Test func splitLinesAndImmediateExitAreCollected() throws {
        let session = try ProcessSession(executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", "import sys,time;sys.stdout.write('hel');sys.stdout.flush();time.sleep(.02);print('lo');print('world')"],
            environment: ["PATH": "/usr/bin:/bin"], directory: FileManager.default.temporaryDirectory)
        defer { session.stop() }
        let output = try session.collect(until: Date().addingTimeInterval(5), control: OperationControl())
        #expect(String(decoding: output, as: UTF8.self) == "hello\nworld\n")
    }
    @Test func silentProcessCanBeCancelled() throws {
        let control = OperationControl()
        let session = try ProcessSession(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], environment: [:], directory: FileManager.default.temporaryDirectory)
        defer { session.stop() }
        control.cancel()
        #expect(throws: AccountError.self) { try session.line(until: Date().addingTimeInterval(5), control: control) }
    }
    @Test func silentProcessTimesOut() throws {
        let session = try ProcessSession(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], environment: [:], directory: FileManager.default.temporaryDirectory)
        defer { session.stop() }
        #expect(throws: AccountError.self) { try session.line(until: Date().addingTimeInterval(0.05), control: OperationControl()) }
    }
    // Explicit opt-in: exercises the installed binary, never opens a browser or signs in.
    @Test func isolatedCodexLoginCancellation() throws {
        guard ProcessInfo.processInfo.environment["AGENTBAR_LIVE_AUTH_PROBE"] == "1" else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentbar-live-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let control = OperationControl()
        let rpc = try CodexRPC(directory: directory, control: control)
        defer { rpc.stop() }
        #expect(throws: AccountError.self) { try rpc.identity() }
        #expect(throws: AccountError.self) {
            try rpc.login { url in
                #expect(url.scheme == "https")
                #expect(url.host?.hasSuffix("openai.com") == true)
                control.cancel()
            }
        }
        #expect(control.cancelled, "The installed CLI must reach the login URL callback before cancellation.")
    }
}
