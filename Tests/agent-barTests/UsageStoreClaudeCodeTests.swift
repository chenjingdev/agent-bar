import AppKit
import Foundation
import SwiftUI
import Testing
@testable import agent_bar

// The store's side of "Use in Claude Code", against the fake Claude Code and Keychain from the engine tests. The real
// `claude`, `/usr/bin/security` and default login are never named: the engine is built from the fake world and a
// default login that lives in the temporary directory. The suite runs one test at a time because the engine blocks
// threads of the shared pool while a test holds a step shut.
@MainActor
@Suite(.serialized)
struct UsageStoreClaudeCodeTests {
    private static let tooOld = "Claude Code 2.1.308 is too old. Update to 2.1.309 or newer."

    // MARK: What each window shows

    @Test func theAccountClaudeCodeUsesSaysSoAndTheOthersOfferTheButton() async throws {
        let f = try StoreFixture(["a", "b"], signedIn: "a"); defer { f.close() }
        await f.start()

        #expect(f.panel("a") == ClaudeCodePanel(control: .inClaudeCode, lines: []))
        #expect(f.panel("b").lines.isEmpty && f.enabled("b"))
        #expect(f.store.claudeCodeAvailability == .ready)
        #expect(f.store.claudeCodeAccountID == f.account("a").id)
    }

    @Test func theMarkerFollowsTheRealLoginWhoeverChangesIt() async throws {
        let f = try StoreFixture(["a", "b"], signedIn: "a"); defer { f.close() }
        await f.start()

        // Signed in as b in a terminal.
        f.switching.signInDefault(f.account("b"))
        await f.refresh()
        #expect(f.panel("b").control == .inClaudeCode && f.enabled("a"))

        // Logged out: no window has the marker.
        f.world.removeItem(f.switching.defaultSlot)
        await f.refresh()
        #expect(f.enabled("a") && f.enabled("b"))

        // Signed in as somebody AgentBar does not have: still no marker.
        f.switching.signInDefault(email: "stranger@example.test")
        await f.refresh()
        #expect(f.enabled("a") && f.enabled("b") && f.store.claudeCodeAccountID == nil)
    }

    @Test func openingAPopoverReadsTheLoginAgainButTheVersionOnlyEachCycle() async throws {
        let f = try StoreFixture(["a", "b"], signedIn: "a"); defer { f.close() }
        await f.start()
        f.world.version = "2.1.308 (Claude Code)\n"
        f.switching.signInDefault(f.account("b"))

        f.store.popoverWillOpen()
        await f.store.claudeCodeReading?.value

        #expect(f.panel("b").control == .inClaudeCode)
        #expect(f.store.claudeCodeAvailability == .ready)
        await f.refresh()
        #expect(f.store.claudeCodeAvailability == .blocked(Self.tooOld))
    }

    @Test func withoutClaudeCodeNoWindowOffersAnything() async throws {
        let f = try StoreFixture(["a", "b"], signedIn: "a"); defer { f.close() }
        f.gates.installed = false
        await f.start()

        #expect(f.panel("a") == .hidden && f.panel("b") == .hidden)
        #expect(f.store.claudeCodeAvailability == .missing)
        // Pressing what is not there does nothing.
        f.press("b")
        #expect(f.store.claudeCodeActivity == nil && !f.gates.calls.contains("login"))

        // Installing it shows the buttons within one refresh, and removing it hides them within one.
        f.gates.installed = true
        await f.refresh()
        #expect(f.panel("a").control == .inClaudeCode && f.enabled("b"))
        f.gates.installed = false
        await f.refresh()
        #expect(f.panel("a") == .hidden && f.panel("b") == .hidden)
    }

    @Test func anOldClaudeCodeBlocksTheButtonAndSaysWhy() async throws {
        let f = try StoreFixture(["a", "b"], signedIn: "a"); defer { f.close() }
        f.world.version = "2.1.308 (Claude Code)\n"
        await f.start()

        #expect(f.panel("b") == ClaudeCodePanel(control: .use(enabled: false, help: Self.tooOld), lines: [.notice(Self.tooOld)]))
        // The account Claude Code uses still says so, without a reason for a button it does not have.
        #expect(f.panel("a") == ClaudeCodePanel(control: .inClaudeCode, lines: []))
        let before = f.gates.calls
        f.press("b")
        #expect(f.store.claudeCodeActivity == nil && f.gates.calls == before)

        // Updating Claude Code is noticed within one refresh.
        f.world.version = "2.1.312 (Claude Code)\n"
        await f.refresh()
        #expect(f.enabled("b") && f.panel("b").lines.isEmpty)
    }

    @Test func aVersionThatCannotBeReadBlocksTheButtonToo() async throws {
        let f = try StoreFixture(["a", "b"], signedIn: "a"); defer { f.close() }
        f.world.version = "zsh: command not found: claude\n"
        await f.start()

        let reason = "Could not read the Claude Code version. Update Claude Code and try again."
        #expect(f.panel("b") == ClaudeCodePanel(control: .use(enabled: false, help: reason), lines: [.notice(reason)]))
    }

