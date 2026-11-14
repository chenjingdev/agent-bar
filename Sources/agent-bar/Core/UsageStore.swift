import AppKit
import Combine
import Foundation

struct PendingAccountLogin {
    var account: UsageAccount
    var replacing: UUID?
    /// The menu bar lines a new account starts with, when signing in already
    /// showed its limits (Antigravity's model groups).
    var firstLines: [String]? = nil
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
    @Published private(set) var loginMessage: String?
    @Published private(set) var pendingLogin: PendingAccountLogin?
    @Published private(set) var isLoggingIn = false
    @Published private(set) var canOpenPrivateLogin = false
    @Published var errorMessage: String?
    @Published private(set) var storageUnavailable = false

    @Published private(set) var displayConfiguration = DisplayConfiguration()
    @Published private(set) var selectedMenuBarGroupID: UUID?
    @Published var displayError: String?
    @Published var displayWidthWarning = false
    private var displayWritable = true

    // Switching Claude Code's account (UsageStore+ClaudeCode.swift). Only that file changes these.
    @Published var claudeCodeAvailability = ClaudeCodeAvailability.unknown
    // The registered account Claude Code is signed in to, as last read.
    @Published var claudeCodeAccountID: UUID?
    // True while a switch cut short last time is finished at launch; nothing about Claude Code can be pressed until then.
    @Published var claudeCodeStarting = false
    @Published var claudeCodeActivity: ClaudeCodeActivity?
    @Published var claudeCodeConfirmation: ClaudeCodeConfirmation?
    @Published var claudeCodeResults: [UUID: ClaudeCodeResult] = [:]
    // Accounts whose own folder holds a login a switch can hand to Claude Code without the browser.
    @Published var claudeCodeReady: Set<UUID> = []
    @Published var claudeCodePreparation: ClaudeCodePreparation?
    // Why the last sign-in for Claude Code did not work, per account, for Settings › Accounts.
    @Published var claudeCodeSetupFailures: [UUID: String] = [:]
    // The coupon line of each account while a coupon is asked about, used, or has just been used.
    @Published var couponLines: [UUID: CouponPanel.Line] = [:]
    // The one thing that can change Claude Code's own login. Nil turns the feature off (tests, development runs).
    let claudeCode: ClaudeCodeSwitcher?
    let claudeCodeBrowser: BrowserLoginLauncher
    var claudeCodeReading: Task<Void, Never>?
    var claudeCodeReadAgain = false
    // Bumped when a switch or a sign-in starts or ends, so a reading that began before it is dropped.
    var claudeCodeEpoch = 0
    // Which accounts each menu bar group's panel lists, the group whose panel is open, and the result lines and question
    // that panel has shown since it opened.
    var claudeCodePanelShown: [UUID: Set<UUID>] = [:]
    var claudeCodeOpenPanel: UUID?
    var claudeCodeResultsShown: Set<UUID> = []
    var claudeCodeConfirmationShown = false
    // Held while a deleted account's saved Claude Code sign-in is removed; a switch or sign-in waits for it.
    let lendRemovalLock = NSLock()

    private let settings: AppSettings
    let files: AccountFiles
    private var refreshTask: Task<Void, Never>?
    private var loginTask: Task<Void, Never>?
    private var loginControl: OperationControl?
    private var loginCandidate: UsageAccount?
    private let loginBrowser = BrowserLoginLauncher()
    private var loginAuthorizationURL: URL?
    private var controls: [UUID: OperationControl] = [:]
    private var nextEligibleRefresh: [UUID: Date] = [:]
    // When each service last answered a usage request, for `requestSpacing`.
    private var lastAnswer: [ProviderKind: ContinuousClock.Instant] = [:]
    private var cleaning: Set<UUID> = []
    private var deletingIDs: Set<UUID> = []
    private var pendingRefreshIDs: Set<UUID> = []
    private let automaticRefresh: Bool
    private let loadAccount: (@Sendable (UsageAccount, OperationControl) async -> ProviderSnapshot)?
    // Uses a coupon in place of the service, for tests.
    let useCouponOverride: (@Sendable (UsageAccount, UsageResetCoupons) async -> CouponOutcome)?
    // How long how it ended stays on the coupon line.
    let couponResultSeconds: Double
    // How long to rest between two usage requests to the same service. Empty: no rest.
    let requestSpacing: [ProviderKind: Duration]
    private var refreshTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    // The app's rest, so a group holding many accounts of one service does not ask about them all at once. Antigravity
    // has only one account.
    static let appRequestSpacing: [ProviderKind: Duration] = [.claude: .seconds(1), .codex: .milliseconds(500)]

