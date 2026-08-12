import Darwin
import Foundation
import Testing
@testable import agent_bar

struct CodexAppServerClientTests {
    @Test
    func nativeLauncherWorksWithoutNodeOnPath() throws {
        let fixture = try makeFixtureDirectory(named: "native fixture")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let codex = fixture.appendingPathComponent("codex")
        try writeExecutable(nativeFixtureScript, to: codex)

        let response = try CodexAppServerClient().request(
            codexBinary: codex,
            runtimeDirectories: [],
            environment: minimalEnvironment
        )

        #expect(response["id"] as? Int == 2)
    }

    @Test
    func envNodeLauncherWorksWithMinimalFinderPathAndQuotedDirectories() throws {
        let fixture = try makeFixtureDirectory(named: "codex fixture's dir")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let runtime = fixture.appendingPathComponent("node runtime's dir", isDirectory: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)

        let node = runtime.appendingPathComponent("node")
        try writeExecutable("#!/bin/sh\nexec /bin/sh \"$@\"\n", to: node)
        let codex = fixture.appendingPathComponent("codex launcher")
        try writeExecutable("#!/usr/bin/env node\n\(fixtureResponseBody)\n", to: codex)

        let response = try CodexAppServerClient().request(
            codexBinary: codex,
            runtimeDirectories: [runtime],
            environment: minimalEnvironment
        )

        #expect(response["id"] as? Int == 2)
    }

    @Test
    func envNodeLauncherReportsMissingRuntime() throws {
        let fixture = try makeFixtureDirectory(named: "missing runtime")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let codex = fixture.appendingPathComponent("codex")
        try writeExecutable("#!/usr/bin/env node\n\(fixtureResponseBody)\n", to: codex)

        do {
            _ = try CodexAppServerClient().request(
                codexBinary: codex,
                runtimeDirectories: [],
                environment: minimalEnvironment
            )
            Issue.record("Expected the env-node launcher to fail without a Node runtime.")
        } catch {
            #expect(error.localizedDescription.localizedCaseInsensitiveContains("node"))
        }
    }

    @Test
    func appServerJSONRPCErrorPreservesItsMessage() throws {
        let fixture = try makeFixtureDirectory(named: "error fixture")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let codex = fixture.appendingPathComponent("codex")
        try writeExecutable(
            "#!/bin/sh\nprintf '%s\\n' '{\"jsonrpc\":\"2.0\",\"id\":2,\"error\":{\"message\":\"fixture account error\"}}'\n/bin/sleep 4\n",
            to: codex
        )

        let startedAt = Date()
        do {
            _ = try CodexAppServerClient().request(
                codexBinary: codex,
                runtimeDirectories: [],
                environment: minimalEnvironment
            )
            Issue.record("Expected the fixture app-server error to be thrown.")
        } catch {
            #expect(error.localizedDescription.contains("fixture account error"))
            #expect(Date().timeIntervalSince(startedAt) < 2)
        }
    }

    @Test
    func successfulRequestKillsTermIgnoringLauncherAndDescendant() throws {
        let fixture = try makeFixtureDirectory(named: "cleanup fixture")
        let pidFile = fixture.appendingPathComponent("pids")
        var processIDs: [Int32] = []
        defer {
            forceCleanup(processIDs)
            try? FileManager.default.removeItem(at: fixture)
        }
        let codex = fixture.appendingPathComponent("codex")
        try writeExecutable(termIgnoringFixtureScript(emitsResponse: true), to: codex)

        var environment = minimalEnvironment
        environment["AGENT_BAR_TEST_PID_FILE"] = pidFile.path
        let response = try CodexAppServerClient().request(
            codexBinary: codex,
            runtimeDirectories: [],
            environment: environment
        )
        processIDs = try readProcessIDs(from: pidFile)

        #expect(response["id"] as? Int == 2)
        #expect(processIDs.count == 2)
        #expect(waitUntilProcessesExit(processIDs))
    }

    @Test
    func outerTimeoutKillsTermIgnoringLauncherAndDescendant() throws {
        let fixture = try makeFixtureDirectory(named: "timeout cleanup fixture")
        let pidFile = fixture.appendingPathComponent("pids")
        var processIDs: [Int32] = []
        defer {
            forceCleanup(processIDs)
            try? FileManager.default.removeItem(at: fixture)
        }
        let codex = fixture.appendingPathComponent("codex")
        try writeExecutable(termIgnoringFixtureScript(emitsResponse: false), to: codex)

        var environment = minimalEnvironment
        environment["AGENT_BAR_TEST_PID_FILE"] = pidFile.path
        do {
            _ = try CodexAppServerClient().request(
                codexBinary: codex,
                runtimeDirectories: [],
                environment: environment,
                timeout: 2
            )
            Issue.record("Expected the outer process timeout to fail the request.")
        } catch {
            #expect(error.localizedDescription.contains("did not finish"))
        }
        processIDs = try readProcessIDs(from: pidFile)

        #expect(processIDs.count == 2)
        #expect(waitUntilProcessesExit(processIDs))
    }

    private var minimalEnvironment: [String: String] {
        ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
    }

    private var nativeFixtureScript: String {
        "#!/bin/sh\n\(fixtureResponseBody)\n"
    }

    private var fixtureResponseBody: String {
        "printf '%s\\n' '{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"rateLimits\":{\"planType\":\"pro\",\"primary\":{\"usedPercent\":11,\"windowDurationMins\":10080,\"resetsAt\":1800100000},\"secondary\":null}}}'"
    }

    private func termIgnoringFixtureScript(emitsResponse: Bool) -> String {
        let response = emitsResponse ? "\(fixtureResponseBody)\n" : ""
        return """
        #!/bin/sh
        trap '' TERM
        /bin/sh -c 'trap "" TERM; while :; do /bin/sleep 1; done' &
        descendant=$!
        printf '%s %s\n' "$$" "$descendant" > "$AGENT_BAR_TEST_PID_FILE"
        \(response)while :; do /bin/sleep 1; done
        """
    }

    private func makeFixtureDirectory(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentBarTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeExecutable(_ contents: String, to url: URL) throws {
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }

    private func readProcessIDs(from url: URL) throws -> [Int32] {
        let contents = try String(contentsOf: url, encoding: .utf8)
        return contents.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
    }

    private func waitUntilProcessesExit(
        _ processIDs: [Int32],
        timeout: TimeInterval = 3
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if processIDs.allSatisfy({ processExists($0) == false }) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return processIDs.allSatisfy { processExists($0) == false }
    }

    private func processExists(_ processID: Int32) -> Bool {
        if kill(processID, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    private func forceCleanup(_ processIDs: [Int32]) {
        guard let processGroupID = processIDs.first else { return }
        kill(-processGroupID, SIGKILL)
        for processID in processIDs {
            kill(processID, SIGKILL)
        }
    }
}
