import AppKit
import Foundation

// The store's side of switching the login Claude Code itself uses to a Limi account ("Use" beside the account). The
// engine (ClaudeCodeSwitcher) does the work and blocks, so it always runs on a background task; this file keeps what the
// panels and Settings › Accounts show about it. Adapted from the original AgentBar.

// Whether the Claude account panels can offer "Use" at all.
enum ClaudeCodeAvailability: Equatable, Sendable {
    // Not read yet.
    case unknown
    // Claude Code is not installed: nothing is shown.
    case missing
    // Installed, but switching is not possible. The sentence says why.
    case blocked(String)
    case ready
}

// The switch that is running. Only one runs at a time, and it names the two accounts whose Delete and Reconnect wait.
struct ClaudeCodeActivity {
    let id = UUID()
    let targetID: UUID
    // The account Claude Code was signed in to when the button was pressed, if Limi has it.
    let previousID: UUID?
    var message: String
}

// The browser sign-in that runs from Settings › Accounts to get one account ready for Claude Code. It never runs beside
// a switch or another such sign-in, and while it runs the account's Delete and Reconnect wait.
struct ClaudeCodePreparation {
    let id = UUID()
    let accountID: UUID
    // The address the account is registered with: the browser has to be signed in to it.
    let email: String?
    let control: OperationControl
    var message: String
    // Only the browser wait can be cancelled.
    var canCancel = false
    // Set when the browser could not be opened: the sign-in is cancelled, and this is why.
    var failure: String?
}

// The question asked before a login Limi does not have is removed from Claude Code.
struct ClaudeCodeConfirmation: Equatable {
    var accountID: UUID
    var login: ClaudeCodeUnknownLogin
}

// How the last switch to an account ended. It stays until panels that showed it have closed twice.
struct ClaudeCodeResult: Equatable {
    var succeeded: Bool
    var message: String
    // How many times a panel that showed it has closed since it appeared.
    var closes = 0
}

// What a person asked for that has to wait for Claude Code.
enum ClaudeCodeWaitingAction { case delete, reconnect }

extension UsageStore {
    var claudeCodeLogURL: URL { ActivityLog.claudeCodeSwitchURL(root: files.root) }
    // Whether switching Claude Code's account exists at all in this run.
    var claudeCodeEnabled: Bool { claudeCode != nil }

