import Foundation
import Testing
@testable import agent_bar

// Signing an account in for Claude Code, once, from Settings: the browser signs the account in to its own lend folder.
// The default login is never read or written by it. Against the same fake Claude Code and Keychain as the switch tests.
struct ClaudeCodePrepareTests {
    // MARK: The sign-in

    @Test func theBrowserSignsTheAccountInToItsOwnFolderAndTheDefaultLoginIsNeverTouched() throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev"), target = f.addAccount("target")
        let prevToken = f.signInDefault(prev)
        let identityBefore = try Data(contentsOf: f.defaultSlot.identityFile)
        f.world.plan(.signIn("target@example.test"))
        // While the browser waits, nothing exists that a restart would have to finish.
        let journalWhileWaiting = Recorder<Bool>()

        let result = f.prepare(target, openURL: { _ in journalWhileWaiting.add(f.journal == nil) })

        #expect(result.outcome == .prepared)
        #expect(result.steps == [.checkingVersion, .waitingForBrowser])
        #expect(f.world.openedURLs == [FakeClaudeWorld.browserURL] && journalWhileWaiting.values == [true])
        // Only the account's folder is looked at: the default login is neither read nor written, and the only program run
        // is the version check.
        #expect(f.world.events == ["version", "read lend(target)", "browser lend(target)", "read lend(target)"])
        #expect(f.world.calls.map(\.arguments) == [["--version"]])
        #expect(f.defaultEmail == "prev@example.test" && f.world.token(in: f.defaultSlot) == prevToken && f.world.isLive(prevToken))
        #expect(try Data(contentsOf: f.defaultSlot.identityFile) == identityBefore)
        // The login waits in the account's folder for the switch that will use it.
        #expect(f.lendEmail(target) == "target@example.test" && f.switcher.hasLendLogin(for: target))
        #expect(f.journal == nil && f.world.problems.isEmpty)
    }

    @Test func theLoginTheBrowserMadeIsWhatTheNextSwitchHandsOverWithoutAnotherBrowser() throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev"), target = f.addAccount("target")
        f.signInDefault(prev)
        f.world.plan(.signIn("target@example.test"))
        #expect(f.prepare(target).outcome == .prepared)

        let result = f.switchTo(target)

        #expect(result.outcome == .switched(.init(accountID: target.id, previousAccountID: prev.id, needsLogin: [])))
        #expect(f.world.events.filter { $0.hasPrefix("browser") }.count == 1, "the one in the sign-in, none in the switch")
        #expect(f.defaultEmail == "target@example.test" && f.lendEmail(prev) == "prev@example.test")
        #expect(f.world.problems.isEmpty)
    }

    @Test func aLoginAlreadyWaitingIsLeftAloneAndNoBrowserOpens() throws {
        let f = try SwitchFixture()
        let target = f.addAccount("target")
        let token = try f.saveLogin(for: target)
        f.world.plan(.signIn("target@example.test"))

        let result = f.prepare(target)

        #expect(result.outcome == .alreadyPrepared)
        #expect(result.steps == [.checkingVersion])
        #expect(f.world.events == ["version", "read lend(target)"])
        #expect(f.world.openedURLs.isEmpty && f.world.token(in: f.lendSlot(target)) == token && f.world.isLive(token))
    }

    @Test func aLoginInTheFolderThatCannotBeUsedIsClearedBeforeTheBrowserSignsIn() throws {
        // Somebody else's login, and a login that has no refresh token to hand over.
        for stored in ["intruder@example.test", "target@example.test"] {
            let f = try SwitchFixture()
            let target = f.addAccount("target")
            try f.files.createPrivateDirectory(f.files.lendRoot)
            try f.files.createPrivateDirectory(f.files.lend(target.id))
            f.world.signIn(f.lendSlot(target), as: stored)
            if stored == "target@example.test" {
                f.world.setSecret(f.lendSlot(target), Data(#"{"claudeAiOauth":{"accessToken":"FAKE-ACCESS-ONLY"}}"#.utf8))
            }
            f.world.plan(.signIn("target@example.test"))

            let result = f.prepare(target)

            #expect(result.outcome == .prepared)
            #expect(f.world.events == ["version", "read lend(target)", "delete lend(target)", "browser lend(target)", "read lend(target)"])
            #expect(f.lendEmail(target) == "target@example.test" && f.switcher.hasLendLogin(for: target))
        }
    }

    // MARK: When it does not work

    @Test func aBrowserLoginAsAnotherAccountIsDiscarded() throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev"), target = f.addAccount("target")
        f.signInDefault(prev)
        f.world.plan(.signIn("someone.else@example.test"))

        let result = f.prepare(target)

        #expect(result.outcome == .failed("Signed in as a different account."))
        #expect(!f.world.hasItem(f.lendSlot(target)) && !f.lendFolderExists(target))
        #expect(f.defaultEmail == "prev@example.test" && !f.world.events.contains { $0.hasSuffix("default") || $0.hasPrefix("login") })
        let step = try #require(f.logLines.first { $0["step"] as? String == "browserSignIn" && $0["outcome"] as? String != "waiting" })
        #expect(step["outcome"] as? String == "differentAccount")
    }

    @Test func aSignInWithoutARefreshTokenToHandOverIsNotKept() throws {
        let f = try SwitchFixture()
        let target = f.addAccount("target")
        f.world.plan(.signInWithoutRefreshToken("target@example.test"))

        let result = f.prepare(target)

        #expect(result.outcome == .failed("The browser sign-in could not be used. Try again."))
        #expect(!f.world.hasItem(f.lendSlot(target)) && !f.lendFolderExists(target))
    }

    @Test func cancellingTheWaitLeavesNothingBehind() throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev"), target = f.addAccount("target")
        let prevToken = f.signInDefault(prev)
        let control = OperationControl()
        f.world.plan(.signIn("target@example.test"))

        let result = f.prepare(target, control: control, openURL: { _ in control.cancel() })

        #expect(result.outcome == .cancelled)
        #expect(result.steps.last == .waitingForBrowser)
        #expect(!f.lendFolderExists(target) && !f.world.hasItem(f.lendSlot(target)))
        #expect(f.defaultEmail == "prev@example.test" && f.world.isLive(prevToken) && f.journal == nil)
        let last = try #require(f.logLines.last)
        #expect(last["outcome"] as? String == "cancelled" && last["operation"] as? String == "prepare")
    }

    @Test func aBrowserThatDoesNotFinishFailsWithItsReasonAndLeavesNothingBehind() throws {
        let cases: [(FakeClaudeWorld.Browser, String)] = [(.timeout, "Browser sign-in timed out. Try again."),
                                                          (.failure, "Browser sign-in did not finish. Try again.")]
        for (plan, reason) in cases {
            let f = try SwitchFixture()
            let prev = f.addAccount("prev"), target = f.addAccount("target")
            f.signInDefault(prev)
            f.world.plan(plan)

            let result = f.prepare(target)

            #expect(result.outcome == .failed(reason))
            #expect(!f.lendFolderExists(target) && !f.world.hasItem(f.lendSlot(target)) && f.defaultEmail == "prev@example.test")
        }
    }

    @Test func anOldOrUnreadableClaudeCodeStopsTheSignInBeforeAnythingElse() throws {
        let cases: [(String, String)] = [
            ("2.1.308 (Claude Code)\n", "Claude Code 2.1.308 is too old. Update to 2.1.309 or newer."),
            ("zsh: command not found: claude\n", "Could not read the Claude Code version. Update Claude Code and try again."),
        ]
        for (version, reason) in cases {
            let f = try SwitchFixture()
            let target = f.addAccount("target")
            f.world.version = version
            f.world.plan(.signIn("target@example.test"))

            let result = f.prepare(target)

            #expect(result.outcome == .failed(reason))
            #expect(result.steps == [.checkingVersion])
            #expect(f.world.events == ["version"] && f.world.openedURLs.isEmpty && !f.lendFolderExists(target))
        }
    }

    @Test func accountsThatCannotBeToldApartOrAreNotClaudeAreRefused() throws {
        let f = try SwitchFixture()
        let unverifiable = UsageAccount(id: UUID(), provider: .claude, name: "legacy", identity: nil)
        let codex = UsageAccount(id: UUID(), provider: .codex, name: "codex",
                                 identity: AccountIdentity(email: "c@example.test", organizationID: "o", stableID: "s"))
        f.world.plan(.signIn("legacy@example.test"))

        #expect(f.prepare(unverifiable).outcome == .failed("Reconnect this account before using it in Claude Code."))
        #expect(f.prepare(codex).outcome == .failed("Only a Claude account can be used in Claude Code."))
        #expect(f.world.events.isEmpty && f.world.openedURLs.isEmpty)
    }

    // MARK: One at a time

    @Test func aSignInAndASwitchOrARemovalNeverRunTogether() throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev"), target = f.addAccount("target"), other = f.addAccount("other")
        f.signInDefault(prev)
        try f.saveLogin(for: other)
        f.world.plan(.signIn("target@example.test"))
        let waiting = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        let first = Recorder<ClaudeCodePrepareOutcome>()
        runOnNewThread {
            first.add(f.prepare(target, openURL: { _ in waiting.signal(); release.wait() }).outcome)
            finished.signal()
        }
        #expect(waiting.wait(timeout: .now() + 20) == .success)
        let events = f.world.events

        // A switch, another sign-in and a removal are all turned away while the browser is waited for.
        #expect(f.switchTo(other).outcome == .failed(.init(reason: "Another Claude Code switch is still running.", nothingChanged: true)))
        #expect(f.prepare(other).outcome == .failed("Another Claude Code operation is still running. Try again in a moment."))
        #expect(throws: ClaudeCodeBusyError()) { try f.switcher.removeLendLogin(for: other.id) }
        #expect(f.world.events == events && f.world.hasItem(f.lendSlot(other)) && f.defaultEmail == "prev@example.test")

        release.signal()
        #expect(finished.wait(timeout: .now() + 20) == .success)
        #expect(first.values == [.prepared])
        // Afterwards the engine is free again.
        #expect(f.switchTo(other).outcome == .switched(.init(accountID: other.id, previousAccountID: prev.id, needsLogin: [])))
    }

    @Test func aSignInIsTurnedAwayWhileASwitchRuns() throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev"), target = f.addAccount("target"), other = f.addAccount("other")
        f.signInDefault(prev)
        try f.saveLogin(for: other)
        f.world.plan(.signIn("target@example.test"))
        let hold = f.world.hold(login: "default")
        let finished = DispatchSemaphore(value: 0)
        runOnNewThread { _ = f.switchTo(other); finished.signal() }
        #expect(hold.entered.wait(timeout: .now() + 20) == .success)
        let events = f.world.events

        let result = f.prepare(target)

        #expect(result.outcome == .failed("Another Claude Code operation is still running. Try again in a moment."))
        #expect(result.steps.isEmpty && f.world.events == events && f.world.openedURLs.isEmpty && !f.lendFolderExists(target))
        hold.release.signal()
        #expect(finished.wait(timeout: .now() + 20) == .success)
    }

    // MARK: Folders and the log

    @Test func theFolderIsPrivateAndNeverHoldsACredentialsFile() throws {
        let f = try SwitchFixture()
        let target = f.addAccount("target")
        f.world.plan(.signIn("target@example.test"))

        #expect(f.prepare(target).outcome == .prepared)

        let folder = f.files.lend(target.id)
        #expect(permissions(f.files.lendRoot) == 0o700 && permissions(folder) == 0o700)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(!names.contains(".credentials.json"))
        #expect(!names.contains("agentbar-browser-opener") && !names.contains("agentbar-oauth-url"))
    }

    @Test func theUsageLoginsAreNeverTouched() throws {
        for outcomeWorks in [true, false] {
            let f = try SwitchFixture()
            let prev = f.addAccount("prev"), target = f.addAccount("target")
            f.signInDefault(prev)
            f.world.plan(outcomeWorks ? .signIn("target@example.test") : .signIn("someone.else@example.test"))
            var before: [URL: [String: Data]] = [:]
            for account in [prev, target] {
                let folder = f.files.credentials(try #require(account.credentialID))
                try f.files.createPrivateDirectory(folder)
                try Data("usage-login-of-\(account.name)".utf8).write(to: folder.appendingPathComponent(".credentials.json"))
                before[folder] = try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(atPath: folder.path).map {
                    ($0, try Data(contentsOf: folder.appendingPathComponent($0)))
                })
            }

            let result = f.prepare(target)

            if case .prepared = result.outcome { #expect(outcomeWorks) } else { #expect(!outcomeWorks) }
            for (folder, contents) in before {
                let now = try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(atPath: folder.path).map {
                    ($0, try Data(contentsOf: folder.appendingPathComponent($0)))
                })
                #expect(now == contents)
            }
            #expect(!f.world.calls.contains { $0.environment.values.contains { $0.contains("/credentials/") } })
        }
    }

    @Test func everyStepIsLoggedAsASignInUnderOneAttemptWithoutAnyToken() throws {
        let f = try SwitchFixture()
        let target = f.addAccount("target")
        f.world.plan(.signIn("target@example.test"))

        let result = f.prepare(target)

        #expect(result.outcome == .prepared)
        let lines = f.logLines
        #expect(lines.first?["event"] as? String == "start" && lines.last?["event"] as? String == "result")
        // Told apart from a switch by its first line, and by its result.
        #expect(lines.first?["operation"] as? String == "prepare" && lines.last?["operation"] as? String == "prepare")
        #expect(Set(lines.compactMap { $0["attempt"] as? String }).count == 1 && lines.allSatisfy { $0["attempt"] != nil })
        #expect(lines.allSatisfy { $0["account"] as? String == "target@example.test" && $0["provider"] as? String == "claude" && $0["time"] != nil })
        #expect(lines.compactMap { $0["step"] as? String } == ["version", "savedLogin", "browserSignIn", "browserSignIn"])
        #expect(lines.compactMap { $0["outcome"] as? String } == ["ok", "none", "waiting", "ok", "prepared"])
        let text = f.logText
        for token in f.world.allTokens { #expect(!text.contains(token)) }
        #expect(!text.contains("FAKE-REFRESH") && !text.contains("FAKE-ACCESS"))
        #expect(permissions(f.logURL) == 0o600)
    }

    @Test func aSignInThatFailedIsLoggedWithItsReason() throws {
        let f = try SwitchFixture()
        let target = f.addAccount("target")
        f.world.plan(.timeout)

        _ = f.prepare(target)

        let last = try #require(f.logLines.last)
        #expect(last["event"] as? String == "result" && last["outcome"] as? String == "failed")
        #expect(last["message"] as? String == "Browser sign-in timed out. Try again.")
    }
}
