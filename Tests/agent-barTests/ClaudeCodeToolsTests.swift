import Foundation
import Testing
@testable import agent_bar

// The real wrappers around `claude` and `/usr/bin/security`, run against small shell scripts that stand in for
// them. No real Claude Code, Keychain item or login is involved.
struct ClaudeCodeToolsTests {
    // MARK: claude

    @Test func claudeIsRunWithExactlyTheGivenEnvironmentAndNoInput() throws {
        let directory = try workDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let claude = try script(in: directory, """
        echo "args=$*"
        echo "config=${CLAUDE_CONFIG_DIR-unset}"
        echo "secure=${CLAUDE_SECURESTORAGE_CONFIG_DIR-unset}"
        echo "home=${HOME-unset}"
        echo "token=${CLAUDE_CODE_OAUTH_REFRESH_TOKEN-unset}"
        echo "problem reported on stderr" >&2
        if read -r line; then echo "stdin=open"; else echo "stdin=closed"; fi
        exit 3
        """)
        let cli = SystemClaudeCLI(executable: { claude })

        let folder = ClaudeSlot.folder(directory.appendingPathComponent("lend"))
        var environment = folder.environment
        environment["CLAUDE_CODE_OAUTH_REFRESH_TOKEN"] = "FAKE-TOKEN"
        let inFolder = try cli.run(["auth", "login", "--claudeai"], environment: environment, directory: directory, timeout: 20)
        #expect(inFolder.status == 3 && !inFolder.timedOut)
        #expect(inFolder.text.contains("args=auth login --claudeai"))
        #expect(inFolder.text.contains("config=\(folder.directory!.path)") && inFolder.text.contains("secure=\(folder.directory!.path)"))
        #expect(inFolder.text.contains("token=FAKE-TOKEN"))
        // stderr comes back with stdout, and the input is already closed.
        #expect(inFolder.text.contains("problem reported on stderr"))
        #expect(inFolder.text.contains("stdin=closed"))
        // Nothing is inherited from the test process: the child sees only what it was given.
        let bare = try cli.run([], environment: ["PATH": "/usr/bin:/bin"], directory: directory, timeout: 20)
        #expect(bare.text.contains("home=unset") && bare.text.contains("config=unset") && bare.text.contains("token=unset"))

        let asDefault = try cli.run(["--version"], environment: ClaudeSlot.defaultLogin().environment, directory: directory, timeout: 20)
        #expect(asDefault.text.contains("config=unset") && asDefault.text.contains("secure=unset"))
    }

