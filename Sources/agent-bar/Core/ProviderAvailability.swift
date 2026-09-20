import CryptoKit
import Foundation

enum ProviderAvailability {
    static func availableProviders() -> [ProviderKind] {
        ProviderKind.allCases.filter { isAvailable($0) }
    }

    static func isAvailable(_ provider: ProviderKind) -> Bool {
        switch provider {
        case .claude:
            return isClaudeAvailable()
        case .codex:
            return isCodexAvailable()
        }
    }

    private static func isClaudeAvailable() -> Bool {
        let fileManager = FileManager.default
        let homeDirectory = fileManager.homeDirectoryForCurrentUser
        let configDirectory = claudeConfigDirectory(homeDirectory: homeDirectory)
        let credentialsURL = configDirectory.appendingPathComponent(".credentials.json")

        if fileManager.fileExists(atPath: credentialsURL.path) {
            return true
        }

        let executableCandidates = [
            homeDirectory.appendingPathComponent(".local/bin/claude"),
            homeDirectory.appendingPathComponent(".bun/bin/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
        ]
        if executableCandidates.contains(where: { fileManager.isExecutableFile(atPath: $0.path) }) { return true }
        return keychainServiceNames(configDirectory: configDirectory, homeDirectory: homeDirectory)
            .contains(where: { BackgroundKeychain.contains(service: $0) })
    }

    private static func isCodexAvailable() -> Bool {
        let fileManager = FileManager.default
        let homeDirectory = fileManager.homeDirectoryForCurrentUser
        let candidates = [
            homeDirectory.appendingPathComponent(".bun/bin/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
        ]

        return candidates.contains { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private static func claudeConfigDirectory(homeDirectory: URL) -> URL {
        if let override = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], override.isEmpty == false {
            return URL(fileURLWithPath: override).standardizedFileURL
        }
        return homeDirectory.appendingPathComponent(".claude")
    }

    private static func keychainServiceNames(configDirectory: URL, homeDirectory: URL) -> [String] {
        let legacyService = "Claude Code-credentials"
        let normalizedConfig = configDirectory.standardizedFileURL.path
        let normalizedDefault = homeDirectory.appendingPathComponent(".claude").standardizedFileURL.path

        if normalizedConfig == normalizedDefault {
            return [legacyService]
        }

        let hash = SHA256.hash(data: Data(normalizedConfig.utf8))
        let suffix = hash.compactMap { String(format: "%02x", $0) }.joined().prefix(8)
        return ["\(legacyService)-\(suffix)", legacyService]
    }

}