    @Test func anAccountThatMustSignInAgainIsBlockedWithItsStatusLineAsTheReason() async throws {
        let f = try StoreFixture(["a", "b"], signedIn: "a"); defer { f.close() }
        f.plan.requireSignIn(f.account("b").id)
        await f.start()
        await f.refresh()

        // The status line the window shows anyway is the reason; nothing is written twice.
        #expect(f.panel("b") == ClaudeCodePanel(control: .use(enabled: false, help: "Sign-in required · reconnect in Settings › Accounts"), lines: []))
        #expect(f.store.snapshot(for: f.account("b")).requiresLogin)
        f.press("b")
        #expect(f.store.claudeCodeActivity == nil && !f.gates.calls.contains("login"))
        // Another account, whose usage login is fine, is not held back by it.
        f.world.removeItem(f.switching.defaultSlot)
        await f.refresh()
        #expect(f.enabled("a"))
    }

    @Test func anAccountThatCannotBeToldApartFromAnotherIsBlockedWithAReason() async throws {
        let unverifiable = UsageAccount(id: UUID(), provider: .claude, name: "c",
                                        identity: AccountIdentity(email: "c@example.test"), credentialID: UUID())
        let f = try StoreFixture(["a"], extra: [unverifiable], signedIn: "a"); defer { f.close() }
        await f.start()

        let reason = "Reconnect this account before using it in Claude Code."
        #expect(f.panel("c") == ClaudeCodePanel(control: .use(enabled: false, help: reason), lines: [.notice(reason)]))
        f.press("c")
        #expect(f.store.claudeCodeActivity == nil && !f.gates.calls.contains("login"))
    }

    @Test func theButtonIsOnlyForClaudeAccountsThatAreStillThere() async throws {
        let codex = UsageAccount(id: UUID(), provider: .codex, name: "x", credentialID: UUID())
        let f = try StoreFixture(["a"], extra: [codex], signedIn: "a"); defer { f.close() }
        await f.start()

        #expect(f.panel("x") == .hidden)
        var removed = f.account("a")
        removed.deletionPending = true
        #expect(f.store.claudeCodePanel(for: removed) == .hidden)
    }

    // MARK: Reading the state

    @Test func aReadingThatFinishesWhileASwitchRunsIsNotAppliedAndNoneStartsMeanwhile() async throws {
        let f = try StoreFixture(["a", "b"], signedIn: "a", saved: ["b"]); defer { f.close() }
        await f.start()
        let version = f.gates.holdVersion()
        f.store.refreshClaudeCodeState()
        try await waitFor("the version check of the reading") { version.entered.wait(timeout: .now()) == .success }
        let login = f.world.hold(login: "default")
        f.press("b")
        try await waitFor("the login command") { login.entered.wait(timeout: .now()) == .success }

        // The reading that was already under way finds Claude Code too old; the switch that is running has priority.
        f.world.version = "2.1.308 (Claude Code)\n"
        version.release.signal()
        await f.store.claudeCodeReading?.value
        #expect(f.store.claudeCodeAvailability == .ready && f.store.claudeCodeActivity != nil)
        // And no new reading starts until the switch is over.
        let before = f.gates.calls
        f.store.refreshClaudeCodeState()
        f.store.popoverWillOpen()
        #expect(f.store.claudeCodeReading == nil && f.gates.calls == before)

        login.release.signal()
        await f.finish()
        #expect(f.panel("b").control == .inClaudeCode && f.store.claudeCodeAvailability == .ready)
    }

    @Test func readingsThatOverlapAreFoldedIntoOneMore() async throws {
        let f = try StoreFixture(["a", "b"], signedIn: "a"); defer { f.close() }
        await f.start()
        let versionChecks = { f.gates.calls.filter { $0 == "version" }.count }
        let before = versionChecks()
        let hold = f.gates.holdVersion()
        f.store.refreshClaudeCodeState()
        try await waitFor("the first reading") { hold.entered.wait(timeout: .now()) == .success }

        for _ in 0..<5 { f.store.refreshClaudeCodeState() }
        hold.release.signal()
        await f.store.claudeCodeReading?.value

        #expect(versionChecks() - before == 2, "the first reading, and one more that stands for the five that came in meanwhile")
    }

    @Test func withoutAClaudeAccountClaudeCodeIsNotAskedAnything() async throws {
        let codex = UsageAccount(id: UUID(), provider: .codex, name: "x", credentialID: UUID())
        let f = try StoreFixture([], extra: [codex]); defer { f.close() }

        await f.start()
        await f.refresh()

        #expect(f.gates.calls.isEmpty && f.store.claudeCodeAvailability == .unknown)
        #expect(f.panel("x") == .hidden)
    }

    // MARK: Using an account

    @Test func pressingTheButtonSwitchesClaudeCodeAndLeavesAResultLine() async throws {
        let f = try StoreFixture(["a", "b"], signedIn: "a", saved: ["b"]); defer { f.close() }
        await f.start()

        f.press("b")
        await f.finish()

        #expect(f.switching.defaultEmail == "b@example.test")
        #expect(f.switching.lendEmail(f.account("a")) == "a@example.test")
        #expect(f.panel("b").control == .inClaudeCode && f.enabled("a"))
        let result = try #require(f.result("b"))
        #expect(result.succeeded)
        #expect(result.message == "Claude Code now uses b. Open sessions switch within 30 s. Remote Control disconnects.")
        #expect(f.result("a") == nil)
        #expect(f.store.claudeCodeActivity == nil && f.store.claudeCodeConfirmation == nil)
        #expect(f.world.problems.isEmpty)
        // The log the result line opens is the engine's.
        #expect(f.store.claudeCodeLogURL == f.switching.logURL)
        #expect(f.switching.logLines.last?["outcome"] as? String == "switched")
    }

