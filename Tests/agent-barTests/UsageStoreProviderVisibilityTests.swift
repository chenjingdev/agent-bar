import Foundation
import Testing
@testable import agent_bar

@MainActor
struct UsageStoreProviderVisibilityTests {
    @Test("Manual refresh loads only available enabled providers")
    func manualRefreshLoadsOnlyAvailableEnabledProviders() async {
        let settings = AppSettings(
            availableProviders: [.claude, .codex],
            defaults: createTestDefaults()
        )
        let claudeProvider = RecordingUsageProvider(provider: .claude)
        let codexProvider = RecordingUsageProvider(provider: .codex)
        let store = UsageStore(
            settings: settings,
            availableProviders: [.claude],
            claudeProvider: claudeProvider,
            codexProvider: codexProvider,
            refreshOnInit: false
        )

        await store.refresh()

        #expect(await claudeProvider.loadCount() == 1)
        #expect(await codexProvider.loadCount() == 0)
    }

    @Test("Visual component changes do not load providers")
    func visualComponentChangesDoNotLoadProviders() async {
        let settings = AppSettings(
            availableProviders: [.claude, .codex],
            defaults: createTestDefaults()
        )
        let claudeProvider = RecordingUsageProvider(provider: .claude)
        let codexProvider = RecordingUsageProvider(provider: .codex)
        let store = UsageStore(
            settings: settings,
            availableProviders: [.claude, .codex],
            claudeProvider: claudeProvider,
            codexProvider: codexProvider,
            refreshOnInit: false
        )

        await store.refresh()
        let changed = settings.setComponentShown(.claude, component: .badge, shown: false)

        #expect(changed == true)
        #expect(await claudeProvider.loadCount() == 1)
        #expect(await codexProvider.loadCount() == 1)
    }

    @Test("Disabling a provider prevents it from loading")
    func disablingProviderPreventsItFromLoading() async {
        let settings = AppSettings(
            availableProviders: [.claude, .codex],
            defaults: createTestDefaults()
        )
        let claudeProvider = RecordingUsageProvider(provider: .claude)
        let codexProvider = RecordingUsageProvider(provider: .codex)
        let store = UsageStore(
            settings: settings,
            availableProviders: [.claude, .codex],
            claudeProvider: claudeProvider,
            codexProvider: codexProvider,
            refreshOnInit: false
        )

        let disabled = settings.setProviderEnabled(.claude, enabled: false)
        await store.refresh()

        #expect(disabled == true)
        #expect(await claudeProvider.loadCount() == 0)
        #expect(await codexProvider.loadCount() == 1)
    }

    @Test("Re-enabling during an in-flight refresh loads before the store becomes idle")
    func reenablingProviderDuringRefreshLoadsBeforeStoreBecomesIdle() async throws {
        let settings = AppSettings(
            availableProviders: [.claude, .codex],
            defaults: createTestDefaults()
        )
        let claudeProvider = RecordingUsageProvider(provider: .claude)
        let codexProvider = RecordingUsageProvider(provider: .codex, suspendsLoads: true)
        let store = UsageStore(
            settings: settings,
            availableProviders: [.claude, .codex],
            claudeProvider: claudeProvider,
            codexProvider: codexProvider,
            refreshOnInit: false
        )
        let initiallyDisabled = settings.setProviderEnabled(.claude, enabled: false)
        let idleSignal = RefreshIdleSignal()
        let idleCancellable = store.$isRefreshing.sink { isRefreshing in
            idleSignal.observe(isRefreshing)
        }
        let codexSuspended = Task { await codexProvider.waitUntilSuspended() }
        let refreshTask = Task { @MainActor in
            await store.refresh()
        }

        await codexSuspended.value
        let reenabled = settings.setProviderEnabled(.claude, enabled: true)
        await codexProvider.resumeLoad()
        try await awaitIdle(idleSignal)
        await refreshTask.value

        #expect(initiallyDisabled == true)
        #expect(reenabled == true)
        #expect(await claudeProvider.loadCount() == 1)
        idleCancellable.cancel()
    }