    @Test func aCommandThatDoesNotFinishIsReportedAsTimedOutAndStopped() throws {
        let directory = try workDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("still-running")
        let claude = try script(in: directory, """
        sleep 1; echo alive > "\(marker.path)"; sleep 30
        """)
        let started = Date()

        let result = try SystemClaudeCLI(executable: { claude }).run(["auth", "login"], environment: ["PATH": "/usr/bin:/bin"],
                                                                      directory: directory, timeout: 0.3)

        #expect(result.timedOut && result.status == nil)
        #expect(Date().timeIntervalSince(started) < 10)
        // It was stopped, not left to finish in the background.
        Thread.sleep(forTimeInterval: 1.5)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func aCommandThatRanOutOfTimeStillReportsWhatItPrinted() throws {
        let directory = try workDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let claude = try script(in: directory, """
        echo "Login failed: Request failed with status code 400" >&2
        sleep 30
        """)

        let result = try SystemClaudeCLI(executable: { claude }).run(["auth", "login"], environment: ["PATH": "/usr/bin:/bin"],
                                                                      directory: directory, timeout: 3)

        #expect(result.timedOut && result.status == nil)
        #expect(result.text.contains("Login failed: Request failed with status code 400"))
        // So a refusal that was printed before the command hung is still a refusal.
        #expect(ClaudeCodeOutput.classify(result.text) == .invalid)
    }

    // The two failures Claude Code 2.1.312 gives for `claude auth login --claudeai` with a refresh token, as they were
    // seen with throwaway tokens in a throwaway folder: nothing on stdout, one line on stderr, exit code 1, no browser.
    @Test func theRealFailureTextsComeBackAsTheyWereAndAreClassified() throws {
        let directory = try workDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let refused = try script(in: directory, "echo 'Login failed: Request failed with status code 400' >&2\nexit 1")
        let offline = try script(in: directory, "echo 'Login failed: connect ECONNREFUSED 127.0.0.1:9' >&2\nexit 1")
        let environment = ["PATH": "/usr/bin:/bin"]

        let first = try SystemClaudeCLI(executable: { refused }).run(["auth", "login", "--claudeai"], environment: environment, directory: directory, timeout: 20)
        let second = try SystemClaudeCLI(executable: { offline }).run(["auth", "login", "--claudeai"], environment: environment, directory: directory, timeout: 20)

        #expect(first.status == 1 && first.text == "Login failed: Request failed with status code 400\n")
        #expect(ClaudeCodeOutput.classify(first.text) == .invalid)
        #expect(second.status == 1 && second.text == "Login failed: connect ECONNREFUSED 127.0.0.1:9\n")
        #expect(ClaudeCodeOutput.classify(second.text) == .transient)
    }

    @Test func collectPartialReturnsWhatArrivedAndCollectStillThrowsOnTimeout() throws {
        let environment = ["PATH": "/usr/bin:/bin"], directory = FileManager.default.temporaryDirectory
        let talking = try ProcessSession(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo first; sleep 30"],
                                         environment: environment, directory: directory)
        defer { talking.stop() }
        let (data, timedOut) = try talking.collectPartial(until: Date().addingTimeInterval(3), control: OperationControl())
        #expect(timedOut && String(decoding: data, as: UTF8.self) == "first\n")

        let finished = try ProcessSession(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo done"],
                                          environment: environment, directory: directory)
        defer { finished.stop() }
        let (all, late) = try finished.collectPartial(until: Date().addingTimeInterval(20), control: OperationControl())
        #expect(!late && String(decoding: all, as: UTF8.self) == "done\n" && finished.exitStatus == 0)

        let silent = try ProcessSession(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], environment: environment, directory: directory)
        defer { silent.stop() }
        #expect(throws: AccountError.self) { try silent.collect(until: Date().addingTimeInterval(0.3), control: OperationControl()) }
        let cancelled = OperationControl(); cancelled.cancel()
        #expect(throws: AccountError.self) { try silent.collectPartial(until: Date().addingTimeInterval(20), control: cancelled) }
    }

