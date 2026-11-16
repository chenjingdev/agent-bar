import Foundation
import Testing
@testable import agent_bar

// The store's side of switching Claude Code's account, run against the fake Claude Code and Keychain of
// ClaudeCodeTestSupport. No real Claude Code, Keychain item, login or browser is involved. Accounts that get deleted
// have no usage sign-in folder, so deleting them does not reach the real Keychain either.
@MainActor
@Suite(.serialized)
struct UsageStoreClaudeCodeTests {
    // MARK: What is shown

    @Test func withoutASwitcherNothingIsShown() throws {
        let f = try SwitchFixture()
        let account = f.addAccount("work")
        let (store, done) = try makeStore(f, claudeCode: false)
        defer { done() }

        #expect(store.claudeCodePanel(for: account) == .hidden)
        #expect(store.claudeCodeSetup(for: account) == .hidden)
        #expect(!store.claudeCodeEnabled)
    }

    @Test func startupReadsWhichAccountClaudeCodeUsesAndWhichAreReady() async throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev"), target = f.addAccount("target"), fresh = f.addAccount("fresh")
        f.signInDefault(prev)
        try f.saveLogin(for: target)
        let (store, done) = try makeStore(f)
        defer { done() }

        await store.runClaudeCodeStartup()

        #expect(store.claudeCodeAvailability == .ready)
        #expect(store.claudeCodeAccountID == prev.id)
        #expect(store.claudeCodeReady == [target.id])
        #expect(store.claudeCodePanel(for: prev).control == .inClaudeCode)
        #expect(store.claudeCodePanel(for: target).control
                == .use(enabled: true, help: "Use this account in Claude Code. Open sessions switch within 30 s."))
        // An account with nothing to hand over is sent to Settings, where it signs in once.
        guard case .setUp = store.claudeCodePanel(for: fresh).control else { Issue.record("fresh should be sent to Settings"); return }
        #expect(store.claudeCodeSetup(for: prev).status == .inClaudeCode)
        #expect(store.claudeCodeSetup(for: target).status == .ready)
        #expect(store.claudeCodeSetup(for: fresh).status == .notSetUp(blocked: nil))
    }

    @Test func anOldClaudeCodeBlocksTheButtonAndSaysWhy() async throws {
        let f = try SwitchFixture()
        let target = f.addAccount("target")
        try f.saveLogin(for: target)
        f.world.version = "2.1.100 (Claude Code)\n"
        let (store, done) = try makeStore(f)
        defer { done() }

        await store.runClaudeCodeStartup()

        let reason = "Claude Code 2.1.100 is too old. Update to 2.1.309 or newer."
        #expect(store.claudeCodeAvailability == .blocked(reason))
        #expect(store.claudeCodePanel(for: target) == ClaudeCodePanel(control: .use(enabled: false, help: reason), lines: [.notice(reason)]))
        store.useInClaudeCode(target)
        #expect(store.claudeCodeActivity == nil)
    }

    // MARK: Switching

    @Test func switchingShowsTheResultAndTheLoginThatWasThereIsSavedForLater() async throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev"), target = f.addAccount("target")
        f.signInDefault(prev)
        try f.saveLogin(for: target)
        let (store, done) = try makeStore(f)
        defer { done() }
        await store.runClaudeCodeStartup()

        store.useInClaudeCode(target)
        #expect(store.claudeCodeActivity?.targetID == target.id)
        // Both accounts the switch involves keep their sign-ins until it is done.
        #expect(store.isClaudeCodeLocked(target) && store.isClaudeCodeLocked(prev))
        #expect(await waitUntil { store.claudeCodeActivity == nil })
        await store.claudeCodeReading?.value

        #expect(f.defaultEmail == "target@example.test")
        #expect(store.claudeCodeAccountID == target.id)
        #expect(store.claudeCodeResults[target.id]
                == ClaudeCodeResult(succeeded: true, message: "Claude Code now uses target. Open sessions switch within 30 s. Remote Control disconnects."))
        // The login that was in Claude Code went back to its account, so switching back needs no browser.
        #expect(store.claudeCodeReady == [prev.id])
        #expect(store.claudeCodePanel(for: prev).control
                == .use(enabled: true, help: "Use this account in Claude Code. Open sessions switch within 30 s."))
        #expect(!store.isClaudeCodeLocked(target) && !store.isClaudeCodeLocked(prev))
    }

    @Test func aLoginLimiDoesNotHaveIsAskedAboutBeforeItIsRemoved() async throws {
        let f = try SwitchFixture()
        let target = f.addAccount("target")
        f.signInDefault(email: "stranger@example.test")
        try f.saveLogin(for: target)
        let (store, done) = try makeStore(f)
        defer { done() }
        await store.runClaudeCodeStartup()
        #expect(store.claudeCodeAccountID == nil)

        store.useInClaudeCode(target)
        #expect(await waitUntil { store.claudeCodeActivity == nil })
        #expect(f.defaultEmail == "stranger@example.test")
        #expect(store.claudeCodeConfirmation?.accountID == target.id)
        #expect(store.claudeCodePanel(for: target).lines == [.confirmation(email: "stranger@example.test")])

        store.confirmClaudeCodeSwitch()
        #expect(await waitUntil { store.claudeCodeActivity == nil && store.claudeCodeResults[target.id] != nil })
        #expect(f.defaultEmail == "target@example.test")
        #expect(store.claudeCodeResults[target.id]?.succeeded == true)
        #expect(store.claudeCodeConfirmation == nil)
    }

    @Test func aResultGoesOnlyAfterPanelsThatShowedItHaveClosedTwice() async throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev"), target = f.addAccount("target")
        f.signInDefault(prev)
        try f.saveLogin(for: target)
        let (store, done) = try makeStore(f)
        defer { done() }
        await store.runClaudeCodeStartup()
        // No panel was open while the switch ran, so the result has not been on screen yet.
        store.useInClaudeCode(target)
        #expect(await waitUntil { store.claudeCodeActivity == nil })
        let group = UUID()

        // A panel that only showed the other account leaves it alone, and closing a panel that is not open does nothing.
        store.claudeCodePanelWillOpen(group: group)
        store.claudeCodePanelShows([prev.id], group: group)
        store.claudeCodePanelDidClose(group: group)
        store.claudeCodePanelDidClose(group: group)
        #expect(store.claudeCodeResults[target.id]?.closes == 0)
        // Shown: the first close keeps it, so a panel closed by accident can be opened again to read it.
        store.claudeCodePanelWillOpen(group: group)
        store.claudeCodePanelShows([target.id], group: group)
        store.claudeCodePanelDidClose(group: group)
        #expect(store.claudeCodeResults[target.id]?.closes == 1)
        // Shown again, since the panel lists the accounts it listed last: the second close clears it.
        store.claudeCodePanelWillOpen(group: group)
        store.claudeCodePanelDidClose(group: group)
        #expect(store.claudeCodeResults[target.id] == nil)
    }

    @Test func aResultThatArrivesWhileThePanelShowsItsAccountHasBeenOnScreen() async throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev"), target = f.addAccount("target")
        f.signInDefault(prev)
        try f.saveLogin(for: target)
        let (store, done) = try makeStore(f)
        defer { done() }
        await store.runClaudeCodeStartup()
        let group = UUID()
        store.claudeCodePanelWillOpen(group: group)
        store.claudeCodePanelShows([target.id], group: group)

        store.useInClaudeCode(target)
        #expect(await waitUntil { store.claudeCodeActivity == nil })
        // The reading after the switch finds prev's login put back, so prev can be used below.
        await store.claudeCodeReading?.value
        store.claudeCodePanelDidClose(group: group)
        #expect(store.claudeCodeResults[target.id]?.closes == 1)

        // A result that arrives after the panel stopped listing its account has not been on screen.
        let hold = f.world.hold(login: "default")
        store.claudeCodePanelWillOpen(group: group)
        store.claudeCodePanelShows([prev.id], group: group)
        store.useInClaudeCode(prev)
        #expect(await waitUntil { f.world.calls.filter { $0.arguments == ["auth", "login", "--claudeai"] }.count >= 3 })
        store.claudeCodePanelShows([target.id], group: group)
        hold.release.signal()
        #expect(await waitUntil { store.claudeCodeActivity == nil })
        store.claudeCodePanelDidClose(group: group)
        #expect(store.claudeCodeResults[prev.id]?.succeeded == true && store.claudeCodeResults[prev.id]?.closes == 0)
        // It counts once the panel lists its account again.
        store.claudeCodePanelWillOpen(group: group)
        store.claudeCodePanelShows([prev.id], group: group)
        store.claudeCodePanelDidClose(group: group)
        #expect(store.claudeCodeResults[prev.id]?.closes == 1)
    }

    @Test func theQuestionGoesWithThePanelThatShowedIt() async throws {
        let f = try SwitchFixture()
        let target = f.addAccount("target"), other = f.addAccount("other")
        f.signInDefault(email: "stranger@example.test")
        try f.saveLogin(for: target)
        let (store, done) = try makeStore(f)
        defer { done() }
        await store.runClaudeCodeStartup()
        let group = UUID()
        store.useInClaudeCode(target)
        #expect(await waitUntil { store.claudeCodeActivity == nil && store.claudeCodeConfirmation != nil })

        // Not on screen yet: a panel that showed another account keeps it.
        store.claudeCodePanelWillOpen(group: group)
        store.claudeCodePanelShows([other.id], group: group)
        store.claudeCodePanelDidClose(group: group)
        #expect(store.claudeCodeConfirmation?.accountID == target.id)
        // Shown, then closed: the yes it asked for is not kept.
        store.claudeCodePanelWillOpen(group: group)
        store.claudeCodePanelShows([target.id], group: group)
        store.claudeCodePanelDidClose(group: group)
        #expect(store.claudeCodeConfirmation == nil)
        #expect(f.defaultEmail == "stranger@example.test")
    }

    // MARK: Signing an account in once, in Settings

    @Test func setUpSignsTheAccountInThroughTheBrowserAndMakesItReady() async throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev"), target = f.addAccount("target")
        f.signInDefault(prev)
        let (store, done) = try makeStore(f)
        defer { done() }
        await store.runClaudeCodeStartup()
        f.world.plan(.signIn("target@example.test"))

        store.prepareForClaudeCode(target)
        #expect(store.claudeCodePreparation?.accountID == target.id)
        #expect(store.isClaudeCodeLocked(target) && !store.isClaudeCodeLocked(prev))
        #expect(await waitUntil { store.claudeCodePreparation == nil })

        #expect(store.claudeCodeReady.contains(target.id))
        #expect(store.claudeCodeSetup(for: target).status == .ready)
        // Claude Code's own login was not touched.
        #expect(f.defaultEmail == "prev@example.test")
    }

    @Test func aSetUpThatSignedInAsSomeoneElseSaysSoAndKeepsNothing() async throws {
        let f = try SwitchFixture()
        let target = f.addAccount("target")
        let (store, done) = try makeStore(f)
        defer { done() }
        await store.runClaudeCodeStartup()
        f.world.plan(.signIn("someone@example.test"))

        store.prepareForClaudeCode(target)
        #expect(await waitUntil { store.claudeCodePreparation == nil })

        #expect(store.claudeCodeSetup(for: target) == ClaudeCodeSetup(status: .notSetUp(blocked: nil), failure: "Signed in as a different account."))
        #expect(!f.lendFolderExists(target))
    }

    // MARK: Deleting

    @Test func deletingAnAccountRemovesItsSavedSignInForClaudeCode() async throws {
        let f = try SwitchFixture()
        let gone = unmanagedAccount(f, "gone")
        try f.saveLogin(for: gone)
        let (store, done) = try makeStore(f, extra: [gone])
        defer { done() }

        await store.delete(gone)

        #expect(!store.accounts.contains { $0.id == gone.id })
        #expect(!f.lendFolderExists(gone) && !f.world.hasItem(f.lendSlot(gone)))
    }

    @Test func anAccountASwitchInvolvesWaitsAndAnotherOneIsDeletedWhenTheSwitchEnds() async throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev"), target = f.addAccount("target")
        let gone = unmanagedAccount(f, "gone")
        f.signInDefault(prev)
        try f.saveLogin(for: target)
        try f.saveLogin(for: gone)
        let (store, done) = try makeStore(f, extra: [gone])
        defer { done() }
        await store.runClaudeCodeStartup()
        let hold = f.world.hold(login: "default")

        store.useInClaudeCode(target)
        #expect(await waitUntil { f.world.calls.contains { $0.arguments == ["auth", "login", "--claudeai"] } })

        // Settings says why Delete and Reconnect are greyed out for the two accounts the switch involves, not for others.
        #expect(store.claudeCodeLockNote(for: target) == "Delete and Reconnect wait until Claude Code has switched accounts.")
        #expect(store.claudeCodeLockNote(for: prev) == "Delete and Reconnect wait until Claude Code has switched accounts.")
        #expect(store.claudeCodeLockNote(for: gone) == nil)
        // The account being switched to is not deleted, and the person is told why.
        await store.delete(target)
        #expect(store.errorMessage == "Claude Code is switching accounts. Delete this account after it finishes.")
        #expect(store.accounts.first { $0.id == target.id }?.deletionPending == false)
        // An account the switch does not involve leaves the list at once; its saved sign-in waits for the engine.
        await store.delete(gone)
        #expect(store.accounts.first { $0.id == gone.id }?.deletionPending == true)
        #expect(f.lendFolderExists(gone))

        hold.release.signal()
        #expect(await waitUntil { !store.accounts.contains { $0.id == gone.id } })
        #expect(!f.lendFolderExists(gone) && !f.world.hasItem(f.lendSlot(gone)))
        #expect(f.defaultEmail == "target@example.test")
    }

    // MARK: Launch

    @Test func aSwitchCutShortIsFinishedAtLaunchAndShownOnItsPanel() async throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev"), target = f.addAccount("target")
        // AgentBar quit after Claude Code was switched, before the previous login was saved.
        f.signInDefault(target)
        try f.files.write(ClaudeCodeSwitchJournal(targetID: target.id, previousID: prev.id, stage: .slotSwitched, startedAt: .now),
                          to: f.files.claudeCodeSwitchJournalURL)
        let (store, done) = try makeStore(f)
        defer { done() }

        await store.runClaudeCodeStartup()

        #expect(store.claudeCodeResults[target.id]
                == ClaudeCodeResult(succeeded: true, message: "AgentBar quit while switching. Claude Code now uses target. prev needs to be set up for Claude Code again in Settings › Accounts."))
        #expect(store.claudeCodeAccountID == target.id)
        #expect(!FileManager.default.fileExists(atPath: f.files.claudeCodeSwitchJournalURL.path))
    }

    @Test func onlyTheAppGetsASwitcher() {
        #expect(AppContainer.claudeCodeAllowed([:], isAppBundle: true))
        #expect(AppContainer.claudeCodeAllowed(["HOME": "/Users/someone"], isAppBundle: true))
        // `swift run`, and development or test runs with their own data folder or defaults.
        #expect(!AppContainer.claudeCodeAllowed([:], isAppBundle: false))
        #expect(!AppContainer.claudeCodeAllowed(["AGENTBAR_DATA_DIR": "/tmp/limi-dev"], isAppBundle: true))
        #expect(!AppContainer.claudeCodeAllowed(["AGENTBAR_DEFAULTS_SUITE": "limi-dev"], isAppBundle: true))
    }

    @Test func whileAnInterruptedSwitchIsCheckedAtLaunchEveryClaudeAccountWaits() throws {
        let f = try SwitchFixture()
        let work = f.addAccount("work")
        let (store, done) = try makeStore(f)
        defer { done() }
        store.claudeCodeStarting = true
        #expect(store.isClaudeCodeLocked(work))
        #expect(store.claudeCodeLockNote(for: work) == "Delete and Reconnect wait until AgentBar has checked Claude Code.")
        #expect(store.claudeCodeBusyMessage(for: .reconnect) == "AgentBar is still checking Claude Code. Reconnect this account in a moment.")
    }

    @Test func aFailureWarnsThatTheLoginMayHaveChangedOnlyWhenItMayHave() {
        let nothing = ClaudeCodeSwitchFailure(reason: "Could not switch Claude Code.", nothingChanged: true)
        #expect(UsageStore.claudeCodeFailureMessage(nothing) == "Could not switch Claude Code.")
        let touched = ClaudeCodeSwitchFailure(reason: "Could not confirm which account Claude Code uses now.", nothingChanged: false)
        #expect(UsageStore.claudeCodeFailureMessage(touched)
                == "Could not confirm which account Claude Code uses now. Claude Code's login may have changed.")
        // A reason that already says so is not repeated.
        let saysSo = ClaudeCodeSwitchFailure(reason: "Claude Code's login changed while switching. Try again.", nothingChanged: false)
        #expect(UsageStore.claudeCodeFailureMessage(saysSo) == "Claude Code's login changed while switching. Try again.")
    }

    // MARK: Groups and their account lists

    @Test func scheduledRefreshAndMemberChangesDoNotReadClaudeCode() async throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev"), other = f.addAccount("other")
        f.signInDefault(prev)
        // The menu bar shows prev alone, so other's usage is asked for only once it joins the group.
        var registry = AccountRegistry(accounts: f.accounts)
        registry.repairRepresentatives()
        var display = DisplayConfiguration.initial(registry)
        let group = MenuBarLayout(name: "Work", rows: [MenuBarLine(accountID: prev.id, metricID: "weekly", slot: 0, badgeText: "prev")])
        display.layouts = [group]
        try f.files.write(display, to: f.files.root.appendingPathComponent("display-v2.json"))
        let asked = Recorder<UUID>()
        let (store, done) = try makeStore(f, autoRefresh: true, loadAccount: { account, _ in
            asked.add(account.id)
            return .placeholder(for: account.provider)
        })
        defer { done() }
        // Launch reads which account Claude Code uses.
        #expect(await waitUntil { !store.claudeCodeStarting && store.claudeCodeReading == nil && !store.isRefreshing })
        #expect(store.claudeCodeAccountID == prev.id)

        // Claude Code is signed in to other in a terminal. Neither the timer nor a new member reads it.
        f.signInDefault(other)
        store.refreshOnSchedule()
        #expect(store.claudeCodeReading == nil)
        store.addGroupMember(other.id, to: group.id)
        #expect(store.claudeCodeReading == nil)
        #expect(await waitUntil { asked.values.contains(other.id) && !store.isRefreshing })
        #expect(store.claudeCodeAccountID == prev.id)
        // A panel opening does.
        store.claudeCodePanelWillOpen(group: group.id)
        #expect(await waitUntil { store.claudeCodeAccountID == other.id })
    }

    @Test func listRowsKeepProgressOnTheTargetAndTheAppWideNoticeOnce() async throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev"), target = f.addAccount("target"), other = f.addAccount("other")
        // Without its organization the account cannot be told apart from another login.
        let legacy = UsageAccount(id: UUID(), provider: .claude, name: "legacy",
                                  identity: AccountIdentity(email: "legacy@example.test"), credentialID: UUID())
        f.signInDefault(prev)
        try f.saveLogin(for: target)
        f.world.version = "2.1.100 (Claude Code)\n"
        let (store, done) = try makeStore(f, extra: [legacy])
        defer { done() }
        await store.runClaudeCodeStartup()

        // Too old for every account: the list says why once, and its rows do not.
        let reason = "Claude Code 2.1.100 is too old. Update to 2.1.309 or newer."
        #expect(store.claudeCodeListNotice == reason)
        #expect(store.claudeCodeListRow(for: target) == ClaudeCodePanel(control: .use(enabled: false, help: reason), lines: []))
        #expect(store.claudeCodePanel(for: target).lines == [.notice(reason)])

        // Updated, nothing stands in the way of all of them, and an account's own reason stays on its row.
        f.world.version = "2.1.312 (Claude Code)\n"
        store.refreshClaudeCodeState()
        await store.claudeCodeReading?.value
        #expect(store.claudeCodeListNotice == nil)
        #expect(store.claudeCodeListRow(for: legacy).lines == [.notice("Reconnect this account before using it in Claude Code.")])

        // While Claude Code switches, only the account it switches to shows it; the other rows' buttons wait.
        let hold = f.world.hold(login: "default")
        store.useInClaudeCode(target)
        #expect(await waitUntil { f.world.calls.contains { $0.arguments == ["auth", "login", "--claudeai"] } })
        let step = try #require(store.claudeCodeActivity?.message)
        #expect(store.claudeCodeListRow(for: target).lines == [.progress(step)])
        #expect(store.claudeCodeListRow(for: other)
                == ClaudeCodePanel(control: .use(enabled: false, help: "Claude Code is being switched. Wait for it to finish."), lines: []))
        #expect(store.claudeCodePanel(for: other).lines == [.progress("Switching Claude Code to target…")])
        hold.release.signal()
        #expect(await waitUntil { store.claudeCodeActivity == nil })
    }

    @Test func aListShowsEveryAccountItHolds() async throws {
        let f = try SwitchFixture()
        let a = f.addAccount("a"), b = f.addAccount("b"), c = f.addAccount("c"), away = f.addAccount("away")
        f.signInDefault(email: "stranger@example.test")
        try f.saveLogin(for: b)
        let (store, done) = try makeStore(f)
        defer { done() }
        await store.runClaudeCodeStartup()
        // A switch to b asks about the login AgentBar does not have; a, c and away have results nobody has seen.
        store.useInClaudeCode(b)
        #expect(await waitUntil { store.claudeCodeActivity == nil && store.claudeCodeConfirmation?.accountID == b.id })
        for id in [a.id, c.id, away.id] { store.claudeCodeResults[id] = ClaudeCodeResult(succeeded: true, message: "Done.") }
        let group = UUID()

        // The list shows a, b and c at once: closing it counts for both results, and the question goes with it.
        store.claudeCodePanelWillOpen(group: group)
        store.claudeCodePanelShows([a.id, b.id, c.id], group: group)
        store.claudeCodePanelDidClose(group: group)
        #expect(store.claudeCodeResults[a.id]?.closes == 1 && store.claudeCodeResults[c.id]?.closes == 1)
        #expect(store.claudeCodeResults[away.id]?.closes == 0)
        #expect(store.claudeCodeConfirmation == nil)
        // Opened again, the list shows them again, and the second close clears them.
        store.claudeCodePanelWillOpen(group: group)
        store.claudeCodePanelDidClose(group: group)
        #expect(store.claudeCodeResults[a.id] == nil && store.claudeCodeResults[c.id] == nil)
        #expect(store.claudeCodeResults[away.id]?.closes == 0)
    }

    // MARK: Helpers

    private func makeStore(_ f: SwitchFixture, extra: [UsageAccount] = [], claudeCode: Bool = true, autoRefresh: Bool = false,
                           loadAccount: @escaping @Sendable (UsageAccount, OperationControl) async -> ProviderSnapshot
                               = { account, _ in .placeholder(for: account.provider) }) throws -> (UsageStore, () -> Void) {
        var registry = AccountRegistry(accounts: f.accounts + extra)
        registry.repairRepresentatives()
        try f.files.write(registry, to: f.files.registryURL)
        let suite = "claude-code-store-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        let store = UsageStore(settings: AppSettings(defaults: defaults), files: f.files, autoRefresh: autoRefresh,
                               loadAccount: loadAccount,
                               claudeCode: claudeCode ? f.switcher : nil,
                               claudeCodeBrowser: BrowserLoginLauncher(openURL: { _ in true }))
        return (store, { store.shutdown(); defaults.removePersistentDomain(forName: suite) })
    }

    // A Claude account without a usage sign-in folder of its own: deleting it touches no real Keychain item.
    private func unmanagedAccount(_ f: SwitchFixture, _ name: String) -> UsageAccount {
        let email = "\(name)@example.test"
        let person = f.world.person(email)
        let account = UsageAccount(id: UUID(), provider: .claude, name: name,
                                   identity: AccountIdentity(email: email, organizationID: person.organizationUUID, stableID: person.accountUUID))
        f.world.register(account)
        return account
    }

    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}
