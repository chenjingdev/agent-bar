import AppKit
import Foundation
import SwiftUI
import Testing
@testable import agent_bar

// The store's side of signing an account in for Claude Code from Settings › Accounts: what each account's line there
// says, the browser sign-in and its Cancel, what it locks, and how the answer reaches the account's popover. Against
// the same fake Claude Code and Keychain as the other store tests; no real program, login or browser is used.
@MainActor
@Suite(.serialized)
struct UsageStoreClaudeCodeSetupTests {
    private static let tooOld = "Claude Code 2.1.308 is too old. Update to 2.1.309 or newer."
    private static let switching = "Claude Code is being switched. Wait for it to finish."
    private static let signingIn = "An account is signing in for Claude Code. Wait for it to finish."
    private static func waitText(_ name: String) -> String {
        "Sign in as \(name)@example.test in the browser once so Claude Code can use this account."
    }

    // MARK: What each line says

    @Test func eachClaudeAccountsLineSaysWhereItStands() async throws {
        let codex = UsageAccount(id: UUID(), provider: .codex, name: "x", credentialID: UUID())
        let f = try StoreFixture(["a", "b", "c"], extra: [codex], signedIn: "a", saved: ["b"]); defer { f.close() }
        await f.start()

        #expect(f.setup("a") == ClaudeCodeSetup(status: .inClaudeCode))
        #expect(f.setup("b") == ClaudeCodeSetup(status: .ready))
        #expect(f.setup("c") == ClaudeCodeSetup(status: .notSetUp(blocked: nil)) && f.canSignIn("c"))
        // The Codex account has no such line, and nor has an account that is going away.
        #expect(f.setup("x") == .hidden)
        var going = f.account("c")
        going.deletionPending = true
        #expect(f.store.claudeCodeSetup(for: going) == .hidden)
    }

    @Test func theAccountClaudeCodeUsesNeedsNothingEvenWithASignInSavedForIt() async throws {
        let f = try StoreFixture(["a", "b"], signedIn: "a", saved: ["a"]); defer { f.close() }
        await f.start()

        #expect(f.store.claudeCodeReady.contains(f.account("a").id))
        #expect(f.setup("a") == ClaudeCodeSetup(status: .inClaudeCode), "it is in Claude Code; nothing is left to prepare")
        // And when Claude Code moves on, the saved sign-in is there for it.
        f.switching.signInDefault(f.account("b"))
        await f.refresh()
        #expect(f.setup("a").status == .ready && f.setup("b").status == .inClaudeCode)
    }

    @Test func aUsageSignInThatMustBeRedoneDoesNotStopTheSignInForClaudeCode() async throws {
        let f = try StoreFixture(["a", "b"], signedIn: "a"); defer { f.close() }
        f.plan.requireSignIn(f.account("b").id)
        await f.start()
        await f.refresh()

        // The window's button is blocked by the status line it shows; the line in Settings is a login of its own.
        #expect(f.panel("b").control == .use(enabled: false, help: "Sign-in required · reconnect in Settings › Accounts"))
        #expect(f.setup("b").status == .notSetUp(blocked: nil))
        f.world.plan(.signIn("b@example.test"))
        f.signIn("b")
        await f.finish()
        #expect(f.setup("b").status == .ready)
        // Ready, but the switch still waits for the usage sign-in to be redone.
        #expect(f.panel("b").control == .use(enabled: false, help: "Sign-in required · reconnect in Settings › Accounts"))
    }