    func openClaudeCodeLog() {
        let url = claudeCodeLogURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: What waits for Claude Code

    // The accounts whose Delete and Reconnect must wait: the two a running switch involves, the one a sign-in for Claude
    // Code is saving a login for, or every Claude account while a switch cut short last time is being finished (only the
    // engine knows which accounts that one involves).
    private var claudeCodeLockedIDs: Set<UUID> {
        var ids = Set<UUID>()
        if let activity = claudeCodeActivity {
            ids.insert(activity.targetID)
            if let previous = activity.previousID { ids.insert(previous) }
        }
        if let preparation = claudeCodePreparation { ids.insert(preparation.accountID) }
        if claudeCodeStarting { ids.formUnion(accounts.filter { $0.provider == .claude }.map(\.id)) }
        return ids
    }

    func isClaudeCodeLocked(_ account: UsageAccount) -> Bool { claudeCodeLockedIDs.contains(account.id) }

    // Why the account's Delete and Reconnect are greyed out, for its row in Settings › Accounts; nil when they are not.
    // The account being signed in for Claude Code shows that wait in its own row already.
    func claudeCodeLockNote(for account: UsageAccount) -> String? {
        guard isClaudeCodeLocked(account) else { return nil }
        if claudeCodeActivity != nil { return String(localized: "Delete and Reconnect wait until Claude Code has switched accounts.") }
        if claudeCodeStarting { return String(localized: "Delete and Reconnect wait until \(AppInfo.name) has checked Claude Code.") }
        return nil
    }

    // Why an account cannot be deleted or reconnected now, and when it can.
    func claudeCodeBusyMessage(for action: ClaudeCodeWaitingAction) -> String {
        switch (action, claudeCodeActivity != nil, claudeCodePreparation != nil) {
        case (.delete, true, _): return String(localized: "Claude Code is switching accounts. Delete this account after it finishes.")
        case (.reconnect, true, _): return String(localized: "Claude Code is switching accounts. Reconnect this account after it finishes.")
        case (.delete, false, true):
            return String(localized: "\(AppInfo.name) is signing this account in for Claude Code. Delete it after that finishes.")
        case (.reconnect, false, true):
            return String(localized: "\(AppInfo.name) is signing this account in for Claude Code. Reconnect it after that finishes.")
        case (.delete, false, false): return String(localized: "\(AppInfo.name) is still checking Claude Code. Delete this account in a moment.")
        case (.reconnect, false, false):
            return String(localized: "\(AppInfo.name) is still checking Claude Code. Reconnect this account in a moment.")
        }
    }

    // Why nothing can be started for the account now, or nil. `help` is for the button's tooltip; `notice` is also
    // written under the header, where nothing else already says it. A usage sign-in that has to be redone blocks a
    // switch (the panel already says so) but not the sign-in for Claude Code, which is a login of its own.
    private func claudeCodeBlock(for account: UsageAccount, usageSignInMatters: Bool) -> (help: String, notice: String?)? {
        if claudeCodeStarting || claudeCodeAvailability == .unknown { return (String(localized: "Checking Claude Code…"), nil) }
        if claudeCodeActivity != nil { return (String(localized: "Claude Code is being switched. Wait for it to finish."), nil) }
        if claudeCodePreparation != nil {
            return (String(localized: "An account is signing in for Claude Code. Wait for it to finish."), nil)
        }
        if case .blocked(let reason) = claudeCodeAvailability { return (reason, reason) }
        if usageSignInMatters, snapshot(for: account).requiresLogin {
            return (String(localized: "Sign-in required · reconnect in Settings › Accounts"), nil)
        }
        if !ClaudeSlotIdentity.canVerify(account) {
            let unverifiable = String(localized: "Reconnect this account before using it in Claude Code.")
            return (unverifiable, unverifiable)
        }
        return nil
    }

    // MARK: What the panels and Settings show

    // What the account's panel shows. Nothing without a switcher, for other providers, or when Claude Code is not installed.
    func claudeCodePanel(for account: UsageAccount) -> ClaudeCodePanel {
        guard claudeCode != nil, account.provider == .claude, !account.deletionPending,
              claudeCodeAvailability != .missing else { return .hidden }
        let blocked = claudeCodeBlock(for: account, usageSignInMatters: true)

        var lines: [ClaudeCodePanel.Line] = []
        if let activity = claudeCodeActivity {
            if activity.targetID == account.id {
                lines.append(.progress(activity.message))
            } else if let target = accounts.first(where: { $0.id == activity.targetID }) {
                lines.append(.progress(String(localized: "Switching Claude Code to \(target.title)…")))
            }
        } else if let confirmation = claudeCodeConfirmation, confirmation.accountID == account.id {
            lines.append(.confirmation(email: confirmation.login.email))
        } else if let result = claudeCodeResults[account.id] {
            lines.append(.result(succeeded: result.succeeded, message: result.message))
        }

        let control: ClaudeCodePanel.Control
        if claudeCodeAccountID == account.id {
            control = .inClaudeCode
        } else if let blocked {
            control = .use(enabled: false, help: blocked.help)
            if let notice = blocked.notice { lines.insert(.notice(notice), at: 0) }
        } else if !claudeCodeReady.contains(account.id) {
            // Nothing to hand over yet. The browser sign-in that makes it is done in Settings, never from the panel.
            control = .setUp(help: String(localized: "Sign in once in Settings › Accounts so Claude Code can use this account."))
        } else {
            control = .use(enabled: true, help: String(localized: "Use this account in Claude Code. Open sessions switch within 30 s."))
        }
        return ClaudeCodePanel(control: control, lines: lines)
    }

    // Why Claude Code cannot be used with any account, such as a version too old: a group's account list says it once,
    // under its header, instead of under every Claude account. Nil when nothing stands in the way of all of them.
    var claudeCodeListNotice: String? {
        guard claudeCode != nil, case .blocked(let reason) = claudeCodeAvailability else { return nil }
        return reason
    }

    // What the account's row in a group's account list shows: its panel without what the list says once for all of its
    // rows. Only the account being switched to shows the switch running, and `claudeCodeListNotice` is not repeated.
    func claudeCodeListRow(for account: UsageAccount) -> ClaudeCodePanel {
        var row = claudeCodePanel(for: account)
        if let activity = claudeCodeActivity, activity.targetID != account.id {
            row.lines.removeAll { if case .progress = $0 { true } else { false } }
        }
        if let notice = claudeCodeListNotice { row.lines.removeAll { $0 == .notice(notice) } }
        return row
    }

    // What the account's row in Settings › Accounts shows; nothing where the panel shows no control.
    func claudeCodeSetup(for account: UsageAccount) -> ClaudeCodeSetup {
        guard claudeCode != nil, account.provider == .claude, !account.deletionPending,
              claudeCodeAvailability != .missing else { return .hidden }
        if let preparation = claudeCodePreparation, preparation.accountID == account.id {
            return ClaudeCodeSetup(status: .signingIn(message: preparation.message, cancellable: preparation.canCancel))
        }
        if claudeCodeAccountID == account.id { return ClaudeCodeSetup(status: .inClaudeCode) }
        if claudeCodeReady.contains(account.id) { return ClaudeCodeSetup(status: .ready) }
        return ClaudeCodeSetup(status: .notSetUp(blocked: claudeCodeBlock(for: account, usageSignInMatters: false)?.help),
                               failure: claudeCodeSetupFailures[account.id])
    }

    private func canStartClaudeCodeSwitch(_ account: UsageAccount) -> Bool {
        guard !storageUnavailable, !account.deletionPending, accounts.contains(where: { $0.id == account.id }),
              case .use(let enabled, _) = claudeCodePanel(for: account).control else { return false }
        return enabled
    }

    private func canStartClaudeCodePreparation(_ account: UsageAccount) -> Bool {
        guard !storageUnavailable, !account.deletionPending, accounts.contains(where: { $0.id == account.id }),
              case .notSetUp(let blocked) = claudeCodeSetup(for: account).status else { return false }
        return blocked == nil
    }

    // MARK: Switching

    // "Use" on an account's row in a group's account list.
    func useInClaudeCode(_ account: UsageAccount) {
        // The registry's own copy, in case the one the panel holds is older.
        guard let account = accounts.first(where: { $0.id == account.id }), canStartClaudeCodeSwitch(account) else { return }
        startClaudeCodeSwitch(to: account, confirmed: nil)
    }

    // "Switch" on the question about a login Limi does not have. The yes belongs to the login that was shown.
    func confirmClaudeCodeSwitch() {
        guard let confirmation = claudeCodeConfirmation else { return }
        claudeCodeConfirmation = nil
        guard let account = accounts.first(where: { $0.id == confirmation.accountID && !$0.deletionPending }),
              canStartClaudeCodeSwitch(account) else { return }
        startClaudeCodeSwitch(to: account, confirmed: confirmation.login)
    }

    func cancelClaudeCodeConfirmation() { claudeCodeConfirmation = nil; claudeCodeConfirmationShown = false }

    private func startClaudeCodeSwitch(to account: UsageAccount, confirmed: ClaudeCodeUnknownLogin?) {
        guard let claudeCode else { return }
        // Earlier results describe a login that is about to change.
        claudeCodeConfirmation = nil
        claudeCodeConfirmationShown = false
        claudeCodeResults.removeAll()
        claudeCodeResultsShown.removeAll()
        claudeCodeEpoch += 1
        let activity = ClaudeCodeActivity(targetID: account.id, previousID: claudeCodeAccountID,
                                          message: ClaudeCodeSwitchStep.checkingVersion.message)
        let id = activity.id
        claudeCodeActivity = activity
        let accounts = accounts
        let removing = lendRemovalLock
        Task { [weak self] in
            let outcome = await Task.detached(priority: .utility) {
                // A deleted account's saved login may be being removed; wait for it, or the engine sends this away.
                removing.withLock {}
                return claudeCode.switchAccount(
                    to: account, among: accounts, confirmedLosing: confirmed,
                    progress: { step in
                        DispatchQueue.main.async { MainActor.assumeIsolated { self?.claudeCodeProgress(step, activity: id) } }
                    })
            }.value
            self?.finishClaudeCodeSwitch(outcome, target: account, activity: id)
            // Deletions that had to wait for this switch go on now, without asking anything again.
            await self?.retryCleanup(allowUserInteraction: false)
        }
    }

    private func claudeCodeProgress(_ step: ClaudeCodeSwitchStep, activity id: UUID) {
        guard var activity = claudeCodeActivity, activity.id == id else { return }
        activity.message = step.message
        claudeCodeActivity = activity
    }

    private func finishClaudeCodeSwitch(_ outcome: ClaudeCodeSwitchOutcome, target: UsageAccount, activity id: UUID) {
        guard let activity = claudeCodeActivity, activity.id == id else { return }
        claudeCodeActivity = nil
        claudeCodeEpoch += 1
        switch outcome {
        case .switched(let switched):
            claudeCodeAccountID = switched.accountID
            let message = String(localized: "Claude Code now uses \(target.title). Open sessions switch within 30 s. Remote Control disconnects.")
            setClaudeCodeResult(ClaudeCodeResult(succeeded: true, message: claudeCodeNotes(message, needsLogin: switched.needsLogin)), for: target.id)
        case .alreadyInUse:
            claudeCodeAccountID = target.id
        case .needsConfirmation(let login):
            claudeCodeConfirmation = ClaudeCodeConfirmation(accountID: target.id, login: login)
            claudeCodeConfirmationShown = false
            noteClaudeCodeShown()
        case .needsSetup(let expired):
            // Nothing was changed and no browser opened: the panel now offers the way to Settings, at once.
            claudeCodeReady.remove(target.id)
            let message = expired
                ? String(localized: "The saved sign-in for \(target.title) expired. Set it up again in Settings › Accounts.")
                : String(localized: "Set up \(target.title) for Claude Code in Settings › Accounts first.")
            setClaudeCodeResult(ClaudeCodeResult(succeeded: false, message: message), for: target.id)
        case .failed(let failure):
            setClaudeCodeResult(ClaudeCodeResult(succeeded: false,
                                                 message: claudeCodeNotes(Self.claudeCodeFailureMessage(failure), needsLogin: failure.needsLogin)),
                                for: target.id)
        }
        refreshClaudeCodeState()
    }

    // The engine's reasons that already say Claude Code's login changed.
    nonisolated private static var reasonsSayingTheLoginChanged: Set<String> {
        [String(localized: "Claude Code's login changed unexpectedly. Check it in Claude Code."),
         String(localized: "Claude Code's login changed while switching. Try again."),
         String(localized: "Claude Code is signed in to a different account than expected.")]
    }

    // The engine's one-line reason, with a warning that the login may have changed unless the reason already says so.
    nonisolated static func claudeCodeFailureMessage(_ failure: ClaudeCodeSwitchFailure) -> String {
        guard !failure.nothingChanged, !reasonsSayingTheLoginChanged.contains(failure.reason) else { return failure.reason }
        return failure.reason + " " + String(localized: "Claude Code's login may have changed.")
    }

    // The accounts whose saved login could not be kept have to be set up again before their next use.
    private func claudeCodeNotes(_ message: String, needsLogin ids: [UUID]) -> String {
        ([message] + ids.compactMap { id in
            accounts.first { $0.id == id }.map { String(localized: "\($0.title) needs to be set up for Claude Code again in Settings › Accounts.") }
        }).joined(separator: " ")
    }

    // MARK: Signing an account in once, in Settings

    // "Set Up…" on an account's row in Settings › Accounts: the browser signs the account in once, and its login waits in
    // the account's own folder for the switch that uses it. The panel's button never does this.
    func prepareForClaudeCode(_ account: UsageAccount) {
        guard let account = accounts.first(where: { $0.id == account.id }), canStartClaudeCodePreparation(account) else { return }
        startClaudeCodePreparation(for: account)
    }

    // Cancel while the sign-in waits for the browser. No other step can be cancelled, and none has a button.
    func cancelClaudeCodePreparation() {
        guard var preparation = claudeCodePreparation, preparation.canCancel else { return }
        preparation.canCancel = false
        preparation.message = String(localized: "Cancelling…")
        claudeCodePreparation = preparation
        preparation.control.cancel()
        claudeCodeBrowser.close()
    }

    private func startClaudeCodePreparation(for account: UsageAccount) {
        guard let claudeCode else { return }
        // The last attempt's reason describes what is about to be tried again.
        claudeCodeSetupFailures[account.id] = nil
        claudeCodeEpoch += 1
        let control = OperationControl()
        let preparation = ClaudeCodePreparation(accountID: account.id, email: account.identity?.email, control: control,
                                                message: ClaudeCodePrepareStep.checkingVersion.message)
        let id = preparation.id
        claudeCodePreparation = preparation
        let removing = lendRemovalLock
        Task { [weak self] in
            let outcome = await Task.detached(priority: .utility) {
                removing.withLock {}
                return claudeCode.prepareLendLogin(
                    for: account, control: control,
                    progress: { step in
                        DispatchQueue.main.async { MainActor.assumeIsolated { self?.claudeCodePrepareProgress(step, preparation: id) } }
                    },
                    openURL: { url in
                        DispatchQueue.main.async { MainActor.assumeIsolated { self?.openClaudeCodeBrowser(url, control: control, preparation: id) } }
                    })
            }.value
            self?.finishClaudeCodePreparation(outcome, account: account, preparation: id)
            // Deletions that had to wait for this sign-in go on now.
            await self?.retryCleanup(allowUserInteraction: false)
        }
    }

    private func claudeCodePrepareProgress(_ step: ClaudeCodePrepareStep, preparation id: UUID) {
        guard var preparation = claudeCodePreparation, preparation.id == id else { return }
        if case .waitingForBrowser = step {
            // A cancel already on its way keeps its words.
            preparation.canCancel = !preparation.control.cancelled
            preparation.message = preparation.control.cancelled ? String(localized: "Cancelling…") : step.message(signingInAs: preparation.email)
        } else {
            preparation.canCancel = false
            preparation.message = step.message
        }
        claudeCodePreparation = preparation
    }

    // The sign-in page opens in the person's own browser. Settings stays where it is and the row shows the wait.
    private func openClaudeCodeBrowser(_ url: URL, control: OperationControl, preparation id: UUID) {
        guard claudeCodePreparation?.id == id, !control.cancelled else { return }
        claudeCodeBrowser.open(url, mode: .standard, control: control, failed: { [weak self] message in
            guard var preparation = self?.claudeCodePreparation, preparation.id == id else { return }
            preparation.failure = message
            self?.claudeCodePreparation = preparation
        }, cancelled: {})
    }

    private func finishClaudeCodePreparation(_ outcome: ClaudeCodePrepareOutcome, account: UsageAccount, preparation id: UUID) {
        guard let preparation = claudeCodePreparation, preparation.id == id else { return }
        claudeCodePreparation = nil
        claudeCodeEpoch += 1
        claudeCodeBrowser.close()
        switch outcome {
        case .prepared, .alreadyPrepared:
            // Ready at once, not only after the next reading.
            claudeCodeReady.insert(account.id)
            claudeCodeSetupFailures[account.id] = nil
        case .cancelled:
            // A cancel the person made needs no words; a browser that could not be opened is why it was cancelled.
            if let failure = preparation.failure { claudeCodeSetupFailures[account.id] = failure }
        case .failed(let reason):
            claudeCodeSetupFailures[account.id] = reason
        }
        refreshClaudeCodeState()
    }

    // MARK: What Claude Code is signed in to

    // Runs once when the app starts: finishes or drops a switch that was cut short, then reads what Claude Code is signed
    // in to. Nothing about Claude Code can be pressed before it is done.
    func runClaudeCodeStartup() async {
        guard let claudeCode else { return }
        // Without the registry the engine cannot tell which account a cut-short switch was for, and would drop its record.
        guard !storageUnavailable else { claudeCodeStarting = false; return }
        claudeCodeStarting = true
        let accounts = accounts
        let removing = lendRemovalLock
        let recovery = await Task.detached(priority: .utility) {
            removing.withLock {}
            return claudeCode.recoverInterruptedSwitch(among: accounts)
        }.value
        if let recovery { showClaudeCodeRecovery(recovery) }
        claudeCodeStarting = false
        refreshClaudeCodeState()
        await claudeCodeReading?.value
    }

    private func showClaudeCodeRecovery(_ recovery: ClaudeCodeRecovery) {
        guard let target = accounts.first(where: { $0.id == recovery.accountID }) else { return }
        let message: String
        switch recovery.kind {
        case .finished: message = recovery.message + " " + String(localized: "Claude Code now uses \(target.title).")
        case .rolledBack: message = recovery.message
        }
        setClaudeCodeResult(ClaudeCodeResult(succeeded: recovery.kind == .finished,
                                             message: claudeCodeNotes(message, needsLogin: recovery.needsLogin)), for: target.id)
    }

    // Reads, in the background, whether Claude Code is installed and new enough, which registered account it is signed in
    // to, and which accounts have a login waiting to be handed over. Only whether a login exists and whose it is is read,
    // never a secret, so no Keychain window can come up. Reads that overlap are folded into one more. None runs beside a
    // switch or a sign-in for Claude Code.
    func refreshClaudeCodeState() {
        guard claudeCode != nil, !claudeCodeStarting, claudeCodeActivity == nil, claudeCodePreparation == nil else { return }
        guard claudeCodeReading == nil else { claudeCodeReadAgain = true; return }
        claudeCodeReading = Task { [weak self] in
            guard let self else { return }
            repeat {
                claudeCodeReadAgain = false
                await readClaudeCodeState()
            } while claudeCodeReadAgain && claudeCodeActivity == nil && claudeCodePreparation == nil && !claudeCodeStarting
            claudeCodeReading = nil
        }
    }

    private func readClaudeCodeState() async {
        guard let claudeCode else { return }
        let accounts = accounts
        // Nothing to offer without a Claude account, so Claude Code is not asked anything.
        guard accounts.contains(where: { $0.provider == .claude && !$0.deletionPending }) else { return }
        let known = claudeCodeAvailability
        let epoch = claudeCodeEpoch
        let reading = await Task.detached(priority: .utility) {
            Self.readClaudeCode(claudeCode, accounts: accounts, known: known)
        }.value
        // A switch or a sign-in that started or ended meanwhile makes this reading old.
        guard epoch == claudeCodeEpoch, claudeCodeActivity == nil, claudeCodePreparation == nil else { return }
        if claudeCodeAvailability != reading.availability { claudeCodeAvailability = reading.availability }
        if claudeCodeAccountID != reading.accountID { claudeCodeAccountID = reading.accountID }
        if claudeCodeReady != reading.ready { claudeCodeReady = reading.ready }
        // A reason stops being true once the account is set up, or Claude Code uses it.
        for id in claudeCodeSetupFailures.keys where reading.ready.contains(id) || id == reading.accountID {
            claudeCodeSetupFailures[id] = nil
        }
    }

    private struct ClaudeCodeReading: Sendable {
        var availability: ClaudeCodeAvailability
        var accountID: UUID?
        var ready: Set<UUID>
    }

    nonisolated private static func readClaudeCode(_ claudeCode: ClaudeCodeSwitcher, accounts: [UsageAccount],
                                                   known: ClaudeCodeAvailability) -> ClaudeCodeReading {
        guard claudeCode.isInstalled() else { return ClaudeCodeReading(availability: .missing, accountID: nil, ready: []) }
        // The version is read until it is known to be new enough. Claude Code only updates forward, and every switch
        // and sign-in checks it again before it changes anything.
        var availability = known
        if known != .ready {
            availability = claudeCode.checkVersion().blockReason.map { .blocked($0) } ?? .ready
        }
        let ready = Set(accounts.filter { $0.provider == .claude && !$0.deletionPending && claudeCode.hasLendLogin(for: $0) }.map(\.id))
        return ClaudeCodeReading(availability: availability, accountID: claudeCode.currentAccountID(among: accounts), ready: ready)
    }

    // MARK: Panels

    // The panel of menu bar group `group` is about to open. The login may have been changed in a terminal since it was
    // last read.
    func claudeCodePanelWillOpen(group: UUID) {
        refreshClaudeCodeState()
        claudeCodeOpenPanel = group
        claudeCodeResultsShown = []
        claudeCodeConfirmationShown = false
        noteClaudeCodeShown()
    }

    // The panel says which accounts it shows: a group's account list shows all of its accounts at once.
    func claudeCodePanelShows(_ accountIDs: [UUID], group: UUID) {
        claudeCodePanelShown[group] = Set(accountIDs)
        if claudeCodeOpenPanel == group { noteClaudeCodeShown() }
    }

    // A result line goes once panels that showed it have closed twice, so it can still be read after the panel closed
    // by accident; one that was never on screen waits. The question about a login Limi does not have goes with the
    // panel that showed it.
    func claudeCodePanelDidClose(group: UUID) {
        guard claudeCodeOpenPanel == group else { return }
        claudeCodeOpenPanel = nil
        for id in claudeCodeResultsShown {
            guard var result = claudeCodeResults[id] else { continue }
            result.closes += 1
            claudeCodeResults[id] = result.closes >= 2 ? nil : result
        }
        claudeCodeResultsShown = []
        if claudeCodeConfirmationShown { claudeCodeConfirmation = nil }
        claudeCodeConfirmationShown = false
        // A coupon question goes with the panel too; a coupon being used goes on.
        couponLines = couponLines.filter { entry in
            switch entry.value {
            case .choosing, .confirmation: return false
            case .progress, .result: return true
            }
        }
    }

    // A new result has not been on screen yet, unless the open panel shows its account right now.
    private func setClaudeCodeResult(_ result: ClaudeCodeResult, for id: UUID) {
        claudeCodeResults[id] = result
        claudeCodeResultsShown.remove(id)
        noteClaudeCodeShown()
    }

    // What the open panel shows now: its accounts' result lines or question.
    private func noteClaudeCodeShown() {
        guard let group = claudeCodeOpenPanel, let ids = claudeCodePanelShown[group] else { return }
        claudeCodeResultsShown.formUnion(ids.filter { claudeCodeResults[$0] != nil })
        if let confirmation = claudeCodeConfirmation, ids.contains(confirmation.accountID) { claudeCodeConfirmationShown = true }
    }
}
