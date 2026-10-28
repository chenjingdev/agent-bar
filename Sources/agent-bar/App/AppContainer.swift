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
        // The one place that can change Claude Code's own login. Tests build a store without it, or with a stand-in.
        self.store = UsageStore(settings: settings, files: files, claudeCode: .system(files: files))
    }
}
