import Foundation

@MainActor
final class AppContainer {
    static let shared = AppContainer()

    let settings: AppSettings
    let store: UsageStore
    let availableProviders: [ProviderKind]

    private convenience init() { self.init(environment: ProcessInfo.processInfo.environment) }

    // `environment` is what the app was started with; a test passes its own.
    init(environment: [String: String]) {
        let defaults = environment["AGENTBAR_DEFAULTS_SUITE"].flatMap(UserDefaults.init(suiteName:)) ?? .standard
        let settings = AppSettings(defaults: defaults)
        let files = environment["AGENTBAR_DATA_DIR"].map { AccountFiles(root: URL(fileURLWithPath: $0)) } ?? AccountFiles()
        let availableProviders = ProviderAvailability.availableProviders()
        self.settings = settings
        self.availableProviders = availableProviders
        // The one place that can change Claude Code's own login. Tests build a store without it, or with a stand-in.
        self.store = UsageStore(settings: settings, files: files,
                                claudeCode: Self.claudeCodeAllowed(environment) ? .system(files: files) : nil)
    }

    // "Use in Claude Code" changes the login Claude Code itself uses, whatever data folder AgentBar was given. A run with
    // its own data folder or its own defaults is a development or test run: it must not change that login, nor finish a
    // switch the installed app has under way in the same folder, so it gets no switcher.
    nonisolated static func claudeCodeAllowed(_ environment: [String: String]) -> Bool {
        environment["AGENTBAR_DATA_DIR"] == nil && environment["AGENTBAR_DEFAULTS_SUITE"] == nil
    }
}
