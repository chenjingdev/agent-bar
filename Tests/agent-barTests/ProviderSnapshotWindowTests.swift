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
        let hostingView = NSHostingView(
            rootView: MenuBarLabelView(
                snapshot: snapshot,
                displaySettings: ProviderDisplaySettings(
                    isEnabled: true,
                    showsBadge: true,
                    showsUsageBars: true,
                    showsPercentage: true
                )
            )
        )

        #expect(hostingView.fittingSize.width > 28)
        #expect(hostingView.fittingSize.height > 0)
    }

    @Test @MainActor
    func weeklyOnlyStatusItemHasDescriptiveAccessibility() async {
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
        let store = UsageStore(settings: settings, availableProviders: [.codex], files: AccountFiles(root: root), autoRefresh: false,
                               loadAccount: { _, _ in snapshot })
        await store.refresh()
        let item = store.displayConfiguration.activeItems.first { !$0.accountIDs.isEmpty }!
        let controller = StatusBarController(itemID: item.id, store: store)
        defer { controller.remove() }
        controller.apply(item, number: 1)
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
