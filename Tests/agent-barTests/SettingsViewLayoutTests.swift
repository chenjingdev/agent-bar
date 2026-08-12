import AppKit
import Foundation
import SwiftUI
import Testing
@testable import agent_bar

@MainActor
struct SettingsViewLayoutTests {
    @Test("Settings view stays within its bounded height")
    func settingsViewHeightIsBounded() {
        let identifier = "SettingsViewLayoutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: identifier)!
        defaults.removePersistentDomain(forName: identifier)
        let providers: [ProviderKind] = [.claude, .codex]
        let settings = AppSettings(availableProviders: providers, defaults: defaults)
        let store = UsageStore(
            settings: settings,
            availableProviders: providers,
            claudeProvider: SettingsLayoutUsageProvider(provider: .claude),
            codexProvider: SettingsLayoutUsageProvider(provider: .codex),
            refreshOnInit: false
        )
        let view = SettingsView()
            .environmentObject(settings)
            .environmentObject(store)
        let hostingView = NSHostingView(rootView: view)
        let size = hostingView.fittingSize

        #expect(size.width == 430)
        #expect(size.height >= 360)
        #expect(size.height <= 640)
    }
}

private struct SettingsLayoutUsageProvider: UsageProviding {
    let provider: ProviderKind

    func load() async -> ProviderSnapshot {
        .placeholder(for: provider)
    }
}
