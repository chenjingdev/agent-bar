import Foundation
import Testing
@testable import agent_bar

struct AccountManagementTests {
    @Test @MainActor func accountOrderPersistsWithoutChangingUsageLineSelectionsOrIdentities() throws {
        let files = try temporaryFiles(); defer { try? FileManager.default.removeItem(at: files.root) }
        let a = UsageAccount.currentCLI(.claude), b = UsageAccount.currentCLI(.codex)
        let c = UsageAccount(id: UUID(), provider: .claude, name: "Work")
        let d = UsageAccount(id: UUID(), provider: .codex, name: "Extra")
        var registry = AccountRegistry(accounts: [a, b, c, d]); registry.repairRepresentatives()
        try files.write(registry, to: files.registryURL)
        let suite = "account-order-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let store = UsageStore(settings: settings, availableProviders: [], files: files, autoRefresh: false)
        defer { store.shutdown() }
        let group = MenuBarLayout(name: "Mixed", rows: [MenuBarLine(accountID: c.id, metricID: "weekly"), MenuBarLine(accountID: a.id, metricID: "5h")])
        store.updateDisplay { $0.layouts = [group]; $0.setVisible(c.id, false) }
        let layouts = store.displayConfiguration.effectiveLayouts
        let appearances = store.displayConfiguration.accounts
        #expect(store.moveAccount(c.id, to: a.id))
        #expect(store.orderedAccounts.map(\.id) == [c.id, a.id, b.id, d.id])
        #expect(store.displayConfiguration.effectiveLayouts == layouts)
        #expect(store.displayConfiguration.accounts == appearances)
        #expect(store.registry == registry)
        #expect(!store.moveAccount(c.id, to: c.id))
        #expect(!store.moveAccount(UUID(), to: a.id))

        let restored = UsageStore(settings: settings, availableProviders: [], files: files, autoRefresh: false)
        defer { restored.shutdown() }
        #expect(restored.orderedAccounts.map(\.id) == [c.id, a.id, b.id, d.id])
        #expect(restored.displayConfiguration.effectiveLayouts == layouts)

        // Registry sync appends new accounts and removes deleted ones without resetting custom order.
        let added = UsageAccount(id: UUID(), provider: .codex, name: "New")
        registry.accounts.append(added)
        registry.accounts[1].deletionPending = true
        registry.repairRepresentatives()
        try files.write(registry, to: files.registryURL)
        let synced = UsageStore(settings: settings, availableProviders: [], files: files, autoRefresh: false)
        defer { synced.shutdown() }
        #expect(synced.orderedAccounts.map(\.id) == [c.id, a.id, d.id, added.id])
        #expect(!synced.moveAccount(b.id, to: a.id))
    }

    @Test @MainActor func movingAccountsPreservesLegacyMenuBarGroupOrder() throws {
        let files = try temporaryFiles(); defer { try? FileManager.default.removeItem(at: files.root) }
        let a = UsageAccount.currentCLI(.claude), b = UsageAccount.currentCLI(.codex)
        try files.write(AccountRegistry(accounts: [a, b]), to: files.registryURL)
        let suite = "legacy-account-order-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageStore(settings: AppSettings(defaults: defaults), availableProviders: [], files: files, autoRefresh: false)
        defer { store.shutdown() }
        #expect(store.displayConfiguration.layouts == nil)
        var normalized = store.displayConfiguration
        normalized.freezeBadgeLabels()
        let groups = normalized.effectiveLayouts
        #expect(store.moveAccount(b.id, to: a.id))
        #expect(store.orderedAccounts.map(\.id) == [b.id, a.id])
        #expect(store.displayConfiguration.effectiveLayouts == groups)
    }

