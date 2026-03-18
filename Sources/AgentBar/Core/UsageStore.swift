import Combine
import Foundation

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var claudeSnapshot = ProviderSnapshot.placeholder(for: .claude)
    @Published private(set) var codexSnapshot = ProviderSnapshot.placeholder(for: .codex)
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var isRefreshing = false

    private let settings: AppSettings
    private let claudeProvider = ClaudeUsageProvider()
    private let codexProvider = CodexUsageProvider()

    private var refreshTask: Task<Void, Never>?
    private var refreshTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    init(settings: AppSettings) {
        self.settings = settings
        bindSettings()
        configureTimer()
        refreshNow()
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
        guard refreshTask == nil else { return }

        isRefreshing = true
        refreshTask = Task { [weak self] in
            guard let self else { return }

            async let claude = claudeProvider.load()
            async let codex = codexProvider.load()
            let (claudeSnapshot, codexSnapshot) = await (claude, codex)

            guard Task.isCancelled == false else { return }

            self.claudeSnapshot = claudeSnapshot
            self.codexSnapshot = codexSnapshot
            self.lastRefresh = .now
            self.isRefreshing = false
            self.refreshTask = nil
        }
    }

    private func bindSettings() {
        settings.$refreshIntervalSeconds
            .dropFirst()
            .sink { [weak self] _ in
                self?.configureTimer()
            }
            .store(in: &cancellables)

        settings.objectWillChange
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshNow()
            }
            .store(in: &cancellables)
    }

    private func configureTimer() {
        refreshTimer?.invalidate()
        let interval = max(settings.refreshIntervalSeconds, 60)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshNow()
            }
        }
    }
}
