import Foundation

// Where Claude Code keeps one login. The default login is the one Claude Code uses when it starts
// without folder variables; a folder login belongs to the folder both variables name. The default
// slot's paths come from the caller so a test never points at the real ones.
struct ClaudeSlot: Equatable, Sendable {
    static let defaultService = "Claude Code-credentials"

    // nil for the default login.
    let directory: URL?
    // `~/.claude.json` for the default login, `<folder>/.claude.json` for a folder.
    let identityFile: URL
    let service: String
    let account: String

    static func defaultLogin(
        identityFile: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json"),
        service: String = defaultService, account: String = NSUserName()
    ) -> ClaudeSlot {
        ClaudeSlot(directory: nil, identityFile: identityFile, service: service, account: account)
    }

    static func folder(_ directory: URL, account: String = NSUserName()) -> ClaudeSlot {
        // Claude Code names the Keychain item after the folder path it is given, so hand it the same path.
        let directory = directory.standardizedFileURL
        return ClaudeSlot(directory: directory, identityFile: directory.appendingPathComponent(".claude.json"),
                          service: AccountFiles.claudeService(directory), account: account)
    }

    // The minimal environment, plus both folder variables for a folder. The default login never gets them,
    // whatever the environment AgentBar itself was started with.
    var environment: [String: String] { makeEnvironment(from: ProcessInfo.processInfo.environment) }
    func makeEnvironment(from source: [String: String]) -> [String: String] {
        directory.map { ProviderCLI.environment(provider: .claude, directory: $0, from: source) }
            ?? ProviderCLI.processEnvironment(from: source)
    }
    var workingDirectory: URL { directory ?? FileManager.default.homeDirectoryForCurrentUser }
}

// The `oauthAccount` block Claude Code writes into a slot's `.claude.json`.
struct ClaudeOAuthAccount: Equatable, Sendable {
    var accountUUID: String?
    var organizationUUID: String?
    var email: String?

    // nil when the data is not a JSON object; all fields nil when it has no `oauthAccount`.
    init?(claudeJSON data: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let account = object["oauthAccount"] as? [String: Any]
        func text(_ key: String) -> String? { (account?[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        accountUUID = text("accountUuid")
        organizationUUID = text("organizationUuid")
        email = text("emailAddress")
    }
}

// What a slot says about whose login it holds: its identity file plus whether its Keychain item exists.
// Without the item the slot is signed out, whatever the identity file still says.
struct ClaudeSlotIdentity: Equatable, Sendable {
    var accountUUID: String?
    var organizationUUID: String?
    var email: String?
    var hasLogin: Bool

    init(_ account: ClaudeOAuthAccount?, hasLogin: Bool) {
        accountUUID = account?.accountUUID
        organizationUUID = account?.organizationUUID
        email = account?.email
        self.hasLogin = hasLogin
    }

    // The same account is the same account UUID in the same organization. An account registered before its
    // UUID was filled in can only be compared by organization and email, which both must be known.
    func matches(_ account: UsageAccount) -> Bool {
        guard account.provider == .claude, let identity = account.identity else { return false }
        if let stableID = identity.stableID {
            guard let organizationID = identity.organizationID else { return false }
            return Self.same(accountUUID, stableID) && Self.same(organizationUUID, organizationID)
        }
        guard let organizationID = identity.organizationID, let registeredEmail = identity.email else { return false }
        return Self.same(organizationUUID, organizationID) && Self.same(email, registeredEmail)
    }

    // Whether an account has enough identity to tell its login from another.
    static func canVerify(_ account: UsageAccount) -> Bool {
        guard account.provider == .claude, let identity = account.identity, identity.organizationID != nil else { return false }
        return identity.stableID != nil || identity.email != nil
    }

    private static func same(_ value: String?, _ other: String) -> Bool {
        value?.lowercased() == other.lowercased()
    }
}

// The part of Claude Code's Keychain item that another slot needs: the refresh token and its scopes.
// It never prints, so a token cannot reach a log or message by accident.
struct ClaudeLoginCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    static let defaultScopes = ["user:inference", "user:profile", "user:sessions:claude_code", "user:mcp_servers"]

    let refreshToken: String
    let scopes: [String]

    init?(keychainData data: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let token = oauth["refreshToken"] as? String, !token.isEmpty else { return nil }
        refreshToken = token
        let stored = (oauth["scopes"] as? [String])?.filter { !$0.isEmpty } ?? []
        scopes = stored.isEmpty ? Self.defaultScopes : stored
    }

    var description: String { "ClaudeLoginCredential(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: []) }
}

extension AccountFiles {
    var lendRoot: URL { root.appendingPathComponent("lend") }
    // The folder where one account's login waits to be used in Claude Code.
    func lend(_ accountID: UUID) -> URL { lendRoot.appendingPathComponent(accountID.uuidString) }
    var claudeCodeSwitchJournalURL: URL { root.appendingPathComponent("claude-code-switch.json") }
}

extension LimitResetLog {
    static let claudeCodeSwitchFileName = "claude-code-switch.log"
    static func claudeCodeSwitchURL(root: URL) -> URL { url(root: root, fileName: claudeCodeSwitchFileName) }
}

// Registered Claude accounts have no account UUID yet. It is read once from the account's own login folder,
// and only when that folder's organization is the registered one.
enum ClaudeAccountUUIDFill {
    static func stableID(for account: UsageAccount, claudeJSON data: Data?) -> String? {
        guard account.provider == .claude, let identity = account.identity, identity.stableID == nil,
              let registered = identity.organizationID, !registered.isEmpty,
              let data, let oauth = ClaudeOAuthAccount(claudeJSON: data),
              let organization = oauth.organizationUUID, organization.lowercased() == registered.lowercased() else { return nil }
        return oauth.accountUUID
    }

    static func stableID(for account: UsageAccount, loginDirectory: URL) -> String? {
        stableID(for: account, claudeJSON: try? Data(contentsOf: loginDirectory.appendingPathComponent(".claude.json")))
    }
}
