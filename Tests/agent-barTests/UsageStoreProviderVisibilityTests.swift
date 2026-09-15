import Foundation
import Testing
@testable import agent_bar

@MainActor
struct UsageStoreProviderVisibilityTests {
    @Test func hiddenAccountsAreSkippedByManualRefresh() async throws {
        let fixture = try VisibilityFixture()
        defer { fixture.close() }
        fixture.store.updateDisplay { $0.resize(1) }
        await fixture.store.refresh()
        #expect(await fixture.loader.count(fixture.claude.id) == 1)
        #expect(await fixture.loader.count(fixture.codex.id) == 0)
    }

    @Test func hidingAllComponentsOrMetricsStopsRefreshButMissingDataDoesNot() async throws {
        let fixture = try VisibilityFixture()
        defer { fixture.close() }
        fixture.store.updateDisplay {
            $0.items[0].showService = false; $0.items[0].showBars = false; $0.items[0].showPercent = false
            $0.metrics[fixture.codex.id.uuidString] = []
        }
        await fixture.store.refresh()
        #expect(await fixture.loader.total == 0)
        fixture.store.updateDisplay { $0.metrics[fixture.codex.id.uuidString] = ["5h"] }
        // There is no 5h data yet, but polling must discover its later arrival.
        await fixture.store.refresh()
        #expect(await fixture.loader.count(fixture.codex.id) == 1)
        #expect(await fixture.loader.count(fixture.claude.id) == 0)
    }

    @Test func hidingAnInflightAccountCancelsAndDiscardsItsResult() async throws {
        let fixture = try VisibilityFixture(suspend: true)
        defer { fixture.close() }
        let task = Task { await fixture.store.refresh() }
        try await fixture.waitFor { await fixture.loader.count(fixture.claude.id) == 1 }
        fixture.store.updateDisplay { $0.remove(fixture.claude.id, from: $0.items[0].id) }
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
        try await fixture.waitFor { await fixture.loader.count(fixture.claude.id) == 1 }
        fixture.store.updateDisplay { $0.remove(fixture.codex.id, from: $0.items[0].id) }
        await fixture.loader.release()
        await task.value
        #expect(await fixture.loader.count(fixture.codex.id) == 0)
    }

    @Test func showingAnAccountDuringRefreshQueuesOnlyThatAccount() async throws {
        let fixture = try VisibilityFixture(suspend: true, automatic: true)
        defer { fixture.close() }
        fixture.store.updateDisplay { $0.resize(1) }
        try await fixture.waitFor { await fixture.loader.count(fixture.claude.id) == 1 }
        fixture.store.updateDisplay { $0.resize(2) }
        await fixture.loader.release()
        try await fixture.waitFor { !fixture.store.isRefreshing }
        #expect(await fixture.loader.count(fixture.claude.id) == 1)
        #expect(await fixture.loader.count(fixture.codex.id) == 1)
    }

    @Test func visualChangesDoNotRefetchAndReenabledAccountRefreshes() async throws {
        let fixture = try VisibilityFixture(automatic: true)
        defer { fixture.close() }
        try await fixture.waitFor { !fixture.store.isRefreshing }
        fixture.store.updateDisplay { $0.items[0].showService = false; $0.items[0].maxRows = 3 }
        #expect(!fixture.store.isRefreshing)
        fixture.store.updateDisplay { $0.resize(1) }
        fixture.store.updateDisplay { $0.resize(2) }
        try await fixture.waitFor { !fixture.store.isRefreshing }
        #expect(await fixture.loader.count(fixture.claude.id) == 1)
        #expect(await fixture.loader.count(fixture.codex.id) == 2)
    }