    @Test func aResultLineSurvivesOneClosingOfThePopoverAndGoesWithTheNext() async throws {
        let f = try StoreFixture(["a", "b"], signedIn: "a", saved: ["b"]); defer { f.close() }
        await f.start()
        f.press("b")
        await f.finish()
        let b = f.account("b").id, a = f.account("a").id

        // A window that did not show the account does not count.
        f.store.popoverDidClose(accountIDs: [a])
        f.store.popoverDidClose(accountIDs: [a])
        #expect(f.result("b") != nil)

        f.store.popoverDidClose(accountIDs: [a, b])
        #expect(f.result("b") != nil, "closing the window once and opening it again still shows the result")
        f.store.popoverDidClose(accountIDs: [b])
        #expect(f.result("b") == nil, "closing it once more clears it")
        #expect(f.store.claudeCodeResults.isEmpty)
    }

    @Test func aNewSwitchClearsWhatEarlierOnesSaid() async throws {
        let f = try StoreFixture(["a", "b"], signedIn: "a", saved: ["b"]); defer { f.close() }
        await f.start()
        f.press("b")
        await f.finish()
        #expect(f.result("b") != nil)

        f.press("a")
        #expect(f.result("b") == nil, "the old result describes a login that is changing")
        await f.finish()

        #expect(f.result("a")?.message == "Claude Code now uses a. Open sessions switch within 30 s. Remote Control disconnects.")
        #expect(f.result("b") == nil && f.panel("a").control == .inClaudeCode)
    }

    @Test func anAccountWhoseLoginCouldNotBeSavedIsNamedInTheResult() async throws {
        let f = try StoreFixture(["a", "b"], signedIn: "a", saved: ["b"]); defer { f.close() }
        // Lending a's login back is refused, as when an open session had already used its token.
        f.world.script("lend(a)", .invalidGrant(echoToken: false))
        await f.start()

        f.press("b")
        await f.finish()

        let result = try #require(f.result("b"))
        #expect(result.succeeded)
        #expect(result.message == "Claude Code now uses b. Open sessions switch within 30 s. Remote Control disconnects. a needs a browser sign-in next time.")
    }

    @Test func aFailureShowsItsReasonAndLeavesTheMarkerWhereItWas() async throws {
        let f = try StoreFixture(["a", "b"], signedIn: "a", saved: ["b"]); defer { f.close() }
        f.world.script("default", .networkError)
        await f.start()

        f.press("b")
        await f.finish()

        let result = try #require(f.result("b"))
        #expect(!result.succeeded)
        #expect(result.message == "Claude Code could not sign in. Check the connection and try again.")
        #expect(f.panel("a").control == .inClaudeCode && f.enabled("b"))
        #expect(f.store.claudeCodeActivity == nil)
        // It can be tried again.
        f.press("b")
        await f.finish()
        #expect(f.panel("b").control == .inClaudeCode)
    }

    @Test func aFailureThatMayHaveChangedTheLoginSaysSoAndNamesWhoNeedsTheBrowser() async throws {
        let f = try StoreFixture(["a", "b"], signedIn: "a", saved: ["b"]); defer { f.close() }
        f.world.script("default", .writesAnotherAccount("other@example.test"))
        await f.start()

        f.press("b")
        await f.finish()

        let result = try #require(f.result("b"))
        #expect(!result.succeeded)
        #expect(result.message == "Claude Code is signed in to a different account than expected. Claude Code's login may have changed. b needs a browser sign-in next time.")
        // The marker is read again from the real login: nobody registered is signed in now.
        #expect(f.store.claudeCodeAccountID == nil)
    }

    // MARK: While a switch runs

    @Test func whileASwitchRunsEveryWindowIsBlockedAndTheTwoAccountsCannotBeDeletedOrReconnected() async throws {
        let f = try StoreFixture(["a", "b", "c"], signedIn: "a", saved: ["b"]); defer { f.close() }
        await f.start()
        let hold = f.world.hold(login: "default")

        f.press("b")
        try await waitFor("the login command") { hold.entered.wait(timeout: .now()) == .success }
        try await waitFor("its progress") { f.store.claudeCodeActivity?.message == ClaudeCodeSwitchStep.signingIn.message }

        // Progress is shown everywhere; nothing can be pressed.
        #expect(f.panel("b") == ClaudeCodePanel(control: .use(enabled: false, help: f.panel("b").helpText), lines: [.progress("Switching Claude Code…", cancellable: false)]))
        #expect(!f.enabled("b") && !f.enabled("c"))
        #expect(f.panel("c").lines == [.progress("Switching Claude Code to b…", cancellable: false)])
        #expect(f.panel("a") == ClaudeCodePanel(control: .inClaudeCode, lines: [.progress("Switching Claude Code to b…", cancellable: false)]))
        let calls = f.gates.calls
        f.press("c"); f.press("b")
        #expect(f.gates.calls == calls && f.store.claudeCodeActivity?.targetID == f.account("b").id)

        // The target and the account Claude Code had are locked; a third account is not.
        #expect(f.store.isClaudeCodeLocked(f.account("b")) && f.store.isClaudeCodeLocked(f.account("a")))
        #expect(!f.store.isClaudeCodeLocked(f.account("c")))
        #expect(f.store.claudeCodeLockNote(for: f.account("b")) == "Switching Claude Code" && f.store.claudeCodeLockNote(for: f.account("c")) == nil)
        await f.store.delete(f.account("a"))
        await f.store.delete(f.account("b"))
        #expect(f.store.accounts.map(\.name) == ["a", "b", "c"] && !f.store.accounts.contains(where: \.deletionPending))
        // `startLogin` begins with this question; it is asked here instead of starting a real sign-in.
        #expect(!f.store.canStartLogin(replacing: f.account("a")) && !f.store.canStartLogin(replacing: f.account("b")))
        #expect(f.store.canStartLogin(replacing: f.account("c")) && f.store.canStartLogin(), "other accounts and a new one are not held back")

        hold.release.signal()
        await f.finish()

        #expect(f.switching.defaultEmail == "b@example.test")
        #expect(!f.store.isClaudeCodeLocked(f.account("a")) && !f.store.isClaudeCodeLocked(f.account("b")))
        #expect(f.enabled("a") && f.enabled("c") && f.panel("b").control == .inClaudeCode)
        // One switch ran, not three.
        #expect(f.gates.calls.filter { $0 == "login" }.count == 2, "one login into the default slot and one lending a's back")
    }

