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
        #expect(snapshot.primaryWindow.tokens == 20)
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
        let hostingView = NSHostingView(rootView: MenuBarLabelView(snapshot: snapshot))

        #expect(hostingView.fittingSize.width > 28)
        #expect(hostingView.fittingSize.height > 0)
    }

}
