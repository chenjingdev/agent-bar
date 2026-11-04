import Combine
import Foundation
import Testing
@testable import agent_bar

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct UsageStoreProviderVisibilityTests {
    @Test func hiddenAccountsAreSkippedByManualRefresh() async throws {
        let fixture = try VisibilityFixture()
        defer { fixture.close() }
        fixture.store.updateDisplay { $0.setVisible(fixture.codex.id, false) }
        await fixture.store.refresh()
        #expect(await fixture.loader.count(fixture.claude.id) == 1)
        #expect(await fixture.loader.count(fixture.codex.id) == 0)
    }

    @Test func missingMetricDataDoesNotStopRefresh() async throws {
        let fixture = try VisibilityFixture()
        defer { fixture.close() }
        fixture.store.updateDisplay { $0.setVisible(fixture.claude.id, false); $0.update(fixture.codex.id) { $0.primary = "5h" } }
        // The loader reports weekly only, but polling must discover 5h data arriving later.
        await fixture.store.refresh()
        #expect(await fixture.loader.count(fixture.codex.id) == 1)
        #expect(await fixture.loader.count(fixture.claude.id) == 0)
        #expect(fixture.store.menuBarEntry(for: fixture.codex).metric.id == "weekly")
    }

    @Test func hidingAnInflightAccountCancelsAndDiscardsItsResult() async throws {
        let fixture = try VisibilityFixture(suspend: true)
        defer { fixture.close() }
        let task = Task { await fixture.store.refresh() }
        await fixture.loader.waitForLoad(fixture.claude.id)
        fixture.store.updateDisplay { $0.setVisible(fixture.claude.id, false) }
        #expect(await fixture.loader.wasCancelled(fixture.claude.id))
        await fixture.loader.release()
        await task.value
        #expect(fixture.store.snapshots[fixture.claude.id] == nil)
        #expect(fixture.store.snapshots[fixture.codex.id] != nil)
    }

    @Test func hidingAQueuedAccountPreventsItsRequest() async throws {
        let fixture = try VisibilityFixture(suspend: true, sameProvider: true)
        defer { fixture.close() }
        let task = Task { await fixture.store.refresh() }
        await fixture.loader.waitForLoad(fixture.claude.id)
        fixture.store.updateDisplay { $0.setVisible(fixture.codex.id, false) }
        await fixture.loader.release()
        await task.value
        #expect(await fixture.loader.count(fixture.codex.id) == 0)
    }

    @Test func showingAnAccountDuringRefreshQueuesOnlyThatAccount() async throws {
        let fixture = try VisibilityFixture(suspend: true, automatic: true)
        defer { fixture.close() }
        fixture.store.updateDisplay { $0.setVisible(fixture.codex.id, false) }
        await fixture.loader.waitForLoad(fixture.claude.id)
        fixture.store.updateDisplay { $0.setVisible(fixture.codex.id, true) }
        await fixture.loader.release()
        await fixture.waitForRefreshToFinish()
        #expect(await fixture.loader.count(fixture.claude.id) == 1)
        #expect(await fixture.loader.count(fixture.codex.id) == 1)
    }

    @Test func visualChangesDoNotRefetchAndReenabledAccountRefreshes() async throws {
        let fixture = try VisibilityFixture(automatic: true)
        defer { fixture.close() }
        await fixture.waitForRefreshToFinish()
        fixture.store.updateDisplay { $0.showPercent = false; $0.update(fixture.codex.id) { $0.color = .teal }; $0.move(fixture.codex.id, offset: -1) }
        #expect(!fixture.store.isRefreshing)
        fixture.store.updateDisplay { $0.setVisible(fixture.codex.id, false) }
        fixture.store.updateDisplay { $0.setVisible(fixture.codex.id, true) }
        await fixture.waitForRefreshToFinish()
        #expect(await fixture.loader.count(fixture.claude.id) == 1)
        #expect(await fixture.loader.count(fixture.codex.id) == 2)
    }

    @Test func newDisplayFileIgnoresAndKeepsOldProviderPreferences() throws {
        let fixture = try VisibilityFixture()
        defer { fixture.close() }
        let defaults = fixture.defaults
        let old = ["provider_claude_enabled", "provider_codex_component_badge", "provider_codex_component_percentage"]
        for key in old { defaults.set(false, forKey: key) }
        try FileManager.default.removeItem(at: fixture.files.root.appendingPathComponent("display-v2.json"))
        let settings = AppSettings(defaults: defaults)
        let store = UsageStore(settings: settings, files: fixture.files, autoRefresh: false)
        #expect(store.displayConfiguration == DisplayConfiguration.initial(store.registry))
        #expect(store.displayConfiguration.visibleAccountIDs == [fixture.claude.id, fixture.codex.id])
        #expect(store.displayConfiguration.showBar && store.displayConfiguration.showPercent)
        #expect(old.allSatisfy { defaults.object(forKey: $0) as? Bool == false })
        let reloaded = UsageStore(settings: settings, files: fixture.files, autoRefresh: false)
        #expect(reloaded.displayConfiguration == store.displayConfiguration)
    }

    @Test func invalidAccountRegistryDoesNotEraseDisplayAssignments() throws {
        let fixture = try VisibilityFixture()
        defer { fixture.close() }
        let displayURL = fixture.files.root.appendingPathComponent("display-v2.json")
        let before = try Data(contentsOf: displayURL)
        try Data("{bad".utf8).write(to: fixture.files.registryURL)
        let store = UsageStore(settings: AppSettings(defaults: fixture.defaults), files: fixture.files, autoRefresh: false)
        #expect(store.storageUnavailable)
        #expect(try Data(contentsOf: displayURL) == before)
    }
}