    // MARK: The question

    @Test func aLoginAgentBarDoesNotHaveIsAskedAboutFirstAndRemovedOnlyOnYes() async throws {
        let f = try StoreFixture(["a", "b"], saved: ["b"]) { $0.signInDefault(email: "stranger@example.test") }; defer { f.close() }
        await f.start()
        let stranger = f.world.person("stranger@example.test")

        f.press("b")
        await f.finish()

        let asked = ClaudeCodeUnknownLogin(email: "stranger@example.test", accountUUID: stranger.accountUUID, organizationUUID: stranger.organizationUUID)
        #expect(f.store.claudeCodeConfirmation == ClaudeCodeConfirmation(accountID: f.account("b").id, login: asked))
        #expect(f.panel("b").lines == [.confirmation(email: "stranger@example.test")])
        #expect(f.switching.defaultEmail == "stranger@example.test", "nothing changed before the yes")
        #expect(!f.gates.calls.contains("login") && f.result("b") == nil)
        // The window that asks is the only one that shows it, and the others can still be used.
        #expect(f.panel("a").lines.isEmpty && f.enabled("a"))

        f.store.confirmClaudeCodeSwitch()
        await f.finish()

        #expect(f.store.claudeCodeConfirmation == nil)
        #expect(f.switching.defaultEmail == "b@example.test" && f.panel("b").control == .inClaudeCode)
        #expect(f.result("b")?.succeeded == true)
        // Nobody is logged out, and nothing is lent for a login that has no account.
        #expect(!f.world.events.contains("delete default") && !f.world.events.contains { $0.hasPrefix("login lend(") })
    }

    @Test func decliningTheQuestionChangesNothing() async throws {
        let f = try StoreFixture(["a", "b"], saved: ["b"]) { $0.signInDefault(email: "stranger@example.test") }; defer { f.close() }
        await f.start()
        f.press("b")
        await f.finish()
        #expect(f.store.claudeCodeConfirmation != nil)

        f.store.cancelClaudeCodeConfirmation()

        #expect(f.store.claudeCodeConfirmation == nil && f.panel("b").lines.isEmpty)
        #expect(f.switching.defaultEmail == "stranger@example.test" && !f.gates.calls.contains("login"))
        // A yes with no question open does nothing.
        f.store.confirmClaudeCodeSwitch()
        #expect(f.store.claudeCodeActivity == nil && !f.gates.calls.contains("login"))
        // Pressing again asks again.
        f.press("b")
        await f.finish()
        #expect(f.panel("b").lines == [.confirmation(email: "stranger@example.test")])
    }

    @Test func aLoginThatChangedWhileTheQuestionWasOpenIsAskedAboutAgain() async throws {
        let f = try StoreFixture(["a", "b"], saved: ["b"]) { $0.signInDefault(email: "stranger@example.test") }; defer { f.close() }
        await f.start()
        f.press("b")
        await f.finish()

        f.switching.signInDefault(email: "someone.else@example.test")
        f.store.confirmClaudeCodeSwitch()
        await f.finish()

        #expect(f.panel("b").lines == [.confirmation(email: "someone.else@example.test")])
        #expect(f.switching.defaultEmail == "someone.else@example.test" && !f.gates.calls.contains("login"))
    }

    @Test func theQuestionIsDroppedWhenTheWindowThatAskedItCloses() async throws {
        let f = try StoreFixture(["a", "b"], saved: ["b"]) { $0.signInDefault(email: "stranger@example.test") }; defer { f.close() }
        await f.start()
        f.press("b")
        await f.finish()

        f.store.popoverDidClose(accountIDs: [f.account("a").id])
        #expect(f.store.claudeCodeConfirmation != nil)
        f.store.popoverDidClose(accountIDs: [f.account("b").id])
        #expect(f.store.claudeCodeConfirmation == nil)
        f.store.confirmClaudeCodeSwitch()
        #expect(f.store.claudeCodeActivity == nil, "a closed question cannot be answered later")
    }

    // MARK: The browser

