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
        let store = UsageStore(
            settings: settings,
            availableProviders: [.codex],
            claudeProvider: SnapshotUsageProvider(snapshot: .placeholder(for: .claude)),
            codexProvider: SnapshotUsageProvider(snapshot: snapshot),
            refreshOnInit: false
        )

        await store.refresh()
        let coordinator = StatusBarCoordinator(
            store: store,
            settings: settings,
            providers: [.codex]
        )

        #expect(coordinator.statusItemAccessibilityLabel(for: .codex) == "Codex weekly usage")
        #expect(coordinator.statusItemAccessibilityValue(for: .codex) == "11%")
    }

}

private struct SnapshotUsageProvider: UsageProviding {
    let snapshot: ProviderSnapshot

    func load() async -> ProviderSnapshot {
        snapshot
    }
}