@MainActor
private final class VisibilityFixture {
    let files = AccountFiles(root: FileManager.default.temporaryDirectory.appendingPathComponent("visibility-\(UUID())"))
    let suite = "visibility-\(UUID())"
    let defaults: UserDefaults
    let claude = UsageAccount(id: UUID(), provider: .claude, name: "A", credentialID: UUID())
    let codex: UsageAccount
    let loader: VisibilityLoader
    let store: UsageStore

    init(suspend: Bool = false, sameProvider: Bool = false, automatic: Bool = false) throws {
        defaults = UserDefaults(suiteName: suite)!
        codex = UsageAccount(id: UUID(), provider: sameProvider ? .claude : .codex, name: "B", credentialID: UUID())
        loader = VisibilityLoader(suspended: suspend)
        var registry = AccountRegistry(accounts: [claude, codex]); registry.repairRepresentatives()
        try files.write(registry, to: files.registryURL)
        try files.write(DisplayConfiguration.initial(registry), to: files.root.appendingPathComponent("display-v2.json"))
        let loader = loader
        store = UsageStore(settings: AppSettings(defaults: defaults), files: files,
                           autoRefresh: automatic, loadAccount: { await loader.load($0, control: $1) })
    }
    func close() { store.shutdown(); try? FileManager.default.removeItem(at: files.root); defaults.removePersistentDomain(forName: suite) }
    func waitForRefreshToFinish() async {
        for await refreshing in store.$isRefreshing.values {
            if !refreshing { return }
        }
    }
}

private actor VisibilityLoader {
    private var counts: [UUID: Int] = [:]
    private var controls: [UUID: OperationControl] = [:]
    private var suspended: Bool
    private var loadWaiters: [UUID: [AsyncStream<Void>.Continuation]] = [:]
    private var releaseWaiters: [AsyncStream<Void>.Continuation] = []
    init(suspended: Bool) { self.suspended = suspended }
    var total: Int { counts.values.reduce(0, +) }
    func count(_ id: UUID) -> Int { counts[id, default: 0] }
    func wasCancelled(_ id: UUID) -> Bool { controls[id]?.cancelled == true }
    func waitForLoad(_ id: UUID) async {
        guard counts[id, default: 0] == 0 else { return }
        let (started, continuation) = AsyncStream<Void>.makeStream()
        loadWaiters[id, default: []].append(continuation)
        for await _ in started { return }
    }
    func release() {
        suspended = false
        for waiter in releaseWaiters { waiter.yield(); waiter.finish() }
        releaseWaiters.removeAll()
    }
    func load(_ account: UsageAccount, control: OperationControl) async -> ProviderSnapshot {
        counts[account.id, default: 0] += 1; controls[account.id] = control
        for waiter in loadWaiters.removeValue(forKey: account.id) ?? [] { waiter.yield(); waiter.finish() }
        if suspended {
            let (released, continuation) = AsyncStream<Void>.makeStream()
            releaseWaiters.append(continuation)
            for await _ in released { break }
        }
        return ProviderSnapshot(provider: account.provider, updatedAt: .now, fiveHour: nil,
            weekly: WindowSummary(tokens: 42, limitTokens: 100, resetAt: nil, displayStyle: .percentage),
            modelWeeklies: [], planName: nil, sourceDescription: "Fixture", note: nil, isStale: false, requiresLogin: false)
    }
}
