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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: identifier) }
        let store = UsageStore(settings: settings, files: AccountFiles(root: root), autoRefresh: false)
        let view = SettingsView()
            .environmentObject(settings)
            .environmentObject(store)
        let hostingView = NSHostingView(rootView: view)
        let size = hostingView.fittingSize

        #expect(size.width == 540)
        #expect(size.height >= 320)
        #expect(size.height <= 700)
    }
}

private struct SettingsLayoutUsageProvider: UsageProviding {
    let provider: ProviderKind

    func load() async -> ProviderSnapshot {
        .placeholder(for: provider)
    }
}