    @Test func upstreamPreferencesMigrateOnceAndPreserveHiddenItem() throws {
        let fixture = try VisibilityFixture()
        defer { fixture.close() }
        let defaults = fixture.defaults
        defaults.set(false, forKey: AppSettings.storageKeyForProvider(.claude))
        defaults.set(false, forKey: AppSettings.storageKeyForComponent(.codex, .badge))
        defaults.set(false, forKey: AppSettings.storageKeyForComponent(.codex, .percentage))
        try FileManager.default.removeItem(at: fixture.files.root.appendingPathComponent("display-v1.json"))
        let settings = AppSettings(defaults: defaults)
        let store = UsageStore(settings: settings, availableProviders: [], files: fixture.files, autoRefresh: false)
        #expect(store.displayConfiguration.activeCount == 1)
        #expect(store.displayConfiguration.items[0].accountIDs == [fixture.codex.id])
        #expect(store.displayConfiguration.items[0].showBars)
        #expect(!store.displayConfiguration.items[0].showService)
        #expect(!store.displayConfiguration.items[0].showPercent)
        #expect(store.displayConfiguration.items[1].accountIDs == [fixture.claude.id])
        store.updateDisplay { $0.resize(2) }
        let reloaded = UsageStore(settings: settings, availableProviders: [], files: fixture.files, autoRefresh: false)
        #expect(reloaded.displayConfiguration == store.displayConfiguration)
    }

    @Test func invalidAccountRegistryDoesNotEraseDisplayAssignments() throws {
        let fixture = try VisibilityFixture()
        defer { fixture.close() }
        let displayURL = fixture.files.root.appendingPathComponent("display-v1.json")
        let before = try Data(contentsOf: displayURL)
        try Data("{bad".utf8).write(to: fixture.files.registryURL)
        let store = UsageStore(settings: AppSettings(defaults: fixture.defaults), availableProviders: [], files: fixture.files, autoRefresh: false)
        #expect(store.storageUnavailable)
        #expect(try Data(contentsOf: displayURL) == before)
    }
}

@MainActor
private final class VisibilityFixture {
    let files = AccountFiles(root: FileManager.default.temporaryDirectory.appendingPathComponent("visibility-\(UUID())"))
    let suite = "visibility-\(UUID())"
    let defaults: UserDefaults
    let claude = UsageAccount(id: UUID(), provider: .claude, name: "A")
    let codex: UsageAccount
    let loader: VisibilityLoader
    let store: UsageStore

    init(suspend: Bool = false, sameProvider: Bool = false, automatic: Bool = false) throws {
        defaults = UserDefaults(suiteName: suite)!
        codex = UsageAccount(id: UUID(), provider: sameProvider ? .claude : .codex, name: "B")
        loader = VisibilityLoader(suspended: suspend)
        var registry = AccountRegistry(accounts: [claude, codex]); registry.repairRepresentatives()
        try files.write(registry, to: files.registryURL)
        var display = DisplayConfiguration.initial(registry)
        if sameProvider { display.assign(codex.id, to: display.items[0].id) }
        try files.write(display, to: files.root.appendingPathComponent("display-v1.json"))
        let loader = loader
        store = UsageStore(settings: AppSettings(defaults: defaults), availableProviders: [], files: files,
                           autoRefresh: automatic, loadAccount: { await loader.load($0, control: $1) })
    }
    func close() { store.shutdown(); try? FileManager.default.removeItem(at: files.root); defaults.removePersistentDomain(forName: suite) }
    func waitFor(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !(await condition()) {
            if Date() > deadline { throw AccountError.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor VisibilityLoader {
    private var counts: [UUID: Int] = [:]
    private var controls: [UUID: OperationControl] = [:]
    private var suspended: Bool
    init(suspended: Bool) { self.suspended = suspended }
    var total: Int { counts.values.reduce(0, +) }
    func count(_ id: UUID) -> Int { counts[id, default: 0] }
    func wasCancelled(_ id: UUID) -> Bool { controls[id]?.cancelled == true }
    func release() { suspended = false }
    func load(_ account: UsageAccount, control: OperationControl) async -> ProviderSnapshot {
        counts[account.id, default: 0] += 1; controls[account.id] = control
        let deadline = Date().addingTimeInterval(3)
        while suspended && Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        return ProviderSnapshot(provider: account.provider, updatedAt: .now, fiveHour: nil,
            weekly: WindowSummary(tokens: 42, limitTokens: 100, resetAt: nil, displayStyle: .percentage),
            modelWeeklies: [], planName: nil, sourceDescription: "Fixture", note: nil, isStale: false, requiresLogin: false)
    }
}
