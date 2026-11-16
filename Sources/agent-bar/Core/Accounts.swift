import CryptoKit
import Foundation
import Security

struct AccountIdentity: Codable, Equatable, Sendable {
    var email: String?
    var organization: String?
    var organizationID: String?
    var stableID: String?

    var description: String {
        [email, organization].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The organization worth showing beside the email. A personal one named
    /// after the email ("…'s Organization") only repeats it.
    var visibleOrganization: String? {
        guard let organization = organization?.trimmingCharacters(in: .whitespaces), !organization.isEmpty else { return nil }
        if let email, !email.isEmpty, organization.localizedCaseInsensitiveContains(email) { return nil }
        return organization
    }

    // Email is display information, not a provider-guaranteed immutable identifier.
    func comparison(to other: Self) -> IdentityComparison {
        if let stableID, let otherID = other.stableID {
            return stableID == otherID && organizationID == other.organizationID ? .same : .different
        }
        if let email, let otherEmail = other.email, email.lowercased() != otherEmail.lowercased() { return .different }
        if let organizationID, let otherID = other.organizationID, organizationID != otherID { return .different }
        return .unverified
    }
}

enum IdentityComparison { case same, different, unverified }

struct UsageAccount: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let provider: ProviderKind
    var name: String
    var identity: AccountIdentity?
    var credentialID: UUID?
    var deletionPending = false

    init(id: UUID, provider: ProviderKind, name: String, identity: AccountIdentity? = nil, credentialID: UUID? = nil,
         deletionPending: Bool = false) {
        self.id = id; self.provider = provider; self.name = name; self.identity = identity
        self.credentialID = credentialID; self.deletionPending = deletionPending
    }

    // agent-bar keeps no name and calls every account by its login email; an account it saved reads the same way here.
    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try fields.decode(UUID.self, forKey: .id)
        provider = try fields.decode(ProviderKind.self, forKey: .provider)
        identity = try fields.decodeIfPresent(AccountIdentity.self, forKey: .identity)
        credentialID = try fields.decodeIfPresent(UUID.self, forKey: .credentialID)
        deletionPending = try fields.decodeIfPresent(Bool.self, forKey: .deletionPending) ?? false
        name = try fields.decodeIfPresent(String.self, forKey: .name)
            ?? identity?.email.flatMap { $0.isEmpty ? nil : $0 } ?? provider.displayName
    }

    var isManaged: Bool { credentialID != nil }
    var isBuiltIn: Bool { id == Self.currentCLI(provider).id }
    var title: String { name }
    static func currentCLI(_ provider: ProviderKind) -> Self {
        Self(id: UUID(uuidString: {
            switch provider {
            case .claude: return "00000000-0000-0000-0000-000000000001"
            case .codex: return "00000000-0000-0000-0000-000000000002"
            case .antigravity: return "00000000-0000-0000-0000-000000000003"
            }
        }())!,
             provider: provider, name: "Current CLI account")
    }
}

struct AccountRegistry: Codable, Equatable {
    var version = 1
    var accounts: [UsageAccount] = []
    var representatives: [String: UUID] = [:]
    var cleanupPending: [UsageAccount] = []

    mutating func repairRepresentatives() {
        for provider in ProviderKind.allCases {
            let eligible = accounts.filter { $0.provider == provider && !$0.deletionPending }
            if !eligible.contains(where: { $0.id == representatives[provider.rawValue] }) {
                representatives[provider.rawValue] = eligible.first?.id
            }
        }
    }
}

