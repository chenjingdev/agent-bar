import Foundation

@MainActor
final class AppContainer {
    static let shared = AppContainer()

    let settings: AppSettings
    let store: UsageStore
    let availableProviders: [ProviderKind]

    private init() {
        let environment = ProcessInfo.processInfo.environment
        let defaults = environment["AGENTBAR_DEFAULTS_SUITE"].flatMap(UserDefaults.init(suiteName:)) ?? .standard
        let settings = AppSettings(defaults: defaults)
        let files = environment["AGENTBAR_DATA_DIR"].map { AccountFiles(root: URL(fileURLWithPath: $0)) } ?? AccountFiles()
        let availableProviders = ProviderAvailability.availableProviders()
        self.settings = settings
        self.availableProviders = availableProviders
        self.store = UsageStore(settings: settings, availableProviders: availableProviders, files: files)
    }
}
