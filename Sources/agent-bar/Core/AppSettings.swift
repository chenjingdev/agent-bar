import AppKit
import Combine
import Foundation

// The look of AgentBar's own windows and popovers. The menu bar item always
// follows the real menu bar.
enum AppearanceTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
    // nil follows the system appearance.
    var appearanceName: NSAppearance.Name? {
        switch self {
        case .system: return nil
        case .light: return .aqua
        case .dark: return .darkAqua
        }
    }
    var appearance: NSAppearance? { appearanceName.flatMap(NSAppearance.init(named:)) }
}

@MainActor
final class AppSettings: ObservableObject {
    @Published var refreshIntervalSeconds: Double {
        didSet { defaults.set(refreshIntervalSeconds, forKey: Keys.refreshIntervalSeconds) }
    }
    @Published var theme: AppearanceTheme {
        didSet { defaults.set(theme.rawValue, forKey: Keys.theme) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedInterval = defaults.object(forKey: Keys.refreshIntervalSeconds) as? Double ?? 120
        self.refreshIntervalSeconds = max(storedInterval, 60)
        self.theme = defaults.string(forKey: Keys.theme).flatMap(AppearanceTheme.init(rawValue:)) ?? .system
    }

    func consumeDisplaySetupNotice() -> Bool {
        let key = "multiAccountDisplaySetupShown-v1"
        guard !defaults.bool(forKey: key) else { return false }
        defaults.set(true, forKey: key)
        return true
    }

    enum Keys {
        static let refreshIntervalSeconds = "refreshIntervalSeconds"
        static let theme = "theme"
    }
}
