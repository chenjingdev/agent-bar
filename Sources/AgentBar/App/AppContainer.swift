import Foundation

@MainActor
final class AppContainer {
    static let shared = AppContainer()

    let settings: AppSettings
    let store: UsageStore

    private init() {
        let settings = AppSettings()
        self.settings = settings
        self.store = UsageStore(settings: settings)
    }
}
