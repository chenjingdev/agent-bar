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
    @Published var errorMessage: String?
    @Published private(set) var storageUnavailable = false

    @Published private(set) var displayConfiguration = DisplayConfiguration()
    @Published var displayError: String?
    @Published var displayWidthWarning = false
    private var displayWritable = true

    private let settings: AppSettings
    let files: AccountFiles
    private var refreshTask: Task<Void, Never>?
    private var loginTask: Task<Void, Never>?
    private var loginControl: OperationControl?
    private var loginCandidate: UsageAccount?
    private var controls: [UUID: OperationControl] = [:]
    private var nextEligibleRefresh: [UUID: Date] = [:]
    private var cleaning: Set<UUID> = []
    private var deletingIDs: Set<UUID> = []
    private var pendingRefreshIDs: Set<UUID> = []
    private let automaticRefresh: Bool
    private let loadAccount: (@Sendable (UsageAccount, OperationControl) async -> ProviderSnapshot)?
    private var refreshTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    init(settings: AppSettings, availableProviders: [ProviderKind], files: AccountFiles = AccountFiles(), autoRefresh: Bool = true,
         loadAccount: (@Sendable (UsageAccount, OperationControl) async -> ProviderSnapshot)? = nil) {
        self.settings = settings
        self.automaticRefresh = autoRefresh
        self.loadAccount = loadAccount
        self.files = files
        do {
            var loaded = try files.load()
            for provider in availableProviders where !loaded.accounts.contains(where: { $0.provider == provider && !$0.isManaged }) {
                loaded.accounts.append(.currentCLI(provider))
            }
            loaded.repairRepresentatives()
            try files.write(loaded, to: files.registryURL)
            registry = loaded
            // Only managed accounts have reusable, account-owned snapshots.
            for account in loaded.accounts where account.isManaged && !account.deletionPending {
                if let cached = try? files.read(ProviderSnapshot.self, at: lastGoodURL(account)) {
                    snapshots[account.id] = cached.failed("저장된 값입니다. 최신 사용량을 확인하고 있습니다.")
                }
            }
        } catch { storageUnavailable = true; errorMessage = error.localizedDescription }
        if !storageUnavailable { loadDisplayConfiguration() }
        else { displayWritable = false }
        updateRepresentatives()
        if autoRefresh {
            configureTimer()
            settings.$refreshIntervalSeconds.dropFirst().sink { [weak self] _ in self?.configureTimer() }.store(in: &cancellables)
            refreshNow()
            Task { await retryCleanup() }
        }
    }

    private var displayURL: URL { files.root.appendingPathComponent("display-v1.json") }
    private func loadDisplayConfiguration() {
        do {
            if FileManager.default.fileExists(atPath: displayURL.path) {
                let loaded = try files.read(DisplayConfiguration.self, at: displayURL)
                guard loaded.valid else { throw AccountError.message("표시 설정 형식이 올바르지 않습니다.") }
                displayConfiguration = loaded
                updateDisplay { $0.prune(Set(accounts.filter { !$0.deletionPending }.map(\.id))) }
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
            displayError = "표시 설정을 읽지 못해 기본 표시로 복구했습니다. 원본을 보존했습니다."
        }
    }
    func updateDisplay(_ change: (inout DisplayConfiguration) -> Void) {
        guard displayWritable else { return }
        var next = displayConfiguration; change(&next)
        guard next.valid else { return }
        do {
            try files.write(next, to: displayURL)
            let previous = refreshAccountIDs
            displayConfiguration = next
            let current = refreshAccountIDs
            for id in previous.subtracting(current) {
                controls[id]?.cancel()
                pendingRefreshIDs.remove(id)
                if let snapshot = snapshots[id] {
                    if !snapshot.isStale && snapshot.retryAt == nil { nextEligibleRefresh[id] = nil }
                    snapshots[id] = snapshot.failed("숨긴 계정입니다. 새로고침이 중단되었습니다.")
                }
            }
            updateRepresentatives()
            if automaticRefresh { requestRefresh(current.subtracting(previous)) }
        }
        catch { displayError = "표시 설정 저장 실패: \(error.localizedDescription)" }
    }
    func displayAccounts(_ item: DisplayItem) -> [UsageAccount] {
        item.accountIDs.compactMap { id in accounts.first { $0.id == id && !$0.deletionPending } }
    }
    func displayRows(_ item: DisplayItem) -> [DisplayRow] {
        DisplayRow.make(item: item, accounts: accounts, snapshots: snapshots, config: displayConfiguration)
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
        snapshots[account.id] ?? .placeholder(for: account.provider)
    }
    private func lastGoodURL(_ account: UsageAccount) -> URL {
        files.cache(account).deletingLastPathComponent().appendingPathComponent("last-good.json")
    }
    @discardableResult
    private func commit(_ value: AccountRegistry) -> Bool {
        guard !storageUnavailable else { return false }
        do { try files.write(value, to: files.registryURL); registry = value; updateDisplay { $0.prune(Set(value.accounts.filter { !$0.deletionPending }.map(\.id))) }; updateRepresentatives(); return true }
        catch { errorMessage = "계정 설정을 저장하지 못했습니다: \(error.localizedDescription)"; return false }
    }
    func selectRepresentative(_ account: UsageAccount) {
        guard !account.deletionPending else { return }
        var next = registry; next.representatives[account.provider.rawValue] = account.id; _ = commit(next)
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
        displayConfiguration.refreshAccountIDs.intersection(accounts.filter { !$0.deletionPending }.map(\.id))
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
            if let next = nextEligibleRefresh[account.id], Date() < next { continue }
            let control = OperationControl(); controls[account.id] = control
            refreshingAccounts.insert(account.id)
            let directory = account.credentialID.map { files.credentials($0) }
            let result: ProviderSnapshot
            if let loadAccount {
                result = await loadAccount(account, control)
            } else if provider == .codex {
                result = await CodexUsageProvider(directory: directory, expectedIdentity: account.identity, control: control).load()
            } else {
                result = await ClaudeUsageProvider(directory: directory, cacheURL: files.cache(account), expectedIdentity: account.identity).load()
            }
            controls[account.id] = nil; refreshingAccounts.remove(account.id)
            guard !control.cancelled, refreshAccountIDs.contains(account.id), Self.acceptsResult(request: account, current: accounts.first(where: { $0.id == account.id })) else { continue }
            var display = result
            if result.isStale, account.isManaged, result.fiveHour?.utilization == nil, result.weekly?.utilization == nil,
               let previous = snapshots[account.id], previous.fiveHour?.utilization != nil || previous.weekly?.utilization != nil {
                display = previous.failed(result.note ?? "사용량 조회 실패", requiresLogin: result.requiresLogin)
            }
            // CLI accounts never carry a previous account's fallback across a refresh.
            snapshots[account.id] = display
            nextEligibleRefresh[account.id] = result.retryAt ?? Date().addingTimeInterval(result.isStale ? 60 : 5)
            if account.isManaged && !result.isStale { try? files.write(result, to: lastGoodURL(account)) }
            updateRepresentatives()
        }
    }
    private func configureTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: max(60, settings.refreshIntervalSeconds), repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in if self?.isRefreshing == false { self?.refreshNow() } }
        }
    }

    func startLogin(_ provider: ProviderKind, replacing: UsageAccount? = nil) {
        guard !isLoggingIn, pendingLogin == nil, !storageUnavailable else { return }
        do { _ = try ProviderCLI.executable(provider) }
        catch { errorMessage = error.localizedDescription; return }
        let candidate = UsageAccount(id: UUID(), provider: provider, name: "새 \(provider.displayName) 계정", credentialID: UUID())
        do { try files.createPrivateDirectory(files.credentials(candidate.credentialID!)) }
        catch { errorMessage = error.localizedDescription; return }
        var next = registry; next.cleanupPending.append(candidate)
        guard commit(next) else { try? files.removeCredentials(candidate); return }
        let control = OperationControl(); loginControl = control; loginCandidate = candidate
        isLoggingIn = true; errorMessage = nil
        loginMessage = "분리된 새 로그인 창에서 \(provider.displayName) 계정을 선택하세요. 기존 브라우저 로그인은 공유하지 않습니다. (최대 5분)"
        let directory = files.credentials(candidate.credentialID!)
        let openURL: @Sendable (URL) -> Void = { [weak self] url in
            Task { @MainActor [weak self] in
                guard let self, !control.cancelled else { return }
                IsolatedLoginWindow.shared.open(url, control: control) { [weak self] message in
                    self?.errorMessage = message
                }
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
            guard let self else { return }
            isLoggingIn = false; loginTask = nil
            IsolatedLoginWindow.shared.finish()
            if !control.cancelled, case .success(let identity) = result {
                var completed = candidate; completed.identity = identity
                completed.name = identity.email ?? "\(provider.displayName) 계정"
                pendingLogin = PendingAccountLogin(account: completed, replacing: replacing?.id)
                loginMessage = "로그인한 계정 정보를 확인한 뒤 등록하세요."
            } else {
                loginMessage = nil
                if !control.cancelled, case .failure(let error) = result { errorMessage = error.localizedDescription }
                await cleanCandidate(candidate)
            }
            loginControl = nil; loginCandidate = nil
        }
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
        }) { errorMessage = "이미 등록된 계정입니다: \(duplicate.title)"; return }
        if let id = pending.replacing, !addAsNew {
            guard let index = next.accounts.firstIndex(where: { $0.id == id }), !next.accounts[index].deletionPending else { return }
            if reconnectionComparison == .different { errorMessage = "다른 계정입니다. 새 계정으로 추가하세요."; return }
            if reconnectionComparison != .same && !replaceUnverified { return }
            let old = next.accounts[index]
            incoming = UsageAccount(id: old.id, provider: old.provider, name: old.name, identity: incoming.identity, credentialID: incoming.credentialID)
            next.accounts[index] = incoming; next.cleanupPending.append(old)
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
        IsolatedLoginWindow.shared.finish()
        loginControl?.cancel()
        if let pending = pendingLogin {
            pendingLogin = nil; loginMessage = nil
            Task { await cleanCandidate(pending.account) }
        } else if isLoggingIn { loginMessage = "로그인을 취소하고 있습니다…" }
    }
    private func cleanCandidate(_ account: UsageAccount) async {
        guard let credentialID = account.credentialID, !cleaning.contains(credentialID) else { return }
        cleaning.insert(credentialID)
        defer { cleaning.remove(credentialID) }
        while refreshingAccounts.contains(account.id) { try? await Task.sleep(for: .milliseconds(100)) }
        let files = files
        let error: String? = await Task.detached {
            do {
                try files.removeCredentials(account)
                let cacheDirectory = files.cache(account).deletingLastPathComponent()
                if FileManager.default.fileExists(atPath: cacheDirectory.path) { try FileManager.default.removeItem(at: cacheDirectory) }
                return nil
            }
            catch { return error.localizedDescription }
        }.value
        if let error { errorMessage = error; return }
        var next = registry; next.cleanupPending.removeAll { $0.credentialID == account.credentialID }; _ = commit(next)
    }
    func retryCleanup() async {
        for account in registry.cleanupPending where account.credentialID != loginCandidate?.credentialID && account.credentialID != pendingLogin?.account.credentialID {
            await cleanCandidate(account)
        }
        for account in accounts where account.deletionPending { await delete(account) }
    }
    func delete(_ account: UsageAccount) async {
        guard account.isManaged, !deletingIDs.contains(account.id), let index = registry.accounts.firstIndex(where: { $0.id == account.id }) else { return }
        deletingIDs.insert(account.id)
        defer { deletingIDs.remove(account.id) }
        var next = registry; next.accounts[index].deletionPending = true; next.repairRepresentatives()
        guard commit(next) else { return }
        controls[account.id]?.cancel(); snapshots[account.id] = nil; updateRepresentatives()
        // Wait for this account's in-flight request before removing its cache directory.
        while refreshingAccounts.contains(account.id) { try? await Task.sleep(for: .milliseconds(100)) }
        let files = files
        let error: String? = await Task.detached {
            do { try files.removeCredentials(account); try files.removeUsage(account); return nil }
            catch { return error.localizedDescription }
        }.value
        if let error { errorMessage = error; return }
        next = registry; next.accounts.removeAll { $0.id == account.id }; next.repairRepresentatives(); _ = commit(next)
    }
    func shutdown() {
        IsolatedLoginWindow.shared.finish()
        refreshTimer?.invalidate(); refreshTask?.cancel(); loginControl?.cancel()
        controls.values.forEach { $0.cancel() }
    }
}