    private func temporaryFiles() throws -> AccountFiles {
        let files = AccountFiles(root: FileManager.default.temporaryDirectory.appendingPathComponent("agentbar-tests-\(UUID())"))
        try files.createPrivateDirectory(files.root)
        return files
    }
    @Test func identityDoesNotMergeByEmailOrPlan() {
        let a = AccountIdentity(email: "a@example.test", organizationID: "one")
        #expect(a.comparison(to: a) == .unverified)
        #expect(a.comparison(to: .init(email: "b@example.test", organizationID: "one")) == .different)
        #expect(a.comparison(to: .init(email: "a@example.test", organizationID: "two")) == .different)
        let stable = AccountIdentity(email: "a@example.test", organizationID: "one", stableID: "user-1")
        #expect(stable.comparison(to: stable) == .same)
    }
    @Test func accountPathsAndCredentialRotationsAreIsolated() throws {
        let files = try temporaryFiles(); defer { try? FileManager.default.removeItem(at: files.root) }
        let a = UsageAccount(id: UUID(), provider: .claude, name: "A", credentialID: UUID())
        var rotated = a; rotated.credentialID = UUID()
        let b = UsageAccount(id: UUID(), provider: .claude, name: "B", credentialID: UUID())
        #expect(files.cache(a) != files.cache(b))
        #expect(files.cache(a) != files.cache(rotated))
        #expect(AccountFiles.claudeService(files.credentials(a.credentialID!)) != AccountFiles.claudeService(files.credentials(b.credentialID!)))
        #expect(AccountFiles.claudeService(files.credentials(a.credentialID!)) != "Claude Code-credentials")
        try files.write(ProviderSnapshot.placeholder(for: .claude), to: files.cache(a))
        #expect(!FileManager.default.fileExists(atPath: files.cache(b).path))
        let attributes = try FileManager.default.attributesOfItem(atPath: files.cache(a).path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
    @Test @MainActor func representativePersistsAndDeletedAccountIsSkipped() throws {
        let files = try temporaryFiles(); defer { try? FileManager.default.removeItem(at: files.root) }
        let a = UsageAccount(id: UUID(), provider: .codex, name: "A", credentialID: UUID())
        let b = UsageAccount(id: UUID(), provider: .codex, name: "B", credentialID: UUID())
        var registry = AccountRegistry(accounts: [a, b]); registry.repairRepresentatives()
        try files.write(registry, to: files.registryURL)
        let suite = "agentbar-test-\(UUID())"; let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let store = UsageStore(settings: settings, availableProviders: [], files: files, autoRefresh: false)
        store.selectRepresentative(b)
        let reloaded = UsageStore(settings: settings, availableProviders: [], files: files, autoRefresh: false)
        #expect(reloaded.representative(for: .codex)?.id == b.id)
        var saved = try files.load(); saved.accounts[1].deletionPending = true; saved.repairRepresentatives()
        #expect(saved.representatives["codex"] == a.id)
    }
    @Test @MainActor func everySavedAccountAlwaysUsesItsOwnUsageCredentialDirectory() async throws {
        let files = try temporaryFiles(); defer { try? FileManager.default.removeItem(at: files.root) }
        var original = UsageAccount.currentCLI(.claude)
        original.credentialID = UUID()
        original.identity = AccountIdentity(email: "personal@example.test", organizationID: "personal")
        let work = UsageAccount(id: UUID(), provider: .claude, name: "Work",
            identity: AccountIdentity(email: "work@example.test", organizationID: "work"), credentialID: UUID())
        let codex = UsageAccount.currentCLI(.codex)
        var registry = AccountRegistry(accounts: [original, work, codex]); registry.repairRepresentatives()
        try files.write(registry, to: files.registryURL)
        let suite = "usage-only-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageStore(settings: AppSettings(defaults: defaults), availableProviders: [.claude, .codex],
            files: files, autoRefresh: false, loadAccount: { account, _ in
                ProviderSnapshot(provider: account.provider, updatedAt: .now, fiveHour: nil,
                    weekly: WindowSummary(tokens: account.isBuiltIn ? 20 : 70, limitTokens: 100, resetAt: nil, displayStyle: .percentage),
                    modelWeeklies: [], planName: "Fixture", sourceDescription: "Fixture", note: nil, isStale: false, requiresLogin: false)
            })
        defer { store.shutdown() }
        #expect(store.accounts.count == 3)
        #expect(store.credentialDirectory(for: original) == files.credentials(original.credentialID!))
        #expect(store.credentialDirectory(for: work) == files.credentials(work.credentialID!))
        #expect(store.credentialDirectory(for: codex) == nil)
        await store.refresh()
        #expect(store.snapshot(for: original).weekly?.utilization == 0.2)
        #expect(store.snapshot(for: work).weekly?.utilization == 0.7)
        #expect(store.accounts.first { $0.id == original.id }?.identity == original.identity)
        #expect(store.accounts.first { $0.id == work.id }?.identity == work.identity)
    }
    @Test @MainActor func lateResultsCannotRestoreRemovedOrReconnectedAccounts() {
        let a = UsageAccount(id: UUID(), provider: .codex, name: "A", credentialID: UUID())
        #expect(UsageStore.acceptsResult(request: a, current: a))
        #expect(!UsageStore.acceptsResult(request: a, current: nil))
        var changed = a; changed.credentialID = UUID()
        #expect(!UsageStore.acceptsResult(request: a, current: changed))
        changed = a; changed.deletionPending = true
        #expect(!UsageStore.acceptsResult(request: a, current: changed))
    }
    @Test @MainActor func corruptRegistryIsPreserved() throws {
        let files = try temporaryFiles(); defer { try? FileManager.default.removeItem(at: files.root) }
        let bad = Data("{not valid".utf8); try bad.write(to: files.registryURL)
        let suite = "agentbar-test-\(UUID())"; let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageStore(settings: AppSettings(defaults: defaults), availableProviders: [.codex], files: files, autoRefresh: false)
        #expect(store.storageUnavailable)
        #expect(try Data(contentsOf: files.registryURL) == bad)
    }
    @Test func unavailableIsNotZero() {
        let snapshot = ProviderSnapshot.placeholder(for: .codex)
        #expect(snapshot.primaryWindow?.utilization == nil)
        #expect(snapshot.weekly?.utilization == nil)
        #expect(TokenFormatters.percentageString(for: snapshot.weekly?.utilization) == "--")
        let zero = WindowSummary(tokens: 0, limitTokens: 100, resetAt: nil, displayStyle: .percentage)
        #expect(TokenFormatters.percentageString(for: zero.utilization) == "0%")
    }
    @Test func missingWeeklyWindowDoesNotBecomeZero() throws {
        let raw = Data(#"{"result":{"rateLimits":{"planType":"pro","primary":{"usedPercent":0,"windowDurationMins":300},"secondary":null}}}"#.utf8)
        let payload = try JSONDecoder().decode(CodexRateLimitResponse.self, from: raw)
        let mapped = CodexRateLimitMapper.map(payload.result.rateLimits)
        #expect(mapped.fiveHourUsedPercent == 0)
        #expect(mapped.weeklyUsedPercent == nil)
    }
    @Test func providerEnvironmentDoesNotInheritForeignAuthentication() {
        let directory = URL(fileURLWithPath: "/tmp/agentbar-profile")
        let env = ProviderCLI.environment(provider: .codex, directory: directory)
        #expect(env["CODEX_HOME"] == directory.path)
        #expect(env["OPENAI_API_KEY"] == nil)
        #expect(env["OPENCODEX_API_AUTH_TOKEN"] == nil)
        #expect(env["ANTHROPIC_API_KEY"] == nil)
    }
}