    // `claudeCode` turns on switching Claude Code's account; only the app's assembly passes the real one.
    // `claudeCodeBrowser` opens the sign-in page for it. Only the app passes `appRequestSpacing`, so tests do not wait.
    init(settings: AppSettings, files: AccountFiles = AccountFiles(), autoRefresh: Bool = true,
         loadAccount: (@Sendable (UsageAccount, OperationControl) async -> ProviderSnapshot)? = nil,
         requestSpacing: [ProviderKind: Duration] = [:],
         claudeCode: ClaudeCodeSwitcher? = nil, claudeCodeBrowser: BrowserLoginLauncher? = nil,
         useCoupon: (@Sendable (UsageAccount, UsageResetCoupons) async -> CouponOutcome)? = nil,
         couponResultSeconds: Double = 6) {
        self.settings = settings
        self.useCouponOverride = useCoupon
        self.couponResultSeconds = couponResultSeconds
        self.automaticRefresh = autoRefresh
        self.loadAccount = loadAccount
        self.requestSpacing = requestSpacing
        self.files = files
        self.claudeCode = claudeCode
        self.claudeCodeBrowser = claudeCodeBrowser ?? BrowserLoginLauncher()
        do {
            var loaded = try files.load()
            loaded.repairRepresentatives()
            files.recordMissingClaudeAccountIDs(in: &loaded)
            try files.write(loaded, to: files.registryURL)
            registry = loaded
            // Legacy rows without an AgentBar credential stay in their existing
            // layouts, but require a separate login before any usage is read.
            for account in loaded.accounts where account.isManaged && !account.deletionPending {
                if let cached = try? files.read(ProviderSnapshot.self, at: lastGoodURL(account)) {
                    snapshots[account.id] = cached.failed(String(localized: "Cached usage. Checking for an update."))
                }
            }
        } catch { storageUnavailable = true; errorMessage = error.localizedDescription }
        if !storageUnavailable { loadDisplayConfiguration() }
        else { displayWritable = false }
        updateRepresentatives()
        if autoRefresh {
            configureTimer()
            settings.$refreshIntervalSeconds.dropFirst().sink { [weak self] interval in self?.configureTimer(interval: interval) }.store(in: &cancellables)
            // Set before the first refresh, so Claude Code is not read before a switch cut short last time is finished.
            if claudeCode != nil && !storageUnavailable { claudeCodeStarting = true }
            refreshNow()
            // Deletions left from last time go on after that, so none of them meets the engine busy.
            Task { [weak self] in
                await self?.runClaudeCodeStartup()
                await self?.retryCleanup(allowUserInteraction: false)
            }
        }
    }

