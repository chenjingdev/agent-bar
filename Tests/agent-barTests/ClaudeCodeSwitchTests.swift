import Foundation
import Testing
@testable import agent_bar

// The switch, step by step, against a fake Claude Code and a fake Keychain.
struct ClaudeCodeSwitchTests {
    // MARK: The normal path

    @Test func switchesTheDefaultLoginAndLendsThePreviousOneBack() throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev"), target = f.addAccount("target")
        let prevToken = f.signInDefault(prev)
        let targetToken = try f.saveLogin(for: target)

        let result = f.switchTo(target)

        #expect(result.outcome == .switched(ClaudeCodeSwitched(accountID: target.id, previousAccountID: prev.id, needsLogin: [])))
        // R5: read the previous login, hand the new one over, remove its used-up copy, read the slot again, then lend the
        // previous one back. The journal says "started" before the default login is touched and "slotSwitched" before
        // the lending back, and the lend folder is looked at before and after so that no token is used twice.
        #expect(f.world.events == [
            "version",
            "read default",
            "read lend(target)",
            "login default <- target [journal started]",
            "delete lend(target)",
            "read default",
            "read lend(prev)",
            "login lend(prev) <- prev [journal slotSwitched]",
            "read lend(prev)",
        ])
        #expect(result.steps == [.checkingVersion, .readingCurrentLogin, .signingIn, .verifying, .returningPreviousLogin])
        #expect(f.defaultEmail == "target@example.test")
        #expect(!f.world.hasItem(f.lendSlot(target)) && !f.lendFolderExists(target))
        #expect(f.lendEmail(prev) == "prev@example.test")
        // Both tokens were used once, and the logins that exist now hold fresh ones.
        #expect(!f.world.isLive(prevToken) && !f.world.isLive(targetToken))
        #expect(f.world.token(in: f.defaultSlot).map(f.world.isLive) == true)
        #expect(f.world.token(in: f.lendSlot(prev)).map(f.world.isLive) == true)
        #expect(f.journal == nil)
        #expect(f.world.problems.isEmpty)
    }

    @Test func theSavedLoginKeepsItsScopes() throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev"), target = f.addAccount("target")
        f.signInDefault(prev)
        try f.files.createPrivateDirectory(f.files.lendRoot)
        try f.files.createPrivateDirectory(f.files.lend(target.id))
        f.world.signIn(f.lendSlot(target), as: "target@example.test", scopes: ["user:inference", "user:profile", "user:file_upload"])

        _ = f.switchTo(target)

        let login = try #require(f.world.calls.first { $0.arguments.first == "auth" })
        #expect(login.environment["CLAUDE_CODE_OAUTH_SCOPES"] == "user:inference user:profile user:file_upload")
    }

    @Test func switchingThereAndBackNeedsNoBrowser() throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev"), target = f.addAccount("target")
        f.signInDefault(prev)
        try f.saveLogin(for: target)

        #expect(f.switchTo(target).outcome == .switched(.init(accountID: target.id, previousAccountID: prev.id, needsLogin: [])))
        let back = f.switchTo(prev)

        #expect(back.outcome == .switched(.init(accountID: prev.id, previousAccountID: target.id, needsLogin: [])))
        #expect(f.defaultEmail == "prev@example.test")
        #expect(f.lendEmail(target) == "target@example.test")
        #expect(!f.world.hasItem(f.lendSlot(prev)) && !f.lendFolderExists(prev))
        #expect(!f.world.events.contains { $0.hasPrefix("browser") })
        #expect(f.world.problems.isEmpty)
    }

    @Test func accountsWithoutAnAccountUUIDAreComparedByOrganizationAndEmail() throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev", stableID: false), target = f.addAccount("target", stableID: false)
        f.signInDefault(prev)
        try f.saveLogin(for: target)

        let result = f.switchTo(target)

        #expect(result.outcome == .switched(.init(accountID: target.id, previousAccountID: prev.id, needsLogin: [])))
        #expect(f.defaultEmail == "target@example.test" && f.lendEmail(prev) == "prev@example.test")
    }

    @Test func alreadyInUseChangesNothing() throws {
        let f = try SwitchFixture()
        let target = f.addAccount("target")
        let token = f.signInDefault(target)
        try f.saveLogin(for: target)

        let result = f.switchTo(target)

        #expect(result.outcome == .alreadyInUse)
        #expect(f.world.events == ["version", "read default"])
        #expect(f.world.isLive(token) && f.defaultEmail == "target@example.test")
        #expect(f.world.hasItem(f.lendSlot(target)))
        #expect(f.journal == nil)
    }

    @Test func aSignedOutDefaultLoginIsSwitchedWithoutAskingOrLendingBack() throws {
        for leftoverIdentity in [false, true] {
            let f = try SwitchFixture()
            let prev = f.addAccount("prev"), target = f.addAccount("target")
            if leftoverIdentity { f.signInDefault(prev); f.world.removeItem(f.defaultSlot) }
            try f.saveLogin(for: target)

            let result = f.switchTo(target)

            #expect(result.outcome == .switched(.init(accountID: target.id, previousAccountID: nil, needsLogin: [])))
            #expect(f.world.events == ["version", "read default", "read lend(target)", "login default <- target [journal started]",
                                       "delete lend(target)", "read default"])
            #expect(f.defaultEmail == "target@example.test")
        }
    }

    // MARK: A login AgentBar does not know

    @Test func anUnknownPreviousLoginNeedsAYesBeforeAnythingChanges() throws {
        let f = try SwitchFixture()
        let target = f.addAccount("target")
        let strangerToken = f.signInDefault(email: "stranger@example.test")
        try f.saveLogin(for: target)

        let asked = f.switchTo(target)

        guard case .needsConfirmation(let login) = asked.outcome else { Issue.record("expected a question"); return }
        #expect(login.email == "stranger@example.test" && login.accountUUID != nil && login.organizationUUID != nil)
        #expect(f.world.events == ["version", "read default"])
        #expect(f.world.isLive(strangerToken) && f.defaultEmail == "stranger@example.test")
        #expect(f.world.hasItem(f.lendSlot(target)))
        #expect(f.journal == nil)
        #expect(f.logLines.last?["outcome"] as? String == "needsConfirmation")

        let confirmed = f.switchTo(target, confirmedLosing: login)

        #expect(confirmed.outcome == .switched(.init(accountID: target.id, previousAccountID: nil, needsLogin: [])))
        #expect(f.defaultEmail == "target@example.test")
        // Nobody is logged out, and nothing is lent for a login that has no account.
        #expect(!f.world.events.contains("delete default"))
        #expect(!f.world.events.contains { $0.hasPrefix("login lend(") })
        #expect(!f.world.calls.contains { $0.environment["CLAUDE_CODE_OAUTH_REFRESH_TOKEN"] == strangerToken })
    }

    @Test func aLoginWithoutAnyIdentityAlsoNeedsAYes() throws {
        let f = try SwitchFixture()
        let target = f.addAccount("target")
        f.world.setSecret(f.defaultSlot, Data(#"{"claudeAiOauth":{"refreshToken":"FAKE-REFRESH-X"}}"#.utf8))
        try f.saveLogin(for: target)

        let nobody = ClaudeCodeUnknownLogin(email: nil, accountUUID: nil, organizationUUID: nil)
        #expect(f.switchTo(target).outcome == .needsConfirmation(nobody))
        #expect(f.switchTo(target, confirmedLosing: nobody).outcome == .switched(.init(accountID: target.id, previousAccountID: nil, needsLogin: [])))
    }

    // MARK: The first time: the browser

    @Test func withoutASavedLoginTheBrowserSignsTheAccountInFirst() throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev"), target = f.addAccount("target")
        f.signInDefault(prev)
        f.world.plan(.signIn("target@example.test"))
        let opened = Recorder<URL>()

        let result = f.switchTo(target, openURL: { opened.add($0) })

        #expect(result.outcome == .switched(.init(accountID: target.id, previousAccountID: prev.id, needsLogin: [])))
        #expect(result.steps == [.checkingVersion, .readingCurrentLogin, .waitingForBrowser(.noSavedLogin), .signingIn,
                                 .verifying, .returningPreviousLogin])
        #expect(opened.values == [FakeClaudeWorld.browserURL])
        // The previous login is read again after the wait, so it is as fresh as it can be.
        #expect(f.world.events == [
            "version", "read default", "read lend(target)",
            "browser lend(target)", "read lend(target)", "read default",
            "login default <- target [journal started]", "delete lend(target)", "read default",
            "read lend(prev)", "login lend(prev) <- prev [journal slotSwitched]", "read lend(prev)",
        ])
        #expect(f.defaultEmail == "target@example.test" && f.lendEmail(prev) == "prev@example.test")
        #expect(f.world.problems.isEmpty)
    }

    @Test func aSavedLoginThatBelongsToSomeoneElseIsClearedAndNeverLent() throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev"), target = f.addAccount("target")
        f.signInDefault(prev)
        try f.files.createPrivateDirectory(f.files.lendRoot)
        try f.files.createPrivateDirectory(f.files.lend(target.id))
        let intruder = f.world.signIn(f.lendSlot(target), as: "intruder@example.test")
        f.world.plan(.signIn("target@example.test"))

        let result = f.switchTo(target)

        #expect(result.outcome == .switched(.init(accountID: target.id, previousAccountID: prev.id, needsLogin: [])))
        #expect(f.world.events.prefix(5).elementsEqual(["version", "read default", "read lend(target)", "delete lend(target)", "browser lend(target)"]))
        #expect(!f.world.calls.contains { $0.environment["CLAUDE_CODE_OAUTH_REFRESH_TOKEN"] == intruder })
        #expect(f.defaultEmail == "target@example.test")
    }

    @Test func aRefusedSavedLoginIsRemovedAndTheBrowserIsUsedOnce() throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev"), target = f.addAccount("target")
        f.signInDefault(prev)
        let spent = try f.saveLogin(for: target)
        f.world.revoke(spent)
        f.world.plan(.signIn("target@example.test"))

        let result = f.switchTo(target)

        #expect(result.outcome == .switched(.init(accountID: target.id, previousAccountID: prev.id, needsLogin: [])))
        #expect(result.steps == [.checkingVersion, .readingCurrentLogin, .signingIn, .waitingForBrowser(.savedLoginExpired),
                                 .signingIn, .verifying, .returningPreviousLogin])
        #expect(f.world.events == [
            "version", "read default", "read lend(target)",
            "login default <- target (spent) [journal started]", "read default", "delete lend(target)",
            "browser lend(target)", "read lend(target)", "read default",
            "login default <- target [journal started]", "delete lend(target)", "read default",
            "read lend(prev)", "login lend(prev) <- prev [journal slotSwitched]", "read lend(prev)",
        ])
        #expect(f.defaultEmail == "target@example.test")
    }

    @Test func aLoginChangedWhileTheBrowserWasOpenIsTheOneLentBack() throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev"), other = f.addAccount("other"), target = f.addAccount("target")
        f.signInDefault(prev)
        let spent = try f.saveLogin(for: target)
        f.world.revoke(spent)
        f.world.plan(.signIn("target@example.test"))

        // While the browser is open, somebody signs Claude Code in as another registered account.
        let result = f.switchTo(target, openURL: { _ in f.signInDefault(other) })

        #expect(result.outcome == .switched(.init(accountID: target.id, previousAccountID: other.id, needsLogin: [])))
        #expect(f.lendEmail(other) == "other@example.test" && !f.world.hasItem(f.lendSlot(prev)))
        // The record that a crash would leave behind names the login that is really there to lend.
        let journals = f.world.journalsAtLogin
        #expect(journals.map { $0?.previousID } == [prev.id, other.id, other.id])
        #expect(journals.allSatisfy { $0?.stage == .started || $0?.stage == .slotSwitched })
    }

    @Test func aRefusedLoginIsRetriedWithTheBrowserOnlyOnce() throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev"), target = f.addAccount("target")
        let prevToken = f.signInDefault(prev)
        try f.saveLogin(for: target)
        f.world.plan(.signIn("target@example.test"))
        f.world.script("default", .invalidGrant(echoToken: false), .invalidGrant(echoToken: false))

        let result = f.switchTo(target)

        #expect(result.outcome == .failed(.init(reason: "Claude rejected the sign-in. Try again.", nothingChanged: true)))
        #expect(f.world.events.filter { $0.hasPrefix("browser") }.count == 1)
        #expect(f.world.events.filter { $0.hasPrefix("login default") }.count == 2)
        #expect(f.defaultEmail == "prev@example.test" && f.world.isLive(prevToken))
        #expect(!f.world.events.contains { $0.hasPrefix("login lend(prev)") })
        // The login the browser just made was refused too: its copy is not kept, and the browser is not opened again.
        #expect(!f.world.hasItem(f.lendSlot(target)) && !f.lendFolderExists(target))
        #expect(f.journal == nil)
    }

    @Test func aBrowserLoginAsAnotherAccountIsDiscarded() throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev"), target = f.addAccount("target")
        f.signInDefault(prev)
        f.world.plan(.signIn("someone.else@example.test"))

        let result = f.switchTo(target)

        #expect(result.outcome == .failed(.init(reason: "Signed in as a different account.", nothingChanged: true)))
        #expect(!f.world.hasItem(f.lendSlot(target)) && !f.lendFolderExists(target))
        #expect(f.defaultEmail == "prev@example.test")
        #expect(!f.world.events.contains { $0.hasPrefix("login") })
        #expect(f.journal == nil)
    }

    @Test func cancellingTheBrowserWaitChangesNothing() throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev"), target = f.addAccount("target")
        let prevToken = f.signInDefault(prev)
        let control = OperationControl()
        f.world.plan(.signIn("target@example.test"))

        let result = f.switchTo(target, control: control, openURL: { _ in control.cancel() })

        #expect(result.outcome == .cancelled)
        #expect(result.steps.last == .waitingForBrowser(.noSavedLogin))
        #expect(!f.lendFolderExists(target) && !f.world.hasItem(f.lendSlot(target)))
        #expect(f.defaultEmail == "prev@example.test" && f.world.isLive(prevToken))
        #expect(!f.world.events.contains { $0.hasPrefix("login") })
        #expect(f.logLines.last?["outcome"] as? String == "cancelled")
    }

    @Test func aBrowserLoginThatDoesNotFinishFailsWithoutChanges() throws {
        for plan in [FakeClaudeWorld.Browser.timeout, .failure] {
            let f = try SwitchFixture()
            let prev = f.addAccount("prev"), target = f.addAccount("target")
            f.signInDefault(prev)
            f.world.plan(plan)

            let result = f.switchTo(target)

            guard case .failed(let failure) = result.outcome else { Issue.record("expected a failure"); return }
            #expect(failure.nothingChanged && failure.reason.hasPrefix("Browser sign-in"))
            if case .timeout = plan { #expect(failure.reason == "Browser sign-in timed out. Try again.") }
            #expect(!f.lendFolderExists(target) && f.defaultEmail == "prev@example.test")
        }
    }

    // MARK: Failures

    @Test func aFailedHandoverLeavesEverythingAsItWas() throws {
        for failure in [FakeClaudeWorld.Script.timeout, .networkError] {
            let f = try SwitchFixture()
            let prev = f.addAccount("prev"), target = f.addAccount("target")
            let prevToken = f.signInDefault(prev)
            let targetToken = try f.saveLogin(for: target)
            f.world.script("default", failure)

            let result = f.switchTo(target)

            #expect(result.outcome == .failed(.init(reason: "Claude Code could not sign in. Check the connection and try again.",
                                                    nothingChanged: true)))
            #expect(f.world.events == ["version", "read default", "read lend(target)", "login default <- target [journal started]",
                                       "read default"])
            #expect(f.defaultEmail == "prev@example.test" && f.world.isLive(prevToken))
            // The saved login was not used up, so the next try needs no browser.
            #expect(f.world.hasItem(f.lendSlot(target)) && f.world.isLive(targetToken))
            #expect(f.journal == nil)
        }
    }

    @Test func aHandoverThatWorkedButTimedOutCountsAsDone() throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev"), target = f.addAccount("target")
        f.signInDefault(prev)
        try f.saveLogin(for: target)
        f.world.script("default", .writesThenTimeout)

        let result = f.switchTo(target)

        #expect(result.outcome == .switched(.init(accountID: target.id, previousAccountID: prev.id, needsLogin: [])))
        #expect(f.defaultEmail == "target@example.test" && f.lendEmail(prev) == "prev@example.test")
    }

    @Test func aDefaultLoginThatIsNotTheTargetAfterwardsIsAFailureButThePreviousLoginIsStillSaved() throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev"), target = f.addAccount("target")
        f.signInDefault(prev)
        try f.saveLogin(for: target)
        f.world.script("default", .writesAnotherAccount("stranger@example.test"))

        let result = f.switchTo(target)

        #expect(result.outcome == .failed(.init(reason: "Claude Code is signed in to a different account than expected.",
                                                nothingChanged: false, needsLogin: [target.id])))
        #expect(f.lendEmail(prev) == "prev@example.test")
        #expect(f.journal == nil)
    }

    @Test func aMissingOrUnreadableDefaultLoginStopsBeforeAnyChange() throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev"), target = f.addAccount("target")
        f.signInDefault(prev)
        try f.saveLogin(for: target)
        f.world.failReads("default")

        let result = f.switchTo(target)

        #expect(result.outcome == .failed(.init(reason: "Could not read the current Claude Code login.", nothingChanged: true)))
        #expect(f.world.events == ["version", "read default"])
    }

    @Test func aSwitchThatCannotBeRecordedDoesNotStart() throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev"), target = f.addAccount("target")
        f.signInDefault(prev)
        try f.saveLogin(for: target)
        // A directory where the record belongs makes it impossible to write.
        try FileManager.default.createDirectory(at: f.files.claudeCodeSwitchJournalURL, withIntermediateDirectories: true)

        let result = f.switchTo(target)

        #expect(result.outcome == .failed(.init(reason: "Could not record the switch on this Mac.", nothingChanged: true)))
        #expect(!f.world.events.contains { $0.hasPrefix("login") })
    }

    @Test func aUsedUpCopyThatWillNotGoAwayDoesNotFailTheSwitch() throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev"), target = f.addAccount("target")
        f.signInDefault(prev)
        try f.saveLogin(for: target)
        f.world.keepItem("lend(target)")

        let result = f.switchTo(target)

        #expect(result.outcome == .switched(.init(accountID: target.id, previousAccountID: prev.id, needsLogin: [])))
        #expect(f.world.events.filter { $0 == "delete lend(target)" }.count == 2)
        let removal = f.logLines.first { $0["step"] as? String == "removeUsedUpCopy" }
        #expect(removal?["outcome"] as? String == "failed")

        // The item that stayed no longer passes for the account's login, so asking for that account again cannot hand its
        // spent token over: it is cleared first, and while the Keychain refuses to clear it nothing is handed over.
        #expect(!f.switcher.hasLendLogin(for: target))
        f.signInDefault(prev)
        let loginsBefore = f.world.events.filter { $0.hasPrefix("login default") }.count
        let again = f.switchTo(target)
        #expect(again.outcome == .failed(.init(reason: "Could not clear an old sign-in for this account.", nothingChanged: true)))
        #expect(f.world.events.filter { $0.hasPrefix("login default") }.count == loginsBefore)
    }

    @Test func accountsThatCannotBeToldApartOrAreNotClaudeAreRefused() throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev")
        f.signInDefault(prev)
        let unverifiable = UsageAccount(id: UUID(), provider: .claude, name: "legacy", identity: nil)
        let codex = UsageAccount(id: UUID(), provider: .codex, name: "codex",
                                 identity: AccountIdentity(email: "c@example.test", organizationID: "o", stableID: "s"))

        for account in [unverifiable, codex] {
            guard case .failed(let failure) = f.switchTo(account).outcome else { Issue.record("expected a failure"); return }
            #expect(failure.nothingChanged)
        }
        #expect(f.world.events.isEmpty)
        #expect(f.defaultEmail == "prev@example.test")
    }

    // MARK: Handing the previous login back

    @Test func aPreviousLoginRefusedOnTheWayBackMeansThatAccountNeedsABrowserNextTime() throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev"), target = f.addAccount("target")
        f.signInDefault(prev)
        try f.saveLogin(for: target)
        f.world.script("lend(prev)", .invalidGrant(echoToken: false))

        let result = f.switchTo(target)

        #expect(result.outcome == .switched(.init(accountID: target.id, previousAccountID: prev.id, needsLogin: [prev.id])))
        #expect(f.defaultEmail == "target@example.test")
        #expect(f.world.events.filter { $0.hasPrefix("login lend(prev)") }.count == 1)
        #expect(f.world.pauses.isEmpty)
        #expect(!f.lendFolderExists(prev) && !f.world.hasItem(f.lendSlot(prev)))
    }

    @Test func aPreviousLoginThatFailsForOtherReasonsIsTriedThreeTimes() throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev"), target = f.addAccount("target")
        f.signInDefault(prev)
        try f.saveLogin(for: target)
        f.world.script("lend(prev)", .timeout, .networkError, .timeout)

        let result = f.switchTo(target)

        #expect(result.outcome == .switched(.init(accountID: target.id, previousAccountID: prev.id, needsLogin: [prev.id])))
        #expect(f.world.events.filter { $0.hasPrefix("login lend(prev)") }.count == 3)
        #expect(f.world.pauses == ClaudeCodeSwitcher.giveBackRetryDelays)
        #expect(f.defaultEmail == "target@example.test")
        #expect(!f.lendFolderExists(prev))
    }

    @Test func aPreviousLoginThatWorksOnTheSecondTryNeedsNoBrowser() throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev"), target = f.addAccount("target")
        f.signInDefault(prev)
        try f.saveLogin(for: target)
        f.world.script("lend(prev)", .timeout)

        let result = f.switchTo(target)

        #expect(result.outcome == .switched(.init(accountID: target.id, previousAccountID: prev.id, needsLogin: [])))
        #expect(f.world.pauses == Array(ClaudeCodeSwitcher.giveBackRetryDelays.prefix(1)))
        #expect(f.lendEmail(prev) == "prev@example.test")
    }

    @Test func aPreviousLoginRotatedByAnOpenSessionIsReportedNotFatal() throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev"), target = f.addAccount("target")
        let prevToken = f.signInDefault(prev)
        try f.saveLogin(for: target)
        // An open session renewed the login after AgentBar read it: the copy in memory is spent when it is lent back.
        f.world.revoke(prevToken)

        let result = f.switchTo(target)

        #expect(result.outcome == .switched(.init(accountID: target.id, previousAccountID: prev.id, needsLogin: [prev.id])))
        #expect(f.defaultEmail == "target@example.test")
    }

    @Test func aPreviousLoginWithoutARefreshTokenCannotBeLent() throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev"), target = f.addAccount("target")
        f.signInDefault(prev)
        f.world.setSecret(f.defaultSlot, Data(#"{"claudeAiOauth":{"accessToken":"FAKE-ACCESS-ONLY"}}"#.utf8))
        try f.saveLogin(for: target)

        let result = f.switchTo(target)

        #expect(result.outcome == .switched(.init(accountID: target.id, previousAccountID: prev.id, needsLogin: [prev.id])))
        #expect(!f.world.events.contains { $0.hasPrefix("login lend(") })
    }

    // MARK: Never the same refresh token twice

    @Test func aCommandThatSucceedsWithoutSwitchingNeverHasThePreviousTokenLentOut() throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev"), target = f.addAccount("target")
        let prevToken = f.signInDefault(prev)
        try f.saveLogin(for: target)
        f.world.script("default", .exitsZeroWithoutWriting)

        let result = f.switchTo(target)

        // The slot still holds the previous login's token: lending it back would use that token a second time and the
        // next renewal could end both logins. That login is still in Claude Code, so it is not reported as lost.
        #expect(result.outcome == .failed(.init(reason: "Claude Code did not switch accounts.", nothingChanged: true, needsLogin: [target.id])))
        #expect(!f.world.events.contains { $0.hasPrefix("login lend(") })
        #expect(f.world.token(in: f.defaultSlot) == prevToken && f.world.isLive(prevToken))
        #expect(f.defaultEmail == "prev@example.test" && !f.lendFolderExists(prev))
        // The token of the new login was given to the command, so its saved copy is gone.
        #expect(!f.world.hasItem(f.lendSlot(target)) && !f.lendFolderExists(target))
        #expect(f.journal == nil)
    }

    @Test func aPreviousLoginRenewedByAnOpenSessionIsNotLentBackStale() throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev"), target = f.addAccount("target")
        let prevToken = f.signInDefault(prev)
        try f.saveLogin(for: target)
        f.world.script("default", .openSessionRenewsPreviousInstead)

        let result = f.switchTo(target)

        // An open session renewed the previous login while the command ran: the token read earlier is spent.
        #expect(result.outcome == .failed(.init(reason: "Claude Code's login changed while switching. Try again.", nothingChanged: false,
                                                needsLogin: [target.id])))
        #expect(!f.world.events.contains { $0.hasPrefix("login lend(") })
        #expect(!f.world.isLive(prevToken))
        let kept = try #require(f.world.token(in: f.defaultSlot))
        #expect(kept != prevToken && f.world.isLive(kept) && f.defaultEmail == "prev@example.test")
        #expect(!f.world.hasItem(f.lendSlot(target)) && !f.lendFolderExists(prev))
    }

    @Test func aSlotLeftEmptyByAFailedHandoverGetsThePreviousLoginBack() throws {
        for lendingBackWorks in [true, false] {
            let f = try SwitchFixture()
            let prev = f.addAccount("prev"), target = f.addAccount("target")
            f.signInDefault(prev)
            try f.saveLogin(for: target)
            f.world.script("default", .emptiesSlotThenTimeout)
            if !lendingBackWorks { f.world.script("lend(prev)", .invalidGrant(echoToken: false)) }

            let result = f.switchTo(target)

            // The previous login's token left the slot, so it is lent back; if that cannot be done, that account is reported.
            let lost = lendingBackWorks ? [target.id] : [target.id, prev.id]
            #expect(result.outcome == .failed(.init(reason: "Claude Code's login changed unexpectedly. Check it in Claude Code.",
                                                    nothingChanged: false, needsLogin: lost)))
            #expect(f.world.events.filter { $0.hasPrefix("login lend(prev)") }.count == 1)
            #expect(lendingBackWorks ? f.lendEmail(prev) == "prev@example.test" : !f.lendFolderExists(prev))
            // Whatever the command did with the new login, its saved copy is not kept.
            #expect(!f.world.hasItem(f.lendSlot(target)) && !f.lendFolderExists(target))
            #expect(!f.world.events.contains { $0.hasPrefix("browser") })
            #expect(f.journal == nil)
        }
    }

    @Test func aFailedHandoverThatMovedTheSlotEndsTheSwitchInsteadOfGoingOnToTheBrowser() throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev"), target = f.addAccount("target")
        f.signInDefault(prev)
        try f.saveLogin(for: target)
        f.world.plan(.signIn("target@example.test"))
        f.world.script("default", .emptiesSlotThenRefuses)

        let result = f.switchTo(target)

        // The previous login must not vanish from the result just because a second round could have worked.
        #expect(result.outcome == .failed(.init(reason: "Claude Code's login changed unexpectedly. Check it in Claude Code.",
                                                nothingChanged: false, needsLogin: [target.id])))
        #expect(!f.world.events.contains { $0.hasPrefix("browser") })
        #expect(f.lendEmail(prev) == "prev@example.test")
        #expect(!f.world.hasItem(f.lendSlot(target)))
    }

    @Test func aNewLoginInTheKeychainAloneIsNotMistakenForNoChange() throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev"), target = f.addAccount("target")
        f.signInDefault(prev)
        let targetToken = try f.saveLogin(for: target)
        f.world.script("default", .writesKeychainOnlyThenTimeout)

        let result = f.switchTo(target)

        // The identity file still names the previous account, but the Keychain item holds a new login: the saved copy
        // of the target was used up and must not stay for the next click.
        #expect(result.outcome == .failed(.init(reason: "Claude Code's login changed unexpectedly. Check it in Claude Code.",
                                                nothingChanged: false, needsLogin: [target.id])))
        #expect(!f.world.hasItem(f.lendSlot(target)) && !f.lendFolderExists(target) && !f.world.isLive(targetToken))
        #expect(!f.world.events.contains { $0.hasPrefix("login lend(") })
        #expect(f.journal == nil)
    }

    @Test func aSlotThatCannotBeReadAfterwardsIsNeitherTrustedNorLentFrom() throws {
        for failure in [FakeClaudeWorld.Script?.none, .some(.timeout)] {
            let f = try SwitchFixture()
            let prev = f.addAccount("prev"), target = f.addAccount("target")
            f.signInDefault(prev)
            try f.saveLogin(for: target)
            // The first read (before the handover) works; the one after it does not.
            f.world.failReads("default", afterSuccessfulReads: 1)
            if let failure { f.world.script("default", failure) }

            let result = f.switchTo(target)

            // After a handover that reported success the previous token is kept out of use, so that account needs the
            // browser next time; after a failed one the target's used-up copy is gone instead.
            let handoverWorked = failure == nil
            #expect(result.outcome == .failed(.init(reason: "Could not confirm which account Claude Code uses now.", nothingChanged: false,
                                                    needsLogin: handoverWorked ? [prev.id] : [target.id])))
            #expect(!f.world.events.contains { $0.hasPrefix("login lend(") })
            #expect(!f.world.hasItem(f.lendSlot(target)))
        }
    }

    @Test func aPreviousAccountWithItsOwnLendLoginIsNotAskedToSignInWhenTheSlotCannotBeRead() throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev"), target = f.addAccount("target")
        f.signInDefault(prev)
        try f.saveLogin(for: prev)
        try f.saveLogin(for: target)
        f.world.failReads("default", afterSuccessfulReads: 1)

        let result = f.switchTo(target)

        #expect(result.outcome == .failed(.init(reason: "Could not confirm which account Claude Code uses now.", nothingChanged: false,
                                                needsLogin: [])))
        #expect(!f.world.events.contains { $0.hasPrefix("login lend(") })
    }

    @Test func aLendingBackThatSavedAndTimedOutIsNotRepeated() throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev"), target = f.addAccount("target")
        f.signInDefault(prev)
        try f.saveLogin(for: target)
        f.world.script("lend(prev)", .writesThenTimeout)

        let result = f.switchTo(target)

        // The first try saved the login and then did not report in time. Trying the same token again would use it twice,
        // and a refusal of that second try must never remove the login the first one saved.
        #expect(result.outcome == .switched(.init(accountID: target.id, previousAccountID: prev.id, needsLogin: [])))
        #expect(f.world.events.filter { $0.hasPrefix("login lend(prev)") }.count == 1)
        #expect(f.world.pauses.isEmpty)
        #expect(f.lendEmail(prev) == "prev@example.test" && f.world.token(in: f.lendSlot(prev)).map(f.world.isLive) == true)
    }

    @Test func aFolderThatCannotBeLookedAtAfterLendingBackIsNotTouchedAndNotTriedAgain() throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev"), target = f.addAccount("target")
        f.signInDefault(prev)
        try f.saveLogin(for: target)
        f.world.script("lend(prev)", .writesThenTimeout)
        // The first look at the folder works; the one after the attempt does not.
        f.world.failReads("lend(prev)", afterSuccessfulReads: 1)

        let result = f.switchTo(target)

        // It cannot be told whether the login was saved: the token is not used again and what may be there is not removed.
        // The folder does hold a login of that account, so the account is not reported as lost.
        #expect(result.outcome == .switched(.init(accountID: target.id, previousAccountID: prev.id, needsLogin: [])))
        #expect(f.world.events.filter { $0.hasPrefix("login lend(prev)") }.count == 1)
        #expect(!f.world.events.contains("delete lend(prev)"))
        #expect(f.world.hasItem(f.lendSlot(prev)))
    }

    @Test func aLendingBackThatSavedNothingIsTriedAgainAndReplacesTheOlderLogin() throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev"), target = f.addAccount("target")
        f.signInDefault(prev)
        try f.saveLogin(for: target)
        let older = try f.saveLogin(for: prev)
        f.world.script("lend(prev)", .timeout)

        let result = f.switchTo(target)

        // A login that was already in the folder is not mistaken for the one that was just lent.
        #expect(result.outcome == .switched(.init(accountID: target.id, previousAccountID: prev.id, needsLogin: [])))
        #expect(f.world.events.filter { $0.hasPrefix("login lend(prev)") }.count == 2)
        #expect(f.world.pauses == Array(ClaudeCodeSwitcher.giveBackRetryDelays.prefix(1)))
        let lent = try #require(f.world.token(in: f.lendSlot(prev)))
        #expect(lent != older && f.world.isLive(lent))
    }

    @Test func aPreviousLoginThatAlreadyHasASavedLoginIsNotReportedAsLost() throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev"), target = f.addAccount("target")
        f.signInDefault(prev)
        try f.saveLogin(for: target)
        let older = try f.saveLogin(for: prev)
        f.world.script("lend(prev)", .invalidGrant(echoToken: false))

        let result = f.switchTo(target)

        // Lending the current login back was refused, but the account's folder holds a login of its own, which stays.
        #expect(result.outcome == .switched(.init(accountID: target.id, previousAccountID: prev.id, needsLogin: [])))
        #expect(f.world.token(in: f.lendSlot(prev)) == older && f.lendFolderExists(prev))
    }

    @Test func aTimeoutThatAlreadyPrintedARefusalIsARefusal() throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev"), target = f.addAccount("target")
        f.signInDefault(prev)
        try f.saveLogin(for: target)
        f.world.plan(.signIn("target@example.test"))
        f.world.script("default", .timeoutAfterOutput("Login failed: Request failed with status code 400 for {token}"))

        let result = f.switchTo(target)

        // The command printed why it failed and then hung: that is the saved login being refused, not a network problem.
        #expect(result.outcome == .switched(.init(accountID: target.id, previousAccountID: prev.id, needsLogin: [])))
        #expect(result.steps.contains(.waitingForBrowser(.savedLoginExpired)))
        let refusal = try #require(f.logLines.first { $0["step"] as? String == "signIn" })
        #expect(refusal["outcome"] as? String == "invalid")
        let output = try #require(refusal["output"] as? String)
        #expect(output.contains("status code 400") && output.contains("[redacted]"))
        for token in f.world.allTokens { #expect(!f.logText.contains(token)) }
    }

    @Test func aTimeoutWithNothingPrintedIsStillAPassingFailureAndItsOutputIsLogged() throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev"), target = f.addAccount("target")
        f.signInDefault(prev)
        let targetToken = try f.saveLogin(for: target)
        f.world.script("default", .timeoutAfterOutput("Opening the browser for {token}"))

        let result = f.switchTo(target)

        #expect(result.outcome == .failed(.init(reason: "Claude Code could not sign in. Check the connection and try again.", nothingChanged: true)))
        #expect(f.world.hasItem(f.lendSlot(target)) && f.world.isLive(targetToken))
        let step = try #require(f.logLines.first { $0["step"] as? String == "signIn" })
        #expect(step["outcome"] as? String == "timedOut")
        #expect((step["output"] as? String)?.contains("Opening the browser for [redacted]") == true)
        #expect(!f.logText.contains(targetToken))
    }

    // MARK: A yes belongs to the login that was asked about

    @Test func aConfirmationBelongsToTheLoginThatWasAskedAbout() throws {
        let f = try SwitchFixture()
        let target = f.addAccount("target")
        try f.saveLogin(for: target)
        f.signInDefault(email: "first@example.test")
        guard case .needsConfirmation(let first) = f.switchTo(target).outcome else { Issue.record("expected a question"); return }
        #expect(first.email == "first@example.test")

        // By the time the yes arrives the default login is another one that AgentBar does not know either.
        f.signInDefault(email: "second@example.test")
        let again = f.switchTo(target, confirmedLosing: first)

        guard case .needsConfirmation(let second) = again.outcome else { Issue.record("a yes for another login must ask again"); return }
        #expect(second.email == "second@example.test" && second != first)
        #expect(f.defaultEmail == "second@example.test" && !f.world.events.contains { $0.hasPrefix("login") })
        #expect(f.switchTo(target, confirmedLosing: second).outcome == .switched(.init(accountID: target.id, previousAccountID: nil, needsLogin: [])))
    }

    @Test func aLoginThatChangesWhileTheBrowserIsOpenIsAskedAboutAgain() throws {
        let f = try SwitchFixture()
        let target = f.addAccount("target")
        f.signInDefault(email: "first@example.test")
        f.world.plan(.signIn("target@example.test"))
        guard case .needsConfirmation(let first) = f.switchTo(target).outcome else { Issue.record("expected a question"); return }

        let result = f.switchTo(target, confirmedLosing: first, openURL: { _ in f.signInDefault(email: "second@example.test") })

        guard case .needsConfirmation(let second) = result.outcome else { Issue.record("expected a second question"); return }
        #expect(second.email == "second@example.test")
        // Nothing was changed, and the sign-in the person just did is kept for the next try.
        #expect(f.defaultEmail == "second@example.test" && !f.world.events.contains { $0.hasPrefix("login") })
        #expect(f.world.hasItem(f.lendSlot(target)) && f.lendEmail(target) == "target@example.test")
    }

    // MARK: Removing a lend login

    @Test func removingALendLoginWhileASwitchRunsIsRefused() throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev"), target = f.addAccount("target"), other = f.addAccount("other")
        f.signInDefault(prev)
        try f.saveLogin(for: target)
        try f.saveLogin(for: other)
        let hold = f.world.hold(login: "default")
        let finished = DispatchSemaphore(value: 0)
        runOnNewThread { _ = f.switchTo(target); finished.signal() }
        #expect(hold.entered.wait(timeout: .now() + 20) == .success)

        #expect(throws: ClaudeCodeBusyError()) { try f.switcher.removeLendLogin(for: other.id) }
        #expect(ClaudeCodeBusyError().localizedDescription == "A Claude Code switch is running. Try again when it has finished.")
        #expect(f.world.hasItem(f.lendSlot(other)) && f.lendFolderExists(other))
        hold.release.signal()
        #expect(finished.wait(timeout: .now() + 20) == .success)

        try f.switcher.removeLendLogin(for: other.id)
        #expect(!f.world.hasItem(f.lendSlot(other)) && !f.lendFolderExists(other))
    }

    // MARK: Version

    @Test func anOldClaudeCodeBlocksTheSwitchBeforeAnythingElse() throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev"), target = f.addAccount("target")
        f.signInDefault(prev)
        f.world.version = "2.1.308 (Claude Code)\n"

        let result = f.switchTo(target)

        #expect(result.outcome == .failed(.init(reason: "Claude Code 2.1.308 is too old. Update to 2.1.309 or newer.", nothingChanged: true)))
        #expect(f.world.events == ["version"])
        #expect(result.steps == [.checkingVersion])
    }

    @Test func aVersionThatCannotBeReadBlocksTheSwitch() throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev"), target = f.addAccount("target")
        f.signInDefault(prev)
        f.world.version = "zsh: command not found: claude\n"

        guard case .failed(let failure) = f.switchTo(target).outcome else { Issue.record("expected a failure"); return }
        #expect(failure.reason == "Could not read the Claude Code version. Update Claude Code and try again.")
        #expect(failure.nothingChanged)
        #expect(f.world.events == ["version"])
    }

    @Test func checkVersionAnswersWithoutSwitching() throws {
        let f = try SwitchFixture()
        #expect(f.switcher.checkVersion() == .supported(ClaudeCodeVersion(major: 2, minor: 1, patch: 312)))
        f.world.version = "2.1.308 (Claude Code)"
        #expect(f.switcher.checkVersion() == .tooOld(ClaudeCodeVersion(major: 2, minor: 1, patch: 308)))
        f.world.version = "3.0.0 (Claude Code)"
        #expect(f.switcher.checkVersion().blockReason == nil)
    }

    // MARK: Environment

    @Test func theDefaultLoginGetsNoFolderVariablesAndAFolderGetsBothOnItsOwnPath() throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev"), target = f.addAccount("target")
        f.signInDefault(prev)
        try f.saveLogin(for: target)
        let minimal = Set(ProviderCLI.processEnvironment().keys)
        let folderVariables: Set<String> = ["CLAUDE_CONFIG_DIR", "CLAUDE_SECURESTORAGE_CONFIG_DIR"]
        let login: Set<String> = ["CLAUDE_CODE_OAUTH_REFRESH_TOKEN", "CLAUDE_CODE_OAUTH_SCOPES", "BROWSER"]

        _ = f.switchTo(target)

        let calls = f.world.calls
        try #require(calls.count == 3)
        let version = calls[0], intoDefault = calls[1], intoFolder = calls[2]
        #expect(version.arguments == ["--version"])
        #expect(Set(version.environment.keys) == minimal)
        #expect(intoDefault.arguments == ["auth", "login", "--claudeai"])
        #expect(Set(intoDefault.environment.keys) == minimal.union(login))
        #expect(intoDefault.environment["BROWSER"] == "/usr/bin/true")
        #expect(intoFolder.arguments == ["auth", "login", "--claudeai"])
        #expect(Set(intoFolder.environment.keys) == minimal.union(login).union(folderVariables))
        let folder = f.files.lend(prev.id).standardizedFileURL.path
        #expect(intoFolder.environment["CLAUDE_CONFIG_DIR"] == folder)
        #expect(intoFolder.environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == folder)
        // The folder is created before Claude Code is run in it.
        #expect(f.world.problems.isEmpty)
    }

    // MARK: Lend folders

    @Test func lendFoldersArePrivateAndNeverHoldACredentialsFile() throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev"), target = f.addAccount("target")
        f.signInDefault(prev)
        f.world.plan(.signIn("target@example.test"))
        // The handover does not go through, so the fresh login stays in its folder.
        f.world.script("default", .timeout)

        let result = f.switchTo(target)

        guard case .failed(let failure) = result.outcome else { Issue.record("expected a failure"); return }
        #expect(failure.nothingChanged)
        let folder = f.files.lend(target.id)
        #expect(permissions(f.files.lendRoot) == 0o700 && permissions(folder) == 0o700)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(!names.contains(".credentials.json"))
        #expect(!names.contains("agentbar-browser-opener") && !names.contains("agentbar-oauth-url"))
        #expect(f.world.hasItem(f.lendSlot(target)))
    }

    @Test func aLendFolderLivesUnderTheDataDirectoryByAccountID() throws {
        let files = AccountFiles(root: URL(fileURLWithPath: "/tmp/agentbar-example/multi-account-v1"))
        let id = UUID()
        #expect(files.lend(id).path == "/tmp/agentbar-example/multi-account-v1/lend/\(id.uuidString)")
        #expect(files.claudeCodeSwitchJournalURL.path == "/tmp/agentbar-example/multi-account-v1/claude-code-switch.json")
        // The usage login folder is a different place.
        #expect(files.lend(id) != files.credentials(id))
    }

    @Test func removingAnAccountsLendLoginRemovesOnlyThatOne() throws {
        let f = try SwitchFixture()
        let a = f.addAccount("a"), b = f.addAccount("b")
        try f.saveLogin(for: a)
        try f.saveLogin(for: b)

        try f.switcher.removeLendLogin(for: a.id)

        #expect(!f.world.hasItem(f.lendSlot(a)) && !f.lendFolderExists(a))
        #expect(f.world.hasItem(f.lendSlot(b)) && f.lendFolderExists(b))
        #expect(f.switcher.hasLendLogin(for: b) && !f.switcher.hasLendLogin(for: a))
    }

    @Test func theCurrentClaudeCodeAccountIsTheRegisteredOneWithTheSamePair() throws {
        let f = try SwitchFixture()
        let a = f.addAccount("a"), b = f.addAccount("b")
        #expect(f.switcher.currentAccountID(among: f.accounts) == nil)
        f.signInDefault(b)
        #expect(f.switcher.currentAccountID(among: f.accounts) == b.id)
        f.signInDefault(email: "stranger@example.test")
        #expect(f.switcher.currentAccountID(among: f.accounts) == nil)
        f.signInDefault(a)
        f.world.removeItem(f.defaultSlot)
        #expect(f.switcher.currentAccountID(among: f.accounts) == nil)
    }

    // MARK: The usage logins

    // F4: usage polling keeps its own login folders. A switch neither reads nor writes them, whether it works or not.
    @Test func theUsageLoginsAreNeverTouched() throws {
        for failure in [false, true] {
            let f = try SwitchFixture()
            let prev = f.addAccount("prev"), target = f.addAccount("target")
            f.signInDefault(prev)
            try f.saveLogin(for: target)
            if failure { f.world.script("default", .timeout) }
            var before: [URL: [String: Data]] = [:]
            for account in [prev, target] {
                let folder = f.files.credentials(try #require(account.credentialID))
                try f.files.createPrivateDirectory(folder)
                try Data("usage-login-of-\(account.name)".utf8).write(to: folder.appendingPathComponent(".credentials.json"))
                try Data(#"{"oauthAccount":{"accountUuid":"usage"}}"#.utf8).write(to: folder.appendingPathComponent(".claude.json"))
                before[folder] = try fileContents(of: folder)
            }

            let result = f.switchTo(target)

            if case .switched = result.outcome { #expect(!failure) } else { #expect(failure) }
            for (folder, contents) in before { #expect(try fileContents(of: folder) == contents) }
            // Claude Code was never pointed at one of them, and the folders it did use hold no credentials file.
            #expect(!f.world.calls.contains { $0.environment.values.contains { $0.contains("/credentials/") } })
            for account in [prev, target] where f.lendFolderExists(account) {
                #expect(!(try FileManager.default.contentsOfDirectory(atPath: f.files.lend(account.id).path)).contains(".credentials.json"))
            }
            #expect(f.lendSlot(prev).service != ClaudeSlot.folder(f.files.credentials(try #require(prev.credentialID))).service)
        }
    }

    // MARK: One at a time

    @Test func onlyOneSwitchRunsAtATime() throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev"), target = f.addAccount("target")
        f.signInDefault(prev)
        try f.saveLogin(for: target)
        let hold = f.world.hold(login: "default")
        let finished = DispatchSemaphore(value: 0)
        let first = Recorder<ClaudeCodeSwitchOutcome>()
        runOnNewThread {
            first.add(f.switchTo(target).outcome)
            finished.signal()
        }
        #expect(hold.entered.wait(timeout: .now() + 20) == .success)
        let callsBefore = f.world.calls.count

        let second = f.switchTo(target)

        #expect(second.outcome == .failed(.init(reason: "Another Claude Code switch is still running.", nothingChanged: true)))
        #expect(second.steps.isEmpty)
        #expect(f.world.calls.count == callsBefore)
        #expect(f.switcher.recoverInterruptedSwitch(among: f.accounts) == nil)
        hold.release.signal()
        #expect(finished.wait(timeout: .now() + 20) == .success)
        #expect(first.values == [.switched(.init(accountID: target.id, previousAccountID: prev.id, needsLogin: []))])
        // The next one is accepted.
        #expect(f.switchTo(prev).outcome == .switched(.init(accountID: prev.id, previousAccountID: target.id, needsLogin: [])))
    }

    // MARK: Interrupted switches

    @Test func aSwitchCutShortAfterTheDefaultLoginChangedIsFinishedOnTheNextLaunch() throws {
        for stage in [ClaudeCodeSwitchJournal.Stage.started, .slotSwitched] {
            let f = try SwitchFixture()
            let prev = f.addAccount("prev"), target = f.addAccount("target")
            f.signInDefault(target)
            try f.saveLogin(for: target)
            try f.files.write(ClaudeCodeSwitchJournal(targetID: target.id, previousID: prev.id, stage: stage, startedAt: Date()),
                              to: f.files.claudeCodeSwitchJournalURL)

            let recovery = f.switcher.recoverInterruptedSwitch(among: f.accounts)

            #expect(recovery == ClaudeCodeRecovery(kind: .finished, accountID: target.id, needsLogin: [prev.id],
                                                   message: "AgentBar quit while switching."))
            #expect(!f.world.hasItem(f.lendSlot(target)) && !f.lendFolderExists(target))
            #expect(f.defaultEmail == "target@example.test")
            #expect(f.journal == nil)
            #expect(f.logLines.last?["event"] as? String == "recovery")
        }
    }

    @Test func aSwitchCutShortBeforeTheDefaultLoginChangedIsDroppedAsIfNothingHappened() throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev"), target = f.addAccount("target")
        let prevToken = f.signInDefault(prev)
        let targetToken = try f.saveLogin(for: target)
        try f.files.write(ClaudeCodeSwitchJournal(targetID: target.id, previousID: prev.id, stage: .started, startedAt: Date()),
                          to: f.files.claudeCodeSwitchJournalURL)

        let recovery = f.switcher.recoverInterruptedSwitch(among: f.accounts)

        #expect(recovery?.kind == .rolledBack && recovery?.needsLogin == [])
        #expect(f.world.events.isEmpty)
        #expect(f.world.isLive(prevToken) && f.world.isLive(targetToken) && f.world.hasItem(f.lendSlot(target)))
        #expect(f.journal == nil)
    }

    @Test func aPreviousLoginThatWasAlreadyLentBackNeedsNoBrowserAfterRecovery() throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev"), target = f.addAccount("target")
        f.signInDefault(target)
        try f.saveLogin(for: prev)
        try f.files.write(ClaudeCodeSwitchJournal(targetID: target.id, previousID: prev.id, stage: .slotSwitched, startedAt: Date()),
                          to: f.files.claudeCodeSwitchJournalURL)

        let recovery = f.switcher.recoverInterruptedSwitch(among: f.accounts)

        #expect(recovery?.kind == .finished && recovery?.needsLogin == [])
        #expect(f.world.hasItem(f.lendSlot(prev)))
    }

    @Test func recoveryHasNothingToDoWithoutARecordOrWithAnUnreadableOne() throws {
        let f = try SwitchFixture()
        let target = f.addAccount("target")
        #expect(f.switcher.recoverInterruptedSwitch(among: f.accounts) == nil)
        try Data("{not json".utf8).write(to: f.files.claudeCodeSwitchJournalURL)
        #expect(f.switcher.recoverInterruptedSwitch(among: f.accounts) == nil)
        #expect(!FileManager.default.fileExists(atPath: f.files.claudeCodeSwitchJournalURL.path))
        // A record for an account that no longer exists is dropped too.
        try f.files.write(ClaudeCodeSwitchJournal(targetID: UUID(), previousID: nil, stage: .slotSwitched, startedAt: Date()),
                          to: f.files.claudeCodeSwitchJournalURL)
        #expect(f.switcher.recoverInterruptedSwitch(among: [target]) == nil)
        #expect(f.journal == nil)
    }

    @Test func theJournalHoldsNoTokenAndIsPrivate() throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev"), target = f.addAccount("target")
        f.signInDefault(prev)
        try f.saveLogin(for: target)
        let hold = f.world.hold(login: "default")
        let finished = DispatchSemaphore(value: 0)
        runOnNewThread { _ = f.switchTo(target); finished.signal() }
        #expect(hold.entered.wait(timeout: .now() + 20) == .success)

        // The default login is being changed right now: this is what a crash would leave behind.
        let journal = try #require(f.journal)
        let text = try String(contentsOf: f.files.claudeCodeSwitchJournalURL, encoding: .utf8)
        #expect(journal.stage == .started && journal.targetID == target.id && journal.previousID == prev.id)
        #expect(!text.contains("FAKE-"))
        #expect(permissions(f.files.claudeCodeSwitchJournalURL) == 0o600)
        hold.release.signal()
        #expect(finished.wait(timeout: .now() + 20) == .success)
        #expect(f.journal == nil)
    }

    // MARK: The log

    @Test func everyStepIsLoggedUnderOneAttemptWithoutAnyToken() throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev"), target = f.addAccount("target")
        f.signInDefault(prev)
        try f.saveLogin(for: target)
        f.world.plan(.signIn("target@example.test"))
        // Claude Code echoes the token it was given in two of its error messages.
        f.world.script("default", .invalidGrant(echoToken: true))
        f.world.script("lend(prev)", .invalidGrant(echoToken: true))

        let result = f.switchTo(target)

        #expect(result.outcome == .switched(.init(accountID: target.id, previousAccountID: prev.id, needsLogin: [prev.id])))
        let lines = f.logLines
        #expect(lines.first?["event"] as? String == "start" && lines.last?["event"] as? String == "result")
        #expect(Set(lines.compactMap { $0["attempt"] as? String }).count == 1 && lines.allSatisfy { $0["attempt"] != nil })
        #expect(lines.allSatisfy { $0["account"] as? String == "target" && $0["provider"] as? String == "claude" && $0["time"] != nil })
        let steps = lines.compactMap { $0["step"] as? String }
        #expect(steps == ["version", "readCurrentLogin", "savedLogin", "signIn", "browserSignIn", "browserSignIn", "readCurrentLogin",
                          "signIn", "removeUsedUpCopy", "verify", "giveBack"])
        #expect(lines.last?["outcome"] as? String == "switched")
        // The refusal is kept, the token inside it is not.
        let refusal = try #require(lines.first { $0["step"] as? String == "giveBack" })
        #expect((refusal["output"] as? String)?.contains("status code 400") == true && (refusal["output"] as? String)?.contains("[redacted]") == true)
        let text = f.logText
        for token in f.world.allTokens { #expect(!text.contains(token)) }
        #expect(!text.contains("FAKE-REFRESH") && !text.contains("FAKE-ACCESS"))
        #expect(!"\(result.outcome)".contains("FAKE-"))
        #expect(permissions(f.logURL) == 0o600)
    }

    @Test func aSwitchThatChangesNothingStillWritesItsResult() throws {
        let f = try SwitchFixture()
        let prev = f.addAccount("prev"), target = f.addAccount("target")
        f.signInDefault(prev)
        try f.saveLogin(for: target)
        f.world.script("default", .timeout)

        _ = f.switchTo(target)

        let last = try #require(f.logLines.last)
        #expect(last["event"] as? String == "result" && last["outcome"] as? String == "failed" && last["nothingChanged"] as? Bool == true)
        #expect((last["message"] as? String)?.isEmpty == false)
    }
}

private func fileContents(of directory: URL) throws -> [String: Data] {
    var result: [String: Data] = [:]
    for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
        result[name] = try Data(contentsOf: directory.appendingPathComponent(name))
    }
    return result
}

func permissions(_ url: URL) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
}
