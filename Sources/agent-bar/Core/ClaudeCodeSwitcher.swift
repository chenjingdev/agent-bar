import Foundation

// Changes the login Claude Code uses by default to an AgentBar account, and takes the login that was
// there back into that account's own folder. Everything here blocks: call it from a background task.
//
// Each account has one "lend" folder (lend/<account id>/) where Claude Code keeps a login that
// AgentBar may hand to the default slot. Handing a login over uses it up (its refresh token rotates),
// so the copy left behind is removed, and the login that was in the default slot is lent back to its
// own account. Only Claude Code writes a login (`claude auth login` fed a refresh token) and only
// /usr/bin/security reads or removes a Keychain item.

enum ClaudeCodeBrowserReason: Equatable, Sendable {
    // No usable login for this account has been saved on this Mac.
    case noSavedLogin
    // The saved login was refused when it was handed over.
    case savedLoginExpired

    var message: String {
        switch self {
        case .noSavedLogin: return "Sign in once in the browser so Claude Code can use this account."
        case .savedLoginExpired: return "The saved sign-in expired. Sign in again in the browser."
        }
    }

    // The same, naming the account the browser has to be signed in to when its address is known.
    func message(signingInAs email: String?) -> String {
        guard let email, !email.isEmpty else { return message }
        switch self {
        case .noSavedLogin: return "Sign in as \(email) in the browser once so Claude Code can use this account."
        case .savedLoginExpired: return "The saved sign-in expired. Sign in as \(email) in the browser again."
        }
    }
}

enum ClaudeCodeSwitchStep: Equatable, Sendable {
    case checkingVersion
    case readingCurrentLogin
    // The only step that can be cancelled.
    case waitingForBrowser(ClaudeCodeBrowserReason)
    case signingIn
    case verifying
    case returningPreviousLogin

    var message: String {
        switch self {
        case .checkingVersion: return "Checking Claude Code…"
        case .readingCurrentLogin: return "Reading the current Claude Code login…"
        case .waitingForBrowser(let reason): return reason.message
        case .signingIn: return "Switching Claude Code…"
        case .verifying: return "Checking the new login…"
        case .returningPreviousLogin: return "Saving the previous login…"
        }
    }
}

struct ClaudeCodeSwitched: Equatable, Sendable {
    var accountID: UUID
    // The registered account whose login was in the default slot; nil when there was none or it was not registered.
    var previousAccountID: UUID?
    // Accounts whose login could not be saved: their next use needs a browser sign-in.
    var needsLogin: [UUID]
}

struct ClaudeCodeSwitchFailure: Equatable, Sendable {
    // One English line the popover can show as it is.
    var reason: String
    // False when the default login may have been touched.
    var nothingChanged: Bool
    // Accounts whose saved login is gone: their next use needs a browser sign-in.
    var needsLogin: [UUID] = []
}

// The login of an account AgentBar does not have, as it was shown to the person who was asked about losing it.
struct ClaudeCodeUnknownLogin: Equatable, Sendable {
    var email: String?
    var accountUUID: String?
    var organizationUUID: String?
}

enum ClaudeCodeSwitchOutcome: Equatable, Sendable {
    case switched(ClaudeCodeSwitched)
    case alreadyInUse
    // Claude Code holds a login of an account AgentBar does not have. Nothing was changed; ask, then call again
    // with `confirmedLosing:` set to this login. A yes belongs to the login that was asked about: if the default
    // login is a different unknown one by then, this comes back again.
    case needsConfirmation(ClaudeCodeUnknownLogin)
    // Only while waiting for the browser. Nothing was changed.
    case cancelled
    case failed(ClaudeCodeSwitchFailure)
}

// What finishing an interrupted switch found.
struct ClaudeCodeRecovery: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        // The default login had not changed; the record was dropped.
        case rolledBack
        // The default login was already the new account; the clean-up was done.
        case finished
    }
    var kind: Kind
    var accountID: UUID
    var needsLogin: [UUID]
    var message: String
}