    @Test func aMissingClaudeIsAnError() throws {
        let cli = SystemClaudeCLI(executable: { throw AccountError.message("Could not find the Claude CLI.") })
        #expect(throws: AccountError.self) {
            try cli.run(["--version"], environment: [:], directory: FileManager.default.temporaryDirectory, timeout: 5)
        }
    }

    // MARK: The browser sign-in

    @Test func theBrowserSignInHandsOverOnlyAValidatedURLAndWaitsForClaude() throws {
        let directory = try workDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("lend"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let claude = try script(in: directory, browserScript(url: "https://claude.ai/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A54321%2Fcallback"))
        let opened = Recorder<URL>()

        try SystemClaudeCLI(executable: { claude }, urlTimeout: 5, loginTimeout: 20).browserLogin(directory: folder, control: OperationControl()) { url in
            opened.add(url)
            // Claude Code goes on only after the URL was handed over.
            FileManager.default.createFile(atPath: folder.appendingPathComponent("go").path, contents: Data())
        }

        #expect(opened.values.map(\.host) == ["claude.ai"])
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(".claude.json").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("agentbar-oauth-url").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(".credentials.json").path))
    }

    @Test func aURLThatIsNotClaudesIsNeverOpened() throws {
        let directory = try workDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("lend"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let claude = try script(in: directory, browserScript(url: "https://example.test/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A54321%2Fcallback"))
        let opened = Recorder<URL>()

        #expect(throws: AccountError.self) {
            try SystemClaudeCLI(executable: { claude }, urlTimeout: 1, loginTimeout: 5)
                .browserLogin(directory: folder, control: OperationControl()) { opened.add($0) }
        }
        #expect(opened.values.isEmpty)
    }

    @Test func cancellingTheBrowserWaitStopsClaude() throws {
        let directory = try workDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("lend"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let claude = try script(in: directory, browserScript(url: "https://claude.ai/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A54321%2Fcallback"))
        let control = OperationControl()
        let started = Date()

        do {
            try SystemClaudeCLI(executable: { claude }, urlTimeout: 5, loginTimeout: 60)
                .browserLogin(directory: folder, control: control) { _ in control.cancel() }
            Issue.record("A cancelled sign-in must not succeed")
        } catch AccountError.cancelled {
            #expect(Date().timeIntervalSince(started) < 10)
        }
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(".claude.json").path))
    }

    @Test func aBrowserSignInThatNeverFinishesTimesOut() throws {
        let directory = try workDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("lend"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let claude = try script(in: directory, browserScript(url: "https://claude.ai/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A54321%2Fcallback"))

        do {
            try SystemClaudeCLI(executable: { claude }, urlTimeout: 5, loginTimeout: 0.5)
                .browserLogin(directory: folder, control: OperationControl()) { _ in }
            Issue.record("A sign-in nobody finishes must not succeed")
        } catch AccountError.timeout {}
    }

    // MARK: security

    // `security` exits 44 for an item that does not exist, which was also seen on the real tool.
    @Test func securityIsAskedForAttributesSecretsAndRemovalsWithExactArguments() throws {
        let directory = try workDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let calls = directory.appendingPathComponent("calls.log")
        let security = try script(in: directory, """
        echo "$@" >> "\(calls.path)"
        service=""
        for argument in "$@"; do if [ "$previous" = "-s" ]; then service="$argument"; fi; previous="$argument"; done
        case "$1:$service" in
          find-generic-password:present)
            if [ "$2" = "-w" ]; then printf '%s\\n' '{"claudeAiOauth":{"refreshToken":"FAKE-REFRESH-TOKEN"}}'; else echo 'keychain: "login.keychain-db"'; fi
            exit 0;;
          delete-generic-password:present) echo 'password has been deleted.'; exit 0;;
          *:locked) exit 36;;
          *) echo 'The specified item could not be found in the keychain.' >&2; exit 44;;
        esac
        """)
        let keychain = SecurityCommandKeychain(executable: security, timeout: 20)

        #expect(try keychain.contains(service: "present", account: "me"))
        #expect(try !keychain.contains(service: "absent", account: "me"))
        let secret = try #require(try keychain.readSecret(service: "present", account: "me"))
        #expect(String(decoding: secret, as: UTF8.self) == #"{"claudeAiOauth":{"refreshToken":"FAKE-REFRESH-TOKEN"}}"#)
        #expect(try keychain.readSecret(service: "absent", account: "me") == nil)
        try keychain.delete(service: "present", account: "me")
        try keychain.delete(service: "absent", account: "me")
        #expect(throws: AccountError.self) { try keychain.contains(service: "locked", account: "me") }
        #expect(throws: AccountError.self) { try keychain.readSecret(service: "locked", account: "me") }
        #expect(throws: AccountError.self) { try keychain.delete(service: "locked", account: "me") }

        let lines = try String(contentsOf: calls, encoding: .utf8).split(separator: "\n").map(String.init)
        // Attributes only for "does it exist" (no -w, no -g), the secret only with -w.
        #expect(lines.prefix(7) == ["find-generic-password -s present -a me", "find-generic-password -s absent -a me",
                                    "find-generic-password -w -s present -a me", "find-generic-password -w -s absent -a me",
                                    "delete-generic-password -s present -a me", "delete-generic-password -s absent -a me",
                                    "find-generic-password -s locked -a me"])
    }

    @Test func aKeychainCommandThatHangsGivesUpInsteadOfWaitingForAPrompt() throws {
        let directory = try workDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let security = try script(in: directory, "sleep 30")
        let started = Date()

        #expect(throws: AccountError.self) {
            try SecurityCommandKeychain(executable: security, timeout: 0.3).readSecret(service: "present", account: "me")
        }
        #expect(Date().timeIntervalSince(started) < 10)
    }

    // MARK: Helpers

    private func browserScript(url: String) -> String {
        """
        "$BROWSER" "\(url)"
        waited=0
        while [ ! -e "$CLAUDE_CONFIG_DIR/go" ] && [ $waited -lt 300 ]; do sleep 0.1; waited=$((waited+1)); done
        [ -e "$CLAUDE_CONFIG_DIR/go" ] || exit 9
        echo '{"oauthAccount":{"accountUuid":"acc-1"}}' > "$CLAUDE_CONFIG_DIR/.claude.json"
        exit 0
        """
    }

    private func workDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentbar-tools-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func script(in directory: URL, _ body: String) throws -> URL {
        let url = directory.appendingPathComponent("tool-\(UUID().uuidString)")
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}
