import Combine
import Foundation

@MainActor
final class AppSettings: ObservableObject {
    @Published var refreshIntervalSeconds: Double {
        didSet { defaults.set(refreshIntervalSeconds, forKey: Keys.refreshIntervalSeconds) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.refreshIntervalSeconds = defaults.object(forKey: Keys.refreshIntervalSeconds) as? Double ?? 30
    }

    private enum Keys {
        static let refreshIntervalSeconds = "refreshIntervalSeconds"
    }
}