// Written before the default login changes and removed when the switch ends, so a switch that dies halfway
// can be finished on the next launch. It holds no token.
struct ClaudeCodeSwitchJournal: Codable, Equatable, Sendable {
    enum Stage: String, Codable, Sendable {
        case started
        case slotSwitched
    }
    var targetID: UUID
    var previousID: UUID?
    var stage: Stage
    var startedAt: Date
}

final class ClaudeCodeSwitcher: @unchecked Sendable {
    static let loginTimeout: TimeInterval = 60
    // Pauses before the second and third try at lending the previous login back.
    static let giveBackRetryDelays: [TimeInterval] = [3, 6]

    let files: AccountFiles
    let defaultSlot: ClaudeSlot
    private let cli: any ClaudeCLI
    private let keychain: any ClaudeKeychain
    private let pause: @Sendable (TimeInterval) -> Void
    private let now: @Sendable () -> Date
    private let busyLock = NSLock()
    private var busy = false

    // Every dependency is passed in, so a test cannot reach the real Claude Code, Keychain or default login by omission.
    init(files: AccountFiles, defaultSlot: ClaudeSlot, cli: any ClaudeCLI, keychain: any ClaudeKeychain,
         pause: @escaping @Sendable (TimeInterval) -> Void, now: @escaping @Sendable () -> Date) {
        self.files = files
        self.defaultSlot = defaultSlot
        self.cli = cli
        self.keychain = keychain
        self.pause = pause
        self.now = now
    }

    static func system(files: AccountFiles = AccountFiles()) -> ClaudeCodeSwitcher {
        ClaudeCodeSwitcher(files: files, defaultSlot: .defaultLogin(), cli: SystemClaudeCLI(), keychain: SecurityCommandKeychain(),
                           pause: { Thread.sleep(forTimeInterval: $0) }, now: { Date() })
    }

    // MARK: Reading

    // Whether Claude Code is on this Mac at all. The popover hides its button when it is not.
    func isInstalled() -> Bool { cli.isInstalled() }

    func checkVersion() -> ClaudeCodeVersionCheck {
        let output: ClaudeCLIOutput
        do {
            output = try cli.run(["--version"], environment: ProviderCLI.processEnvironment(),
                                 directory: FileManager.default.homeDirectoryForCurrentUser, timeout: 20)
        } catch { return .unreadable(error.localizedDescription) }
        guard output.status == 0, let version = ClaudeCodeVersion(output: output.text) else {
            return .unreadable("Could not read the Claude Code version. Update Claude Code and try again.")
        }
        return version >= .minimum ? .supported(version) : .tooOld(version)
    }

    // The registered account Claude Code is signed in to right now, if any.
    func currentAccountID(among accounts: [UsageAccount]) -> UUID? {
        guard (try? keychain.contains(service: defaultSlot.service, account: defaultSlot.account)) == true else { return nil }
        let identity = readIdentity(of: defaultSlot, hasLogin: true)
        return accounts.first { !$0.deletionPending && identity.matches($0) }?.id
    }

    // Whether the account's own folder holds a login that can be handed over without the browser.
    func hasLendLogin(for account: UsageAccount) -> Bool {
        let slot = lendSlot(account.id)
        guard (try? keychain.contains(service: slot.service, account: slot.account)) == true else { return false }
        return readIdentity(of: slot, hasLogin: true).matches(account)
    }

    // For deleting an account: its lend folder and Keychain item go, nothing else does. It waits for no switch: while
    // one is running it throws.
    func removeLendLogin(for accountID: UUID) throws {
        guard beginOperation() else {
            throw AccountError.message("A Claude Code switch is running. Try again when it has finished.")
        }
        defer { endOperation() }
        try dropLend(accountID)
    }

    // MARK: Switching

