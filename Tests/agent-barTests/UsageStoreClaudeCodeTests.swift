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
    static let setUpHelp = "Sign in once in Settings › Accounts so Claude Code can use this account."

    // MARK: What each window shows

    @Test func theAccountClaudeCodeUsesSaysSoAndTheOthersOfferTheButtonOrTheWayToSettings() async throws {
        let f = try StoreFixture(["a", "b", "c"], signedIn: "a", saved: ["b"]); defer { f.close() }
        await f.start()

        #expect(f.panel("a") == ClaudeCodePanel(control: .inClaudeCode, lines: []))
        #expect(f.panel("b").lines.isEmpty && f.enabled("b"))
        // c has no sign-in saved for Claude Code: its window sends the person to Settings and starts nothing itself.
        #expect(f.panel("c") == ClaudeCodePanel(control: .setUp(help: Self.setUpHelp), lines: []))
        #expect(f.store.claudeCodeAvailability == .ready)
        #expect(f.store.claudeCodeAccountID == f.account("a").id)
        #expect(f.store.claudeCodeReady == [f.account("b").id])
        f.press("c")
        #expect(f.store.claudeCodeActivity == nil && f.store.claudeCodePreparation == nil)
        #expect(f.gates.calls.filter { $0 != "version" }.allSatisfy { $0.hasPrefix("read") || $0.hasPrefix("contains") })
        #expect(f.opened.values.isEmpty)
    }

    @Test func theMarkerFollowsTheRealLoginWhoeverChangesIt() async throws {
        let f = try StoreFixture(["a", "b"], signedIn: "a", saved: ["a", "b"]); defer { f.close() }
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
        let f = try StoreFixture(["a", "b"], signedIn: "a", saved: ["b"]); defer { f.close() }
        f.gates.installed = false
        await f.start()

        #expect(f.panel("a") == .hidden && f.panel("b") == .hidden)
        // Nor does Settings: Claude Code is not there to be signed in for.
        #expect(f.setup("a") == .hidden && f.setup("b") == .hidden)
        f.signIn("b")
        #expect(f.store.claudeCodePreparation == nil && !f.gates.calls.contains("browser"))
        #expect(f.store.claudeCodeAvailability == .missing)
        // Pressing what is not there does nothing.
        f.press("b")
        #expect(f.store.claudeCodeActivity == nil && !f.gates.calls.contains("login"))

        // Installing it shows the buttons within one refresh, and removing it hides them within one.
        f.gates.installed = true
        await f.refresh()
        #expect(f.panel("a").control == .inClaudeCode && f.enabled("b") && f.setup("b").status == .ready)
        f.gates.installed = false
        await f.refresh()
        #expect(f.panel("a") == .hidden && f.panel("b") == .hidden && f.setup("b") == .hidden)
    }

    @Test func anOldClaudeCodeBlocksTheButtonAndSaysWhy() async throws {
        let f = try StoreFixture(["a", "b"], signedIn: "a", saved: ["b"]); defer { f.close() }
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
        let f = try StoreFixture(["a", "b"], signedIn: "a", saved: ["a", "b"]); defer { f.close() }
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

    @Test func theHeaderIsTallerByTheEstimateWhenTheControlIsThere() async throws {
        let f = try StoreFixture(["a", "b", "c"], signedIn: "a", saved: ["b"]); defer { f.close() }
        await f.start()
        await f.refresh()
        // The same account and usage in a store that has no Claude Code.
        let suite = "claude-code-height-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let plain = UsageStore(settings: AppSettings(defaults: defaults), files: f.files, autoRefresh: false,
                               loadAccount: { account, _ in SnapshotPlan.usage(for: account.provider) })
        defer { plain.shutdown() }
        await plain.refresh()
        func height(of store: UsageStore, _ account: UsageAccount) -> CGFloat {
            let host = NSHostingView(rootView: AccountPopoverView(accountID: account.id).environmentObject(store))
            host.frame = NSRect(x: 0, y: 0, width: 392, height: 800)
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }

        // b offers the switch, c the way to Settings: either control makes the header as much taller.
        let b = f.account("b"), c = f.account("c")
        #expect(f.enabled("b"))
        guard case .setUp = f.panel("c").control else { Issue.record("c should offer Settings"); return }
        #expect(plain.claudeCodePanel(for: b) == .hidden && plain.claudeCodePanel(for: c) == .hidden)
        for account in [b, c] {
            let growth = height(of: f.store, account) - height(of: plain, account)
            #expect(abs(growth - CGFloat(ClaudeCodePanel.headerGrowth)) < 1, "the popover grew by \(growth)")
        }
    }    // MARK: Using an account

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

    @Test func aResultOnATabThatWasNotShownIsNotClearedByClosings() async throws {
        let f = try StoreFixture(["a", "b"], signedIn: "a", saved: ["b"]); defer { f.close() }
        await f.start()
        f.press("b")
        await f.finish()
        let a = f.account("a").id, b = f.account("b").id, group = UUID()

        // A popover with a tab for each account opens on the first one, a, and is closed twice: nobody saw b's result.
        for _ in 0..<2 {
            f.store.popoverWillOpen(group: group, accountIDs: [a, b])
            f.store.popoverDidClose(group: group)
        }
        #expect(f.store.claudeCodeResults[b]?.closes == 0 && f.result("b") != nil)

        // The person flips to b's tab and closes: the first closing that b's result was seen through.
        f.store.popoverWillOpen(group: group, accountIDs: [a, b])
        f.store.popoverShows(b, group: group)
        f.store.popoverDidClose(group: group)
        #expect(f.store.claudeCodeResults[b]?.closes == 1)

        // It opens on the tab it showed last, b's, and the next closing clears the result.
        f.store.popoverWillOpen(group: group, accountIDs: [a, b])
        f.store.popoverDidClose(group: group)
        #expect(f.result("b") == nil)
    }

    @Test func whatAPopoverShowedWhileClosedOrInAnotherGroupDoesNotCount() async throws {
        let f = try StoreFixture(["a", "b"], signedIn: "a", saved: ["b"]); defer { f.close() }
        await f.start()
        f.press("b")
        await f.finish()
        let a = f.account("a").id, b = f.account("b").id, group = UUID(), other = UUID()

        f.store.popoverShows(b, group: group)            // a tab shown while the popover is closed
        f.store.popoverDidClose(group: group)
        #expect(f.store.claudeCodeResults[b]?.closes == 0)

        f.store.popoverWillOpen(group: other, accountIDs: [a])
        f.store.popoverDidClose(group: other)            // another group's popover
        #expect(f.store.claudeCodeResults[b]?.closes == 0)

        // It opens on b, the tab it showed last.
        f.store.popoverWillOpen(group: group, accountIDs: [a, b])
        f.store.popoverDidClose(group: group)
        #expect(f.store.claudeCodeResults[b]?.closes == 1 && f.store.shownAccount(in: group) == b)
        // A tab that is gone is not what it starts on, and b is not among what it can show now.
        f.store.popoverWillOpen(group: group, accountIDs: [a])
        f.store.popoverDidClose(group: group)
        #expect(f.store.claudeCodeResults[b]?.closes == 1)
    }

    @Test func aGroupMadeAgainStartsOnItsFirstTab() async throws {
        let f = try StoreFixture(["a", "b"], signedIn: "a", saved: ["b"]); defer { f.close() }
        await f.start()
        f.press("b")
        await f.finish()
        let a = f.account("a").id, b = f.account("b").id, group = UUID()

        f.store.popoverWillOpen(group: group, accountIDs: [a, b])
        f.store.popoverShows(b, group: group)
        f.store.popoverDidClose(group: group)
        #expect(f.store.claudeCodeResults[b]?.closes == 1)

        // The group leaves the menu bar and comes back: its new window opens on a, so b's result was not seen again.
        f.store.popoverForget(group: group)
        f.store.popoverWillOpen(group: group, accountIDs: [a, b])
        f.store.popoverDidClose(group: group)
        #expect(f.store.claudeCodeResults[b]?.closes == 1 && f.result("b") != nil)
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
        #expect(result.message == "Claude Code now uses b. Open sessions switch within 30 s. Remote Control disconnects. a needs to sign in again in Settings › Accounts.")
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

    @Test func aFailureThatChangedTheLoginIsNotToldTwiceAndNamesWhoMustSignInAgain() async throws {
        let f = try StoreFixture(["a", "b"], signedIn: "a", saved: ["b"]); defer { f.close() }
        f.world.script("default", .writesAnotherAccount("other@example.test"))
        await f.start()

        f.press("b")
        await f.finish()

        let result = try #require(f.result("b"))
        #expect(!result.succeeded)
        #expect(result.message == "Claude Code is signed in to a different account than expected. b needs to sign in again in Settings › Accounts.")
        // The marker is read again from the real login: nobody registered is signed in now.
        #expect(f.store.claudeCodeAccountID == nil)
    }

    @Test func aFailureGetsTheWarningThatTheLoginMayHaveChangedOnlyWhenItsReasonDoesNotSayThat() {
        func message(_ reason: String, nothingChanged: Bool) -> String {
            UsageStore.claudeCodeFailureMessage(ClaudeCodeSwitchFailure(reason: reason, nothingChanged: nothingChanged))
        }
        // Nothing was touched: the reason stands alone.
        #expect(message("Claude rejected the sign-in. Try again.", nothingChanged: true) == "Claude rejected the sign-in. Try again.")
        // Something may have changed and the reason does not say it.
        #expect(message("Claude Code is not signed in after switching.", nothingChanged: false)
                == "Claude Code is not signed in after switching. Claude Code's login may have changed.")
        #expect(message("Could not confirm which account Claude Code uses now.", nothingChanged: false)
                == "Could not confirm which account Claude Code uses now. Claude Code's login may have changed.")
        // The reason already says it.
        for reason in ["Claude Code's login changed unexpectedly. Check it in Claude Code.", "Claude Code's login changed while switching. Try again.",
                       "Claude Code is signed in to a different account than expected."] {
            #expect(message(reason, nothingChanged: false) == reason)
        }
    }

    @Test func aLoginRenewedByAnOpenSessionIsReportedOnceWithWhoMustSignInAgain() async throws {
        let f = try StoreFixture(["a", "b"], signedIn: "a", saved: ["b"]); defer { f.close() }
        f.world.script("default", .openSessionRenewsPreviousInstead)
        await f.start()

        f.press("b")
        await f.finish()

        let result = try #require(f.result("b"))
        #expect(!result.succeeded)
        #expect(result.message == "Claude Code's login changed while switching. Try again. b needs to sign in again in Settings › Accounts.")
    }

    // MARK: While a switch runs

    @Test func whileASwitchRunsEveryWindowIsBlockedAndTheTwoAccountsCannotBeDeletedOrReconnected() async throws {
        let f = try StoreFixture(["a", "b", "c"], signedIn: "a", saved: ["b", "c"]); defer { f.close() }
        await f.start()
        let hold = f.world.hold(login: "default")

        f.press("b")
        try await waitFor("the login command") { hold.entered.wait(timeout: .now()) == .success }
        try await waitFor("its progress") { f.store.claudeCodeActivity?.message == ClaudeCodeSwitchStep.signingIn.message }

        // Progress is shown everywhere; nothing can be pressed.
        #expect(f.panel("b") == ClaudeCodePanel(control: .use(enabled: false, help: f.panel("b").helpText), lines: [.progress("Switching Claude Code…")]))
        #expect(!f.enabled("b") && !f.enabled("c"))
        #expect(f.panel("c").lines == [.progress("Switching Claude Code to b…")])
        #expect(f.panel("a") == ClaudeCodePanel(control: .inClaudeCode, lines: [.progress("Switching Claude Code to b…")]))
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
        // Somebody who confirmed the deletion is told why nothing happened; a leftover deletion retried by itself is not.
        #expect(f.store.errorMessage == "Claude Code is switching accounts. Delete this account after it finishes.")
        f.store.errorMessage = nil
        await f.store.delete(f.account("a"), allowUserInteraction: false)
        await f.store.retryCleanup(allowUserInteraction: false)
        #expect(f.store.errorMessage == nil && f.store.accounts.count == 3)
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

    @Test func aReconnectUnderReviewIsNotRegisteredWhileTheSwitchUsesItsAccount() async throws {
        let f = try StoreFixture(["a", "b", "c"], signedIn: "a", saved: ["b"]); defer { f.close() }
        await f.start()
        let b = f.account("b"), c = f.account("c")
        func signedInAgain(_ account: UsageAccount, as identity: AccountIdentity? = nil) -> PendingAccountLogin {
            PendingAccountLogin(account: UsageAccount(id: UUID(), provider: .claude, name: account.name,
                                                      identity: identity ?? account.identity, credentialID: UUID()), replacing: account.id)
        }
        let hold = f.world.hold(login: "default")

        f.press("b")
        try await waitFor("the login command") { hold.entered.wait(timeout: .now()) == .success }

        // A reconnect of b, started before the switch, is confirmed while the switch runs: it waits.
        f.store.reviewSignedIn(signedInAgain(b))
        #expect(f.store.reconnectLockedByClaudeCode)
        f.store.confirmLogin()
        #expect(f.store.accounts.first { $0.id == b.id }?.credentialID == b.credentialID, "b stays registered as it was")
        #expect(f.store.pendingLogin != nil, "the sign-in stays under review")
        #expect(f.store.errorMessage == "Claude Code is switching accounts. Press Reconnect again after it finishes.")

        // A reconnect of an account the switch does not use is not held back, and neither is adding the sign-in as a new account.
        f.store.reviewSignedIn(signedInAgain(c))
        #expect(!f.store.reconnectLockedByClaudeCode)
        f.store.errorMessage = nil
        f.store.reviewSignedIn(signedInAgain(b, as: AccountIdentity(email: "new@example.test", organization: "new", organizationID: "org-new")))
        f.store.confirmLogin(addAsNew: true)
        #expect(f.store.accounts.count == 4 && f.store.pendingLogin == nil && f.store.errorMessage == nil)

        hold.release.signal()
        await f.finish()
        f.store.reviewSignedIn(signedInAgain(b))
        #expect(!f.store.reconnectLockedByClaudeCode, "when the switch is over the reconnect can be confirmed")
    }

    // MARK: The question

    @Test func aLoginAgentBarDoesNotHaveIsAskedAboutFirstAndRemovedOnlyOnYes() async throws {
        let f = try StoreFixture(["a", "b"], saved: ["a", "b"]) { $0.signInDefault(email: "stranger@example.test") }; defer { f.close() }
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

    @Test func aSwitchToAnAccountWithNothingSavedOpensNoBrowserAndSendsThePersonToSettings() async throws {
        let f = try StoreFixture(["a", "b"], signedIn: "a", saved: ["b"]); defer { f.close() }
        f.world.plan(.signIn("b@example.test"))
        await f.start()
        // b's saved sign-in goes away behind the app's back, after the window was told it was there.
        f.world.removeItem(f.switching.lendSlot(f.account("b")))
        try FileManager.default.removeItem(at: f.files.lend(f.account("b").id))
        #expect(f.enabled("b"))
        let token = f.world.token(in: f.switching.defaultSlot)

        f.press("b")
        await f.finish()

        // Nothing was changed, no page was opened, and the person is told where to go.
        let result = try #require(f.result("b"))
        #expect(!result.succeeded && result.message == "Sign in to b once in Settings › Accounts first.")
        #expect(f.opened.values.isEmpty && !f.gates.calls.contains("browser") && !f.gates.calls.contains("login"))
        #expect(f.switching.defaultEmail == "a@example.test" && f.world.token(in: f.switching.defaultSlot) == token)
        #expect(f.store.claudeCodeActivity == nil && f.panel("a").control == .inClaudeCode)
        // The window offers Settings from now on, without waiting for the next reading.
        #expect(f.panel("b").control == .setUp(help: Self.setUpHelp))
        #expect(f.setup("b").status == .notSetUp(blocked: nil))
        #expect(f.switching.logLines.last?["outcome"] as? String == "needsSetup")
    }

    @Test func aSavedLoginThatExpiredIsRemovedAndTheWindowSendsThePersonToSettings() async throws {
        let f = try StoreFixture(["a", "b"], signedIn: "a", saved: ["b"]); defer { f.close() }
        // b's saved sign-in was used up elsewhere, so the handover is refused.
        f.world.revoke(try #require(f.world.token(in: f.switching.lendSlot(f.account("b")))))
        f.world.plan(.signIn("b@example.test"))
        await f.start()
        #expect(f.enabled("b") && f.setup("b").status == .ready)
        let token = f.world.token(in: f.switching.defaultSlot)

        f.press("b")
        await f.finish()

        let result = try #require(f.result("b"))
        #expect(!result.succeeded && result.message == "The saved sign-in for b expired. Sign in again in Settings › Accounts.")
        #expect(f.opened.values.isEmpty && !f.gates.calls.contains("browser"))
        #expect(f.switching.defaultEmail == "a@example.test" && f.world.token(in: f.switching.defaultSlot) == token)
        #expect(!f.switching.lendFolderExists(f.account("b")) && f.store.claudeCodeActivity == nil)
        // Its window offers Settings, its line there offers the sign-in, and nothing says the sign-in is ready.
        #expect(f.panel("b").control == .setUp(help: Self.setUpHelp) && f.result("b") != nil)
        #expect(f.setup("b").status == .notSetUp(blocked: nil) && !f.store.claudeCodeReady.contains(f.account("b").id))
        // Also after the window has read the folders again.
        await f.refresh()
        #expect(f.panel("b").control == .setUp(help: Self.setUpHelp))
    }

    @Test func theBrowserLineFallsBackToItsPlainWordsWithoutAnAddress() {
        let step = ClaudeCodePrepareStep.waitingForBrowser
        #expect(step.message == "Sign in once in the browser so Claude Code can use this account.")
        #expect(step.message(signingInAs: nil) == step.message && step.message(signingInAs: "") == step.message)
        #expect(step.message(signingInAs: "x@example.test") == "Sign in as x@example.test in the browser once so Claude Code can use this account.")
        // Only the browser wait names an account.
        #expect(ClaudeCodePrepareStep.checkingVersion.message(signingInAs: "x@example.test") == "Checking Claude Code…")
    }    // MARK: Starting the app

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
        #expect(result.message == "AgentBar quit while switching. Claude Code now uses target. prev needs to sign in again in Settings › Accounts.")
        // prev's login was only in memory when the app quit, so its window sends the person to Settings.
        #expect(f.panel("target").control == .inClaudeCode && f.panel("prev").control == .setUp(help: Self.setUpHelp))
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
        let f = try StoreFixture(["prev", "target", "other"], saved: ["prev", "other"]) { sf in
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
        #expect(f.store.errorMessage == "AgentBar is still checking Claude Code. Delete this account in a moment.")

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

    @Test func anAccountSignsInOnceInSettingsAndAfterThatSwitchesNeedNoBrowser() async throws {
        let f = try StoreFixture(["a", "b"], signedIn: "a"); defer { f.close() }
        f.world.plan(.signIn("b@example.test"))
        await f.start()
        #expect(f.panel("b").control == .setUp(help: Self.setUpHelp))

        f.signIn("b")
        await f.finish()

        #expect(f.opened.values == [FakeClaudeWorld.browserURL], "the page opened in the person's browser, once")
        #expect(f.setup("b").status == .ready && f.enabled("b"))
        #expect(f.switching.defaultEmail == "a@example.test", "signing in does not touch Claude Code's login")

        f.press("b")
        await f.finish()
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

    // MARK: Deleting an account

    @Test func deletingAClaudeAccountRemovesTheLoginSavedForClaudeCodeAndNothingElse() async throws {
        let f = try StoreFixture(["a", "b", "c"], signedIn: "a", saved: ["b", "c"]); defer { f.close() }
        await f.start()
        #expect(f.store.claudeCodeEnabled)
        let b = f.account("b"), c = f.account("c")
        let defaultToken = try #require(f.world.token(in: f.switching.defaultSlot))
        let defaultIdentity = try Data(contentsOf: f.switching.defaultSlot.identityFile)
        let before = f.gates.calls

        await f.store.delete(b)

        #expect(f.store.accounts.map(\.name) == ["a", "c"] && f.store.errorMessage == nil)
        #expect(try f.files.load().accounts.map(\.name) == ["a", "c"], "the deletion is saved")
        // The folder and the Keychain item are gone, and the Keychain was asked again to be sure.
        #expect(!f.switching.lendFolderExists(b) && !f.world.hasItem(f.switching.lendSlot(b)))
        let asked = Array(f.gates.calls.dropFirst(before.count))
        #expect(asked.contains("delete lend") && asked.last == "contains lend")
        // Another account's saved login stays, and Claude Code's own login was not even looked at.
        #expect(f.switching.lendFolderExists(c) && f.switching.lendEmail(c) == "c@example.test")
        #expect(!asked.contains { $0.hasSuffix("default") } && !asked.contains("login"))
        #expect(f.switching.defaultEmail == "a@example.test" && f.world.token(in: f.switching.defaultSlot) == defaultToken)
        #expect(try Data(contentsOf: f.switching.defaultSlot.identityFile) == defaultIdentity)
        #expect(f.world.problems.isEmpty)
    }

    @Test func deletingTheAccountClaudeCodeUsesLeavesClaudeCodeSignedIn() async throws {
        let f = try StoreFixture(["a", "b"], signedIn: "a", saved: ["a", "b"]); defer { f.close() }
        await f.start()
        let a = f.account("a")
        #expect(f.panel("a").control == .inClaudeCode)
        let defaultToken = try #require(f.world.token(in: f.switching.defaultSlot))
        let defaultIdentity = try Data(contentsOf: f.switching.defaultSlot.identityFile)
        let loginCommands = f.world.calls.filter { $0.arguments.first == "auth" }.count

        await f.store.delete(a)

        #expect(f.store.accounts.map(\.name) == ["b"] && f.store.errorMessage == nil)
        #expect(!f.switching.lendFolderExists(a) && !f.world.hasItem(f.switching.lendSlot(a)))
        // Claude Code keeps the very login it had: same item, same token, same identity file. Nobody was signed out.
        #expect(f.world.hasItem(f.switching.defaultSlot) && f.switching.defaultEmail == "a@example.test")
        #expect(f.world.token(in: f.switching.defaultSlot) == defaultToken && f.world.isLive(defaultToken))
        #expect(try Data(contentsOf: f.switching.defaultSlot.identityFile) == defaultIdentity)
        #expect(f.world.calls.filter { $0.arguments.first == "auth" }.count == loginCommands && f.world.problems.isEmpty)

        // AgentBar no longer has that account, so no window says Claude Code uses it.
        await f.refresh()
        #expect(f.store.claudeCodeAccountID == nil && f.enabled("b"))
    }

    @Test func anAccountDeletedWhileASwitchRunsGoesWhenTheSwitchEndsAndSoDoesItsSavedLogin() async throws {
        let f = try StoreFixture(["a", "b", "c"], signedIn: "a", saved: ["b", "c"]); defer { f.close() }
        await f.start()
        let c = f.account("c")
        let hold = f.world.hold(login: "default")
        f.press("b")
        try await waitFor("the login command") { hold.entered.wait(timeout: .now()) == .success }

        // c is not one of the two accounts the switch uses, so it can be deleted. The engine will not remove a saved login
        // meanwhile; that is not a failure to tell anyone about.
        await f.store.delete(c)

        #expect(f.store.errorMessage == nil)
        let waiting = try #require(f.store.accounts.first { $0.id == c.id })
        #expect(waiting.deletionPending && f.panel("c") == .hidden, "gone from the windows, still to be finished")
        #expect(f.switching.lendFolderExists(c) && f.world.hasItem(f.switching.lendSlot(c)))

        // Nothing tries again while the switch runs: a file put back where a try would remove it stays.
        let marker = f.files.root.appendingPathComponent("usage/\(c.id.uuidString)/marker")
        try f.files.createPrivateDirectory(marker.deletingLastPathComponent())
        try Data("x".utf8).write(to: marker)
        try await Task.sleep(for: .milliseconds(350))
        #expect(FileManager.default.fileExists(atPath: marker.path))

        hold.release.signal()
        await f.finish()

        // The clean-up the switch's end does is a whole deletion again: the file is gone too.
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(f.store.accounts.map(\.name) == ["a", "b"] && f.store.errorMessage == nil)
        #expect(try f.files.load().accounts.map(\.name) == ["a", "b"])
        #expect(!f.switching.lendFolderExists(c) && !f.world.hasItem(f.switching.lendSlot(c)))
        // The switch itself went through: b is in Claude Code and a's login was lent back to its own folder.
        #expect(f.switching.defaultEmail == "b@example.test" && f.switching.lendEmail(f.account("a")) == "a@example.test")
        #expect(f.result("b")?.succeeded == true && f.world.problems.isEmpty)
    }

    @Test func twoDeletionsAtOnceAreBothFinishedInsteadOfTheSecondBeingTurnedAway() async throws {
        let f = try StoreFixture(["a", "b", "c"], signedIn: "a", saved: ["b", "c"]); defer { f.close() }
        await f.start()
        let b = f.account("b"), c = f.account("c")
        let hold = f.gates.holdKeychain()

        // b's saved login is being removed: the engine is inside, waiting for the Keychain.
        let first = Task { await f.store.delete(b) }
        try await waitFor("the first removal") { hold.entered.wait(timeout: .now()) == .success }
        let second = Task { await f.store.delete(c) }
        try await waitFor("the second deletion to start") { f.store.accounts.first { $0.id == c.id }?.deletionPending == true }
        try await Task.sleep(for: .milliseconds(300))
        // No switch is running, so the second one waits its turn; it is not sent away as if one were.
        #expect(f.store.errorMessage == nil && f.switching.lendFolderExists(c))

        hold.release.signal()
        await first.value
        await second.value

        #expect(f.store.accounts.map(\.name) == ["a"] && f.store.errorMessage == nil)
        #expect(try f.files.load().accounts.map(\.name) == ["a"])
        #expect(!f.switching.lendFolderExists(b) && !f.switching.lendFolderExists(c))
        #expect(!f.world.hasItem(f.switching.lendSlot(b)) && !f.world.hasItem(f.switching.lendSlot(c)))
    }

    @Test func aDeletionTurnedAwayWhileNoSwitchIsRunningIsTriedAgainByItself() async throws {
        let f = try StoreFixture(["a", "b", "c"], signedIn: "a", saved: ["b", "c"]); defer { f.close() }
        await f.start()
        let c = f.account("c")
        // The engine is held by somebody the store does not know of. That is how the store sees the moment in which a switch
        // has just ended while the engine turned the removal away: the end of that switch cleaned up without this deletion,
        // which was still running, and no later end of a switch will come for it.
        let engine = f.engine
        let hold = f.gates.holdKeychain()
        let finished = DispatchSemaphore(value: 0)
        runOnNewThread { _ = try? engine.removeLendLogin(for: UUID()); finished.signal() }
        try await waitFor("the engine to be held") { hold.entered.wait(timeout: .now()) == .success }

        await f.store.delete(c)

        #expect(f.store.errorMessage == nil && f.store.claudeCodeActivity == nil)
        #expect(f.store.accounts.first { $0.id == c.id }?.deletionPending == true && f.switching.lendFolderExists(c))
        try await Task.sleep(for: .milliseconds(250))
        #expect(f.store.accounts.contains { $0.id == c.id }, "turned away again while the engine is still held")

        hold.release.signal()
        try await waitFor("the deletion to go on by itself", timeout: 5) { !f.store.accounts.contains { $0.id == c.id } }
        try await waitFor("the other removal to end") { finished.wait(timeout: .now()) == .success }
        #expect(!f.switching.lendFolderExists(c) && !f.world.hasItem(f.switching.lendSlot(c)) && f.store.errorMessage == nil)
        #expect(try f.files.load().accounts.map(\.name) == ["a", "b"])
    }

    @Test func aSwitchPressedWhileASavedLoginIsBeingRemovedWaitsForItInsteadOfBeingTurnedAway() async throws {
        let f = try StoreFixture(["a", "b", "c"], signedIn: "a", saved: ["b", "c"]); defer { f.close() }
        await f.start()
        let hold = f.gates.holdKeychain()
        // b's saved login is being removed: the engine is inside, waiting for the Keychain.
        let deleting = Task { await f.store.delete(f.account("b")) }
        try await waitFor("the removal") { hold.entered.wait(timeout: .now()) == .success }

        #expect(f.enabled("c"))
        f.press("c")
        try await Task.sleep(for: .milliseconds(300))
        // Not sent away with "Another Claude Code switch is still running.": the switch is still there, waiting its turn.
        #expect(f.store.claudeCodeActivity?.targetID == f.account("c").id && f.result("c") == nil)

        hold.release.signal()
        await deleting.value
        await f.finish()

        #expect(f.result("c")?.succeeded == true && f.switching.defaultEmail == "c@example.test")
        #expect(f.switching.lendEmail(f.account("a")) == "a@example.test", "a's login was lent back to its own folder")
        #expect(f.store.accounts.map(\.name) == ["a", "c"] && f.store.errorMessage == nil)
        #expect(!f.switching.lendFolderExists(f.account("b")) && !f.world.hasItem(f.switching.lendSlot(f.account("b"))))
    }

    @Test func aSavedLoginThatCannotBeRemovedIsReportedLikeAnyOtherFailedDeletion() async throws {
        let f = try StoreFixture(["a", "b"], signedIn: "a", saved: ["b"]); defer { f.close() }
        await f.start()
        f.world.keepItem("lend(b)")

        await f.store.delete(f.account("b"))

        #expect(f.store.errorMessage == "Keychain cleanup is required for the saved Claude Code sign-in.")
        let kept = try #require(f.store.accounts.first { $0.name == "b" })
        #expect(kept.deletionPending, "it stays hidden, and a later clean-up tries again")
        #expect(f.store.accounts.map(\.name) == ["a", "b"])
        #expect(f.switching.defaultEmail == "a@example.test")
    }

    @Test func deletingACodexAccountNeverAsksClaudeCode() async throws {
        let codex = UsageAccount(id: UUID(), provider: .codex, name: "x", credentialID: UUID())
        let f = try StoreFixture(["a"], extra: [codex], signedIn: "a"); defer { f.close() }
        await f.start()
        // A folder under the Codex account's id that only the engine would remove.
        try f.files.createPrivateDirectory(f.files.lendRoot)
        try f.files.createPrivateDirectory(f.files.lend(codex.id))
        let asked = f.gates.calls, events = f.world.events

        await f.store.delete(codex)

        #expect(f.store.accounts.map(\.name) == ["a"] && f.store.errorMessage == nil)
        #expect(f.gates.calls == asked && f.world.events == events, "neither the Keychain nor Claude Code was asked anything")
        #expect(FileManager.default.fileExists(atPath: f.files.lend(codex.id).path))
    }

    @Test func aDeletionCutShortIsFinishedAtLaunchAndTakesTheSavedLoginWithIt() async throws {
        let leftover = UsageAccount(id: UUID(), provider: .claude, name: "old", credentialID: UUID(), deletionPending: true)
        let f = try StoreFixture(["a"], extra: [leftover], signedIn: "a", saved: ["old"], autoRefresh: true); defer { f.close() }

        try await waitFor("the leftover deletion") { !f.store.accounts.contains { $0.id == leftover.id } }

        #expect(f.store.errorMessage == nil)
        #expect(!f.switching.lendFolderExists(leftover) && !f.world.hasItem(f.switching.lendSlot(leftover)))
        #expect(f.switching.defaultEmail == "a@example.test")
    }

    @Test func theDeleteQuestionTellsAboutTheSavedClaudeCodeLoginOnlyWhereOneCanBeSaved() {
        let always = "This removes only the selected account’s AgentBar credentials and usage cache. External CLI sign-ins are preserved."
        // A Codex account is asked about with the words the question always had, whether or not Use in Claude Code is on.
        #expect(AccountManagementView.deleteMessage(for: .codex, claudeCodeEnabled: true) == always)
        #expect(AccountManagementView.deleteMessage(for: .codex, claudeCodeEnabled: false) == always)
        // So is a Claude account in a run without Use in Claude Code, which saves no sign-in and removes none.
        #expect(AccountManagementView.deleteMessage(for: .claude, claudeCodeEnabled: false) == always)
        #expect(AccountManagementView.deleteMessage(for: .claude, claudeCodeEnabled: true)
                == "This removes only the selected account’s AgentBar credentials and usage cache, plus any sign-in AgentBar saved on this Mac "
                + "for Use in Claude Code. If Claude Code is using this account now, Claude Code stays signed in. External CLI sign-ins are preserved.")
    }

    @Test func withoutASwitcherDeletingAClaudeAccountWorksAsItAlwaysDid() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-code-delete-off-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let files = AccountFiles(root: root)
        let suite = "claude-code-delete-off-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        func claude(_ name: String) -> UsageAccount {
            UsageAccount(id: UUID(), provider: .claude, name: name,
                         identity: AccountIdentity(email: "\(name)@example.test", organizationID: "org-1"), credentialID: UUID())
        }
        let account = claude("a"), other = claude("b")
        var registry = AccountRegistry(accounts: [account, other]); registry.repairRepresentatives()
        try files.write(registry, to: files.registryURL)
        let login = files.credentials(try #require(account.credentialID))
        try files.createPrivateDirectory(login)
        try files.write(ProviderSnapshot.placeholder(for: .claude), to: files.cache(account))
        let store = UsageStore(settings: AppSettings(defaults: defaults), files: files, autoRefresh: false)
        defer { store.shutdown() }

        await store.delete(account)

        #expect(store.accounts.map(\.name) == ["b"] && store.errorMessage == nil)
        #expect(!FileManager.default.fileExists(atPath: login.path) && !FileManager.default.fileExists(atPath: files.cache(account).path))
        #expect(!FileManager.default.fileExists(atPath: files.lendRoot.path), "no switcher, no saved logins to look for")
        #expect(try files.load().accounts.map(\.name) == ["b"])
        // Nothing is saved or removed in such a run, so the question for a Claude account does not say it is.
        #expect(!store.claudeCodeEnabled)
        #expect(AccountManagementView.deleteMessage(for: .claude, claudeCodeEnabled: store.claudeCodeEnabled)
                == AccountManagementView.deleteMessage(for: .codex, claudeCodeEnabled: store.claudeCodeEnabled))
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
        // Settings › Accounts asks for nothing either: no line, no sign-in, nothing read when the list opens.
        store.prepareForClaudeCode(account)
        store.cancelClaudeCodePreparation()
        store.accountsListDidOpen()
        store.popoverDidClose(accountIDs: [account.id])
        await store.fillAccountUUIDs()
        await store.claudeCodeReading?.value
        await store.claudeCodePreparationTask?.value

        #expect(store.claudeCodePanel(for: account) == .hidden && store.claudeCodeSetup(for: account) == .hidden)
        #expect(store.claudeCodeAvailability == .unknown && store.claudeCodeAccountID == nil)
        #expect(store.claudeCodeActivity == nil && store.claudeCodeConfirmation == nil && store.claudeCodeResults.isEmpty)
        #expect(store.claudeCodePreparation == nil && store.claudeCodeReady.isEmpty && store.claudeCodeSetupFailures.isEmpty)
        #expect(!store.claudeCodeStarting && !store.isClaudeCodeLocked(account) && store.claudeCodeLockNote(for: account) == nil)
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

        coordinator.willOpenPopover(for: b)
        NotificationCenter.default.post(name: NSPopover.didCloseNotification, object: popover)
        try await waitFor("the first closing") { f.store.claudeCodeResults[b]?.closes == 1 }
        #expect(f.result("b") != nil)

        // A closing that no opening came before has nothing to count.
        NotificationCenter.default.post(name: NSPopover.didCloseNotification, object: popover)
        try await Task.sleep(for: .milliseconds(100))
        #expect(f.store.claudeCodeResults[b]?.closes == 1)

        coordinator.willOpenPopover(for: b)
        NotificationCenter.default.post(name: NSPopover.didCloseNotification, object: popover)
        try await waitFor("the second closing") { f.store.claudeCodeResults[b] == nil }
        #expect(f.result("b") == nil)
    }

    @Test func aGroupPopoverCountsClosingsOnlyForTheAccountItShowed() async throws {
        let f = try StoreFixture(["a", "b"], signedIn: "a", saved: ["b"]); defer { f.close() }
        await f.start()
        f.press("b")
        await f.finish()
        let a = f.account("a").id, b = f.account("b").id
        f.store.updateDisplay { $0.update(a) { $0.group = 1 }; $0.update(b) { $0.group = 1 } }
        let coordinator = StatusBarCoordinator(store: f.store, providers: [.claude])
        defer { coordinator.removeAll() }
        let group = DisplayConfiguration.groupKey(1)
        try await waitFor("the group's popover") { coordinator.popoverAccountIDs(for: group) == [a, b] }
        let popover = try #require(coordinator.popover(for: group))

        // The popover opens on its first tab, a, and closes twice; b's result was never in front of anybody.
        for _ in 0..<2 {
            coordinator.willOpenPopover(for: group)
            NotificationCenter.default.post(name: NSPopover.didCloseNotification, object: popover)
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(f.store.claudeCodeResults[b]?.closes == 0 && f.result("b") != nil)

        // The person flips to b's tab, and the popover closes.
        coordinator.willOpenPopover(for: group)
        f.store.popoverShows(b, group: group)
        NotificationCenter.default.post(name: NSPopover.didCloseNotification, object: popover)
        try await waitFor("the closing that b was shown through") { f.store.claudeCodeResults[b]?.closes == 1 }
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
