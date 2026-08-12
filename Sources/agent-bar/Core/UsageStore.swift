import Combine
import Foundation

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var claudeSnapshot = ProviderSnapshot.placeholder(for: .claude)
    @Published private(set) var codexSnapshot = ProviderSnapshot.placeholder(for: .codex)
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var isRefreshing = false

    private let settings: AppSettings
    private let availableProviders: Set<ProviderKind>
    private let claudeProvider: any UsageProviding
    private let codexProvider: any UsageProviding

    private var enabledProviders: Set<ProviderKind>
    private var pendingProviders = Set<ProviderKind>()
    private var refreshTask: Task<Void, Never>?
    private var refreshTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    init(
        settings: AppSettings,
        availableProviders: [ProviderKind],
        claudeProvider: any UsageProviding,
        codexProvider: any UsageProviding,
        refreshOnInit: Bool = true
    ) {
        self.settings = settings
        self.availableProviders = Set(availableProviders)
        self.claudeProvider = claudeProvider
        self.codexProvider = codexProvider
        self.enabledProviders = Set(
            availableProviders.filter { settings.getProviderDisplaySettings($0).isEnabled }
        )
        bindSettings()
        configureTimer()

        if refreshOnInit {
            refreshNow()
        }
    }

    func snapshot(for provider: ProviderKind) -> ProviderSnapshot {
        switch provider {
        case .claude:
            return claudeSnapshot
        case .codex:
            return codexSnapshot
        }
    }

    func refreshNow() {
        Task { @MainActor [weak self] in
            await self?.refresh()
        }
    }

    func refresh() async {
        await refresh(only: availableProviders)
    }

    private func refresh(only requestedProviders: Set<ProviderKind>) async {
        requestRefresh(only: requestedProviders)
        await refreshTask?.value
    }

    private func requestRefresh(only requestedProviders: Set<ProviderKind>) {
        pendingProviders.formUnion(requestedProviders)

        guard refreshTask == nil else { return }

        isRefreshing = true
        refreshTask = Task { @MainActor [weak self] in
            await self?.drainRefreshQueue()
        }
    }

    private func drainRefreshQueue() async {
        defer {
            isRefreshing = false
            refreshTask = nil
        }

        while pendingProviders.isEmpty == false {
            let requestedProviders = pendingProviders
            pendingProviders.removeAll()
            let claudeProvider = self.claudeProvider
            let codexProvider = self.codexProvider
            var nextClaudeSnapshot = claudeSnapshot
            var nextCodexSnapshot = codexSnapshot
            var loadedProviders = Set<ProviderKind>()

            if shouldRefresh(.claude, requestedProviders: requestedProviders) {
                nextClaudeSnapshot = await claudeProvider.load()
                loadedProviders.insert(.claude)
            }

            if shouldRefresh(.codex, requestedProviders: requestedProviders) {
                nextCodexSnapshot = await codexProvider.load()
                loadedProviders.insert(.codex)
            }

            guard Task.isCancelled == false else { return }

            if loadedProviders.contains(.claude),
               settings.getProviderDisplaySettings(.claude).isEnabled {
                claudeSnapshot = nextClaudeSnapshot
            }
            if loadedProviders.contains(.codex),
               settings.getProviderDisplaySettings(.codex).isEnabled {
                codexSnapshot = nextCodexSnapshot
            }
            lastRefresh = .now
        }
    }

    private func shouldRefresh(
        _ provider: ProviderKind,
        requestedProviders: Set<ProviderKind>
    ) -> Bool {
        requestedProviders.contains(provider)
            && availableProviders.contains(provider)
            && settings.getProviderDisplaySettings(provider).isEnabled
    }

    private func bindSettings() {
        settings.$refreshIntervalSeconds
            .dropFirst()
            .sink { [weak self] _ in
                self?.configureTimer()
            }
            .store(in: &cancellables)

        settings.$providerSettings
            .dropFirst()
            .sink { [weak self] providerSettings in
                self?.providerSettingsDidChange(providerSettings)
            }
            .store(in: &cancellables)
    }

    private func providerSettingsDidChange(_ providerSettings: [ProviderKind: ProviderDisplaySettings]) {
        let nextEnabledProviders = Set(
            availableProviders.filter { providerSettings[$0]?.isEnabled == true }
        )
        let newlyEnabledProviders = nextEnabledProviders.subtracting(enabledProviders)
        enabledProviders = nextEnabledProviders

        guard newlyEnabledProviders.isEmpty == false else { return }

        requestRefresh(only: newlyEnabledProviders)
    }

    private func configureTimer() {
        refreshTimer?.invalidate()
        let interval = max(settings.refreshIntervalSeconds, 60)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
    }
}