    @Test func whatBlocksTheSignInIsSaidOnTheButtonAndSavedAccountsStillSayReady() async throws {
        let unverifiable = UsageAccount(id: UUID(), provider: .claude, name: "u",
                                        identity: AccountIdentity(email: "u@example.test"), credentialID: UUID())
        let f = try StoreFixture(["a", "b", "c"], extra: [unverifiable], signedIn: "a", saved: ["c"]); defer { f.close() }
        f.world.version = "2.1.308 (Claude Code)\n"
        await f.start()

        // An old Claude Code, with the reason it gives for its switch buttons.
        #expect(f.setup("b").status == .notSetUp(blocked: Self.tooOld) && !f.canSignIn("b"))
        #expect(f.setup("c").status == .ready && f.setup("a").status == .inClaudeCode)
        f.signIn("b")
        #expect(f.store.claudeCodePreparation == nil && !f.gates.calls.contains("browser"))

        // A version that cannot be read blocks it too, and so does an account that cannot be told apart from another.
        f.world.version = "zsh: command not found: claude\n"
        await f.refresh()
        #expect(f.setup("b").status == .notSetUp(blocked: "Could not read the Claude Code version. Update Claude Code and try again."))
        f.world.version = "2.1.312 (Claude Code)\n"
        await f.refresh()
        #expect(f.canSignIn("b"))
        #expect(f.setup("u").status == .notSetUp(blocked: "Reconnect this account before using it in Claude Code."))
        f.signIn("u")
        #expect(f.store.claudeCodePreparation == nil)
    }

    // MARK: Reading what is ready

    @Test func theReadyAccountsAreReadFromWhatTheirFoldersHold() async throws {
        let f = try StoreFixture(["a", "b", "c"], signedIn: "a", saved: ["b"]); defer { f.close() }
        await f.start()
        #expect(f.store.claudeCodeReady == [f.account("b").id])

        // A sign-in appears in c's folder and b's goes: Settings notices when it opens, the popover when it opens.
        try f.switching.saveLogin(for: f.account("c"))
        f.world.removeItem(f.switching.lendSlot(f.account("b")))
        f.store.accountsListDidOpen()
        await f.store.claudeCodeReading?.value
        #expect(f.store.claudeCodeReady == [f.account("c").id])
        #expect(f.setup("c").status == .ready && f.setup("b").status == .notSetUp(blocked: nil))
        #expect(f.panel("c").control == .use(enabled: true, help: "Switches Claude Code to this account. Open sessions switch within 30 s."))
        #expect(f.panel("b").control == .setUp(help: UsageStoreClaudeCodeTests.setUpHelp))

        try f.switching.saveLogin(for: f.account("b"))
        f.store.popoverWillOpen()
        await f.store.claudeCodeReading?.value
        #expect(f.store.claudeCodeReady == [f.account("b").id, f.account("c").id])
        // And on every refresh.
        f.world.removeItem(f.switching.lendSlot(f.account("c")))
        await f.refresh()
        #expect(f.store.claudeCodeReady == [f.account("b").id])
    }