    @Test func theBrowserWaitShowsItsReasonAndCanBeCancelled() async throws {
        let f = try StoreFixture(["a", "b", "c"], signedIn: "a"); defer { f.close() }
        f.world.plan(.signIn("b@example.test"))
        let hold = f.gates.holdBrowser()
        await f.start()
        let token = f.world.token(in: f.switching.defaultSlot)

        f.press("b")
        try await waitFor("the browser page") { hold.entered.wait(timeout: .now()) == .success }
        try await waitFor("the cancel button") { f.store.claudeCodeActivity?.canCancel == true && f.opened.values.count == 1 }

        // The page was opened by the store's own browser, once, and the first line says to sign in once.
        #expect(f.opened.values == [FakeClaudeWorld.browserURL])
        #expect(f.panel("b").lines == [.progress(ClaudeCodeBrowserReason.noSavedLogin.message, cancellable: true)])
        // Another account's window shows that a switch is running, without a Cancel of its own.
        #expect(f.panel("c").lines == [.progress("Switching Claude Code to b…", cancellable: false)])

        f.store.cancelClaudeCodeSwitch()
        #expect(f.panel("b").lines == [.progress("Cancelling…", cancellable: false)])
        await f.finish()

        // Cancelling is not an error: nothing is said, nothing changed, and the half-made sign-in is gone.
        #expect(f.store.claudeCodeActivity == nil && f.result("b") == nil)
        #expect(f.switching.defaultEmail == "a@example.test" && f.world.token(in: f.switching.defaultSlot) == token)
        #expect(!f.switching.lendFolderExists(f.account("b")) && !f.gates.calls.contains("login"))
        #expect(f.panel("a").control == .inClaudeCode && f.enabled("b"))
    }

    @Test func cancelOnlyWorksWhileTheBrowserIsWaited() async throws {
        let f = try StoreFixture(["a", "b"], signedIn: "a", saved: ["b"]); defer { f.close() }
        await f.start()
        let hold = f.world.hold(login: "default")

        f.press("b")
        try await waitFor("the login command") { hold.entered.wait(timeout: .now()) == .success }
        f.store.cancelClaudeCodeSwitch()
        hold.release.signal()
        await f.finish()

        #expect(f.switching.defaultEmail == "b@example.test", "a step that cannot be cancelled goes on to the end")
        #expect(f.result("b")?.succeeded == true)
    }

    @Test func aBrowserThatCannotBeOpenedEndsTheSwitchWithThatReason() async throws {
        let f = try StoreFixture(["a", "b"], signedIn: "a", browserOpens: false); defer { f.close() }
        _ = f.gates.holdBrowser()
        await f.start()

        f.press("b")
        await f.finish()

        let result = try #require(f.result("b"))
        #expect(!result.succeeded)
        #expect(result.message == "Could not open your browser. Check the default browser setting and try again.")
        #expect(f.switching.defaultEmail == "a@example.test" && f.store.claudeCodeActivity == nil)
    }

    @Test func aBrowserSignInThatTimesOutShowsItsReason() async throws {
        let f = try StoreFixture(["a", "b"], signedIn: "a"); defer { f.close() }
        f.world.plan(.timeout)
        await f.start()

        f.press("b")
        await f.finish()

        #expect(f.result("b")?.message == "Browser sign-in timed out. Try again.")
        #expect(f.result("b")?.succeeded == false && f.switching.defaultEmail == "a@example.test")
        #expect(f.opened.values == [FakeClaudeWorld.browserURL])
    }

    @Test func aSignInAsAnotherAccountIsDiscardedAndSaid() async throws {
        let f = try StoreFixture(["a", "b"], signedIn: "a"); defer { f.close() }
        f.world.plan(.signIn("someone.else@example.test"))
        await f.start()

        f.press("b")
        await f.finish()

        #expect(f.result("b")?.message == "Signed in as a different account.")
        #expect(f.switching.defaultEmail == "a@example.test" && !f.switching.lendFolderExists(f.account("b")))
    }

    @Test func quittingEndsTheBrowserWaitAndChangesNothing() async throws {
        let f = try StoreFixture(["a", "b"], signedIn: "a"); defer { f.close() }
        f.world.plan(.signIn("b@example.test"))
        let hold = f.gates.holdBrowser()
        await f.start()

        f.press("b")
        try await waitFor("the browser page") { hold.entered.wait(timeout: .now()) == .success }
        f.store.shutdown()
        await f.finish()

        #expect(f.store.claudeCodeActivity == nil && f.result("b") == nil)
        #expect(f.switching.defaultEmail == "a@example.test" && !f.gates.calls.contains("login"))
        #expect(f.switching.journal == nil)
    }

    // MARK: Starting the app

    @Test func aSwitchCutShortIsFinishedAtLaunchAndSaidOnTheTargetsWindow() async throws {
        let f = try StoreFixture(["prev", "target"], stableID: false) { sf in
            let prev = sf.accounts[0], target = sf.accounts[1]
            sf.signInDefault(target)
            try sf.saveLogin(for: target)
            try sf.files.write(ClaudeCodeSwitchJournal(targetID: target.id, previousID: prev.id, stage: .slotSwitched, startedAt: Date()),
                               to: sf.files.claudeCodeSwitchJournalURL)
            for account in sf.accounts { try writeUsageLogin(for: account, in: sf) }
        }
        defer { f.close() }
        // When Claude Code is asked for its version, the recovery and the UUID fill must both be over.
        let seen = Recorder<String>()
        let journalURL = f.files.claudeCodeSwitchJournalURL, files = f.files
        f.gates.onVersion {
            let filled = (try? files.load())?.accounts.allSatisfy { $0.identity?.stableID != nil } ?? false
            seen.add("journal=\(FileManager.default.fileExists(atPath: journalURL.path)) filled=\(filled)")
        }

        await f.start()

        #expect(seen.values == ["journal=false filled=true"])
        let result = try #require(f.result("target"))
        #expect(result.succeeded)
        #expect(result.message == "AgentBar quit while switching. Claude Code now uses target. prev needs a browser sign-in next time.")
        #expect(f.panel("target").control == .inClaudeCode && f.enabled("prev"))
        #expect(!f.switching.lendFolderExists(f.account("target")) && f.switching.journal == nil)
    }