struct AccountFiles: Sendable {
    var root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agentbar/multi-account-v1")
    var registryURL: URL { root.appendingPathComponent("accounts.json") }
    func credentials(_ id: UUID) -> URL { root.appendingPathComponent("credentials/\(id.uuidString)") }
    func cache(_ account: UsageAccount) -> URL {
        root.appendingPathComponent("usage/\(account.id.uuidString)/\(account.credentialID?.uuidString ?? "cli")/usage.json")
    }
    func createPrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    func write<T: Encodable>(_ value: T, to url: URL) throws {
        try createPrivateDirectory(url.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func read<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(contentsOf: url))
    }
    func load() throws -> AccountRegistry {
        guard FileManager.default.fileExists(atPath: registryURL.path) else { return AccountRegistry() }
        let registry = try read(AccountRegistry.self, at: registryURL)
        guard registry.version == 1 else { throw AccountError.message(String(localized: "Unsupported account settings version. The settings file was preserved.")) }
        guard Set(registry.accounts.map(\.id)).count == registry.accounts.count else {
            throw AccountError.message(String(localized: "Duplicate account IDs in settings. The settings file was preserved."))
        }
        let credentialIDs = registry.accounts.compactMap(\.credentialID)
        guard Set(credentialIDs).count == credentialIDs.count else {
            throw AccountError.message(String(localized: "Multiple accounts reference the same credential directory. The settings file was preserved."))
        }
        return registry
    }
    func removeCredentials(_ account: UsageAccount, allowUserInteraction: Bool = true) throws {
        guard let id = account.credentialID else { return }
        let directory = credentials(id)
        if account.provider == .claude {
            let service = Self.claudeService(directory)
            var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                        kSecAttrService as String: service,
                                        kSecAttrAccount as String: NSUserName()]
            if !allowUserInteraction { query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }
            var status = try BackgroundKeychain.withInteraction(allowUserInteraction) { SecItemDelete(query as CFDictionary) }
            if status == errSecInvalidOwnerEdit && allowUserInteraction {
                // CLI-created legacy Keychain items can reject deletion by this
                // ad-hoc-signed app. Use the system Keychain client with the exact
                // managed namespace; never widen the query or change its ACL.
                let process = try ProcessSession(executable: URL(fileURLWithPath: "/usr/bin/security"),
                    arguments: ["delete-generic-password", "-s", service, "-a", NSUserName()],
                    environment: ["PATH": "/usr/bin:/bin"], directory: FileManager.default.temporaryDirectory)
                defer { process.stop() }
                _ = try process.collect(until: Date().addingTimeInterval(15), control: OperationControl())
                // Exit success alone does not establish removal. Read attributes,
                // not the secret, and require the exact item to be absent.
                var verification = query
                verification[kSecReturnAttributes as String] = true
                verification[kSecMatchLimit as String] = kSecMatchLimitOne
                let remaining = try BackgroundKeychain.withInteraction(allowUserInteraction) { SecItemCopyMatching(verification as CFDictionary, nil) }
                status = remaining == errSecItemNotFound ? errSecItemNotFound : (remaining == errSecSuccess ? errSecInvalidOwnerEdit : remaining)
            }
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw AccountError.message(String(localized: "Keychain cleanup is required for this account (\(Int(status))). Retry deletion."))
            }
        }
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
    // Claude accounts linked while the CLI status omitted the account ID could
    // never be matched on reconnect. Their login recorded it in the config file.
    func recordMissingClaudeAccountIDs(in registry: inout AccountRegistry) {
        for index in registry.accounts.indices {
            let account = registry.accounts[index]
            guard account.provider == .claude, let id = account.credentialID,
                  let identity = account.identity, identity.stableID == nil,
                  let local = try? ProviderCLI.claudeLocalIdentity(directory: credentials(id)),
                  local.stableID != nil, local.comparison(to: identity) != .different else { continue }
            registry.accounts[index].identity?.stableID = local.stableID
        }
    }
    func removeUsage(_ account: UsageAccount) throws {
        let directory = root.appendingPathComponent("usage/\(account.id.uuidString)")
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
    static func claudeService(_ directory: URL) -> String {
        let normalized = directory.standardizedFileURL.path
        let suffix = SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8)
        return "Claude Code-credentials-\(suffix)"
    }
}

enum AccountError: LocalizedError {
    case message(String)
    case loginRequired
    case cancelled
    case timeout
    case rateLimited(TimeInterval)
    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        case .loginRequired: return String(localized: "Sign-in required. Reconnect the account.")
        case .cancelled: return String(localized: "Operation cancelled.")
        case .rateLimited: return String(localized: "Rate limited. Retrying after the required delay.")
        case .timeout: return String(localized: "The request timed out. Please try again.")
        }
    }
}