    func switchAccount(
        to target: UsageAccount, among accounts: [UsageAccount], confirmedLosing: ClaudeCodeUnknownLogin? = nil,
        control: OperationControl = OperationControl(),
        progress: @escaping @Sendable (ClaudeCodeSwitchStep) -> Void = { _ in },
        openURL: @escaping @Sendable (URL) -> Void
    ) -> ClaudeCodeSwitchOutcome {
        guard beginOperation() else {
            return .failed(ClaudeCodeSwitchFailure(reason: "Another Claude Code switch is still running.", nothingChanged: true))
        }
        defer { endOperation() }
        let run = Run(target: target, accounts: accounts.filter { $0.provider == .claude && !$0.deletionPending },
                      confirmedLosing: confirmedLosing, control: control, progress: progress, openURL: openURL,
                      log: LimitResetLog(root: files.root, account: target, attempt: UUID(), fileName: LimitResetLog.claudeCodeSwitchFileName),
                      startedAt: now())
        run.log.record("start", [:])
        let outcome: ClaudeCodeSwitchOutcome
        do { outcome = try perform(run) }
        catch let abort as Abort {
            outcome = abort.cancelled ? .cancelled
                : .failed(ClaudeCodeSwitchFailure(reason: abort.reason, nothingChanged: !run.slotTouched, needsLogin: abort.needsLogin))
        } catch {
            outcome = .failed(ClaudeCodeSwitchFailure(reason: "Could not switch Claude Code.", nothingChanged: !run.slotTouched))
        }
        try? FileManager.default.removeItem(at: files.claudeCodeSwitchJournalURL)
        run.log.record("result", Self.describe(outcome))
        return outcome
    }

    private func perform(_ run: Run) throws -> ClaudeCodeSwitchOutcome {
        let target = run.target
        guard target.provider == .claude else { throw Abort("Only a Claude account can be used in Claude Code.") }
        guard ClaudeSlotIdentity.canVerify(target) else {
            throw Abort("Reconnect this account before using it in Claude Code.")
        }
        run.progress(.checkingVersion)
        let version = checkVersion()
        run.step("version", version.blockReason == nil ? "ok" : "blocked", ["version": String(describing: version)])
        if let reason = version.blockReason { throw Abort(reason) }

        // The login in the default slot, read now so nothing is changed for a person who has to confirm first.
        run.progress(.readingCurrentLogin)
        var current = try readDefault(run)
        if let early = gate(current, run) { return early }

        var credential = try savedLogin(for: target, run)
        if credential == nil {
            credential = try browserSignIn(for: target, reason: .noSavedLogin, run)
            // Minutes may have passed: the previous login is read again so its token is as fresh as it can be.
            current = try readDefault(run)
            if let early = gate(current, run) { return early }
        }

        try writeJournal(.started, previousID: current.accountID, run)
        var handedOver = false
        for round in 0..<2 {
            guard let login = credential else { break }
            run.progress(.signingIn)
            run.slotTouched = true
            let result = putLogin(login, into: defaultSlot, run, step: "signIn")
            if result == .ok { handedOver = true; break }
            // The command says it failed. The slot tells more: a login may have been written all the same, or the slot
            // may have moved without one.
            let after = snapshotDefault(run)
            if let after, after.identity.hasLogin, after.identity.matches(target), after.token != current.token {
                run.step("signIn", "finishedDespiteError")
                handedOver = true
                break
            }
            guard let after, after.identity == current.identity, after.token == current.token else {
                throw abandon(after: after, before: current, run)
            }
            run.slotTouched = false
            guard result == .invalid, round == 0, !run.freshLogin else {
                // A login that was refused is dead and its copy goes; a failure that may pass keeps it for the next try.
                if result == .invalid { try? dropLend(target.id) }
                throw Abort(result == .invalid ? "Claude rejected the sign-in. Try again."
                                               : "Claude Code could not sign in. Check the connection and try again.")
            }
            // The saved login is dead: remove it and sign in once more in the browser.
            do { try dropLend(target.id) } catch { throw Abort("Could not remove the expired sign-in. Try again.") }
            credential = try browserSignIn(for: target, reason: .savedLoginExpired, run)
            current = try readDefault(run)
            if let early = gate(current, run) { return early }
            try writeJournal(.started, previousID: current.accountID, run)
        }
        guard handedOver else { throw Abort("Claude Code could not sign in. Try again.") }

        // The copy of the new login that stayed in its own folder was used up.
        removeUsedUpLend(target.id, run)
        try? writeJournal(.slotSwitched, previousID: current.accountID, run)

        // Read the slot again before anything is lent back: the previous login may only be lent once its refresh
        // token has left the slot, or the same token would be used twice.
        run.progress(.verifying)
        let after = snapshotDefault(run)
        let verdict = judge(after, before: current, target: target)
        run.step("verify", verdict.reason == nil ? "ok" : "failed", ["reason": verdict.reason as Any])
        run.progress(.returningPreviousLogin)
        var needsLogin: [UUID] = verdict.mayLendBack ? giveBack(current, run) : []
        if let reason = verdict.reason {
            run.slotTouched = verdict.changed
            // Its saved copy is gone and the slot does not hold its login.
            if after != nil { needsLogin.insert(target.id, at: 0) }
            // An unreadable slot after a handover that reported success most likely holds the target now. The previous
            // token is not lent back because it may still be there, so that account signs in with the browser next time
            // unless a login of its own already waits in its folder.
            if after == nil, current.credential != nil, let id = current.accountID,
               let account = run.accounts.first(where: { $0.id == id }), !hasLendLogin(for: account) {
                needsLogin.append(id)
            }
            throw Abort(reason, needsLogin: needsLogin)
        }
        return .switched(ClaudeCodeSwitched(accountID: target.id, previousAccountID: current.accountID, needsLogin: needsLogin))
    }

