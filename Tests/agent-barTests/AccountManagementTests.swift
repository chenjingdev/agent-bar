import Foundation
import Testing
@testable import agent_bar

struct AccountManagementTests {
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
