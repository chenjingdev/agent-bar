import AppKit
import Combine
import Foundation

struct PendingAccountLogin {
    var account: UsageAccount
    var replacing: UUID?
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
    private var cleaning: Set<UUID> = []
    private var deletingIDs: Set<UUID> = []
    private var pendingRefreshIDs: Set<UUID> = []
    private let automaticRefresh: Bool
    private let loadAccount: (@Sendable (UsageAccount, OperationControl) async -> ProviderSnapshot)?
    private var refreshTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    init(settings: AppSettings, files: AccountFiles = AccountFiles(), autoRefresh: Bool = true,
         loadAccount: (@Sendable (UsageAccount, OperationControl) async -> ProviderSnapshot)? = nil) {
        self.settings = settings
        self.automaticRefresh = autoRefresh
        self.loadAccount = loadAccount
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
            configureTimer()
            settings.$refreshIntervalSeconds.dropFirst().sink { [weak self] interval in self?.configureTimer(interval: interval) }.store(in: &cancellables)
            refreshNow()
            Task { await retryCleanup(allowUserInteraction: false) }
        }
    }

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
                if loaded.layouts != nil { loaded.freezeBadgeLabels() }
                if loaded != original {
                    try FileManager.default.copyItem(at: displayURL, to: files.root.appendingPathComponent("display-before-three-lines-\(UUID()).json"))
                }
                guard loaded.valid else { throw AccountError.message("Invalid display settings format.") }
                displayConfiguration = loaded
                updateDisplay { $0.sync(liveAccounts) }
            } else if FileManager.default.fileExists(atPath: legacyDisplayURL.path) {
                // The item-based file stays untouched so the previous version can still read it.
                let legacy = try files.read(LegacyDisplayConfiguration.self, at: legacyDisplayURL)
                guard legacy.valid else { throw AccountError.message("Invalid original layout.") }
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
            displayError = "Could not read display settings. Using defaults; the original was preserved."
        }
    }
    var hasOriginalDisplayConfiguration: Bool {
        FileManager.default.fileExists(atPath: legacyDisplayURL.path)
    }
    func restoreOriginalDisplayConfiguration() {
        guard displayWritable else { return }
        do {
            let legacy = try files.read(LegacyDisplayConfiguration.self, at: legacyDisplayURL)
            guard legacy.valid else { throw AccountError.message("Invalid original layout.") }
            let restored = DisplayConfiguration.migrated(from: legacy, accounts: liveAccounts)
            if FileManager.default.fileExists(atPath: displayURL.path) {
                try FileManager.default.copyItem(at: displayURL, to: files.root.appendingPathComponent("display-before-restore-\(UUID()).json"))
            }
            updateDisplay { next in
                next.layouts = restored.layouts
                for id in legacy.items.flatMap(\.accountIDs) { next.setVisible(id, true) }
            }
        } catch { displayError = "Could not restore original groups: \(error.localizedDescription)" }
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

    func refreshNow() { requestRefresh(refreshAccountIDs) }

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
                result = await CodexUsageProvider(directory: directory, expectedIdentity: account.identity, control: control).load()
            } else {
                result = await ClaudeUsageProvider(directory: directory, cacheURL: files.cache(account),
                    expectedIdentity: account.identity, control: control).load()
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
    private func configureTimer(interval: Double? = nil) {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: max(60, interval ?? settings.refreshIntervalSeconds), repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in if self?.isRefreshing == false { self?.refreshNow() } }
        }
    }

    func startLogin(_ provider: ProviderKind, replacing: UsageAccount? = nil) {
        guard !isLoggingIn, pendingLogin == nil, !storageUnavailable else { return }
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
                pendingLogin = PendingAccountLogin(account: completed, replacing: replacing?.id)
                loginMessage = "Review the signed-in account, then register it."
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
            controls[id]?.cancel(); snapshots[id] = nil; nextEligibleRefresh[id] = nil
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
        Task { await retryCleanup() }
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
        let account = registry.accounts[index]
        deletingIDs.insert(account.id)
        defer { deletingIDs.remove(account.id) }
        var next = registry; next.accounts[index].deletionPending = true; next.repairRepresentatives()
        guard commit(next) else { return }
        controls[account.id]?.cancel(); snapshots[account.id] = nil; updateRepresentatives()
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
    func shutdown() {
        refreshTimer?.invalidate(); refreshTask?.cancel(); loginControl?.cancel()
        loginBrowser.close()
        loginAuthorizationURL = nil; canOpenPrivateLogin = false
        controls.values.forEach { $0.cancel() }
    }
}