    // After a failed handover the slot is not as it was read, or cannot be read. The new login may have been used up, so
    // its saved copy goes; the previous login is lent back if its token has left the slot.
    private func abandon(after: DefaultLogin?, before: DefaultLogin, _ run: Run) -> Abort {
        removeUsedUpLend(run.target.id, run)
        let needsLogin = [run.target.id]
        guard let after else {
            run.step("slotAfterFailure", "unreadable")
            return Abort("Could not confirm which account Claude Code uses now.", needsLogin: needsLogin)
        }
        let previous = previousToken(in: after, before: before)
        run.step("slotAfterFailure", "changed", ["previousToken": String(describing: previous)])
        let lent = previous == .left || previous == .notLent ? giveBack(before, run) : []
        return Abort("Claude Code's login changed unexpectedly. Check it in Claude Code.", needsLogin: needsLogin + lent)
    }

    // Already there, or a login of someone AgentBar does not know would disappear without a yes.
    private func gate(_ current: DefaultLogin, _ run: Run) -> ClaudeCodeSwitchOutcome? {
        if current.identity.hasLogin, current.identity.matches(run.target) { return .alreadyInUse }
        if current.identity.hasLogin, current.accountID == nil {
            let login = ClaudeCodeUnknownLogin(email: current.identity.email, accountUUID: current.identity.accountUUID,
                                               organizationUUID: current.identity.organizationUUID)
            if run.confirmedLosing != login { return .needsConfirmation(login) }
        }
        return nil
    }

    // MARK: The default slot

    private struct DefaultLogin {
        var identity: ClaudeSlotIdentity
        // Nil when signed out or when the stored login has no refresh token to lend.
        var credential: ClaudeLoginCredential?
        // The registered account the login belongs to.
        var accountID: UUID?
        // The refresh token the slot holds.
        var token: String? { credential?.refreshToken }
    }

    // The default slot as it is right now; nil when its Keychain item cannot be read.
    private func snapshotDefault(_ run: Run) -> DefaultLogin? {
        let secret: Data?
        do { secret = try keychain.readSecret(service: defaultSlot.service, account: defaultSlot.account) }
        catch { return nil }
        let identity = readIdentity(of: defaultSlot, hasLogin: secret != nil)
        let owner = identity.hasLogin ? run.accounts.first(where: identity.matches) : nil
        return DefaultLogin(identity: identity, credential: secret.flatMap(ClaudeLoginCredential.init(keychainData:)),
                            accountID: owner?.id)
    }

    private func readDefault(_ run: Run) throws -> DefaultLogin {
        guard let login = snapshotDefault(run) else {
            run.step("readCurrentLogin", "failed")
            throw Abort("Could not read the current Claude Code login.")
        }
        let owner = run.accounts.first { $0.id == login.accountID }
        run.step("readCurrentLogin", login.identity.hasLogin ? "signedIn" : "signedOut",
                 ["previousAccount": owner?.name ?? (login.identity.hasLogin ? "unregistered login" : "none"),
                  "unregisteredEmail": owner == nil && login.identity.hasLogin ? login.identity.email as Any : NSNull()])
        return login
    }

