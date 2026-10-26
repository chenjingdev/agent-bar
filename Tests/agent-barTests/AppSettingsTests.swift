import AppKit
import Testing
import Foundation
@testable import agent_bar

@MainActor
struct AppSettingsTests {
    private func createTestDefaults() -> UserDefaults {
        let identifier = UUID().uuidString
        let suite = UserDefaults(suiteName: identifier)!
        suite.removePersistentDomain(forName: identifier)
        return suite
    }

    @Test("AppSettings uses the System theme by default and for unknown stored values")
    func themeDefaultsToSystem() {
        let defaults = createTestDefaults()
        #expect(AppSettings(defaults: defaults).theme == .system)
        defaults.set("sepia", forKey: AppSettings.Keys.theme)
        #expect(AppSettings(defaults: defaults).theme == .system)
    }

    @Test("AppSettings persists the theme across recreation")
    func persistsTheme() {
        let defaults = createTestDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.theme = .dark
        #expect(defaults.string(forKey: AppSettings.Keys.theme) == "dark")
        #expect(AppSettings(defaults: defaults).theme == .dark)
        settings.theme = .light
        #expect(AppSettings(defaults: defaults).theme == .light)
        settings.theme = .system
        #expect(AppSettings(defaults: defaults).theme == .system)
    }

    @Test("Each theme maps to its appearance name")
    func themeMapsToAppearanceName() {
        #expect(AppearanceTheme.allCases.map(\.title) == ["System", "Light", "Dark"])
        #expect(AppearanceTheme.system.appearanceName == nil && AppearanceTheme.system.appearance == nil)
        #expect(AppearanceTheme.light.appearanceName == .aqua && AppearanceTheme.light.appearance?.name == .aqua)
        #expect(AppearanceTheme.dark.appearanceName == .darkAqua && AppearanceTheme.dark.appearance?.name == .darkAqua)
    }
}
