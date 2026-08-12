import Testing
import Foundation
import Combine
@testable import agent_bar

@MainActor
struct AppSettingsTests {
    private func createTestDefaults() -> UserDefaults {
        let identifier = UUID().uuidString
        let suite = UserDefaults(suiteName: identifier)!
        suite.removePersistentDomain(forName: identifier)
        return suite
    }

    @Test("AppSettings initializes with all available providers enabled by default")
    func defaultsAllProvidersEnabled() {
        let defaults = createTestDefaults()
        let providers: [ProviderKind] = [.claude, .codex]
        let settings = AppSettings(availableProviders: providers, defaults: defaults)

        for provider in providers {
            let displaySettings = settings.getProviderDisplaySettings(provider)
            #expect(displaySettings.isEnabled == true)
            #expect(displaySettings.showsBadge == true)
            #expect(displaySettings.showsUsageBars == true)
            #expect(displaySettings.showsPercentage == true)
        }
    }

    @Test("AppSettings computes visibleComponents in deterministic order: badge, bars, percentage")
    func visibleComponentsOrderedDeterministically() {
        let defaults = createTestDefaults()
        let providers: [ProviderKind] = [.claude]
        let settings = AppSettings(availableProviders: providers, defaults: defaults)

        let displaySettings = settings.getProviderDisplaySettings(.claude)
        #expect(displaySettings.visibleComponents == [.badge, .bars, .percentage])
    }

    @Test("AppSettings rejects mutations for unknown providers")
    func rejectsUnknownProviderMutations() {
        let defaults = createTestDefaults()
        let providers: [ProviderKind] = [.claude]
        let settings = AppSettings(availableProviders: providers, defaults: defaults)

        let result1 = settings.setProviderEnabled(.codex, enabled: false)
        let result2 = settings.setComponentShown(.codex, component: .badge, shown: false)

        #expect(result1 == false)
        #expect(result2 == false)
    }

    @Test("AppSettings provider settings are independent across providers")
    func providerSettingsIndependent() {
        let defaults = createTestDefaults()
        let providers: [ProviderKind] = [.claude, .codex]
        let settings = AppSettings(availableProviders: providers, defaults: defaults)

        settings.setComponentShown(.claude, component: .badge, shown: false)

        let claudeSettings = settings.getProviderDisplaySettings(.claude)
        let codexSettings = settings.getProviderDisplaySettings(.codex)

        #expect(claudeSettings.showsBadge == false)
        #expect(codexSettings.showsBadge == true)
    }

    @Test("AppSettings persists provider enabled state across recreation")
    func persistsEnabledState() {
        let defaults = createTestDefaults()
        let providers: [ProviderKind] = [.claude, .codex]

        var settings = AppSettings(availableProviders: providers, defaults: defaults)
        settings.setProviderEnabled(.claude, enabled: false)

        settings = AppSettings(availableProviders: providers, defaults: defaults)
        #expect(settings.getProviderDisplaySettings(.claude).isEnabled == false)
        #expect(settings.getProviderDisplaySettings(.codex).isEnabled == true)
    }

    @Test("AppSettings persists component visibility across recreation")
    func persistsComponentVisibility() {
        let defaults = createTestDefaults()
        let providers: [ProviderKind] = [.claude]

        var settings = AppSettings(availableProviders: providers, defaults: defaults)
        settings.setComponentShown(.claude, component: .bars, shown: false)

        settings = AppSettings(availableProviders: providers, defaults: defaults)
        let displaySettings = settings.getProviderDisplaySettings(.claude)
        #expect(displaySettings.showsBadge == true)
        #expect(displaySettings.showsUsageBars == false)
        #expect(displaySettings.showsPercentage == true)
    }

    @Test("AppSettings persists exact visibleComponents order across recreation")
    func persistsExactComponentOrder() {
        let defaults = createTestDefaults()
        let providers: [ProviderKind] = [.claude]

        var settings = AppSettings(availableProviders: providers, defaults: defaults)
        settings.setComponentShown(.claude, component: .bars, shown: false)

        settings = AppSettings(availableProviders: providers, defaults: defaults)
        let displaySettings = settings.getProviderDisplaySettings(.claude)
        #expect(displaySettings.visibleComponents == [.badge, .percentage])
    }

    @Test("AppSettings publishes exactly one update on accepted setProviderEnabled")
    func publishesOnAcceptedSetProviderEnabled() {
        let defaults = createTestDefaults()
        let providers: [ProviderKind] = [.claude, .codex]
        let settings = AppSettings(availableProviders: providers, defaults: defaults)

        var updateCount = 0
        let cancellable = settings.$providerSettings
            .dropFirst()
            .sink { _ in
                updateCount += 1
            }

        settings.setProviderEnabled(.claude, enabled: false)

        #expect(updateCount == 1)
        cancellable.cancel()
    }