    // Where the previous login's refresh token is, judged from the slot after something may have changed it.
    private enum PreviousToken {
        // There was no refresh token to protect.
        case notLent
        // The slot still holds that very token.
        case stillInSlot
        // The slot holds the same login under a newer token: an open session renewed it, and the old token is spent.
        case renewedByOpenSession
        // The slot no longer holds it: signed out, or another login.
        case left
    }

    private func previousToken(in now: DefaultLogin, before: DefaultLogin) -> PreviousToken {
        guard let token = before.token else { return .notLent }
        guard now.identity.hasLogin else { return .left }
        if now.token == token { return .stillInSlot }
        return now.identity.sameLogin(as: before.identity) ? .renewedByOpenSession : .left
    }

    private struct Verdict {
        // Why the slot does not hold the target's login; nil when it does.
        var reason: String?
        // The previous login's token is no longer in the slot, so it can be lent back.
        var mayLendBack: Bool
        // The slot is not as it was read.
        var changed: Bool
    }

    // R9, and whether it is safe to lend the previous login back. The target's login counts only if the slot's
    // refresh token moved: an identity file that changed beside the same token is not a switch.
    private func judge(_ now: DefaultLogin?, before: DefaultLogin, target: UsageAccount) -> Verdict {
        guard let now else {
            return Verdict(reason: "Could not confirm which account Claude Code uses now.", mayLendBack: false, changed: true)
        }
        let previous = previousToken(in: now, before: before)
        let mayLendBack = previous == .left || previous == .notLent
        let changed = now.identity != before.identity || now.token != before.token
        if now.identity.hasLogin, now.identity.matches(target), now.token != before.token {
            return Verdict(reason: nil, mayLendBack: mayLendBack, changed: changed)
        }
        let reason: String
        if !now.identity.hasLogin { reason = "Claude Code is not signed in after switching." }
        else if previous == .stillInSlot || now.identity.matches(target) { reason = "Claude Code did not switch accounts." }
        else if previous == .renewedByOpenSession { reason = "Claude Code's login changed while switching. Try again." }
        else { reason = "Claude Code is signed in to a different account than expected." }
        return Verdict(reason: reason, mayLendBack: mayLendBack, changed: changed)
    }

    // MARK: Lend folders

    private func lendSlot(_ accountID: UUID) -> ClaudeSlot { .folder(files.lend(accountID)) }

    // The account's own login if the folder holds one for exactly that account; anything else in the folder is cleared.
    private func savedLogin(for account: UsageAccount, _ run: Run) throws -> ClaudeLoginCredential? {
        let slot = lendSlot(account.id)
        let secret: Data?
        do { secret = try keychain.readSecret(service: slot.service, account: slot.account) }
        catch {
            run.step("savedLogin", "failed")
            throw Abort("Could not read the saved sign-in for this account.")
        }
        let identity = readIdentity(of: slot, hasLogin: secret != nil)
        if let secret, identity.matches(account), let credential = ClaudeLoginCredential(keychainData: secret) {
            run.step("savedLogin", "found")
            return credential
        }
        let folderExists = slot.directory.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        if secret != nil || folderExists {
            run.step("savedLogin", "unusable")
            do { try dropLend(account.id) } catch { throw Abort("Could not clear an old sign-in for this account.") }
        } else {
            run.step("savedLogin", "none")
        }
        return nil
    }