    @Test func aSwitchThatNeverReachedTheLoginIsDroppedAtLaunchAndSaidToo() async throws {
        let f = try StoreFixture(["prev", "target"]) { sf in
            let prev = sf.accounts[0], target = sf.accounts[1]
            sf.signInDefault(prev)
            try sf.saveLogin(for: target)
            try sf.files.write(ClaudeCodeSwitchJournal(targetID: target.id, previousID: prev.id, stage: .started, startedAt: Date()),
                               to: sf.files.claudeCodeSwitchJournalURL)
        }
        defer { f.close() }

        await f.start()

        let result = try #require(f.result("target"))
        #expect(!result.succeeded && result.message == "AgentBar quit while switching. Nothing was changed.")
        #expect(f.panel("prev").control == .inClaudeCode && f.enabled("target"))
        #expect(f.switching.journal == nil && f.switching.defaultEmail == "prev@example.test")
    }

    @Test func nothingCanBePressedUntilTheRecoveryIsOver() async throws {
        let f = try StoreFixture(["prev", "target", "other"]) { sf in
            let prev = sf.accounts[0], target = sf.accounts[1]
            sf.signInDefault(target)
            try sf.saveLogin(for: target)
            try sf.files.write(ClaudeCodeSwitchJournal(targetID: target.id, previousID: prev.id, stage: .slotSwitched, startedAt: Date()),
                               to: sf.files.claudeCodeSwitchJournalURL)
        }
        defer { f.close() }
        let hold = f.gates.holdKeychain()

        let launching = Task { await f.start() }
        try await waitFor("the recovery") { hold.entered.wait(timeout: .now()) == .success }

        #expect(f.store.claudeCodeStarting)
        #expect(!f.enabled("prev") && !f.enabled("other"))
        f.press("other")
        #expect(f.store.claudeCodeActivity == nil && !f.gates.calls.contains("login"))
        // The accounts the recovery may be using cannot be deleted or reconnected either.
        #expect(f.store.accounts.allSatisfy { f.store.isClaudeCodeLocked($0) })
        #expect(f.store.claudeCodeLockNote(for: f.account("prev")) == "Checking Claude Code")
        await f.store.delete(f.account("prev"))
        #expect(f.store.accounts.count == 3 && !f.store.accounts.contains(where: \.deletionPending))

        hold.release.signal()
        await launching.value

        #expect(!f.store.claudeCodeStarting && f.enabled("prev") && f.enabled("other"))
        #expect(f.store.accounts.allSatisfy { !f.store.isClaudeCodeLocked($0) })
    }

    @Test func leftoverDeletionsWaitForTheRecoveryAndThenGoOn() async throws {
        let leftover = UsageAccount(id: UUID(), provider: .codex, name: "old", credentialID: UUID(), deletionPending: true)
        let f = try StoreFixture(["prev", "target"], extra: [leftover], autoRefresh: true, holdingKeychain: true) { sf in
            let prev = sf.accounts[0], target = sf.accounts[1]
            sf.signInDefault(prev)
            try sf.files.write(ClaudeCodeSwitchJournal(targetID: target.id, previousID: prev.id, stage: .started, startedAt: Date()),
                               to: sf.files.claudeCodeSwitchJournalURL)
        }
        defer { f.close() }
        let hold = try #require(f.launchHold)

        // The app is starting: the recovery is asking the Keychain and has not finished.
        try await waitFor("the recovery") { hold.entered.wait(timeout: .now()) == .success }
        try await Task.sleep(for: .milliseconds(200))
        #expect(f.store.claudeCodeStarting)
        #expect(f.store.accounts.contains { $0.id == leftover.id }, "the leftover deletion must not run beside the recovery")

        hold.release.signal()
        try await waitFor("the leftover deletion") { !f.store.accounts.contains { $0.id == leftover.id } }
        #expect(!f.store.claudeCodeStarting)
        #expect(f.result("target")?.message == "AgentBar quit while switching. Nothing was changed.")
    }

    @Test func aRegistryThatCannotBeReadLeavesTheSwitchRecordForALaterLaunch() async throws {
        let sf = try SwitchFixture()
        let target = sf.addAccount("target")
        try sf.files.write(ClaudeCodeSwitchJournal(targetID: target.id, previousID: nil, stage: .slotSwitched, startedAt: Date()),
                           to: sf.files.claudeCodeSwitchJournalURL)
        try Data("{not valid".utf8).write(to: sf.files.registryURL)
        let suite = "claude-code-corrupt-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let switcher = ClaudeCodeSwitcher(files: sf.files, defaultSlot: sf.defaultSlot, cli: sf.world, keychain: sf.world,
                                          pause: { _ in }, now: { Date() })
        let store = UsageStore(settings: AppSettings(defaults: defaults), files: sf.files, autoRefresh: false, claudeCode: switcher)
        defer { store.shutdown() }
        #expect(store.storageUnavailable)

        await store.runClaudeCodeStartup()

