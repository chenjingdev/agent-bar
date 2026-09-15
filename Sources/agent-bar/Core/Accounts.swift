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

    var isManaged: Bool { credentialID != nil }
    var title: String { name }
    static func currentCLI(_ provider: ProviderKind) -> Self {
        Self(id: UUID(uuidString: provider == .claude
            ? "00000000-0000-0000-0000-000000000001"
            : "00000000-0000-0000-0000-000000000002")!,
             provider: provider, name: "현재 CLI 계정")
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
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
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
        guard registry.version == 1 else { throw AccountError.message("지원하지 않는 계정 설정 버전입니다. 설정 파일을 보존했습니다.") }
        guard Set(registry.accounts.map(\.id)).count == registry.accounts.count else {
            throw AccountError.message("계정 설정에 중복 ID가 있습니다. 설정 파일을 보존했습니다.")
        }
        let credentialIDs = registry.accounts.compactMap(\.credentialID)
        guard Set(credentialIDs).count == credentialIDs.count else {
            throw AccountError.message("여러 계정이 같은 인증 폴더를 가리킵니다. 설정 파일을 보존했습니다.")
        }
        return registry
    }
    func removeCredentials(_ account: UsageAccount) throws {
        guard let id = account.credentialID else { return }
        let directory = credentials(id)
        if account.provider == .claude {
            let service = Self.claudeService(directory)
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                        kSecAttrService as String: service,
                                        kSecAttrAccount as String: NSUserName()]
            var status = SecItemDelete(query as CFDictionary)
            if status == errSecInvalidOwnerEdit {
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
                let remaining = SecItemCopyMatching(verification as CFDictionary, nil)
                status = remaining == errSecItemNotFound ? errSecItemNotFound : (remaining == errSecSuccess ? errSecInvalidOwnerEdit : remaining)
            }
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw AccountError.message("이 계정의 Keychain 정리가 필요합니다 (\(status)). 삭제를 재시도하세요.")
            }
        }
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
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
        case .loginRequired: return "로그인이 필요합니다. 계정을 재연결하세요."
        case .cancelled: return "로그인을 취소했습니다."
        case .rateLimited: return "요청 제한으로 잠시 후 다시 확인합니다."
        case .timeout: return "응답 시간이 초과되었습니다. 다시 시도하세요."
        }
    }
}
