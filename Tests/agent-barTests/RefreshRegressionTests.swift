import Foundation
import Testing
@testable import agent_bar

@MainActor struct RefreshRegressionTests {
    @Test func refreshIntervalChangeAppliesNewValue() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let store = UsageStore(settings: settings, availableProviders: [], files: AccountFiles(root: root))
        defer { store.shutdown() }
        settings.refreshIntervalSeconds = 300
        let raw = try #require(Mirror(reflecting: store).children.first { $0.label == "refreshTimer" }?.value)
        let timer = try #require(raw as? Timer)
        #expect(timer.timeInterval == 300)
    }
    @Test func showingAnAccountClearsPausedMessageWithoutLosingLoginState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let files = AccountFiles(root: root)
        let account = UsageAccount(id: UUID(), provider: .codex, name: "Fixture")
        var registry = AccountRegistry(accounts: [account]); registry.repairRepresentatives()
        try files.write(registry, to: files.registryURL)
        let store = UsageStore(settings: AppSettings(defaults: defaults), availableProviders: [], files: files, autoRefresh: false,
                               loadAccount: { _, _ in ProviderSnapshot.placeholder(for: .codex).failed("Sign-in required", requiresLogin: true) })
        defer { store.shutdown() }
        await store.refresh()
        store.updateDisplay { $0.resize(1) }
        #expect(store.snapshot(for: account).requiresLogin)
        store.updateDisplay { $0.resize(2) }
        #expect(store.snapshot(for: account).requiresLogin)
        #expect(store.snapshot(for: account).note == "Cached usage. Waiting for the next refresh.")
    }

    @Test func hiddenInflightRateLimitRetainsRetryDeadline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let files = AccountFiles(root: root), loader = LimitedResponseLoader()
        let account = UsageAccount(id: UUID(), provider: .codex, name: "Fixture")
        var registry = AccountRegistry(accounts: [account]); registry.repairRepresentatives()
        try files.write(registry, to: files.registryURL)
        let store = UsageStore(settings: AppSettings(defaults: defaults), availableProviders: [], files: files, autoRefresh: false,
                               loadAccount: { _, _ in await loader.load() })
        defer { store.shutdown() }
        let task = Task { await store.refresh() }
        let deadline = Date().addingTimeInterval(2)
        while await loader.calls == 0 {
            if Date() > deadline { throw AccountError.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
        store.updateDisplay { $0.resize(1) }
        await loader.release()
        await task.value
        store.updateDisplay { $0.resize(2) }
        await store.refresh()
        #expect(await loader.calls == 1)
    }
}
private actor LimitedResponseLoader {
    var calls = 0
    private var released = false
    func release() { released = true }
    func load() async -> ProviderSnapshot {
        calls += 1
        let deadline = Date().addingTimeInterval(2)
        while !released && Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        var result = ProviderSnapshot.placeholder(for: .codex).failed("rate limited")
        result.retryAt = Date().addingTimeInterval(600)
        return result
    }
}