        // The engine would drop a record whose account it cannot find, so it was not asked.
        #expect(sf.journal != nil && !store.claudeCodeStarting && store.claudeCodeResults.isEmpty)
        #expect(sf.world.events.isEmpty)
    }

    @Test func theFirstSwitchToAnAccountSignsInWithTheBrowserOnceAndLaterOnesNeedNoBrowser() async throws {
        let f = try StoreFixture(["a", "b"], signedIn: "a"); defer { f.close() }
        f.world.plan(.signIn("b@example.test"))
        await f.start()

        f.press("b")
        await f.finish()

        #expect(f.opened.values == [FakeClaudeWorld.browserURL], "the page opened in the person's browser, once")
        #expect(f.result("b")?.succeeded == true && f.panel("b").control == .inClaudeCode)
        #expect(f.switching.defaultEmail == "b@example.test" && f.switching.lendEmail(f.account("a")) == "a@example.test")

        // Back to a and to b again: both logins are saved now.
        f.press("a")
        await f.finish()
        f.press("b")
        await f.finish()
        #expect(f.opened.values.count == 1 && f.panel("b").control == .inClaudeCode)
        #expect(f.world.problems.isEmpty)
    }

    @Test func theWindowHoldsTheRegistrysAccountNotAnOlderCopyOfIt() async throws {
        let f = try StoreFixture(["a", "b"], signedIn: "a", saved: ["b"]); defer { f.close() }
        await f.start()
        let stale = f.account("b")
        f.store.rename(stale, name: "b renamed")

        f.store.useInClaudeCode(stale)
        await f.finish()

        #expect(f.result("b renamed")?.message == "Claude Code now uses b renamed. Open sessions switch within 30 s. Remote Control disconnects.")
    }

    @Test func thePopoverDrawsTheControlAndItsLines() async throws {
        let f = try StoreFixture(["a", "b"], signedIn: "a", saved: ["b"]); defer { f.close() }
        await f.start()
        let hold = f.world.hold(login: "default")
        for step in 0..<3 {
            switch step {
            case 1:
                f.press("b")
                try await waitFor("the login command") { hold.entered.wait(timeout: .now()) == .success }
            case 2:
                hold.release.signal()
                await f.finish()
            default: break
            }
            for name in ["a", "b"] {
                let host = NSHostingView(rootView: AccountPopoverView(accountID: f.account(name).id).environmentObject(f.store))
                host.frame = NSRect(x: 0, y: 0, width: 392, height: 420)
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
            }
        }
    }

    // MARK: Account UUIDs

    @Test func registeredAccountsGetTheirAccountUUIDFromTheirOwnLoginFolderOnce() async throws {
        let known = UsageAccount(id: UUID(), provider: .claude, name: "d",
                                 identity: AccountIdentity(email: "d@example.test", organization: "d org", organizationID: "org-d", stableID: "already-known"),
                                 credentialID: UUID())
        let f = try StoreFixture(["a", "b", "c"], extra: [known], stableID: false, signedIn: "a") { sf in
            // a: the folder agrees with the registry. b: the folder belongs to another organization. c: no record at all.
            // d: already has its UUID, and the folder says something else.
            try writeUsageLogin(for: sf.accounts[0], in: sf)
            try writeUsageLogin(for: sf.accounts[1], in: sf, organizationUUID: "another-organization")
            let folder = sf.files.credentials(try #require(known.credentialID))
            try sf.files.createPrivateDirectory(folder)
            try Data(#"{"oauthAccount":{"accountUuid":"u-other","organizationUuid":"org-d","emailAddress":"d@example.test"}}"#.utf8)
                .write(to: folder.appendingPathComponent(".claude.json"))
        }
        defer { f.close() }
        let folders = f.accounts.compactMap { $0.credentialID.map(f.files.credentials) }
        let before = folders.map { try? Data(contentsOf: $0.appendingPathComponent(".claude.json")) }

        await f.start()

        let expected = f.world.person("a@example.test").accountUUID
        #expect(f.account("a").identity?.stableID == expected)
        #expect(f.account("b").identity?.stableID == nil && f.account("c").identity?.stableID == nil)
        #expect(f.account("d").identity?.stableID == "already-known")
        // Kept on disk with the rest of the registry, and the other fields are as they were.
        let saved = try f.files.load()
        #expect(saved.accounts.map { $0.identity?.stableID } == [expected, nil, nil, "already-known"])
        #expect(saved.accounts.map { $0.identity?.organizationID } == f.accounts.map { $0.identity?.organizationID })
        #expect(saved.accounts.map(\.credentialID) == f.accounts.map(\.credentialID))
        // The login folders were only read.
        #expect(folders.map { try? Data(contentsOf: $0.appendingPathComponent(".claude.json")) } == before)
        // Claude Code's own record now says who is in Claude Code by the pair, and the window still shows it.
        #expect(f.panel("a").control == .inClaudeCode)

        // Once: a second pass changes nothing, and an account that gets its record later is filled then.
        let registryBytes = try Data(contentsOf: f.files.registryURL)
        await f.store.fillAccountUUIDs()
        #expect(try Data(contentsOf: f.files.registryURL) == registryBytes)
        try writeUsageLogin(for: f.account("c"), in: f.switching)
        await f.store.fillAccountUUIDs()
        #expect(f.account("c").identity?.stableID == f.world.person("c@example.test").accountUUID)
    }

    @Test func aReconnectIsJudgedTheSameBeforeAndAfterTheAccountUUIDIsFilled() {
        // What `claude auth status` reports after a sign-in has no account UUID; what the registry holds gains one.
        let reported = AccountIdentity(email: "a@example.test", organization: "A", organizationID: "org-1")
        let before = AccountIdentity(email: "a@example.test", organization: "A", organizationID: "org-1")
        var after = before; after.stableID = "u-1"
        for other in [AccountIdentity(email: "A@Example.test", organizationID: "org-1"),
                      AccountIdentity(email: "z@example.test", organizationID: "org-1"),
                      AccountIdentity(email: "a@example.test", organizationID: "org-2"),
                      AccountIdentity(email: nil, organizationID: nil)] {
            #expect(other.comparison(to: before) == other.comparison(to: after))
        }
        #expect(reported.comparison(to: before) == .unverified && reported.comparison(to: after) == .unverified)

        // The usage reading compares the login folder's own record, which does have the UUID, with the registry.
        let record = AccountIdentity(email: "a@example.test", organization: "A", organizationID: "org-1", stableID: "u-1")
        #expect(record.comparison(to: before) != .different && record.comparison(to: after) == .same)
        var sameAccountNewEmail = record; sameAccountNewEmail.email = "renamed@example.test"
        #expect(sameAccountNewEmail.comparison(to: after) == .same && sameAccountNewEmail.comparison(to: before) == .different)
    }

    // MARK: Nothing without a switcher

    @Test func withoutASwitcherNothingIsOfferedOrCalledOrWritten() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-code-off-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let files = AccountFiles(root: root)
        let suite = "claude-code-off-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = UsageAccount(id: UUID(), provider: .claude, name: "a",
                                   identity: AccountIdentity(email: "a@example.test", organizationID: "org-1"), credentialID: UUID())
        var registry = AccountRegistry(accounts: [account]); registry.repairRepresentatives()
        try files.write(registry, to: files.registryURL)
        // A login folder that would be read for its account UUID if the feature were on.
        let folder = files.credentials(try #require(account.credentialID))
        try files.createPrivateDirectory(folder)
        try Data(#"{"oauthAccount":{"accountUuid":"u-1","organizationUuid":"org-1","emailAddress":"a@example.test"}}"#.utf8)
            .write(to: folder.appendingPathComponent(".claude.json"))
        let store = UsageStore(settings: AppSettings(defaults: defaults), files: files, autoRefresh: false)
        defer { store.shutdown() }
        let registryBefore = try Data(contentsOf: files.registryURL)
        let treeBefore = try tree(of: root)

        await store.runClaudeCodeStartup()
        store.refreshClaudeCodeState()
        store.popoverWillOpen()
        store.useInClaudeCode(account)
        store.confirmClaudeCodeSwitch()
        store.cancelClaudeCodeSwitch()
        store.popoverDidClose(accountIDs: [account.id])
        await store.fillAccountUUIDs()
        await store.claudeCodeReading?.value

        #expect(store.claudeCodePanel(for: account) == .hidden)
        #expect(store.claudeCodeAvailability == .unknown && store.claudeCodeAccountID == nil)
        #expect(store.claudeCodeActivity == nil && store.claudeCodeConfirmation == nil && store.claudeCodeResults.isEmpty)
        #expect(!store.claudeCodeStarting && !store.isClaudeCodeLocked(account))
        // No journal, no log, no lend folder, and the registry was not rewritten with an account UUID.
        #expect(try tree(of: root) == treeBefore)
        #expect(try Data(contentsOf: files.registryURL) == registryBefore)
        #expect(store.accounts.first?.identity?.stableID == nil)
    }

    // MARK: A popover closing

    @Test func aPopoverClosingCountsForTheAccountsItShowed() async throws {
        let f = try StoreFixture(["a", "b"], signedIn: "a", saved: ["b"]); defer { f.close() }
        await f.start()
        f.press("b")
        await f.finish()
        let b = f.account("b").id
        let coordinator = StatusBarCoordinator(store: f.store, providers: [.claude])
        defer { coordinator.removeAll() }
        let popover = try #require(coordinator.popover(for: b))
        #expect(coordinator.popoverAccountIDs(for: b) == [b])

        NotificationCenter.default.post(name: NSPopover.didCloseNotification, object: popover)
        try await waitFor("the first close") { f.store.claudeCodeResults[b]?.closes == 1 }
        #expect(f.result("b") != nil)

        NotificationCenter.default.post(name: NSPopover.didCloseNotification, object: popover)
        try await waitFor("the second close") { f.store.claudeCodeResults[b] == nil }
        #expect(f.result("b") == nil)
    }
}

// MARK: Helpers

extension ClaudeCodePanel {
    // The tooltip of a disabled or enabled button.
    var helpText: String {
        if case .use(_, let help) = control { return help }
        return ""
    }
}

// Claude Code's own record of who signed in to an account's usage login folder.
func writeUsageLogin(for account: UsageAccount, in fixture: SwitchFixture, organizationUUID: String? = nil) throws {
    let email = try #require(account.identity?.email)
    let person = fixture.world.person(email)
    let folder = fixture.files.credentials(try #require(account.credentialID))
    try fixture.files.createPrivateDirectory(folder)
    let record: [String: Any] = ["oauthAccount": ["accountUuid": person.accountUUID, "emailAddress": email,
                                                  "organizationUuid": organizationUUID ?? person.organizationUUID]]
    try JSONSerialization.data(withJSONObject: record).write(to: folder.appendingPathComponent(".claude.json"))
}

// Every path under a directory, for checking that nothing was added.
func tree(of root: URL) throws -> [String] {
    let manager = FileManager.default
    guard let walker = manager.enumerator(atPath: root.path) else { return [] }
    return (walker.allObjects as? [String] ?? []).sorted()
}