    @Test func theAccountsListReadsTheLoginsAgainWhenItAppears() async throws {
        let f = try StoreFixture(["a", "b"], signedIn: "a"); defer { f.close() }
        await f.start()
        // b gets a saved sign-in after the line was last read.
        try f.switching.saveLogin(for: f.account("b"))
        #expect(f.setup("b").status == .notSetUp(blocked: nil))

        // A window that is never shown still puts the list on screen.
        let host = NSHostingView(rootView: AccountManagementView().padding(20).environmentObject(f.store))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 560), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        try await waitFor("the list to read the logins") { f.setup("b").status == .ready }
    }

    @Test func readingWhatIsReadyNeverReadsASecret() async throws {
        let f = try StoreFixture(["a", "b", "c"], signedIn: "a", saved: ["b", "c"]); defer { f.close() }

        await f.start()
        await f.refresh()
        f.store.accountsListDidOpen()
        await f.store.claudeCodeReading?.value

        // Only whether the items exist: asking the Keychain for a secret is what could bring up its window.
        #expect(f.gates.calls.contains("contains lend") && f.gates.calls.contains("contains default"))
        #expect(!f.gates.calls.contains { $0.hasPrefix("read") } && !f.gates.calls.contains("login"))
        #expect(f.store.claudeCodeReady == [f.account("b").id, f.account("c").id])
    }

    // MARK: Signing in

    @Test func theLineWaitsForTheBrowserWithCancelAndThenTheAccountIsReadyAndItsWindowOffersTheSwitch() async throws {
        let f = try StoreFixture(["a", "b"], signedIn: "a"); defer { f.close() }
        f.world.plan(.signIn("b@example.test"))
        let hold = f.gates.holdBrowser()
        await f.start()
        let token = f.world.token(in: f.switching.defaultSlot)
        #expect(f.panel("b").control == .setUp(help: UsageStoreClaudeCodeTests.setUpHelp))

        f.signIn("b")
        try await waitFor("the browser page") { hold.entered.wait(timeout: .now()) == .success }
        try await waitFor("the cancel button") { f.store.claudeCodePreparation?.canCancel == true && f.opened.values.count == 1 }

        // The page was opened by the store's own browser, once, and says which account to sign in as.
        #expect(f.opened.values == [FakeClaudeWorld.browserURL])
        #expect(f.setup("b") == ClaudeCodeSetup(status: .signingIn(message: Self.waitText("b"), cancellable: true)))
        #expect(f.store.claudeCodeActivity == nil, "this is no switch")

        hold.release.signal()
        await f.finish()

        // Nothing else is said: the line is ready, and the window can switch. Claude Code's login was never touched.
        #expect(f.setup("b") == ClaudeCodeSetup(status: .ready) && f.store.claudeCodePreparation == nil)
        #expect(f.enabled("b") && f.result("b") == nil && f.store.claudeCodeSetupFailures.isEmpty)
        #expect(f.switching.lendEmail(f.account("b")) == "b@example.test" && f.store.claudeCodeReady.contains(f.account("b").id))
        #expect(f.switching.defaultEmail == "a@example.test" && f.world.token(in: f.switching.defaultSlot) == token)
        #expect(!f.gates.calls.contains("login") && f.world.problems.isEmpty && f.switching.journal == nil)
    }

    @Test func cancelStopsTheWaitAndLeavesNothingNotEvenAReason() async throws {
        let f = try StoreFixture(["a", "b"], signedIn: "a"); defer { f.close() }
        f.world.plan(.signIn("b@example.test"))
        let hold = f.gates.holdBrowser()
        await f.start()
        let token = f.world.token(in: f.switching.defaultSlot)

        f.signIn("b")
        try await waitFor("the browser page") { hold.entered.wait(timeout: .now()) == .success }
        try await waitFor("the cancel button") { f.store.claudeCodePreparation?.canCancel == true }
        f.store.cancelClaudeCodePreparation()
        #expect(f.setup("b").status == .signingIn(message: "Cancelling…", cancellable: false))
        await f.finish()

        #expect(f.store.claudeCodePreparation == nil && f.store.claudeCodeSetupFailures.isEmpty)
        #expect(f.setup("b") == ClaudeCodeSetup(status: .notSetUp(blocked: nil)))
        #expect(!f.switching.lendFolderExists(f.account("b")) && !f.world.hasItem(f.switching.lendSlot(f.account("b"))))
        #expect(f.switching.defaultEmail == "a@example.test" && f.world.token(in: f.switching.defaultSlot) == token)
        #expect(!f.gates.calls.contains("login") && f.canSignIn("b"), "it can be tried again")
        // A Cancel that nothing waits for does nothing.
        f.store.cancelClaudeCodePreparation()
        #expect(f.store.claudeCodePreparation == nil)
    }

    @Test func cancelOnlyWorksWhileTheBrowserIsWaitedFor() async throws {
        let f = try StoreFixture(["a", "b"], signedIn: "a"); defer { f.close() }
        f.world.plan(.signIn("b@example.test"))
        await f.start()
        let version = f.gates.holdVersion()

        f.signIn("b")
        try await waitFor("the version check") { version.entered.wait(timeout: .now()) == .success }
        #expect(f.setup("b").status == .signingIn(message: "Checking Claude Code…", cancellable: false))
        f.store.cancelClaudeCodePreparation()
        version.release.signal()
        await f.finish()

        #expect(f.setup("b").status == .ready, "a step that cannot be cancelled goes on to the end")
    }

    @Test func aSignInThatDoesNotWorkSaysWhyWithOpenLogAndTheNextTryClearsIt() async throws {
        let f = try StoreFixture(["a", "b"], signedIn: "a"); defer { f.close() }
        f.world.plan(.timeout)
        await f.start()

        f.signIn("b")
        await f.finish()

        #expect(f.setup("b") == ClaudeCodeSetup(status: .notSetUp(blocked: nil), failure: "Browser sign-in timed out. Try again."))
        #expect(f.opened.values == [FakeClaudeWorld.browserURL])
        #expect(f.switching.defaultEmail == "a@example.test" && !f.switching.lendFolderExists(f.account("b")))
        // The log "Open Log" opens is the engine's, and it has the attempt.
        #expect(f.store.claudeCodeLogURL == f.switching.logURL)
        #expect(f.switching.logLines.last?["outcome"] as? String == "failed" && f.switching.logLines.last?["operation"] as? String == "prepare")
        // The reason stays until the account is tried again, however often the list is read meanwhile.
        await f.refresh()
        f.store.accountsListDidOpen()
        await f.store.claudeCodeReading?.value
        #expect(f.setup("b").failure == "Browser sign-in timed out. Try again.")

        f.world.plan(.signIn("b@example.test"))
        let hold = f.gates.holdBrowser()
        f.signIn("b")
        #expect(f.setup("b").failure == nil && f.store.claudeCodeSetupFailures[f.account("b").id] == nil, "the reason is gone as soon as the next try starts")
        try await waitFor("the browser page") { hold.entered.wait(timeout: .now()) == .success }
        hold.release.signal()
        await f.finish()
        #expect(f.setup("b") == ClaudeCodeSetup(status: .ready))
    }

    @Test func aSignInAsAnotherAccountIsDiscardedAndSaid() async throws {
        let f = try StoreFixture(["a", "b"], signedIn: "a"); defer { f.close() }
        f.world.plan(.signIn("someone.else@example.test"))
        await f.start()

        f.signIn("b")
        await f.finish()

        #expect(f.setup("b").failure == "Signed in as a different account.")
        #expect(f.setup("b").status == .notSetUp(blocked: nil) && !f.switching.lendFolderExists(f.account("b")))
        #expect(f.switching.defaultEmail == "a@example.test")
    }

    @Test func aBrowserThatCannotBeOpenedEndsTheSignInWithThatReason() async throws {
        let f = try StoreFixture(["a", "b"], signedIn: "a", browserOpens: false); defer { f.close() }
        _ = f.gates.holdBrowser()
        await f.start()

        f.signIn("b")
        await f.finish()

        #expect(f.setup("b").failure == "Could not open your browser. Check the default browser setting and try again.")
        #expect(f.setup("b").status == .notSetUp(blocked: nil) && f.store.claudeCodePreparation == nil)
        #expect(f.switching.defaultEmail == "a@example.test" && !f.switching.lendFolderExists(f.account("b")))
    }

    @Test func aReasonIsDroppedOnceTheAccountIsSetUpOrClaudeCodeHasIt() async throws {
        let f = try StoreFixture(["a", "b", "c"], signedIn: "a"); defer { f.close() }
        f.world.plan(.timeout, .timeout)
        await f.start()
        f.signIn("b"); await f.finish()
        f.signIn("c"); await f.finish()
        #expect(f.setup("b").failure != nil && f.setup("c").failure != nil)

        // b gets its sign-in some other way, and Claude Code is signed in to c in a terminal.
        try f.switching.saveLogin(for: f.account("b"))
        f.switching.signInDefault(f.account("c"))
        await f.refresh()

        #expect(f.setup("b") == ClaudeCodeSetup(status: .ready) && f.setup("c") == ClaudeCodeSetup(status: .inClaudeCode))
        #expect(f.store.claudeCodeSetupFailures.isEmpty)
        // Claude Code moves on again: c has nothing saved, and the old reason is not brought back.
        f.switching.signInDefault(f.account("a"))
        await f.refresh()
        #expect(f.setup("c") == ClaudeCodeSetup(status: .notSetUp(blocked: nil)))
    }

    @Test func anAccountThatAlreadyHasASignInSavedIsNotAskedForTheBrowserAgain() async throws {
        let f = try StoreFixture(["a", "b"], signedIn: "a"); defer { f.close() }
        await f.start()
        #expect(f.setup("b").status == .notSetUp(blocked: nil))
        // It was saved after the line was last read.
        let token = try f.switching.saveLogin(for: f.account("b"))

        f.signIn("b")
        await f.finish()

        #expect(f.setup("b").status == .ready && f.opened.values.isEmpty && !f.gates.calls.contains("browser"))
        #expect(f.world.token(in: f.switching.lendSlot(f.account("b"))) == token && f.world.isLive(token))
    }

    @Test func quittingEndsTheBrowserWaitAndLeavesNothing() async throws {
        let f = try StoreFixture(["a", "b"], signedIn: "a"); defer { f.close() }
        f.world.plan(.signIn("b@example.test"))
        let hold = f.gates.holdBrowser()
        await f.start()

        f.signIn("b")
        try await waitFor("the browser page") { hold.entered.wait(timeout: .now()) == .success }
        f.store.shutdown()
        await f.finish()

        #expect(f.store.claudeCodePreparation == nil && f.store.claudeCodeSetupFailures.isEmpty)
        #expect(!f.switching.lendFolderExists(f.account("b")) && f.switching.defaultEmail == "a@example.test")
        #expect(!f.gates.calls.contains("login") && f.switching.journal == nil)
    }

    @Test func aFinishedSignInChangesTheLineAndTheWindowAtOnceWithoutWaitingForTheNextReading() async throws {
        let f = try StoreFixture(["a", "b"], signedIn: "a"); defer { f.close() }
        f.world.plan(.signIn("b@example.test"))
        await f.start()
        // The reading that follows the sign-in is held, so what is shown is what the end of the sign-in itself changed.
        let hold = f.gates.holdKeychain()

        f.signIn("b")
        try await waitFor("the reading after the sign-in") { hold.entered.wait(timeout: .now()) == .success }

        #expect(f.store.claudeCodePreparation == nil && f.setup("b") == ClaudeCodeSetup(status: .ready) && f.enabled("b"))
        hold.release.signal()
        await f.finish()
        #expect(f.setup("b").status == .ready)
    }

    @Test func aSwitchThatFindsNothingSavedChangesTheWindowAtOnceWithoutWaitingForTheNextReading() async throws {
        let f = try StoreFixture(["a", "b"], signedIn: "a", saved: ["b"]); defer { f.close() }
        await f.start()
        // b's saved sign-in goes away behind the app's back; the window was told it was there.
        f.world.removeItem(f.switching.lendSlot(f.account("b")))
        try FileManager.default.removeItem(at: f.files.lend(f.account("b").id))
        #expect(f.enabled("b"))
        let hold = f.gates.holdKeychain()

        f.press("b")
        try await waitFor("the reading after the switch") { hold.entered.wait(timeout: .now()) == .success }

        #expect(f.store.claudeCodeActivity == nil && f.panel("b").control == .setUp(help: UsageStoreClaudeCodeTests.setUpHelp))
        #expect(f.setup("b").status == .notSetUp(blocked: nil))
        hold.release.signal()
        await f.finish()
        #expect(f.panel("b").control == .setUp(help: UsageStoreClaudeCodeTests.setUpHelp))
    }

    // MARK: What a sign-in locks

    @Test func whileAnAccountSignsInEveryButtonAndTheAccountsOwnDeleteAndReconnectAreBlocked() async throws {
        let f = try StoreFixture(["a", "b", "c", "d"], signedIn: "a", saved: ["c"]); defer { f.close() }
        f.world.plan(.signIn("b@example.test"))
        let hold = f.gates.holdBrowser()
        await f.start()

        f.signIn("b")
        try await waitFor("the browser page") { hold.entered.wait(timeout: .now()) == .success }
        try await waitFor("the cancel button") { f.store.claudeCodePreparation?.canCancel == true }

        // No window can switch: the saved account's button and the others' say so. The account Claude Code uses keeps its mark.
        #expect(f.panel("c") == ClaudeCodePanel(control: .use(enabled: false, help: Self.signingIn), lines: []))
        #expect(f.panel("d") == ClaudeCodePanel(control: .use(enabled: false, help: Self.signingIn), lines: []))
        #expect(f.panel("b").control == .use(enabled: false, help: Self.signingIn) && f.panel("a").control == .inClaudeCode)
        // No other line can sign in either, while its own says what it is doing and the ready ones stay ready.
        #expect(f.setup("d").status == .notSetUp(blocked: Self.signingIn) && !f.canSignIn("d"))
        #expect(f.setup("c").status == .ready && f.setup("a").status == .inClaudeCode)
        let calls = f.gates.calls
        f.signIn("d"); f.press("c"); f.signIn("b")
        #expect(f.gates.calls == calls && f.store.claudeCodePreparation?.accountID == f.account("b").id && f.store.claudeCodeActivity == nil)

        // The account being signed in cannot be deleted or reconnected; the others can.
        #expect(f.store.isClaudeCodeLocked(f.account("b")))
        #expect(!f.store.isClaudeCodeLocked(f.account("a")) && !f.store.isClaudeCodeLocked(f.account("c")) && !f.store.isClaudeCodeLocked(f.account("d")))
        #expect(f.store.claudeCodeLockNote(for: f.account("b")) == "Signing in for Claude Code" && f.store.claudeCodeLockNote(for: f.account("c")) == nil)
        await f.store.delete(f.account("b"))
        #expect(f.store.accounts.map(\.name) == ["a", "b", "c", "d"] && !f.store.accounts.contains(where: \.deletionPending))
        #expect(f.store.errorMessage == "AgentBar is signing this account in for Claude Code. Delete this account after it finishes.")
        f.store.errorMessage = nil
        await f.store.delete(f.account("b"), allowUserInteraction: false)
        #expect(f.store.errorMessage == nil && f.store.accounts.count == 4)
        #expect(!f.store.canStartLogin(replacing: f.account("b")))
        #expect(f.store.canStartLogin(replacing: f.account("c")) && f.store.canStartLogin(), "other accounts and a new one are not held back")

        // A sign-in that would replace b's usage login waits, as it does for a switch.
        let signedInAgain = PendingAccountLogin(account: UsageAccount(id: UUID(), provider: .claude, name: "b", identity: f.account("b").identity,
                                                                     credentialID: UUID()), replacing: f.account("b").id)
        f.store.reviewSignedIn(signedInAgain)
        #expect(f.store.reconnectLockedByClaudeCode)
        f.store.confirmLogin()
        #expect(f.store.pendingLogin != nil && f.store.accounts.first { $0.id == f.account("b").id }?.credentialID == f.account("b").credentialID)
        #expect(f.store.errorMessage == "AgentBar is signing this account in for Claude Code. Press Reconnect again after it finishes.")

        hold.release.signal()
        await f.finish()

        #expect(!f.store.isClaudeCodeLocked(f.account("b")) && !f.store.reconnectLockedByClaudeCode, "when the sign-in is over the reconnect can be confirmed")
        #expect(f.setup("b").status == .ready && f.canSignIn("d") && f.enabled("c"))
    }

    @Test func whileASwitchRunsNoLineCanSignIn() async throws {
        let f = try StoreFixture(["a", "b", "c"], signedIn: "a", saved: ["b"]); defer { f.close() }
        await f.start()
        let hold = f.world.hold(login: "default")
        f.press("b")
        try await waitFor("the login command") { hold.entered.wait(timeout: .now()) == .success }

        #expect(f.setup("c").status == .notSetUp(blocked: Self.switching) && !f.canSignIn("c"))
        let calls = f.gates.calls
        f.signIn("c")
        #expect(f.store.claudeCodePreparation == nil && f.gates.calls == calls)

        hold.release.signal()
        await f.finish()
        #expect(f.canSignIn("c"), "when the switch is over the line can sign in again")
    }

    @Test func nothingReadsClaudeCodeWhileASignInRunsAndTheEndReadsAgain() async throws {
        let f = try StoreFixture(["a", "b"], signedIn: "a"); defer { f.close() }
        f.world.plan(.signIn("b@example.test"))
        let hold = f.gates.holdBrowser()
        await f.start()

        f.signIn("b")
        try await waitFor("the browser page") { hold.entered.wait(timeout: .now()) == .success }
        let calls = f.gates.calls
        f.store.refreshClaudeCodeState()
        f.store.popoverWillOpen()
        f.store.accountsListDidOpen()
        #expect(f.store.claudeCodeReading == nil && f.gates.calls == calls)

        // The login in the default slot changed meanwhile; the reading that follows the sign-in finds it.
        f.switching.signInDefault(f.account("b"))
        hold.release.signal()
        await f.finish()
        #expect(f.store.claudeCodeAccountID == f.account("b").id)
    }

    @Test func aReadingThatFinishesWhileASignInRunsIsNotApplied() async throws {
        let f = try StoreFixture(["a", "b"], signedIn: "a"); defer { f.close() }
        f.world.plan(.signIn("b@example.test"))
        await f.start()
        let version = f.gates.holdVersion()
        f.store.refreshClaudeCodeState()
        try await waitFor("the version check of the reading") { version.entered.wait(timeout: .now()) == .success }
        let browser = f.gates.holdBrowser()
        f.signIn("b")
        try await waitFor("the browser page") { browser.entered.wait(timeout: .now()) == .success }

        // The reading that was already under way finds Claude Code too old and the account's folder empty; the sign-in has priority.
        f.world.version = "2.1.308 (Claude Code)\n"
        version.release.signal()
        await f.store.claudeCodeReading?.value
        #expect(f.store.claudeCodeAvailability == .ready && f.store.claudeCodePreparation != nil)

        f.world.version = "2.1.312 (Claude Code)\n"
        browser.release.signal()
        await f.finish()
        #expect(f.setup("b").status == .ready && f.store.claudeCodeAvailability == .ready)
    }

    // MARK: Deleting meanwhile

    @Test func anAccountDeletedWhileAnotherSignsInGoesWhenTheSignInEndsAndSoDoesItsSavedLogin() async throws {
        let f = try StoreFixture(["a", "b", "c"], signedIn: "a", saved: ["c"]); defer { f.close() }
        f.world.plan(.signIn("b@example.test"))
        let hold = f.gates.holdBrowser()
        await f.start()
        let c = f.account("c")
        f.signIn("b")
        try await waitFor("the browser page") { hold.entered.wait(timeout: .now()) == .success }

        // c is not the account being signed in, so it can be deleted. The engine will not remove a saved login meanwhile;
        // that is no failure to tell anyone about.
        await f.store.delete(c)

        #expect(f.store.errorMessage == nil)
        let waiting = try #require(f.store.accounts.first { $0.id == c.id })
        #expect(waiting.deletionPending && f.panel("c") == .hidden && f.setup("c") == .hidden)
        #expect(f.switching.lendFolderExists(c) && f.world.hasItem(f.switching.lendSlot(c)))

        // Nothing tries again while the sign-in runs: a file put back where a try would remove it stays.
        let marker = f.files.root.appendingPathComponent("usage/\(c.id.uuidString)/marker")
        try f.files.createPrivateDirectory(marker.deletingLastPathComponent())
        try Data("x".utf8).write(to: marker)
        try await Task.sleep(for: .milliseconds(350))
        #expect(FileManager.default.fileExists(atPath: marker.path))

        hold.release.signal()
        await f.finish()

        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(f.store.accounts.map(\.name) == ["a", "b"] && f.store.errorMessage == nil)
        #expect(!f.switching.lendFolderExists(c) && !f.world.hasItem(f.switching.lendSlot(c)))
        #expect(f.setup("b").status == .ready && f.world.problems.isEmpty)
    }

    @Test func aSignInPressedWhileASavedLoginIsBeingRemovedWaitsForItInsteadOfBeingTurnedAway() async throws {
        let f = try StoreFixture(["a", "b", "c"], signedIn: "a", saved: ["b"]); defer { f.close() }
        f.world.plan(.signIn("c@example.test"))
        await f.start()
        let hold = f.gates.holdKeychain()
        // b's saved login is being removed: the engine is inside, waiting for the Keychain.
        let deleting = Task { await f.store.delete(f.account("b")) }
        try await waitFor("the removal") { hold.entered.wait(timeout: .now()) == .success }

        #expect(f.canSignIn("c"))
        f.signIn("c")
        try await Task.sleep(for: .milliseconds(300))
        // Not sent away with "Another Claude Code operation is still running": the sign-in is still there, waiting its turn.
        #expect(f.store.claudeCodePreparation?.accountID == f.account("c").id && f.setup("c").failure == nil)

        hold.release.signal()
        await deleting.value
        await f.finish()

        #expect(f.setup("c").status == .ready && f.store.claudeCodeSetupFailures.isEmpty)
        #expect(f.store.accounts.map(\.name) == ["a", "c"] && f.store.errorMessage == nil)
        #expect(!f.switching.lendFolderExists(f.account("b")) && !f.world.hasItem(f.switching.lendSlot(f.account("b"))))
    }

    // MARK: The whole way round

    @Test func aLoginThatExpiredIsSignedInAgainInSettingsAndThenSwitches() async throws {
        let f = try StoreFixture(["a", "b"], signedIn: "a", saved: ["b"]); defer { f.close() }
        f.world.revoke(try #require(f.world.token(in: f.switching.lendSlot(f.account("b")))))
        await f.start()

        f.press("b")
        await f.finish()
        #expect(f.result("b")?.message == "The saved sign-in for b expired. Sign in again in Settings › Accounts.")
        #expect(f.panel("b").control == .setUp(help: UsageStoreClaudeCodeTests.setUpHelp) && f.canSignIn("b"))

        f.world.plan(.signIn("b@example.test"))
        f.signIn("b")
        await f.finish()
        #expect(f.setup("b").status == .ready && f.enabled("b"))

        f.press("b")
        await f.finish()
        #expect(f.result("b")?.succeeded == true && f.panel("b").control == .inClaudeCode)
        #expect(f.switching.defaultEmail == "b@example.test" && f.switching.lendEmail(f.account("a")) == "a@example.test")
        #expect(f.opened.values == [FakeClaudeWorld.browserURL], "the one page was the one in Settings")
        #expect(f.world.problems.isEmpty)
    }

    @Test func aFirstSwitchThatLosesTheLendBackSendsThePreviousAccountToSettings() async throws {
        let f = try StoreFixture(["a", "b"], signedIn: "a", saved: ["b"]); defer { f.close() }
        f.world.script("lend(a)", .invalidGrant(echoToken: false))
        await f.start()

        f.press("b")
        await f.finish()

        // a could not be lent back: its line and its window both say it has to sign in again, in Settings.
        #expect(f.result("b")?.message == "Claude Code now uses b. Open sessions switch within 30 s. Remote Control disconnects. a needs to sign in again in Settings › Accounts.")
        #expect(f.setup("a") == ClaudeCodeSetup(status: .notSetUp(blocked: nil)))
        #expect(f.panel("a").control == .setUp(help: UsageStoreClaudeCodeTests.setUpHelp))
    }

    // MARK: Drawn

    @Test func theSettingsListDrawsTheLineUnderEveryClaudeAccountInEveryState() async throws {
        let f = try StoreFixture(["a", "b", "c"], signedIn: "a", saved: ["b"]); defer { f.close() }
        f.world.plan(.signIn("c@example.test"))
        let hold = f.gates.holdBrowser()
        await f.start()
        func picture() throws -> Data {
            let host = NSHostingView(rootView: AccountManagementView().padding(20).frame(width: 540, height: 560, alignment: .topLeading)
                .environmentObject(f.store))
            host.frame = NSRect(x: 0, y: 0, width: 540, height: 560)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return try #require(bitmap.representation(using: .png, properties: [:]))
        }
        let idle = try picture()

        f.signIn("c")
        try await waitFor("the browser page") { hold.entered.wait(timeout: .now()) == .success }
        try await waitFor("the cancel button") { f.store.claudeCodePreparation?.canCancel == true }
        let waiting = try picture()
        hold.release.signal()
        await f.finish()
        let done = try picture()

        #expect(Set([idle, waiting, done]).count == 3)
    }
}
