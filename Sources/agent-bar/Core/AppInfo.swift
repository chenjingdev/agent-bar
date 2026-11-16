import Foundation

/// The app's name as people see it. It comes from the bundle, which
/// build-app.sh names from its `app_name` setting, so renaming the app is one
/// build setting rather than a code change. Internal names (the bundle ID
/// dev.chenjing.agent-bar, the ~/.agentbar data folder, the agent-bar module and
/// AGENTBAR_ variables) stay fixed, so a rename keeps settings and accounts.
enum AppInfo {
    static let defaultName = "AgentBar"

    static let name: String = {
        // `swift run` and tests have no app bundle to name them.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return defaultName }
        let info = Bundle.main.infoDictionary ?? [:]
        let named = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
        return named.flatMap { $0.isEmpty ? nil : $0 } ?? defaultName
    }()

    /// The version people see, such as "0.1.0"; "dev" outside a built app.
    static let version: String = {
        guard Bundle.main.bundleURL.pathExtension == "app",
              let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
              !version.isEmpty else { return "dev" }
        return version
    }()

    /// How the app names itself to the services it asks, such as "AgentBar/0.1.0":
    /// its own name, never another app's.
    static var userAgent: String { userAgent(name: name, version: version) }

    /// A User-Agent product name takes only ASCII letters, digits and `.-_`,
    /// so a renamed app keeps those, with spaces as dashes.
    static func userAgent(name: String, version: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        func token(_ text: String) -> String {
            String(String.UnicodeScalarView(text.replacingOccurrences(of: " ", with: "-").unicodeScalars.filter(allowed.contains)))
        }
        let product = token(name), release = token(version)
        return "\(product.isEmpty ? defaultName : product)/\(release.isEmpty ? "dev" : release)"
    }
}