    @Test("AppSettings publishes nothing on rejected setProviderEnabled")
    func publishesNothingOnRejectedSetProviderEnabled() {
        let defaults = createTestDefaults()
        let providers: [ProviderKind] = [.claude]
        let settings = AppSettings(availableProviders: providers, defaults: defaults)

        var updateCount = 0
        let cancellable = settings.$providerSettings
            .dropFirst()
            .sink { _ in
                updateCount += 1
            }

        let result = settings.setProviderEnabled(.claude, enabled: false)

        #expect(result == false)
        #expect(updateCount == 0)
        cancellable.cancel()
    }

    @Test("AppSettings publishes exactly one update on accepted setComponentShown")
    func publishesOnAcceptedSetComponentShown() {
        let defaults = createTestDefaults()
        let providers: [ProviderKind] = [.claude]
        let settings = AppSettings(availableProviders: providers, defaults: defaults)

        var updateCount = 0
        let cancellable = settings.$providerSettings
            .dropFirst()
            .sink { _ in
                updateCount += 1
            }

        settings.setComponentShown(.claude, component: .badge, shown: false)

        #expect(updateCount == 1)
        cancellable.cancel()
    }

    @Test("AppSettings publishes nothing on rejected setComponentShown")
    func publishesNothingOnRejectedSetComponentShown() {
        let defaults = createTestDefaults()
        let providers: [ProviderKind] = [.claude]
        let settings = AppSettings(availableProviders: providers, defaults: defaults)

        settings.setComponentShown(.claude, component: .bars, shown: false)
        settings.setComponentShown(.claude, component: .percentage, shown: false)

        var updateCount = 0
        let cancellable = settings.$providerSettings
            .dropFirst()
            .sink { _ in
                updateCount += 1
            }

        let result = settings.setComponentShown(.claude, component: .badge, shown: false)

        #expect(result == false)
        #expect(updateCount == 0)
        cancellable.cancel()
    }

    @Test("AppSettings publishes nothing on rejected unknown provider mutation")
    func publishesNothingOnUnknownProvider() {
        let defaults = createTestDefaults()
        let providers: [ProviderKind] = [.claude]
        let settings = AppSettings(availableProviders: providers, defaults: defaults)

        var updateCount = 0
        let cancellable = settings.$providerSettings
            .dropFirst()
            .sink { _ in
                updateCount += 1
            }

        let result = settings.setProviderEnabled(.codex, enabled: false)

        #expect(result == false)
        #expect(updateCount == 0)
        cancellable.cancel()
    }

    @Test("AppSettings rejects disabling last enabled provider")
    func rejectsDisablingLastEnabledProvider() {
        let defaults = createTestDefaults()
        let providers: [ProviderKind] = [.claude, .codex]
        let settings = AppSettings(availableProviders: providers, defaults: defaults)

        settings.setProviderEnabled(.codex, enabled: false)
        let result = settings.setProviderEnabled(.claude, enabled: false)

        #expect(result == false)
        #expect(settings.getProviderDisplaySettings(.claude).isEnabled == true)
    }

    @Test("AppSettings allows disabling provider if another remains enabled")
    func allowsDisablingProviderIfOtherEnabled() {
        let defaults = createTestDefaults()
        let providers: [ProviderKind] = [.claude, .codex]
        let settings = AppSettings(availableProviders: providers, defaults: defaults)

        let result = settings.setProviderEnabled(.claude, enabled: false)

        #expect(result == true)
        #expect(settings.getProviderDisplaySettings(.claude).isEnabled == false)
        #expect(settings.getProviderDisplaySettings(.codex).isEnabled == true)
    }

    @Test("AppSettings rejects hiding last visible component of enabled provider")
    func rejectsHidingLastComponentOfEnabledProvider() {
        let defaults = createTestDefaults()
        let providers: [ProviderKind] = [.claude]
        let settings = AppSettings(availableProviders: providers, defaults: defaults)

        settings.setComponentShown(.claude, component: .bars, shown: false)
        settings.setComponentShown(.claude, component: .percentage, shown: false)

        let result = settings.setComponentShown(.claude, component: .badge, shown: false)

        #expect(result == false)
        let displaySettings = settings.getProviderDisplaySettings(.claude)
        #expect(displaySettings.showsBadge == true)
    }

    @Test("AppSettings allows hiding component if others remain visible for enabled provider")
    func allowsHidingComponentIfOthersRemain() {
        let defaults = createTestDefaults()
        let providers: [ProviderKind] = [.claude]
        let settings = AppSettings(availableProviders: providers, defaults: defaults)

        let result = settings.setComponentShown(.claude, component: .badge, shown: false)

        #expect(result == true)
        let displaySettings = settings.getProviderDisplaySettings(.claude)
        #expect(displaySettings.showsBadge == false)
    }

