import Foundation

@MainActor
final class AppContainer {
    static let shared = AppContainer()

    let settings: AppSettings
    let store: UsageStore
    let availableProviders: [ProviderKind]

    private init() {
        let availableProviders = ProviderAvailability.availableProviders()
        let settings = AppSettings(availableProviders: availableProviders)
        self.settings = settings
        self.availableProviders = availableProviders
        self.store = UsageStore(
            settings: settings,
            availableProviders: availableProviders,
            claudeProvider: ClaudeUsageProvider(),
            codexProvider: CodexUsageProvider()
        )
    }
}