    private static let hiddenAccountNote = String(localized: "Hidden account. Refresh is paused.")
    private var displayURL: URL { files.root.appendingPathComponent("display-v2.json") }
    private var legacyDisplayURL: URL { files.root.appendingPathComponent("display-v1.json") }
    private var liveAccounts: [UsageAccount] { accounts.filter { !$0.deletionPending } }
    private func loadDisplayConfiguration() {
        do {
            if FileManager.default.fileExists(atPath: displayURL.path) {
                var loaded = try files.read(DisplayConfiguration.self, at: displayURL)
                let original = loaded
                loaded.limitLayoutSizes()
                loaded.normalizeTextLineSlots()
                loaded.mergeGroupLabels()
                if loaded.layouts != nil { loaded.freezeBadgeLabels() }
                loaded.normalizeMembers()
                if loaded != original {
                    try FileManager.default.copyItem(at: displayURL, to: files.root.appendingPathComponent("display-before-three-lines-\(UUID()).json"))
                }
                guard loaded.valid else { throw AccountError.message(String(localized: "Invalid display settings format.")) }
                displayConfiguration = loaded
                updateDisplay { $0.sync(liveAccounts) }
            } else if FileManager.default.fileExists(atPath: legacyDisplayURL.path) {
                // The item-based file stays untouched so the previous version can still read it.
                let legacy = try files.read(LegacyDisplayConfiguration.self, at: legacyDisplayURL)
                guard legacy.valid else { throw AccountError.message(String(localized: "Invalid original layout.")) }
                displayConfiguration = .migrated(from: legacy, accounts: liveAccounts)
                try files.write(displayConfiguration, to: displayURL)
            } else {
                displayConfiguration = .initial(registry, settings: settings)
                try files.write(displayConfiguration, to: displayURL)
            }
        } catch {
            displayConfiguration = .initial(registry, settings: settings)
            // Preserve the damaged original, then allow the recovered configuration to be saved.
            do {
                if FileManager.default.fileExists(atPath: displayURL.path) {
                    try FileManager.default.copyItem(at: displayURL, to: files.root.appendingPathComponent("display-preserved-\(UUID()).json"))
                }
            } catch { displayWritable = false }
            displayError = String(localized: "Could not read display settings. Using defaults; the original was preserved.")
        }
    }
    var hasOriginalDisplayConfiguration: Bool {
        FileManager.default.fileExists(atPath: legacyDisplayURL.path)
    }
    func restoreOriginalDisplayConfiguration() {
        guard displayWritable else { return }
        do {
            let legacy = try files.read(LegacyDisplayConfiguration.self, at: legacyDisplayURL)
            guard legacy.valid else { throw AccountError.message(String(localized: "Invalid original layout.")) }
            let restored = DisplayConfiguration.migrated(from: legacy, accounts: liveAccounts)
            if FileManager.default.fileExists(atPath: displayURL.path) {
                try FileManager.default.copyItem(at: displayURL, to: files.root.appendingPathComponent("display-before-restore-\(UUID()).json"))
            }
            updateDisplay { next in
                next.layouts = restored.layouts
                for id in legacy.items.flatMap(\.accountIDs) { next.setVisible(id, true) }
            }
        } catch { displayError = String(localized: "Could not restore original groups: \(error.localizedDescription)") }
    }
    func updateDisplay(_ change: (inout DisplayConfiguration) -> Void) {
        guard displayWritable else { return }
        var next = displayConfiguration; change(&next)
        if next.layouts != nil { next.freezeBadgeLabels() }
        // An edit that adds a line for an account a group does not hold yet makes it a member, rather than being dropped.
        next.normalizeMembers()
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
                    snapshots[id] = snapshot.failed(Self.hiddenAccountNote, requiresLogin: snapshot.requiresLogin)
                }
            }
            let newlyVisible = current.subtracting(previous)
            for id in newlyVisible {
                if let snapshot = snapshots[id], snapshot.note == Self.hiddenAccountNote {
                    snapshots[id] = snapshot.failed(String(localized: "Cached usage. Waiting for the next refresh."), requiresLogin: snapshot.requiresLogin)
                }
            }
            updateRepresentatives()
            if automaticRefresh { requestRefresh(newlyVisible) }
        }
        catch { displayError = String(localized: "Could not save display settings: \(error.localizedDescription)") }
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
            return .placeholder(for: account.provider).failed(String(localized: "Sign in to connect this account to \(AppInfo.name) in Settings › Accounts."), requiresLogin: true)
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
        catch { errorMessage = String(localized: "Could not save account settings: \(error.localizedDescription)"); return false }
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
        guard account.name == account.identity?.email || account.name == "Current CLI account" else { return account.name }
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

    // What the timer does: usage only, and nothing while the last round is still running. Which account Claude Code uses
    // is read when a person is there to see it (a panel, Settings, a refresh they asked for): reading it runs
    // /usr/bin/security, which has no way to stay quiet if the Keychain wants to ask, and nothing on a timer may bring up
    // a window.
    func refreshOnSchedule() {
        guard !isRefreshing else { return }
        requestRefresh(refreshAccountIDs)
    }

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
                async let antigravity: Void = refreshService(.antigravity, requested: requested)
                _ = await (claude, codex, antigravity)
            }
            isRefreshing = false; lastRefresh = .now; refreshTask = nil
        }
    }
    // A service is asked about one account at a time, and in the app only after resting `requestSpacing` since its last
    // answer. The accounts the menu bar draws go first, so its numbers are the first to be new.
    private func refreshService(_ provider: ProviderKind, requested: Set<UUID>) async {
        let drawn = Set(displayConfiguration.visibleAccountIDs)
        let selected = accounts(for: provider).filter { !$0.deletionPending && requested.contains($0.id) }
        for account in selected.filter({ drawn.contains($0.id) }) + selected.filter({ !drawn.contains($0.id) }) {
            guard let directory = refreshDirectory(for: account) else { continue }
            if let spacing = requestSpacing[provider], let last = lastAnswer[provider], ContinuousClock.now < last + spacing {
                try? await Task.sleep(until: last + spacing, clock: .continuous)
                // The account may have been hidden, deleted or reconnected meanwhile.
                guard refreshDirectory(for: account) != nil else { continue }
            }
            let control = OperationControl(); controls[account.id] = control
            refreshingAccounts.insert(account.id)
            let result: ProviderSnapshot
            if let loadAccount {
                result = await loadAccount(account, control)
            } else if provider == .antigravity {
                result = await AntigravityUsageProvider(expectedIdentity: account.identity).load()
            } else if provider == .codex {
                result = await CodexUsageProvider(directory: directory, expectedIdentity: account.identity, control: control).load()
            } else {
                result = await ClaudeUsageProvider(directory: directory, cacheURL: files.cache(account),
                    expectedIdentity: account.identity, control: control).load()
            }
            lastAnswer[provider] = .now
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
                display = previous.failed(result.note ?? String(localized: "Could not load usage"), requiresLogin: result.requiresLogin)
            }
            snapshots[account.id] = display
            nextEligibleRefresh[account.id] = result.retryAt ?? Date().addingTimeInterval(result.isStale ? 60 : 5)
            if account.isManaged && !result.isStale { try? files.write(result, to: lastGoodURL(account)) }
            updateRepresentatives()
        }
    }
    // What a used coupon changes before the service is asked again: one fewer after a reset, none when the service has
    // none left. After a reset the account's usage is read again at once, past the usual wait and Claude's cache.
    func applyCouponOutcome(_ outcome: CouponOutcome, coupons: UsageResetCoupons, for account: UsageAccount) {
        guard Self.acceptsResult(request: account, current: accounts.first(where: { $0.id == account.id })),
              var snapshot = snapshots[account.id] else { return }
        switch outcome {
        case .reset:
            snapshot.resetCoupons = coupons.usingOne()
            if account.provider == .claude {
                snapshot.resetCoupons?.redeemable = false
                snapshot.resetCoupons?.affectedUsagePercent = nil
            }
        case .noCoupon:
            snapshot.resetCoupons = account.provider == .claude ? coupons.withholdingSelectedOption() : nil
        case .conditionsChanged:
            guard account.provider == .claude, let directory = credentialDirectory(for: account) else { return }
            snapshot.resetCoupons = ClaudeUsageProvider(directory: directory, cacheURL: files.cache(account)).couponRecord()?.coupons
        case .nothingToReset, .signInAgain, .tryLater: return
        }
        snapshots[account.id] = snapshot
        let refreshClaudeCoupons = account.provider == .claude && (outcome == .reset || outcome == .noCoupon)
        guard outcome == .reset || refreshClaudeCoupons else { return }
        nextEligibleRefresh[account.id] = nil
        if refreshClaudeCoupons {
            controls[account.id]?.cancel()
            let cache = files.cache(account)
            ClaudeUsageCache(overrideURL: cache, enabled: true).expire()
            try? FileManager.default.removeItem(at: ClaudeCouponRecord.url(nextTo: cache))
        }
        requestRefresh([account.id])
    }

    // The account's sign-in folder when its usage may be asked for now: it is still to be refreshed, has not been
    // reconnected or deleted since the round began, and is past the wait its last answer set.
    private func refreshDirectory(for account: UsageAccount) -> URL? {
        guard !Task.isCancelled, refreshAccountIDs.contains(account.id),
              Self.acceptsResult(request: account, current: accounts.first(where: { $0.id == account.id })),
              let directory = credentialDirectory(for: account) else { return nil }
        if let next = nextEligibleRefresh[account.id], Date() < next { return nil }
        return directory
    }
    private func configureTimer(interval: Double? = nil) {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: max(60, interval ?? settings.refreshIntervalSeconds), repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshOnSchedule() }
        }
    }

    /// Antigravity is read from the one account signed in to it on this Mac.
    var hasAntigravityAccount: Bool { accounts.contains { $0.provider == .antigravity && !$0.deletionPending } }
    static var antigravityLimitMessage: String {
        String(localized: "Only one Antigravity account is supported: the one signed in to agy or the Antigravity app on this Mac.")
    }

    func startLogin(_ provider: ProviderKind, replacing: UsageAccount? = nil) {
        guard !isLoggingIn, pendingLogin == nil, !storageUnavailable else { return }
        if let replacing, isClaudeCodeLocked(replacing) { errorMessage = claudeCodeBusyMessage(for: .reconnect); return }
        guard provider != .antigravity || replacing != nil || !hasAntigravityAccount else {
            errorMessage = Self.antigravityLimitMessage; return
        }
        do { _ = try ProviderCLI.executable(provider) }
        catch { errorMessage = error.localizedDescription; return }
        let candidate = UsageAccount(id: UUID(), provider: provider, name: String(localized: "New \(provider.displayName) account"), credentialID: UUID())
        do { try files.createPrivateDirectory(files.credentials(candidate.credentialID!)) }
        catch { errorMessage = error.localizedDescription; return }
        var next = registry; next.cleanupPending.append(candidate)
        guard commit(next) else { try? files.removeCredentials(candidate); return }
        let control = OperationControl(); loginControl = control; loginCandidate = candidate
        isLoggingIn = true; errorMessage = nil
        loginMessage = provider == .antigravity ? String(localized: "Reading the account signed in to Antigravity…")
            : String(localized: "Preparing browser sign-in…")
        let directory = files.credentials(candidate.credentialID!)
        let openURL: @Sendable (URL) -> Void = { [weak self] url in
            Task { @MainActor [weak self] in
                guard let self, self.loginControl === control, !control.cancelled else { return }
                self.presentLogin(url, mode: .standard, control: control)
            }
        }
        loginTask = Task { [weak self] in
            let result: Result<(AccountIdentity, [String]?), Error> = await Task.detached(priority: .utility) {
                do {
                    // No sign-in of its own: the account signed in to Antigravity is
                    // read, along with its model groups for the first menu bar lines.
                    if provider == .antigravity {
                        let connected = try await AntigravityUsageProvider().connect()
                        return .success((connected.identity, DisplayMetric.firstLines(connected.snapshot)))
                    }
                    if provider == .codex {
                        let rpc = try CodexRPC(directory: directory, control: control)
                        defer { rpc.stop() }
                        let identity = try rpc.login(openURL: openURL)
                        return .success((identity, nil))
                    }
                    return .success((try ClaudeOAuthLauncher.login(directory: directory, control: control, openURL: openURL), nil))
                } catch { return .failure(error) }
            }.value
            guard let self, self.loginControl === control else { return }
            loginBrowser.close()
            loginAuthorizationURL = nil; canOpenPrivateLogin = false
            if !control.cancelled, case .success(let (identity, firstLines)) = result {
                var completed = candidate; completed.identity = identity
                completed.name = identity.email ?? "\(provider.displayName) account"
                presentCompletedLogin(completed, replacing: replacing?.id, firstLines: firstLines)
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
            loginMessage = String(localized: "Continue in the private window, then return here to confirm the account. (Up to 5 minutes)")
        } else if loginCandidate?.provider == .claude {
            loginMessage = String(localized: "Continue in your browser. To use another account, choose Switch account on Claude’s approval page. This also switches the Claude website login. Return here to confirm. (Up to 5 minutes)")
        } else {
            loginMessage = String(localized: "Choose an account in your browser, or select Sign in with another account. Return here to confirm. (Up to 5 minutes)")
        }
        loginBrowser.open(url, mode: mode, control: control, failed: { [weak self] message in
            self?.errorMessage = message
            self?.canOpenPrivateLogin = false
        }, cancelled: { [weak self] in self?.cancelLogin() })
    }

    func presentCompletedLogin(_ account: UsageAccount, replacing: UUID?, firstLines: [String]? = nil) {
        pendingLogin = PendingAccountLogin(account: account, replacing: replacing, firstLines: firstLines)
        loginMessage = String(localized: "Review the signed-in account, then register it.")
        // Reconnecting an account proven to be the same leaves nothing to review.
        if reconnectionComparison == .same { confirmLogin() }
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
        var next = registry
        var incoming = pending.account
        var added = false
        if let duplicate = next.accounts.first(where: {
            $0.provider == incoming.provider && $0.id != pending.replacing && $0.identity.map { incoming.identity?.comparison(to: $0) == .same } == true
        }) { errorMessage = String(localized: "This account is already registered: \(duplicate.title)"); return }
        if let id = pending.replacing, !addAsNew {
            guard let index = next.accounts.firstIndex(where: { $0.id == id }), !next.accounts[index].deletionPending else { return }
            // The sign-in stays under review until Claude Code is done with the account.
            if isClaudeCodeLocked(next.accounts[index]) { errorMessage = claudeCodeBusyMessage(for: .reconnect); return }
            if reconnectionComparison == .different { errorMessage = String(localized: "This is a different account. Add it as a new account."); return }
            if reconnectionComparison != .same && !replaceUnverified { return }
            let old = next.accounts[index]
            incoming = UsageAccount(id: old.id, provider: old.provider, name: old.name, identity: incoming.identity, credentialID: incoming.credentialID)
            next.accounts[index] = incoming
            if old.isManaged { next.cleanupPending.append(old) }
            controls[id]?.cancel(); snapshots[id] = nil; nextEligibleRefresh[id] = nil
        } else {
            guard incoming.provider != .antigravity || !hasAntigravityAccount else { errorMessage = Self.antigravityLimitMessage; return }
            let hasManaged = next.accounts.contains { $0.provider == incoming.provider && $0.isManaged && !$0.deletionPending }
            next.accounts.append(incoming)
            if !hasManaged { next.representatives[incoming.provider.rawValue] = incoming.id }
            added = true
        }
        next.cleanupPending.removeAll { $0.credentialID == pending.account.credentialID }
        next.repairRepresentatives()
        guard commit(next) else { return }
        if added, let lines = pending.firstLines, lines != ["weekly"] {
            updateDisplay { config in
                // Lines belong to groups, so settle the account-based layout first.
                if config.layouts == nil { config.layouts = config.effectiveLayouts }
                config.setFirstLines(incoming.id, lines)
            }
        }
        pendingLogin = nil; loginMessage = nil
        refreshNow()
        Task { await retryCleanup() }
    }
    func cancelLogin() {
        loginControl?.cancel()
        loginBrowser.close()
        loginAuthorizationURL = nil; canOpenPrivateLogin = false
        if let pending = pendingLogin {
            pendingLogin = nil; loginMessage = nil
            Task { await cleanCandidate(pending.account) }
        } else if isLoggingIn { loginMessage = String(localized: "Cancelling sign-in…") }
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
        let account = registry.accounts[index]
        // A switch or a sign-in for Claude Code that involves this account finishes first. A deletion left from last
        // time is tried again after it, without a word.
        guard !isClaudeCodeLocked(account) else {
            if allowUserInteraction { errorMessage = claudeCodeBusyMessage(for: .delete) }
            return
        }
        deletingIDs.insert(account.id)
        defer { deletingIDs.remove(account.id) }
        var next = registry; next.accounts[index].deletionPending = true; next.repairRepresentatives()
        guard commit(next) else { return }
        controls[account.id]?.cancel(); snapshots[account.id] = nil; updateRepresentatives()
        // Wait for this account's in-flight request before removing its cache directory.
        while refreshingAccounts.contains(account.id) { try? await Task.sleep(for: .milliseconds(100)) }
        let files = files
        // Its sign-in saved for Claude Code goes too. Claude Code's own login stays as it is, even when it is this account.
        let engine = account.provider == .claude ? claudeCode : nil
        let removalLock = lendRemovalLock
        let removal: AccountRemoval = await Task.detached {
            do {
                try files.removeCredentials(account, allowUserInteraction: allowUserInteraction)
                try files.removeUsage(account)
                if let engine { try removalLock.withLock { try engine.removeLendLogin(for: account.id) } }
                return .removed
            } catch is ClaudeCodeBusyError {
                return .waitsForClaudeCode
            } catch { return .failed(error.localizedDescription) }
        }.value
        switch removal {
        case .removed: break
        case .failed(let message): errorMessage = message; return
        case .waitsForClaudeCode:
            // The account stays marked for deletion. A running switch or sign-in clears it when it ends; anything else
            // had the engine only for a moment.
            if claudeCodeActivity == nil && claudeCodePreparation == nil && !claudeCodeStarting {
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(100))
                    await self?.delete(account, allowUserInteraction: false)
                }
            }
            return
        }
        next = registry; next.accounts.removeAll { $0.id == account.id }; next.repairRepresentatives(); _ = commit(next)
    }
    private enum AccountRemoval: Sendable {
        case removed
        case waitsForClaudeCode
        case failed(String)
    }
    func shutdown() {
        refreshTimer?.invalidate(); refreshTask?.cancel(); loginControl?.cancel()
        loginBrowser.close()
        claudeCodePreparation?.control.cancel(); claudeCodeBrowser.close()
        loginAuthorizationURL = nil; canOpenPrivateLogin = false
        controls.values.forEach { $0.cancel() }
    }
}