    @Test("AppSettings allows hiding all components of disabled provider")
    func allowsHidingAllComponentsOfDisabledProvider() {
        let defaults = createTestDefaults()
        let providers: [ProviderKind] = [.claude, .codex]
        let settings = AppSettings(availableProviders: providers, defaults: defaults)

        settings.setProviderEnabled(.claude, enabled: false)
        let result1 = settings.setComponentShown(.claude, component: .bars, shown: false)
        let result2 = settings.setComponentShown(.claude, component: .percentage, shown: false)
        let result3 = settings.setComponentShown(.claude, component: .badge, shown: false)

        #expect(result1 == true)
        #expect(result2 == true)
        #expect(result3 == true)
    }

    @Test("AppSettings normalizes all-disabled state by enabling first provider and persists across recreation")
    func normalizesAllDisabledStateAndPersists() {
        let defaults = createTestDefaults()
        let providers: [ProviderKind] = [.claude, .codex]

        let claudeKey = AppSettings.storageKeyForProvider(.claude)
        let codexKey = AppSettings.storageKeyForProvider(.codex)
        defaults.set(false, forKey: claudeKey)
        defaults.set(false, forKey: codexKey)

        var settings = AppSettings(availableProviders: providers, defaults: defaults)
        #expect(settings.getProviderDisplaySettings(.claude).isEnabled == true)
        #expect(settings.getProviderDisplaySettings(.codex).isEnabled == false)

        settings = AppSettings(availableProviders: providers, defaults: defaults)
        #expect(settings.getProviderDisplaySettings(.claude).isEnabled == true)
        #expect(settings.getProviderDisplaySettings(.codex).isEnabled == false)
    }

    @Test("AppSettings normalizes enabled provider with no components by enabling badge and persists across recreation")
    func normalizesNoComponentsStateAndPersists() {
        let defaults = createTestDefaults()
        let providers: [ProviderKind] = [.claude]

        let enabledKey = AppSettings.storageKeyForProvider(.claude)
        let badgeKey = AppSettings.storageKeyForComponent(.claude, .badge)
        let barsKey = AppSettings.storageKeyForComponent(.claude, .bars)
        let percentageKey = AppSettings.storageKeyForComponent(.claude, .percentage)
        defaults.set(true, forKey: enabledKey)
        defaults.set(false, forKey: badgeKey)
        defaults.set(false, forKey: barsKey)
        defaults.set(false, forKey: percentageKey)

        var settings = AppSettings(availableProviders: providers, defaults: defaults)
        let displaySettings1 = settings.getProviderDisplaySettings(.claude)
        #expect(displaySettings1.isEnabled == true)
        #expect(displaySettings1.showsBadge == true)
        #expect(displaySettings1.visibleComponents == [.badge])

        settings = AppSettings(availableProviders: providers, defaults: defaults)
        let displaySettings2 = settings.getProviderDisplaySettings(.claude)
        #expect(displaySettings2.isEnabled == true)
        #expect(displaySettings2.showsBadge == true)
        #expect(displaySettings2.visibleComponents == [.badge])
    }

    @Test("AppSettings exposes read-only providerSettings collection")
    func exposesReadOnlyProviderSettings() {
        let defaults = createTestDefaults()
        let providers: [ProviderKind] = [.claude, .codex]
        let settings = AppSettings(availableProviders: providers, defaults: defaults)

        let collection = settings.providerSettings
        #expect(collection[.claude] != nil)
        #expect(collection[.codex] != nil)
        #expect(collection[.claude]?.isEnabled == true)
    }

    @Test("AppSettings providerSettings reflects current state after mutations")
    func providerSettingsReflectsCurrentState() {
        let defaults = createTestDefaults()
        let providers: [ProviderKind] = [.claude, .codex]
        let settings = AppSettings(availableProviders: providers, defaults: defaults)

        settings.setProviderEnabled(.claude, enabled: false)

        let collection = settings.providerSettings
        #expect(collection[.claude]?.isEnabled == false)
    }

    @Test("Re-enabling a componentless provider restores its badge")
    func reEnablingComponentlessProviderRestoresBadge() {
        let defaults = createTestDefaults()
        let settings = AppSettings(
            availableProviders: [.claude, .codex],
            defaults: defaults
        )

        #expect(settings.setProviderEnabled(.claude, enabled: false))
        #expect(settings.setComponentShown(.claude, component: .badge, shown: false))
        #expect(settings.setComponentShown(.claude, component: .bars, shown: false))
        #expect(settings.setComponentShown(.claude, component: .percentage, shown: false))
        #expect(settings.getProviderDisplaySettings(.claude).visibleComponents.isEmpty)

        #expect(settings.setProviderEnabled(.claude, enabled: true))

        let displaySettings = settings.getProviderDisplaySettings(.claude)
        #expect(displaySettings.isEnabled)
        #expect(displaySettings.visibleComponents == [.badge])
    }
}
