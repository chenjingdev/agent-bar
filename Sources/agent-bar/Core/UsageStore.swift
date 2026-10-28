import AppKit
import Combine
import Foundation

struct PendingAccountLogin {
    var account: UsageAccount
    var replacing: UUID?
}

// Whether the Claude account windows can offer "Use in Claude Code" at all.
enum ClaudeCodeAvailability: Equatable {
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
    // The address the target is registered with: the browser has to be signed in to it.
    let targetEmail: String?
    // The account Claude Code was signed in to when the button was pressed, if AgentBar has it.
    let previousID: UUID?
    let control: OperationControl
    var message: String
    // Only the browser wait can be cancelled.
    var canCancel = false
    // Set when the browser could not be opened: the switch is cancelled, and this is why.
    var failure: String?
}

// The question asked before a login AgentBar does not have is removed from Claude Code.
struct ClaudeCodeConfirmation: Equatable {
    var accountID: UUID
    var login: ClaudeCodeUnknownLogin
}

// How the last switch to an account ended.
struct ClaudeCodeResult: Equatable {
    var succeeded: Bool
    var message: String
    var finishedAt = Date.now
    // How often the popover that showed the account has closed since the result appeared. The second close clears it.
    var closes = 0
}

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var registry = AccountRegistry()
    @Published private(set) var snapshots: [UUID: ProviderSnapshot] = [:]
    @Published private(set) var claudeSnapshot = ProviderSnapshot.placeholder(for: .claude)
    @Published private(set) var codexSnapshot = ProviderSnapshot.placeholder(for: .codex)
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var refreshingAccounts: Set<UUID> = []
    // The coupon each account is using right now, by account.
    @Published private(set) var redeemingCoupons: [UUID: String] = [:]
    @Published private(set) var limitResetResults: [UUID: LimitResetResult] = [:]
    @Published private(set) var loginMessage: String?
    @Published private(set) var pendingLogin: PendingAccountLogin?
    @Published private(set) var isLoggingIn = false
    @Published private(set) var canOpenPrivateLogin = false
    @Published var errorMessage: String?
    @Published private(set) var storageUnavailable = false

    // Using an account in Claude Code. Without a switcher none of this exists: no button, no reads, no files.
    @Published private(set) var claudeCodeAvailability = ClaudeCodeAvailability.unknown
    // The registered account Claude Code is signed in to right now.
    @Published private(set) var claudeCodeAccountID: UUID?
    // True from launch until a switch cut short last time has been finished and the account UUIDs are filled in.
    @Published private(set) var claudeCodeStarting = false
    @Published private(set) var claudeCodeActivity: ClaudeCodeActivity?
    @Published private(set) var claudeCodeConfirmation: ClaudeCodeConfirmation?
    @Published private(set) var claudeCodeResults: [UUID: ClaudeCodeResult] = [:]
    private(set) var claudeCodeSwitchTask: Task<Void, Never>?
    private(set) var claudeCodeReading: Task<Void, Never>?
    private var claudeCodeEpoch = 0
    // The account each menu bar group's popover shows, and the accounts it has shown since it last opened.
    private var popoverShown: [UUID: UUID] = [:]
    private var popoverSeen: [UUID: Set<UUID>] = [:]
    private var claudeCodeReadAgain = false
    private var claudeCodeVersionDue = false

    @Published private(set) var displayConfiguration = DisplayConfiguration()
    @Published private(set) var selectedMenuBarGroupID: UUID?
    @Published var displayError: String?
    @Published var displayWidthWarning = false
    private var displayWritable = true

    let settings: AppSettings
    let files: AccountFiles
    private var refreshTask: Task<Void, Never>?
    private var loginTask: Task<Void, Never>?
    private var loginControl: OperationControl?
    private var loginCandidate: UsageAccount?
    private let loginBrowser = BrowserLoginLauncher()
    private var loginAuthorizationURL: URL?
    private var controls: [UUID: OperationControl] = [:]
    private var nextEligibleRefresh: [UUID: Date] = [:]
    private var cleaning: Set<UUID> = []
    private var deletingIDs: Set<UUID> = []
    private var pendingRefreshIDs: Set<UUID> = []
    private var forcedRefreshIDs: Set<UUID> = []
    private let automaticRefresh: Bool
    private let loadAccount: (@Sendable (UsageAccount, OperationControl) async -> ProviderSnapshot)?
    private let claudeCode: ClaudeCodeSwitcher?
    private let claudeCodeBrowser: BrowserLoginLauncher
    private var refreshTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    // `claudeCode` turns on "Use in Claude Code"; only the app's assembly passes one. `claudeCodeBrowser` opens its sign-in page.
    init(settings: AppSettings, files: AccountFiles = AccountFiles(), autoRefresh: Bool = true,
         loadAccount: (@Sendable (UsageAccount, OperationControl) async -> ProviderSnapshot)? = nil,
         claudeCode: ClaudeCodeSwitcher? = nil, claudeCodeBrowser: BrowserLoginLauncher? = nil) {
        self.settings = settings
        self.automaticRefresh = autoRefresh
        self.loadAccount = loadAccount
        self.claudeCode = claudeCode
        self.claudeCodeBrowser = claudeCodeBrowser ?? BrowserLoginLauncher()
        self.files = files
        do {
            var loaded = try files.load()
            loaded.repairRepresentatives()
            try files.write(loaded, to: files.registryURL)
            registry = loaded
            // Legacy rows without an AgentBar credential stay in their existing
            // layouts, but require a separate login before any usage is read.
            for account in loaded.accounts where account.isManaged && !account.deletionPending {
                if let cached = try? files.read(ProviderSnapshot.self, at: lastGoodURL(account)) {
                    snapshots[account.id] = cached.failed("Cached usage. Checking for an update.")
                }
            }
        } catch { storageUnavailable = true; errorMessage = error.localizedDescription }
        if !storageUnavailable { loadDisplayConfiguration() }
        else { displayWritable = false }
        updateRepresentatives()
        if autoRefresh {
            // Nothing can be pressed until a switch cut short last time is finished.
            if claudeCode != nil { claudeCodeStarting = true }
            configureTimer()
            settings.$refreshIntervalSeconds.dropFirst().sink { [weak self] interval in self?.configureTimer(interval: interval) }.store(in: &cancellables)
            refreshNow()
            // Leftover deletions wait for the recovery, which may be using the same accounts' folders.
            Task { [weak self] in
                await self?.runClaudeCodeStartup()
                await self?.retryCleanup(allowUserInteraction: false)
            }
        }
    }

    private var displayURL: URL { files.root.appendingPathComponent("display-v2.json") }
    private var liveAccounts: [UsageAccount] { accounts.filter { !$0.deletionPending } }
    private func loadDisplayConfiguration() {
        do {
            if FileManager.default.fileExists(atPath: displayURL.path) {
                var loaded = try files.read(DisplayConfiguration.self, at: displayURL)
                let original = loaded
                loaded.limitLayoutSizes()
                loaded.normalizeTextLineSlots()
                if loaded.layouts != nil { loaded.freezeBadgeLabels() }
                if loaded != original {
                    try FileManager.default.copyItem(at: displayURL, to: files.root.appendingPathComponent("display-before-three-lines-\(UUID()).json"))
                }
                guard loaded.valid else { throw AccountError.message("Invalid display settings format.") }
                displayConfiguration = loaded
                updateDisplay { $0.sync(liveAccounts) }
            } else {
                displayConfiguration = .initial(registry)
                try files.write(displayConfiguration, to: displayURL)
            }
        } catch {
            displayConfiguration = .initial(registry)
            // Preserve the damaged original, then allow the recovered configuration to be saved.
            do {
                if FileManager.default.fileExists(atPath: displayURL.path) {
                    try FileManager.default.copyItem(at: displayURL, to: files.root.appendingPathComponent("display-preserved-\(UUID()).json"))
                }
            } catch { displayWritable = false }
            displayError = "Could not read display settings. Using defaults; the original was preserved."
        }
    }
    func updateDisplay(_ change: (inout DisplayConfiguration) -> Void) {
        guard displayWritable else { return }
        var next = displayConfiguration; change(&next)
        if next.layouts != nil { next.freezeBadgeLabels() }
        guard next.valid else { return }
        do {
            if displayConfiguration.layouts == nil && next.layouts != nil && FileManager.default.fileExists(atPath: displayURL.path) {
                try FileManager.default.copyItem(at: displayURL, to: files.root.appendingPathComponent("display-before-layouts-\(UUID()).json"))
            }
            try files.write(next, to: displayURL)
            let previous = refreshAccountIDs
            displayConfiguration = next
            if let selectedMenuBarGroupID, !next.effectiveLayouts.contains(where: { $0.id == selectedMenuBarGroupID }) {
                self.selectedMenuBarGroupID = next.effectiveLayouts.first?.id
            }
            let current = refreshAccountIDs
            for id in previous.subtracting(current) {
                controls[id]?.cancel()
                pendingRefreshIDs.remove(id)
                if let snapshot = snapshots[id] {
                    if !snapshot.isStale && snapshot.retryAt == nil { nextEligibleRefresh[id] = nil }
                    snapshots[id] = snapshot.failed("Hidden account. Refresh is paused.", requiresLogin: snapshot.requiresLogin)
                }
            }
            let newlyVisible = current.subtracting(previous)
            for id in newlyVisible {
                if let snapshot = snapshots[id], snapshot.note == "Hidden account. Refresh is paused." {
                    snapshots[id] = snapshot.failed("Cached usage. Waiting for the next refresh.", requiresLogin: snapshot.requiresLogin)
                }
            }
            updateRepresentatives()
            if automaticRefresh { requestRefresh(newlyVisible) }
        }
        catch { displayError = "Could not save display settings: \(error.localizedDescription)" }
    }
    var visibleAccounts: [UsageAccount] {
        displayConfiguration.visibleAccountIDs.compactMap { id in liveAccounts.first { $0.id == id } }
    }
    var orderedAccounts: [UsageAccount] {
        displayConfiguration.order.compactMap { id in liveAccounts.first { $0.id == id } }
    }
    @discardableResult
    func moveAccount(_ id: UUID, to targetID: UUID) -> Bool {
        let ids = orderedAccounts.map(\.id)
        guard id != targetID, ids.contains(id), ids.contains(targetID) else { return false }
        let before = displayConfiguration.order
        updateDisplay { config in
            guard let source = config.order.firstIndex(of: id), let target = config.order.firstIndex(of: targetID) else { return }
            // Freeze legacy group order before changing the account picker order.
            if config.layouts == nil { config.layouts = config.effectiveLayouts }
            let moved = config.order.remove(at: source)
            config.order.insert(moved, at: target)
        }
        return displayConfiguration.order != before
    }
    func menuBarEntry(for account: UsageAccount) -> MenuBarEntry {
        let snapshot = snapshot(for: account)
        return MenuBarEntry(account: account, display: displayConfiguration.display(account),
                            metric: .menuBar(snapshot, preferred: displayConfiguration.display(account).primary), metrics: DisplayMetric.all(snapshot),
                            stale: snapshot.isStale, requiresLogin: snapshot.requiresLogin)
    }
    func menuBarEntry(for id: UUID) -> MenuBarEntry? {
        liveAccounts.first { $0.id == id }.map { menuBarEntry(for: $0) }
    }

    var accounts: [UsageAccount] { registry.accounts }
    func accounts(for provider: ProviderKind) -> [UsageAccount] { accounts.filter { $0.provider == provider } }
    func representative(for provider: ProviderKind) -> UsageAccount? {
        accounts.first { $0.id == registry.representatives[provider.rawValue] && !$0.deletionPending }
    }
    func snapshot(for provider: ProviderKind) -> ProviderSnapshot {
        representative(for: provider).map { snapshot(for: $0) } ?? .placeholder(for: provider)
    }
    func snapshot(for account: UsageAccount) -> ProviderSnapshot {
        guard account.isManaged else {
            return .placeholder(for: account.provider).failed("Sign in to connect this account to AgentBar in Settings › Accounts.", requiresLogin: true)
        }
        return snapshots[account.id] ?? .placeholder(for: account.provider)
    }
    private func lastGoodURL(_ account: UsageAccount) -> URL {
        files.cache(account).deletingLastPathComponent().appendingPathComponent("last-good.json")
    }
    @discardableResult
    private func commit(_ value: AccountRegistry) -> Bool {
        guard !storageUnavailable else { return false }
        do { try files.write(value, to: files.registryURL); registry = value; updateDisplay { $0.sync(value.accounts.filter { !$0.deletionPending }) }; updateRepresentatives(); return true }
        catch { errorMessage = "Could not save account settings: \(error.localizedDescription)"; return false }
    }
    func selectRepresentative(_ account: UsageAccount) {
        guard !account.deletionPending else { return }
        var next = registry; next.representatives[account.provider.rawValue] = account.id; _ = commit(next)
    }
    func selectMenuBarGroup(_ id: UUID) {
        let groups = displayConfiguration.effectiveLayouts
        selectedMenuBarGroupID = groups.contains(where: { $0.id == id }) ? id : groups.first?.id
    }
    @discardableResult
    func moveMenuBarGroup(_ id: UUID, to targetID: UUID) -> Bool {
        let before = displayConfiguration.effectiveLayouts.map(\.id)
        updateDisplay { $0.moveLayout(id, to: targetID) }
        let changed = displayConfiguration.effectiveLayouts.map(\.id) != before
        if changed { selectMenuBarGroup(id) }
        return changed
    }
    func credentialDirectory(for account: UsageAccount) -> URL? {
        account.credentialID.map { files.credentials($0) }
    }

    func accountLabel(for account: UsageAccount) -> String {
        guard account.name == account.identity?.email else { return account.name }
        let peers = accounts.filter { $0.provider == account.provider && !$0.deletionPending }
        let number = (peers.firstIndex(where: { $0.id == account.id }) ?? 0) + 1
        return account.provider.displayName + (number > 1 ? " \(number)" : "")
    }
    func rename(_ account: UsageAccount, name: String) {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !trimmed.isEmpty, let index = registry.accounts.firstIndex(where: { $0.id == account.id }) else { return }
        var next = registry; next.accounts[index].name = trimmed; _ = commit(next)
    }
    private func updateRepresentatives() {
        claudeSnapshot = snapshot(for: .claude)
        codexSnapshot = snapshot(for: .codex)
    }
    static func acceptsResult(request: UsageAccount, current: UsageAccount?) -> Bool {
        guard let current else { return false }
        return current.id == request.id && current.credentialID == request.credentialID && !current.deletionPending
    }

    var refreshAccountIDs: Set<UUID> {
        displayConfiguration.refreshAccountIDs.intersection(accounts.filter { $0.isManaged && !$0.deletionPending }.map(\.id))
    }

    func refreshNow() { requestRefresh(refreshAccountIDs); refreshClaudeCodeState() }

    func refresh() async {
        refreshNow()
        await refreshTask?.value
    }

    private func requestRefresh(_ ids: Set<UUID>) {
        guard !storageUnavailable, !ids.isEmpty else { return }
        pendingRefreshIDs.formUnion(ids)
        guard refreshTask == nil else { return }
        isRefreshing = true
        refreshTask = Task { [weak self] in
            guard let self else { return }
            while !pendingRefreshIDs.isEmpty && !Task.isCancelled {
                let requested = pendingRefreshIDs.intersection(refreshAccountIDs)
                pendingRefreshIDs.removeAll()
                async let claude: Void = refreshService(.claude, requested: requested)
                async let codex: Void = refreshService(.codex, requested: requested)
                _ = await (claude, codex)
            }
            isRefreshing = false; lastRefresh = .now; refreshTask = nil
        }
    }
    private func refreshService(_ provider: ProviderKind, requested: Set<UUID>) async {
        let selected = accounts(for: provider).filter { !$0.deletionPending && requested.contains($0.id) }
        for account in selected {
            guard !Task.isCancelled, refreshAccountIDs.contains(account.id), Self.acceptsResult(request: account, current: accounts.first(where: { $0.id == account.id })) else { continue }
            guard let directory = credentialDirectory(for: account) else { continue }
            if let next = nextEligibleRefresh[account.id], Date() < next { continue }
            let control = OperationControl(); controls[account.id] = control
            refreshingAccounts.insert(account.id)
            let result: ProviderSnapshot
            if let loadAccount {
                result = await loadAccount(account, control)
            } else if provider == .codex {
                result = await CodexUsageProvider(directory: directory, expectedIdentity: account.identity, control: control,
                    resetLog: LimitResetLog(root: files.root, account: account)).load()
            } else {
                result = await ClaudeUsageProvider(directory: directory, cacheURL: files.cache(account),
                    expectedIdentity: account.identity, control: control, forceFetch: forcedRefreshIDs.remove(account.id) != nil,
                    resetLog: LimitResetLog(root: files.root, account: account)).load()
            }
            controls[account.id] = nil; refreshingAccounts.remove(account.id)
            // A hidden response must not update usage, but its provider retry
            // deadline still applies to the same credential generation.
            guard Self.acceptsResult(request: account, current: accounts.first(where: { $0.id == account.id })) else { continue }
            if let retryAt = result.retryAt {
                nextEligibleRefresh[account.id] = max(nextEligibleRefresh[account.id] ?? .distantPast, retryAt)
            }
            guard !control.cancelled, refreshAccountIDs.contains(account.id) else { continue }
            var display = result
            if result.isStale, account.isManaged, result.fiveHour?.utilization == nil, result.weekly?.utilization == nil,
               let previous = snapshots[account.id], previous.fiveHour?.utilization != nil || previous.weekly?.utilization != nil {
                display = previous.failed(result.note ?? "Could not load usage", requiresLogin: result.requiresLogin)
            }
            snapshots[account.id] = display
            nextEligibleRefresh[account.id] = result.retryAt ?? Date().addingTimeInterval(result.isStale ? 60 : 5)
            if account.isManaged && !result.isStale { try? files.write(result, to: lastGoodURL(account)) }
            updateRepresentatives()
        }
    }
    var limitResetLogURL: URL { LimitResetLog.url(root: files.root) }

    // Uses the usage limit reset coupon the person picked and records each step in the reset log,
    // then reads the account again without waiting for the usage cache or the refresh cooldown.
    func redeemLimitReset(_ account: UsageAccount, couponID: String) {
        guard !storageUnavailable, redeemingCoupons[account.id] == nil, !account.deletionPending,
              let directory = credentialDirectory(for: account) else { return }
        let log = LimitResetLog(root: files.root, account: account, attempt: UUID())
        let info = Bundle.main.infoDictionary
        log.record("start", ["coupon": couponID, "shown": LimitResetLog.describe(snapshot(for: account)),
                             "appVersion": info?["CFBundleShortVersionString"] as Any, "appBuild": info?["CFBundleVersion"] as Any])
        redeemingCoupons[account.id] = couponID
        limitResetResults[account.id] = nil
        Task { [weak self] in
            guard let self else { return }
            // A refresh in flight may be using the same CLI home or credential file.
            while refreshingAccounts.contains(account.id) { try? await Task.sleep(for: .milliseconds(100)) }
            let result: LimitResetResult
            if account.provider == .codex {
                result = await CodexUsageProvider(directory: directory, expectedIdentity: account.identity)
                    .redeemLimitReset(couponID: couponID, log: log)
            } else {
                result = await ClaudeUsageProvider(directory: directory, cacheURL: files.cache(account),
                    expectedIdentity: account.identity).redeemLimitReset(couponID: couponID, log: log)
            }
            redeemingCoupons[account.id] = nil
            log.record("result", ["succeeded": result.succeeded, "message": result.message])
            guard Self.acceptsResult(request: account, current: accounts.first(where: { $0.id == account.id })) else { return }
            limitResetResults[account.id] = result
            if snapshots[account.id]?.retryAt.map({ $0 <= Date() }) ?? true { nextEligibleRefresh[account.id] = nil }
            if account.provider == .claude { forcedRefreshIDs.insert(account.id) }
            requestRefresh([account.id])
            await refreshTask?.value
            log.record("after", ["shown": LimitResetLog.describe(snapshot(for: account))])
        }
    }

    private func configureTimer(interval: Double? = nil) {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: max(60, interval ?? settings.refreshIntervalSeconds), repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                if self?.isRefreshing == false { self?.refreshNow() } else { self?.refreshClaudeCodeState() }
            }
        }
    }

    // Whether a sign-in may begin now. Reconnecting an account that a Claude Code switch is using waits for the switch.
    func canStartLogin(replacing: UsageAccount? = nil) -> Bool {
        guard !isLoggingIn, pendingLogin == nil, !storageUnavailable else { return false }
        return replacing.map { !isClaudeCodeLocked($0) } ?? true
    }

    func startLogin(_ provider: ProviderKind, replacing: UsageAccount? = nil) {
        guard canStartLogin(replacing: replacing) else { return }
        do { _ = try ProviderCLI.executable(provider) }
        catch { errorMessage = error.localizedDescription; return }
        let candidate = UsageAccount(id: UUID(), provider: provider, name: "New \(provider.displayName) account", credentialID: UUID())
        do { try files.createPrivateDirectory(files.credentials(candidate.credentialID!)) }
        catch { errorMessage = error.localizedDescription; return }
        var next = registry; next.cleanupPending.append(candidate)
        guard commit(next) else { try? files.removeCredentials(candidate); return }
        let control = OperationControl(); loginControl = control; loginCandidate = candidate
        isLoggingIn = true; errorMessage = nil
        loginMessage = "Preparing browser sign-in…"
        let directory = files.credentials(candidate.credentialID!)
        let openURL: @Sendable (URL) -> Void = { [weak self] url in
            Task { @MainActor [weak self] in
                guard let self, self.loginControl === control, !control.cancelled else { return }
                self.presentLogin(url, mode: .standard, control: control)
            }
        }
        loginTask = Task { [weak self] in
            let result: Result<AccountIdentity, Error> = await Task.detached(priority: .utility) {
                do {
                    if provider == .codex {
                        let rpc = try CodexRPC(directory: directory, control: control)
                        defer { rpc.stop() }
                        let identity = try rpc.login(openURL: openURL)
                        return .success(identity)
                    }
                    return .success(try ClaudeOAuthLauncher.login(directory: directory, control: control, openURL: openURL))
                } catch { return .failure(error) }
            }.value
            guard let self, self.loginControl === control else { return }
            loginBrowser.close()
            loginAuthorizationURL = nil; canOpenPrivateLogin = false
            if !control.cancelled, case .success(let identity) = result {
                var completed = candidate; completed.identity = identity
                completed.name = identity.email ?? "\(provider.displayName) account"
                reviewSignedIn(PendingAccountLogin(account: completed, replacing: replacing?.id))
            } else {
                loginMessage = nil
                if !control.cancelled, case .failure(let error) = result { errorMessage = error.localizedDescription }
                await cleanCandidate(candidate)
            }
            // Keep the attempt busy until cleanup finishes. Otherwise an old
            // cancellation can clear the controls of a newly started login.
            loginControl = nil; loginCandidate = nil; loginTask = nil; isLoggingIn = false
        }
    }

    private func presentLogin(_ url: URL, mode: LoginBrowserMode, control: OperationControl) {
        guard loginControl === control, !control.cancelled else { return }
        loginAuthorizationURL = url
        canOpenPrivateLogin = mode == .standard
        if mode == .privateWindow {
            loginMessage = "Continue in the private window, then return here to confirm the account. (Up to 5 minutes)"
        } else if loginCandidate?.provider == .claude {
            loginMessage = "Continue in your browser. To use another account, choose Switch account on Claude’s approval page. This also switches the Claude website login. Return here to confirm. (Up to 5 minutes)"
        } else {
            loginMessage = "Choose an account in your browser, or select Sign in with another account. Return here to confirm. (Up to 5 minutes)"
        }
        loginBrowser.open(url, mode: mode, control: control, failed: { [weak self] message in
            self?.errorMessage = message
            self?.canOpenPrivateLogin = false
        }, cancelled: { [weak self] in self?.cancelLogin() })
    }

    // The sign-in finished: the account it signed in to is shown for review before it is registered.
    func reviewSignedIn(_ pending: PendingAccountLogin) {
        pendingLogin = pending
        loginMessage = "Review the signed-in account, then register it."
    }

    func openPrivateLogin() {
        guard canOpenPrivateLogin, isLoggingIn, let url = loginAuthorizationURL, let control = loginControl else { return }
        presentLogin(url, mode: .privateWindow, control: control)
    }
    var reconnectionComparison: IdentityComparison? {
        guard let pendingLogin, let id = pendingLogin.replacing,
              let old = accounts.first(where: { $0.id == id }),
              let identity = pendingLogin.account.identity, let previous = old.identity else { return nil }
        return identity.comparison(to: previous)
    }
    func confirmLogin(replaceUnverified: Bool = false, addAsNew: Bool = false) {
        guard let pending = pendingLogin else { return }
        // Registering over an account a switch is using would change its identity under the switch. The sign-in stays under
        // review, so it can be registered once the switch is over.
        if pending.replacing != nil, !addAsNew, reconnectLockedByClaudeCode {
            errorMessage = claudeCodeBusyMessage("Press Reconnect again")
            return
        }
        var next = registry
        var incoming = pending.account
        if let duplicate = next.accounts.first(where: {
            $0.provider == incoming.provider && $0.id != pending.replacing && $0.identity.map { incoming.identity?.comparison(to: $0) == .same } == true
        }) { errorMessage = "This account is already registered: \(duplicate.title)"; return }
        if let id = pending.replacing, !addAsNew {
            guard let index = next.accounts.firstIndex(where: { $0.id == id }), !next.accounts[index].deletionPending else { return }
            if reconnectionComparison == .different { errorMessage = "This is a different account. Add it as a new account."; return }
            if reconnectionComparison != .same && !replaceUnverified { return }
            let old = next.accounts[index]
            incoming = UsageAccount(id: old.id, provider: old.provider, name: old.name, identity: incoming.identity, credentialID: incoming.credentialID)
            next.accounts[index] = incoming
            if old.isManaged { next.cleanupPending.append(old) }
            controls[id]?.cancel(); snapshots[id] = nil; nextEligibleRefresh[id] = nil; limitResetResults[id] = nil
        } else {
            let hasManaged = next.accounts.contains { $0.provider == incoming.provider && $0.isManaged && !$0.deletionPending }
            next.accounts.append(incoming)
            if !hasManaged { next.representatives[incoming.provider.rawValue] = incoming.id }
        }
        next.cleanupPending.removeAll { $0.credentialID == pending.account.credentialID }
        next.repairRepresentatives()
        guard commit(next) else { return }
        pendingLogin = nil; loginMessage = nil
        refreshNow()
        Task {
            await fillAccountUUIDs()
            await retryCleanup()
        }
    }
    func cancelLogin() {
        loginControl?.cancel()
        loginBrowser.close()
        loginAuthorizationURL = nil; canOpenPrivateLogin = false
        if let pending = pendingLogin {
            pendingLogin = nil; loginMessage = nil
            Task { await cleanCandidate(pending.account) }
        } else if isLoggingIn { loginMessage = "Cancelling sign-in…" }
    }
    private func cleanCandidate(_ account: UsageAccount, allowUserInteraction: Bool = true) async {
        guard let credentialID = account.credentialID, !cleaning.contains(credentialID) else { return }
        cleaning.insert(credentialID)
        defer { cleaning.remove(credentialID) }
        while refreshingAccounts.contains(account.id) { try? await Task.sleep(for: .milliseconds(100)) }
        let files = files
        let error: String? = await Task.detached {
            do {
                try files.removeCredentials(account, allowUserInteraction: allowUserInteraction)
                let cacheDirectory = files.cache(account).deletingLastPathComponent()
                if FileManager.default.fileExists(atPath: cacheDirectory.path) { try FileManager.default.removeItem(at: cacheDirectory) }
                return nil
            }
            catch { return error.localizedDescription }
        }.value
        if let error { errorMessage = error; return }
        var next = registry; next.cleanupPending.removeAll { $0.credentialID == account.credentialID }; _ = commit(next)
    }
    func retryCleanup(allowUserInteraction: Bool = true) async {
        for account in registry.cleanupPending where account.credentialID != loginCandidate?.credentialID && account.credentialID != pendingLogin?.account.credentialID {
            await cleanCandidate(account, allowUserInteraction: allowUserInteraction)
        }
        for account in accounts where account.deletionPending { await delete(account, allowUserInteraction: allowUserInteraction) }
    }
    func delete(_ account: UsageAccount, allowUserInteraction: Bool = true) async {
        guard !deletingIDs.contains(account.id), let index = registry.accounts.firstIndex(where: { $0.id == account.id }) else { return }
        // A switch is using this account's logins. A person who asked for the deletion is told; a leftover deletion that
        // is retried by itself waits for a later retry.
        guard !isClaudeCodeLocked(account) else {
            if allowUserInteraction { errorMessage = claudeCodeBusyMessage("Delete this account") }
            return
        }
        let account = registry.accounts[index]
        deletingIDs.insert(account.id)
        defer { deletingIDs.remove(account.id) }
        var next = registry; next.accounts[index].deletionPending = true; next.repairRepresentatives()
        guard commit(next) else { return }
        controls[account.id]?.cancel(); snapshots[account.id] = nil; limitResetResults[account.id] = nil; updateRepresentatives()
        // Wait for this account's in-flight request before removing its cache directory.
        while refreshingAccounts.contains(account.id) { try? await Task.sleep(for: .milliseconds(100)) }
        let files = files
        let error: String? = await Task.detached {
            do { try files.removeCredentials(account, allowUserInteraction: allowUserInteraction); try files.removeUsage(account); return nil }
            catch { return error.localizedDescription }
        }.value
        if let error { errorMessage = error; return }
        next = registry; next.accounts.removeAll { $0.id == account.id }; next.repairRepresentatives(); _ = commit(next)
    }

    // MARK: Claude Code

    var claudeCodeLogURL: URL { LimitResetLog.claudeCodeSwitchURL(root: files.root) }
    // Whether "Use in Claude Code" exists at all in this run.
    var claudeCodeEnabled: Bool { claudeCode != nil }

    // The accounts whose Delete and Reconnect must wait: the two a running switch involves, or every Claude account
    // while a switch cut short last time is being finished (the journal says which, but only the engine reads it).
    private var claudeCodeLockedIDs: Set<UUID> {
        var ids = Set<UUID>()
        if let activity = claudeCodeActivity {
            ids.insert(activity.targetID)
            if let previous = activity.previousID { ids.insert(previous) }
        }
        if claudeCodeStarting { ids.formUnion(accounts.filter { $0.provider == .claude }.map(\.id)) }
        return ids
    }
    func isClaudeCodeLocked(_ account: UsageAccount) -> Bool { claudeCodeLockedIDs.contains(account.id) }
    // Whether the sign-in under review would replace an account a Claude Code switch is using.
    var reconnectLockedByClaudeCode: Bool {
        guard let id = pendingLogin?.replacing, let account = registry.accounts.first(where: { $0.id == id }) else { return false }
        return isClaudeCodeLocked(account)
    }
    // Why an account cannot be changed now, and when it can: `action` is what the person asked for.
    private func claudeCodeBusyMessage(_ action: String) -> String {
        claudeCodeActivity == nil ? "AgentBar is still checking Claude Code. \(action) in a moment."
                                  : "Claude Code is switching accounts. \(action) after it finishes."
    }
    // Why the account is locked, for the Accounts list; nil when it is not.
    func claudeCodeLockNote(for account: UsageAccount) -> String? {
        guard isClaudeCodeLocked(account) else { return nil }
        return claudeCodeActivity == nil ? "Checking Claude Code" : "Switching Claude Code"
    }

    // What the account's window shows. The control is hidden without a switcher and when Claude Code is not installed.
    func claudeCodePanel(for account: UsageAccount) -> ClaudeCodePanel {
        guard claudeCode != nil, account.provider == .claude, !account.deletionPending,
              claudeCodeAvailability != .missing else { return .hidden }
        // Why the button cannot be pressed. `notice` is also written under the header where nothing else already says it:
        // the sign-in status line is shown there anyway.
        var blocked: (help: String, notice: String?)?
        let unverifiable = "Reconnect this account before using it in Claude Code."
        if claudeCodeStarting || claudeCodeAvailability == .unknown {
            blocked = ("Checking Claude Code…", nil)
        } else if claudeCodeActivity != nil {
            blocked = ("Claude Code is being switched. Wait for it to finish.", nil)
        } else if case .blocked(let reason) = claudeCodeAvailability {
            blocked = (reason, reason)
        } else if snapshot(for: account).requiresLogin {
            blocked = (AccountPopoverView.signInRequiredLine, nil)
        } else if !ClaudeSlotIdentity.canVerify(account) {
            blocked = (unverifiable, unverifiable)
        }

        var lines: [ClaudeCodePanel.Line] = []
        if let activity = claudeCodeActivity {
            if activity.targetID == account.id {
                lines.append(.progress(activity.message, cancellable: activity.canCancel))
            } else if let target = accounts.first(where: { $0.id == activity.targetID }) {
                lines.append(.progress("Switching Claude Code to \(target.title)…", cancellable: false))
            }
        } else if let confirmation = claudeCodeConfirmation, confirmation.accountID == account.id {
            lines.append(.confirmation(email: confirmation.login.email))
        } else if let result = claudeCodeResults[account.id] {
            lines.append(.result(succeeded: result.succeeded, message: result.message, finishedAt: result.finishedAt))
        }

        let control: ClaudeCodePanel.Control
        if claudeCodeAccountID == account.id {
            control = .inClaudeCode
        } else if let blocked {
            control = .use(enabled: false, help: blocked.help)
            if let notice = blocked.notice { lines.insert(.notice(notice), at: 0) }
        } else {
            control = .use(enabled: true, help: "Switches Claude Code to this account. Open sessions switch within 30 s.")
        }
        return ClaudeCodePanel(control: control, lines: lines)
    }

    private func canStartClaudeCodeSwitch(_ account: UsageAccount) -> Bool {
        guard !storageUnavailable, !account.deletionPending, accounts.contains(where: { $0.id == account.id }),
              case .use(let enabled, _) = claudeCodePanel(for: account).control else { return false }
        return enabled
    }

    func useInClaudeCode(_ account: UsageAccount) {
        // The registry's own copy, in case the one the window holds is older.
        guard let account = accounts.first(where: { $0.id == account.id }), canStartClaudeCodeSwitch(account) else { return }
        startClaudeCodeSwitch(to: account, confirmed: nil)
    }

    // "Switch" on the question about a login AgentBar does not have. The yes belongs to the login that was shown.
    func confirmClaudeCodeSwitch() {
        guard let confirmation = claudeCodeConfirmation else { return }
        claudeCodeConfirmation = nil
        guard let account = liveAccounts.first(where: { $0.id == confirmation.accountID }),
              canStartClaudeCodeSwitch(account) else { return }
        startClaudeCodeSwitch(to: account, confirmed: confirmation.login)
    }

    func cancelClaudeCodeConfirmation() { claudeCodeConfirmation = nil }

    // Cancel while the switch waits for the browser. Any other step cannot be cancelled and has no button.
    func cancelClaudeCodeSwitch() {
        guard var activity = claudeCodeActivity, activity.canCancel else { return }
        activity.canCancel = false
        activity.message = "Cancelling…"
        claudeCodeActivity = activity
        activity.control.cancel()
        claudeCodeBrowser.close()
    }

    private func startClaudeCodeSwitch(to account: UsageAccount, confirmed: ClaudeCodeUnknownLogin?) {
        guard let claudeCode else { return }
        // Earlier results describe a login that is about to change.
        claudeCodeConfirmation = nil
        claudeCodeResults.removeAll()
        claudeCodeEpoch += 1
        let control = OperationControl()
        let activity = ClaudeCodeActivity(targetID: account.id, targetEmail: account.identity?.email, previousID: claudeCodeAccountID,
                                          control: control, message: ClaudeCodeSwitchStep.checkingVersion.message)
        let id = activity.id
        claudeCodeActivity = activity
        let accounts = registry.accounts
        // The engine blocks, and tells its progress and the sign-in page from its own thread, in order.
        claudeCodeSwitchTask = Task { [weak self] in
            let outcome = await Task.detached(priority: .utility) {
                claudeCode.switchAccount(
                    to: account, among: accounts, confirmedLosing: confirmed, control: control,
                    progress: { step in
                        DispatchQueue.main.async { MainActor.assumeIsolated { self?.claudeCodeProgress(step, activity: id) } }
                    },
                    openURL: { url in
                        DispatchQueue.main.async { MainActor.assumeIsolated { self?.openClaudeCodeBrowser(url, control: control, activity: id) } }
                    })
            }.value
            self?.finishClaudeCodeSwitch(outcome, target: account, activity: id)
        }
    }

    private func claudeCodeProgress(_ step: ClaudeCodeSwitchStep, activity id: UUID) {
        guard var activity = claudeCodeActivity, activity.id == id else { return }
        if case .waitingForBrowser(let reason) = step {
            // A cancel that is already on its way keeps its words.
            activity.canCancel = !activity.control.cancelled
            activity.message = activity.control.cancelled ? "Cancelling…" : reason.message(signingInAs: activity.targetEmail)
        } else {
            activity.canCancel = false
            activity.message = step.message
        }
        claudeCodeActivity = activity
    }

    // The sign-in page is opened in the person's own browser. That closes the popover, so the progress lives here.
    private func openClaudeCodeBrowser(_ url: URL, control: OperationControl, activity id: UUID) {
        guard claudeCodeActivity?.id == id, !control.cancelled else { return }
        claudeCodeBrowser.open(url, mode: .standard, control: control, failed: { [weak self] message in
            guard var activity = self?.claudeCodeActivity, activity.id == id else { return }
            activity.failure = message
            self?.claudeCodeActivity = activity
        }, cancelled: {})
    }

    private func finishClaudeCodeSwitch(_ outcome: ClaudeCodeSwitchOutcome, target: UsageAccount, activity id: UUID) {
        guard let activity = claudeCodeActivity, activity.id == id else { return }
        claudeCodeActivity = nil
        claudeCodeEpoch += 1
        claudeCodeBrowser.close()
        switch outcome {
        case .switched(let switched):
            claudeCodeAccountID = switched.accountID
            let message = "Claude Code now uses \(target.title). Open sessions switch within 30 s. Remote Control disconnects."
            claudeCodeResults[target.id] = ClaudeCodeResult(succeeded: true, message: claudeCodeNotes(message, needsLogin: switched.needsLogin))
        case .alreadyInUse:
            claudeCodeAccountID = target.id
        case .needsConfirmation(let login):
            claudeCodeConfirmation = ClaudeCodeConfirmation(accountID: target.id, login: login)
        case .cancelled:
            if let failure = activity.failure { claudeCodeResults[target.id] = ClaudeCodeResult(succeeded: false, message: failure) }
        case .failed(let failure):
            let message = Self.claudeCodeFailureMessage(failure)
            claudeCodeResults[target.id] = ClaudeCodeResult(succeeded: false, message: claudeCodeNotes(message, needsLogin: failure.needsLogin))
        }
        refreshClaudeCodeState(checkVersion: false)
    }

    // The engine's one-line reason, with a warning that the login may have changed unless the reason already says so.
    nonisolated static func claudeCodeFailureMessage(_ failure: ClaudeCodeSwitchFailure) -> String {
        let reason = failure.reason.lowercased()
        let saysSo = ["login changed", "different account"].contains { reason.contains($0) }
        return failure.reason + (failure.nothingChanged || saysSo ? "" : " Claude Code's login may have changed.")
    }

    // The accounts whose saved login could not be kept sign in with the browser the next time.
    private func claudeCodeNotes(_ message: String, needsLogin ids: [UUID]) -> String {
        ([message] + ids.compactMap { id in
            accounts.first { $0.id == id }.map { "\($0.title) needs a browser sign-in next time." }
        }).joined(separator: " ")
    }

    // MARK: Claude Code: what it is signed in to

    // Run once when the app starts. It finishes or drops a switch that was cut short, fills in the account UUIDs, and
    // reads what Claude Code is signed in to, in that order. Nothing can be pressed before it is done.
    func runClaudeCodeStartup() async {
        guard let claudeCode else { return }
        // Without the registry the engine cannot tell which account a cut-short switch was for, and would drop its record.
        guard !storageUnavailable else { claudeCodeStarting = false; return }
        claudeCodeStarting = true
        let accounts = registry.accounts
        let recovery = await Task.detached(priority: .utility) { claudeCode.recoverInterruptedSwitch(among: accounts) }.value
        if let recovery { showClaudeCodeRecovery(recovery) }
        await fillAccountUUIDs()
        claudeCodeStarting = false
        refreshClaudeCodeState(checkVersion: true)
        await claudeCodeReading?.value
    }

    private func showClaudeCodeRecovery(_ recovery: ClaudeCodeRecovery) {
        guard let target = accounts.first(where: { $0.id == recovery.accountID }) else { return }
        let message: String
        switch recovery.kind {
        case .finished: message = "\(recovery.message) Claude Code now uses \(target.title)."
        case .rolledBack: message = recovery.message
        }
        claudeCodeResults[target.id] = ClaudeCodeResult(succeeded: recovery.kind == .finished,
                                                        message: claudeCodeNotes(message, needsLogin: recovery.needsLogin))
    }

    // Reads, in the background, whether Claude Code is installed and new enough (only when asked, and when it was not
    // usable before) and which registered account it is signed in to. Reads that overlap are folded into one more.
    func refreshClaudeCodeState(checkVersion: Bool = true) {
        guard claudeCode != nil, !claudeCodeStarting, claudeCodeActivity == nil else { return }
        claudeCodeVersionDue = claudeCodeVersionDue || checkVersion
        guard claudeCodeReading == nil else { claudeCodeReadAgain = true; return }
        claudeCodeReading = Task { [weak self] in
            guard let self else { return }
            repeat {
                claudeCodeReadAgain = false
                let versionDue = claudeCodeVersionDue
                claudeCodeVersionDue = false
                await readClaudeCodeState(checkVersion: versionDue)
            } while claudeCodeReadAgain && claudeCodeActivity == nil && !claudeCodeStarting
            claudeCodeReading = nil
        }
    }

    private func readClaudeCodeState(checkVersion: Bool) async {
        guard let claudeCode else { return }
        let accounts = registry.accounts
        // Nothing to offer without a Claude account, so Claude Code is not asked anything.
        guard accounts.contains(where: { $0.provider == .claude && !$0.deletionPending }) else { return }
        let known = claudeCodeAvailability
        let epoch = claudeCodeEpoch
        let reading = await Task.detached(priority: .utility) {
            Self.readClaudeCode(claudeCode, accounts: accounts, checkVersion: checkVersion, known: known)
        }.value
        // A switch that started or ended meanwhile makes this reading old.
        guard epoch == claudeCodeEpoch, claudeCodeActivity == nil else { return }
        claudeCodeAvailability = reading.availability
        claudeCodeAccountID = reading.accountID
    }

    private struct ClaudeCodeReading: Sendable {
        var availability: ClaudeCodeAvailability
        var accountID: UUID?
    }

    nonisolated private static func readClaudeCode(_ claudeCode: ClaudeCodeSwitcher, accounts: [UsageAccount], checkVersion: Bool,
                                                   known: ClaudeCodeAvailability) -> ClaudeCodeReading {
        guard claudeCode.isInstalled() else { return ClaudeCodeReading(availability: .missing, accountID: nil) }
        var availability = known
        if checkVersion || known == .unknown || known == .missing {
            if let reason = claudeCode.checkVersion().blockReason { availability = .blocked(reason) } else { availability = .ready }
        }
        return ClaudeCodeReading(availability: availability, accountID: claudeCode.currentAccountID(among: accounts))
    }

    // The popover of menu bar group `group` is about to open. The login may have been changed in a terminal since it last
    // did. The popover starts on the account it showed last, or the first one it can show; closing counts only for the
    // accounts it shows while it is open.
    func popoverWillOpen(group: UUID? = nil, accountIDs: [UUID] = []) {
        refreshClaudeCodeState(checkVersion: false)
        guard let group else { return }
        let live = Set(liveAccounts.map(\.id))
        let candidates = accountIDs.filter(live.contains)
        let start = popoverShown[group].flatMap { candidates.contains($0) ? $0 : nil } ?? candidates.first
        popoverSeen[group] = start.map { [$0] } ?? []
    }

    // The window says which of its accounts it shows now (a group's popover shows one at a time, chosen by tabs).
    func popoverShows(_ accountID: UUID, group: UUID) {
        popoverShown[group] = accountID
        popoverSeen[group]?.insert(accountID)
    }

    func shownAccount(in group: UUID) -> UUID? { popoverShown[group] }

    // The popover of `group` closed: it counts for the accounts it showed since it opened.
    func popoverDidClose(group: UUID) {
        guard let seen = popoverSeen.removeValue(forKey: group) else { return }
        popoverDidClose(accountIDs: Array(seen))
    }

    // Result lines outlive one closing of the popover that shows them, because the browser closes it too; the next
    // closing clears them. A question that was left open is dropped, as a coupon's confirmation is.
    func popoverDidClose(accountIDs: [UUID]) {
        for id in accountIDs {
            guard var result = claudeCodeResults[id] else { continue }
            result.closes += 1
            claudeCodeResults[id] = result.closes >= 2 ? nil : result
        }
        if let confirmation = claudeCodeConfirmation, accountIDs.contains(confirmation.accountID) { claudeCodeConfirmation = nil }
    }

    // Registered Claude accounts have no account UUID until it is read, once, from the account's own login folder. It is
    // kept only when that folder's organization is the registered one.
    func fillAccountUUIDs() async {
        guard claudeCode != nil else { return }
        let candidates = registry.accounts.filter {
            $0.provider == .claude && !$0.deletionPending && $0.credentialID != nil && $0.identity?.stableID == nil
        }
        guard !candidates.isEmpty else { return }
        let files = files
        let found = await Task.detached(priority: .utility) {
            candidates.compactMap { account -> (UsageAccount, String)? in
                guard let id = account.credentialID,
                      let stableID = ClaudeAccountUUIDFill.stableID(for: account, loginDirectory: files.credentials(id)) else { return nil }
                return (account, stableID)
            }
        }.value
        // The registry is read again: an account may have been reconnected or removed while the files were read.
        var next = registry
        var changed = false
        for (request, stableID) in found {
            guard let index = next.accounts.firstIndex(where: { $0.id == request.id }),
                  Self.acceptsResult(request: request, current: next.accounts[index]),
                  next.accounts[index].identity?.stableID == nil,
                  next.accounts[index].identity?.organizationID == request.identity?.organizationID else { continue }
            next.accounts[index].identity?.stableID = stableID
            changed = true
        }
        if changed { _ = commit(next) }
    }

    func shutdown() {
        refreshTimer?.invalidate(); refreshTask?.cancel(); loginControl?.cancel()
        loginBrowser.close()
        loginAuthorizationURL = nil; canOpenPrivateLogin = false
        controls.values.forEach { $0.cancel() }
        // A switch waiting for the browser ends here. Any other step finishes or is picked up by the next launch.
        claudeCodeActivity?.control.cancel()
        claudeCodeBrowser.close()
    }
}
