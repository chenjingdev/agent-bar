import Combine
import Foundation

enum MenuBarComponent: String, Codable, Hashable, CaseIterable {
    case badge
    case bars
    case percentage

    static let orderedComponents: [MenuBarComponent] = [.badge, .bars, .percentage]
}

struct ProviderDisplaySettings: Equatable {
    let isEnabled: Bool
    let showsBadge: Bool
    let showsUsageBars: Bool
    let showsPercentage: Bool

    var visibleComponents: [MenuBarComponent] {
        MenuBarComponent.orderedComponents.filter { component in
            switch component {
            case .badge:
                return showsBadge
            case .bars:
                return showsUsageBars
            case .percentage:
                return showsPercentage
            }
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    @Published var refreshIntervalSeconds: Double {
        didSet { defaults.set(refreshIntervalSeconds, forKey: Keys.refreshIntervalSeconds) }
    }

    @Published private(set) var providerSettings: [ProviderKind: ProviderDisplaySettings] = [:]

    let availableProviders: [ProviderKind]
    private let defaults: UserDefaults

    init(availableProviders: [ProviderKind], defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.availableProviders = availableProviders

        let storedInterval = defaults.object(forKey: Keys.refreshIntervalSeconds) as? Double ?? 120
        self.refreshIntervalSeconds = max(storedInterval, 60)

        var settings: [ProviderKind: ProviderDisplaySettings] = [:]
        for provider in availableProviders {
            settings[provider] = loadProviderSettings(provider)
        }

        if availableProviders.allSatisfy({ !(settings[$0]?.isEnabled ?? false) }) {
            if let first = availableProviders.first {
                let current = settings[first]!
                settings[first] = ProviderDisplaySettings(
                    isEnabled: true,
                    showsBadge: current.showsBadge,
                    showsUsageBars: current.showsUsageBars,
                    showsPercentage: current.showsPercentage
                )
                persistProviderSettings(first, settings[first]!)
            }
        }

        for provider in availableProviders {
            if (settings[provider]?.isEnabled ?? false) && (settings[provider]?.visibleComponents.isEmpty ?? false) {
                settings[provider] = ProviderDisplaySettings(
                    isEnabled: true,
                    showsBadge: true,
                    showsUsageBars: false,
                    showsPercentage: false
                )
                persistProviderSettings(provider, settings[provider]!)
            }
        }

        self.providerSettings = settings
    }

    func getProviderDisplaySettings(_ provider: ProviderKind) -> ProviderDisplaySettings {
        providerSettings[provider] ?? ProviderDisplaySettings(
            isEnabled: true,
            showsBadge: true,
            showsUsageBars: true,
            showsPercentage: true
        )
    }

    @discardableResult
    func setProviderEnabled(_ provider: ProviderKind, enabled: Bool) -> Bool {
        guard availableProviders.contains(provider) else { return false }

        let current = providerSettings[provider] ?? getProviderDisplaySettings(provider)

        if !enabled {
            let enabledCount = availableProviders.filter { providerSettings[$0]?.isEnabled ?? false }.count
            if enabledCount == 1 && current.isEnabled {
                return false
            }
        }

        let updated = ProviderDisplaySettings(
            isEnabled: enabled,
            showsBadge: enabled && current.visibleComponents.isEmpty
                ? true
                : current.showsBadge,
            showsUsageBars: current.showsUsageBars,
            showsPercentage: current.showsPercentage
        )

        providerSettings[provider] = updated
        persistProviderSettings(provider, updated)
        return true
    }

    @discardableResult
    func setComponentShown(_ provider: ProviderKind, component: MenuBarComponent, shown: Bool) -> Bool {
        guard availableProviders.contains(provider) else { return false }

        let current = providerSettings[provider] ?? getProviderDisplaySettings(provider)

        let (newBadge, newBars, newPercentage) = (
            component == .badge ? shown : current.showsBadge,
            component == .bars ? shown : current.showsUsageBars,
            component == .percentage ? shown : current.showsPercentage
        )

        if !shown && current.isEnabled {
            let visibleCount = [newBadge, newBars, newPercentage].filter { $0 }.count
            if visibleCount == 0 {
                return false
            }
        }

        let updated = ProviderDisplaySettings(
            isEnabled: current.isEnabled,
            showsBadge: newBadge,
            showsUsageBars: newBars,
            showsPercentage: newPercentage
        )

        providerSettings[provider] = updated
        persistProviderSettings(provider, updated)
        return true
    }

    private func loadProviderSettings(_ provider: ProviderKind) -> ProviderDisplaySettings {
        let enabledKey = Self.storageKeyForProvider(provider)
        let badgeKey = Self.storageKeyForComponent(provider, .badge)
        let barsKey = Self.storageKeyForComponent(provider, .bars)
        let percentageKey = Self.storageKeyForComponent(provider, .percentage)

        let isEnabled = defaults.object(forKey: enabledKey) as? Bool ?? true
        let showsBadge = defaults.object(forKey: badgeKey) as? Bool ?? true
        let showsUsageBars = defaults.object(forKey: barsKey) as? Bool ?? true
        let showsPercentage = defaults.object(forKey: percentageKey) as? Bool ?? true

        return ProviderDisplaySettings(
            isEnabled: isEnabled,
            showsBadge: showsBadge,
            showsUsageBars: showsUsageBars,
            showsPercentage: showsPercentage
        )
    }

    private func persistProviderSettings(_ provider: ProviderKind, _ settings: ProviderDisplaySettings) {
        let enabledKey = Self.storageKeyForProvider(provider)
        let badgeKey = Self.storageKeyForComponent(provider, .badge)
        let barsKey = Self.storageKeyForComponent(provider, .bars)
        let percentageKey = Self.storageKeyForComponent(provider, .percentage)

        defaults.set(settings.isEnabled, forKey: enabledKey)
        defaults.set(settings.showsBadge, forKey: badgeKey)
        defaults.set(settings.showsUsageBars, forKey: barsKey)
        defaults.set(settings.showsPercentage, forKey: percentageKey)
    }

    static func storageKeyForProvider(_ provider: ProviderKind) -> String {
        "provider_\(provider.rawValue)_enabled"
    }

    static func storageKeyForComponent(_ provider: ProviderKind, _ component: MenuBarComponent) -> String {
        "provider_\(provider.rawValue)_component_\(component.rawValue)"
    }

    private enum Keys {
        static let refreshIntervalSeconds = "refreshIntervalSeconds"
    }
}