    // Signs the account in with the browser into its own folder and returns the login Claude Code stored there.
    private func browserSignIn(for account: UsageAccount, reason: ClaudeCodeBrowserReason, _ run: Run) throws -> ClaudeLoginCredential {
        let slot = lendSlot(account.id)
        guard let directory = slot.directory else { throw Abort("Could not prepare the sign-in.") }
        do {
            try files.createPrivateDirectory(files.lendRoot)
            try files.createPrivateDirectory(directory)
        } catch { throw Abort("Could not prepare the sign-in folder.") }
        run.progress(.waitingForBrowser(reason))
        run.step("browserSignIn", "waiting", ["reason": String(describing: reason)])
        do { try cli.browserLogin(directory: directory, control: run.control, openURL: run.openURL) }
        catch {
            try? dropLend(account.id)
            switch error {
            case AccountError.cancelled:
                run.step("browserSignIn", "cancelled")
                throw Abort(cancelled: true)
            case AccountError.timeout:
                run.step("browserSignIn", "timedOut")
                throw Abort("Browser sign-in timed out. Try again.")
            default:
                run.step("browserSignIn", "failed")
                throw Abort("Browser sign-in did not finish. Try again.")
            }
        }
        for helper in ["agentbar-browser-opener", "agentbar-oauth-url"] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(helper))
        }
        let secret = try? keychain.readSecret(service: slot.service, account: slot.account)
        let identity = readIdentity(of: slot, hasLogin: secret != nil)
        guard identity.hasLogin, identity.accountUUID != nil || identity.email != nil else {
            try? dropLend(account.id)
            run.step("browserSignIn", "noLogin")
            throw Abort("Browser sign-in did not finish. Try again.")
        }
        // The browser may have been signed in to someone else; that login is not kept.
        guard identity.matches(account) else {
            try? dropLend(account.id)
            run.step("browserSignIn", "differentAccount")
            throw Abort("Signed in as a different account.")
        }
        guard let secret, let credential = ClaudeLoginCredential(keychainData: secret) else {
            try? dropLend(account.id)
            run.step("browserSignIn", "unusable")
            throw Abort("The browser sign-in could not be used. Try again.")
        }
        run.freshLogin = true
        run.step("browserSignIn", "ok")
        return credential
    }

    // Removes the copy a handover used up. If the Keychain item cannot be deleted it stays, but it no longer passes
    // for a login (see dropLend), so it is cleared the next time instead of being used; the log records the failure.
    private func removeUsedUpLend(_ accountID: UUID, _ run: Run) {
        for attempt in 0..<2 {
            do { try dropLend(accountID); run.step("removeUsedUpCopy", "ok"); return }
            catch { if attempt == 1 { run.step("removeUsedUpCopy", "failed") } }
        }
    }

    // Removes an account's Keychain item and checks it is gone, then its folder. Only a lend folder can be named.
    // The identity file goes before either: without it the folder can no longer pass for that account's login, so
    // even an item that refuses to be deleted is never handed over again.
    private func dropLend(_ accountID: UUID) throws {
        let slot = lendSlot(accountID)
        try? FileManager.default.removeItem(at: slot.identityFile)
        try keychain.delete(service: slot.service, account: slot.account)
        guard try !keychain.contains(service: slot.service, account: slot.account) else {
            throw AccountError.message("Keychain cleanup is required for the saved Claude Code sign-in.")
        }
        if let directory = slot.directory, FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    // Lends the login that was in the default slot to its own account. A login that cannot be saved
    // means that account signs in with the browser next time. The same token is never used twice: before it is
    // tried again the folder is looked at, because a command that timed out may already have saved the login.
    private func giveBack(_ previous: DefaultLogin, _ run: Run) -> [UUID] {
        guard previous.identity.hasLogin, let id = previous.accountID, let account = run.accounts.first(where: { $0.id == id }) else {
            run.step("giveBack", "skipped", ["why": previous.identity.hasLogin ? "unregistered login" : "signed out"])
            return []
        }
        // A login of its own that already waits in that folder is enough for the next switch to that account.
        func lost() -> [UUID] { hasLendLogin(for: account) ? [] : [id] }
        guard let credential = previous.credential else {
            run.step("giveBack", "nothingToLend")
            return lost()
        }
        let slot = lendSlot(id)
        let existed = slot.directory.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        guard let before = lendLogin(slot) else {
            run.step("giveBack", "unreadable")
            return lost()
        }
        var unreadable = false
        for delay in [0] + Self.giveBackRetryDelays {
            if delay > 0 { pause(delay) }
            let result = putLogin(credential, into: slot, run, step: "giveBack")
            guard let now = lendLogin(slot) else { unreadable = true; break }
            if now.identity.hasLogin, now.token != before.token {
                if now.identity.matches(account) {
                    if result != .ok { run.step("giveBack", "finishedDespiteError") }
                    return []
                }
                run.step("giveBack", "wrongAccount")
                try? dropLend(id)
                return [id]
            }
            if result != .transient { break }
        }
        // What an attempt left behind goes, unless the folder could not be looked at: a login may be in it.
        if !existed && !unreadable { try? dropLend(id) }
        return lost()
    }

    // What a lend folder holds right now; nil when its Keychain item cannot be read.
    private func lendLogin(_ slot: ClaudeSlot) -> (identity: ClaudeSlotIdentity, token: String?)? {
        let secret: Data?
        do { secret = try keychain.readSecret(service: slot.service, account: slot.account) }
        catch { return nil }
        return (readIdentity(of: slot, hasLogin: secret != nil), secret.flatMap(ClaudeLoginCredential.init(keychainData:))?.refreshToken)
    }

    // MARK: Claude Code

    private enum SignInResult { case ok, invalid, transient }

    // `claude auth login --claudeai` fed the refresh token and scopes. The token only travels in the environment.
    private func putLogin(_ credential: ClaudeLoginCredential, into slot: ClaudeSlot, _ run: Run, step: String) -> SignInResult {
        if let directory = slot.directory {
            do {
                try files.createPrivateDirectory(files.lendRoot)
                try files.createPrivateDirectory(directory)
            } catch { run.step(step, "transient", ["why": "folder"]); return .transient }
        }
        var environment = slot.environment
        environment["CLAUDE_CODE_OAUTH_REFRESH_TOKEN"] = credential.refreshToken
        environment["CLAUDE_CODE_OAUTH_SCOPES"] = credential.scopes.joined(separator: " ")
        // If the CLI falls back to the browser flow, this opens nothing and the command ends by timing out.
        environment["BROWSER"] = "/usr/bin/true"
        let output: ClaudeCLIOutput
        do {
            output = try cli.run(["auth", "login", "--claudeai"], environment: environment,
                                 directory: slot.workingDirectory, timeout: Self.loginTimeout)
        } catch {
            run.step(step, "transient", ["why": "could not run Claude Code"])
            return .transient
        }
        if output.status == 0 { run.step(step, "ok"); return .ok }
        // A command that ran out of time may already have said why it failed.
        let failure = ClaudeCodeOutput.classify(output.text)
        run.step(step, failure == .invalid ? "invalid" : (output.timedOut ? "timedOut" : "transient"),
                 ["exitStatus": output.status as Any, "output": ClaudeCodeOutput.scrubbed(output.text, secrets: [credential.refreshToken])])
        return failure == .invalid ? .invalid : .transient
    }

    // The identity file can be mid-write when another Claude Code process saves it; an unreadable copy is read again.
    private func readIdentity(of slot: ClaudeSlot, hasLogin: Bool) -> ClaudeSlotIdentity {
        var account: ClaudeOAuthAccount?
        for attempt in 0..<3 {
            guard let data = try? Data(contentsOf: slot.identityFile) else { break }
            if let parsed = ClaudeOAuthAccount(claudeJSON: data) { account = parsed; break }
            if attempt < 2 { pause(0.3) }
        }
        return ClaudeSlotIdentity(account, hasLogin: hasLogin)
    }

    // MARK: Journal and recovery

    private func writeJournal(_ stage: ClaudeCodeSwitchJournal.Stage, previousID: UUID?, _ run: Run) throws {
        let journal = ClaudeCodeSwitchJournal(targetID: run.target.id, previousID: previousID, stage: stage, startedAt: run.startedAt)
        do { try files.write(journal, to: files.claudeCodeSwitchJournalURL) }
        catch { throw Abort("Could not record the switch on this Mac.") }
    }

    // Call once when AgentBar starts. Finishes or drops a switch that was cut short; nil when there was none.
    func recoverInterruptedSwitch(among accounts: [UsageAccount]) -> ClaudeCodeRecovery? {
        guard beginOperation() else { return nil }
        defer { endOperation() }
        let url = files.claudeCodeSwitchJournalURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        guard let journal = try? files.read(ClaudeCodeSwitchJournal.self, at: url),
              let target = accounts.first(where: { $0.id == journal.targetID && $0.provider == .claude }) else { return nil }
        let log = LimitResetLog(root: files.root, account: target, attempt: UUID(), fileName: LimitResetLog.claudeCodeSwitchFileName)
        let hasLogin = (try? keychain.contains(service: defaultSlot.service, account: defaultSlot.account)) ?? false
        let switched = hasLogin && readIdentity(of: defaultSlot, hasLogin: true).matches(target)
        guard switched || journal.stage == .slotSwitched else {
            log.record("recovery", ["outcome": "rolledBack", "stage": journal.stage.rawValue])
            return ClaudeCodeRecovery(kind: .rolledBack, accountID: target.id, needsLogin: [],
                                      message: "AgentBar quit while switching. Nothing was changed.")
        }
        var removed = true
        do { try dropLend(target.id) } catch { removed = false }
        // The previous login lived in memory only. Unless it was already lent back, that account signs in again.
        var needsLogin: [UUID] = []
        if let previousID = journal.previousID, let previous = accounts.first(where: { $0.id == previousID }), !hasLendLogin(for: previous) {
            needsLogin = [previousID]
        }
        log.record("recovery", ["outcome": "finished", "stage": journal.stage.rawValue, "removedUsedUpCopy": removed,
                                "needsLogin": needsLogin.map(\.uuidString)])
        return ClaudeCodeRecovery(kind: .finished, accountID: target.id, needsLogin: needsLogin, message: "AgentBar quit while switching.")
    }

    // MARK: One at a time

    private func beginOperation() -> Bool {
        busyLock.lock(); defer { busyLock.unlock() }
        if busy { return false }
        busy = true
        return true
    }
    private func endOperation() {
        busyLock.lock(); busy = false; busyLock.unlock()
    }

    // MARK: Plumbing

    private struct Abort: Error {
        var reason: String
        var cancelled = false
        var needsLogin: [UUID] = []
        init(_ reason: String, needsLogin: [UUID] = []) { self.reason = reason; self.needsLogin = needsLogin }
        init(cancelled: Bool) { reason = "Cancelled."; self.cancelled = cancelled }
    }

    private final class Run {
        let target: UsageAccount
        // Claude accounts that are still alive.
        let accounts: [UsageAccount]
        let confirmedLosing: ClaudeCodeUnknownLogin?
        let control: OperationControl
        let progress: @Sendable (ClaudeCodeSwitchStep) -> Void
        let openURL: @Sendable (URL) -> Void
        let log: LimitResetLog
        let startedAt: Date
        // True from the first call that can write the default slot until that slot is known to be unchanged.
        var slotTouched = false
        // A browser sign-in happened in this run.
        var freshLogin = false

        init(target: UsageAccount, accounts: [UsageAccount], confirmedLosing: ClaudeCodeUnknownLogin?, control: OperationControl,
             progress: @escaping @Sendable (ClaudeCodeSwitchStep) -> Void, openURL: @escaping @Sendable (URL) -> Void,
             log: LimitResetLog, startedAt: Date) {
            self.target = target; self.accounts = accounts; self.confirmedLosing = confirmedLosing; self.control = control
            self.progress = progress; self.openURL = openURL; self.log = log; self.startedAt = startedAt
        }

        func step(_ name: String, _ outcome: String, _ details: [String: Any] = [:]) {
            var entry = details
            entry["step"] = name
            entry["outcome"] = outcome
            log.record("step", entry)
        }
    }

    private static func describe(_ outcome: ClaudeCodeSwitchOutcome) -> [String: Any] {
        switch outcome {
        case .switched(let switched):
            return ["outcome": "switched", "previousAccountID": switched.previousAccountID as Any,
                    "needsLogin": switched.needsLogin.map(\.uuidString)]
        case .alreadyInUse: return ["outcome": "alreadyInUse"]
        case .needsConfirmation(let login): return ["outcome": "needsConfirmation", "unregisteredEmail": login.email as Any]
        case .cancelled: return ["outcome": "cancelled", "nothingChanged": true]
        case .failed(let failure):
            return ["outcome": "failed", "message": failure.reason, "nothingChanged": failure.nothingChanged,
                    "needsLogin": failure.needsLogin.map(\.uuidString)]
        }
    }
}