    @Test("Re-enabling a provider immediately loads only that provider once")
    func reenablingProviderImmediatelyLoadsOnlyThatProviderOnce() async {
        let settings = AppSettings(
            availableProviders: [.claude, .codex],
            defaults: createTestDefaults()
        )
        let claudeProvider = RecordingUsageProvider(provider: .claude)
        let codexProvider = RecordingUsageProvider(provider: .codex)
        let store = UsageStore(
            settings: settings,
            availableProviders: [.claude, .codex],
            claudeProvider: claudeProvider,
            codexProvider: codexProvider,
            refreshOnInit: false
        )

        let disabled = settings.setProviderEnabled(.claude, enabled: false)
        let nextClaudeLoad = Task { await claudeProvider.waitForLoad(after: 0) }
        let enabled = settings.setProviderEnabled(.claude, enabled: true)
        let observedLoadCount = await nextClaudeLoad.value
        withExtendedLifetime(store) {}

        #expect(disabled == true)
        #expect(enabled == true)
        #expect(observedLoadCount == 1)
        #expect(await claudeProvider.loadCount() == 1)
        #expect(await codexProvider.loadCount() == 0)
    }

    private func createTestDefaults() -> UserDefaults {
        let identifier = "UsageStoreProviderVisibilityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: identifier)!
        defaults.removePersistentDomain(forName: identifier)
        return defaults
    }
}

private actor RecordingUsageProvider: UsageProviding {
    private let snapshot: ProviderSnapshot
    private let suspendsLoads: Bool
    private var loads = 0
    private var isSuspended = false
    private var releaseRequested = false
    private var loadWaiters: [(after: Int, continuation: CheckedContinuation<Int, Never>)] = []
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(provider: ProviderKind, suspendsLoads: Bool = false) {
        self.snapshot = .placeholder(for: provider)
        self.suspendsLoads = suspendsLoads
    }

    func load() async -> ProviderSnapshot {
        loads += 1
        let readyWaiters = loadWaiters.filter { loads > $0.after }
        loadWaiters.removeAll { loads > $0.after }
        for waiter in readyWaiters {
            waiter.continuation.resume(returning: loads)
        }

        if suspendsLoads {
            isSuspended = true
            let waiters = suspensionWaiters
            suspensionWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            await withCheckedContinuation { continuation in
                if releaseRequested {
                    continuation.resume()
                } else {
                    releaseContinuation = continuation
                }
            }
        }

        return snapshot
    }

    func loadCount() -> Int {
        loads
    }

    func waitForLoad(after count: Int) async -> Int {
        guard loads <= count else { return loads }
        return await withCheckedContinuation { continuation in
            loadWaiters.append((after: count, continuation: continuation))
        }
    }

    func waitUntilSuspended() async {
        guard isSuspended == false else { return }
        await withCheckedContinuation { continuation in
            suspensionWaiters.append(continuation)
        }
    }

    func resumeLoad() {
        if let releaseContinuation {
            self.releaseContinuation = nil
            releaseContinuation.resume()
        } else {
            releaseRequested = true
        }
    }
}

@MainActor
private final class RefreshIdleSignal {
    private var hasRefreshed = false
    private var isIdle = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func observe(_ isRefreshing: Bool) {
        if isRefreshing {
            hasRefreshed = true
        } else if hasRefreshed {
            isIdle = true
            let waiters = waiters
            self.waiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    func waitForIdle() async {
        guard isIdle == false else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private enum RefreshTimeoutError: Error {
    case elapsed
}

@MainActor
private func awaitIdle(_ signal: RefreshIdleSignal) async throws {
    try await withCheckedThrowingContinuation { continuation in
        let completion = IdleWaitCompletion(continuation: continuation)
        completion.startTimeout()
        Task { @MainActor in
            await signal.waitForIdle()
            completion.succeed()
        }
    }
}

@MainActor
private final class IdleWaitCompletion {
    private let continuation: CheckedContinuation<Void, Error>
    private var isCompleted = false
    private var timeoutTask: Task<Void, Never>?

    init(continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func startTimeout() {
        timeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            self?.fail()
        }
    }

    func succeed() {
        complete(with: .success(()))
    }

    private func fail() {
        complete(with: .failure(RefreshTimeoutError.elapsed))
    }

    private func complete(with result: Result<Void, Error>) {
        guard isCompleted == false else { return }
        isCompleted = true
        timeoutTask?.cancel()
        continuation.resume(with: result)
    }
}
