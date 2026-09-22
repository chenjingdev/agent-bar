import AppKit
import Foundation
import SwiftUI
import Testing
@testable import agent_bar

struct ProviderSnapshotWindowTests {
    @Test
    func claudeSnapshotPrefersFiveHourWindow() {
        let snapshot = ProviderSnapshot(
            provider: .claude,
            updatedAt: .now,
            fiveHour: WindowSummary(
                tokens: 20,
                limitTokens: 100,
                resetAt: nil,
                displayStyle: .percentage
            ),
            weekly: WindowSummary(
                tokens: 40,
                limitTokens: 100,
                resetAt: nil,
                displayStyle: .percentage
            ),
            modelWeeklies: [],
            planName: "Max",
            sourceDescription: ProviderKind.claude.sourceDescription,
            note: nil,
            isStale: false,
            requiresLogin: false
        )

        #expect(snapshot.fiveHour != nil)
        #expect(snapshot.primaryWindow?.tokens == 20)
    }

    @Test @MainActor
    func weeklyOnlyMenuLabelHasVisibleSize() {
        let snapshot = ProviderSnapshot(
            provider: .codex,
            updatedAt: .now,
            fiveHour: nil,
            weekly: WindowSummary(
                tokens: 11,
                limitTokens: 100,
                resetAt: nil,
                displayStyle: .percentage
            ),
            modelWeeklies: [],
            planName: "Pro",
            sourceDescription: ProviderKind.codex.sourceDescription,
            note: nil,
            isStale: false,
            requiresLogin: false
        )

        #expect(snapshot.fiveHour == nil)
        #expect(snapshot.primaryWindow?.tokens == 11)
        let account = UsageAccount(id: UUID(), provider: .codex, name: "Codex")
        var config = DisplayConfiguration(); config.sync([account])
        let entry = MenuBarEntry(account: account, display: config.display(account),
                                 metric: .menuBar(snapshot, preferred: "weekly"), stale: false, requiresLogin: false)
        let image = DisplayStatusRenderer.render(entry: entry, config: config)
        #expect(entry.metric.id == "weekly")
        #expect(image.size.width > 28)
        #expect(image.size.height > 0)
    }

    @Test @MainActor
    func weeklyOnlyStatusItemHasDescriptiveAccessibility() async throws {
        let snapshot = ProviderSnapshot(
            provider: .codex,
            updatedAt: .now,
            fiveHour: nil,
            weekly: WindowSummary(
                tokens: 11,
                limitTokens: 100,
                resetAt: nil,
                displayStyle: .percentage
            ),
            modelWeeklies: [],
            planName: "Pro",
            sourceDescription: ProviderKind.codex.sourceDescription,
            note: nil,
            isStale: false,
            requiresLogin: false
        )
        let identifier = "ProviderSnapshotWindowTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: identifier)!
        defaults.removePersistentDomain(forName: identifier)
        let settings = AppSettings(availableProviders: [.codex], defaults: defaults)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: identifier) }
        let files = AccountFiles(root: root)
        let connected = UsageAccount(id: UUID(), provider: .codex, name: "Codex", credentialID: UUID())
        try files.write(AccountRegistry(accounts: [connected]), to: files.registryURL)
        let store = UsageStore(settings: settings, files: files, autoRefresh: false,
                               loadAccount: { _, _ in snapshot })
        await store.refresh()
        let account = store.visibleAccounts.first!
        let controller = StatusBarController(key: account.id, store: store)
        defer { controller.remove() }
        // The preferred metric is weekly, so a Codex account without 5h data still reads as weekly.
        controller.apply([store.menuBarEntry(for: account)], config: store.displayConfiguration)
        #expect(controller.accessibilityLabel?.contains("Weekly Limit: 11%") == true)
        #expect(controller.accessibilityLabel?.contains("5-Hour") == false)
    }

}

private struct SnapshotUsageProvider: UsageProviding {
    let snapshot: ProviderSnapshot

    func load() async -> ProviderSnapshot {
        snapshot
    }
}
