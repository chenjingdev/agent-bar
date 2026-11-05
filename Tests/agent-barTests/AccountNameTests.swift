import Foundation
import Testing
@testable import agent_bar

// An account's name is the one the account carries at the provider. AgentBar has no name of its own for it.
struct AccountNameTests {
    @Test func claudesProfileGivesTheDisplayNameThenTheFullNameAndTheOrganization() throws {
        let both = Data(#"{"account":{"display_name":" 첸징 ","full_name":"Kim Aram","email":"a@example.test"},"organization":{"name":"Team"}}"#.utf8)
        #expect(ClaudeUsageProvider.profile(from: both) == AccountProfile(name: "첸징", organization: "Team"))
        let fullOnly = Data(#"{"account":{"display_name":"","full_name":"Kim Aram"}}"#.utf8)
        #expect(ClaudeUsageProvider.profile(from: fullOnly) == AccountProfile(name: "Kim Aram", organization: nil))
        let none = Data(#"{"account":{"email":"a@example.test"}}"#.utf8)
        #expect(ClaudeUsageProvider.profile(from: none) == AccountProfile(name: nil, organization: nil))
        #expect(ClaudeUsageProvider.profile(from: Data(#"{"five_hour":null}"#.utf8)) == nil, "a reply without an account says nothing")
    }

    @Test func theClaudeSignInNameIsTheOneClaudeCodeSavedWithIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("claude-name-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(ClaudeOAuthLauncher.profileName(directory: directory) == nil)
        try Data(#"{"oauthAccount":{"emailAddress":"a@example.test","displayName":"유비온","fullName":"Kim"}}"#.utf8)
            .write(to: directory.appendingPathComponent(".claude.json"))
        #expect(ClaudeOAuthLauncher.profileName(directory: directory) == "유비온")
    }

    @Test func theCodexNameIsTheNameClaimOfTheSavedIDToken() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-name-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(CodexAuthFile.profile(directory: directory) == nil, "no sign-in file")
        func save(_ claims: [String: Any]) throws {
            let payload = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            let auth: [String: Any] = ["tokens": ["id_token": "e30.\(payload).signature", "access_token": "fixture-access"]]
            try JSONSerialization.data(withJSONObject: auth).write(to: directory.appendingPathComponent("auth.json"))
        }
        try save(["email": "a@example.test", "name": "김아람"])
        #expect(CodexAuthFile.profile(directory: directory) == AccountProfile(name: "김아람"))
        try save(["email": "a@example.test"])
        #expect(CodexAuthFile.profile(directory: directory) == AccountProfile(name: nil), "a login without a name has none")
    }

    @Test @MainActor func sameNamedAccountsAreToldApartByEmailThenProviderThenOrganization() throws {
        let files = try temporaryFiles(); defer { try? FileManager.default.removeItem(at: files.root) }
        func account(_ provider: ProviderKind, _ name: String?, _ email: String?, _ organization: String? = nil) -> UsageAccount {
            UsageAccount(id: UUID(), provider: provider,
                         identity: AccountIdentity(email: email, organization: organization, name: name), credentialID: UUID())
        }
        let solo = account(.claude, "첸징", "solo@example.test")
        let work = account(.claude, "김아람", "work@example.test", "Team")
        let home = account(.claude, "김아람", "home@example.test")
        let codexWork = account(.codex, "김아람", "work@example.test")
        let twinA = account(.claude, "Lee", "lee@example.test", "Org A")
        let twinB = account(.claude, "lee", "lee@example.test", "Org B")
        let unnamed = account(.codex, nil, "plain@example.test")
        let blank = UsageAccount(id: UUID(), provider: .codex, credentialID: UUID())
        try files.write(AccountRegistry(accounts: [solo, work, home, codexWork, twinA, twinB, unnamed, blank]), to: files.registryURL)
        let suite = "account-names-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageStore(settings: AppSettings(defaults: defaults), files: files, autoRefresh: false)
        defer { store.shutdown() }

        #expect(store.accountLabel(for: solo) == "첸징")
        #expect(store.accountLabel(for: home) == "김아람 · home@example.test")
        #expect(store.accountLabel(for: work) == "김아람 · work@example.test · Claude")
        #expect(store.accountLabel(for: codexWork) == "김아람 · work@example.test · Codex")
        // Where the provider is shown beside the name, only accounts of the same provider count.
        #expect(store.accountLabel(for: work, providerShown: true) == "김아람 · work@example.test")
        #expect(store.accountLabel(for: codexWork, providerShown: true) == "김아람")
        #expect(store.accountLabel(for: twinA) == "Lee · Org A", "an email they share tells nothing apart")
        #expect(store.accountLabel(for: unnamed) == "plain@example.test", "without a name the email stands in")
        #expect(store.accountLabel(for: blank) == "Codex")
    }

    @Test @MainActor func aRefreshFollowsTheProvidersNameAndTheOldAppNameIsGone() async throws {
        let files = try temporaryFiles(); defer { try? FileManager.default.removeItem(at: files.root) }
        let id = UUID(), credential = UUID()
        // A registry saved by an earlier AgentBar, with a name typed in the app.
        let legacy = """
        {"version":1,"representatives":{},"cleanupPending":[],"accounts":[{"id":"\(id.uuidString)","provider":"claude",
        "name":"PB1","credentialID":"\(credential.uuidString)","deletionPending":false,
        "identity":{"email":"a@example.test","organization":"Old Org","organizationID":"org-1","stableID":"acct-1"}}]}
        """
        try files.createPrivateDirectory(files.root)
        try Data(legacy.utf8).write(to: files.registryURL)
        let suite = "account-name-refresh-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        // A new store each time, so no refresh cool-down stands between the reads.
        func refreshed(reporting profile: AccountProfile?) async -> UsageAccount? {
            let store = UsageStore(settings: AppSettings(defaults: defaults), files: files, autoRefresh: false,
                loadAccount: { account, _ in
                    var snapshot = ProviderSnapshot.placeholder(for: account.provider)
                    snapshot.accountProfile = profile
                    return snapshot
                })
            defer { store.shutdown() }
            #expect(store.refreshAccountIDs == [id])
            await store.refresh()
            return store.accounts.first
        }
        let before = UsageStore(settings: AppSettings(defaults: defaults), files: files, autoRefresh: false)
        #expect(before.accounts.first?.title == "a@example.test", "the name typed in the app is not read")
        before.shutdown()

        var account = await refreshed(reporting: AccountProfile(name: "첸징", organization: "New Org"))
        #expect(account?.title == "첸징" && account?.identity?.organization == "New Org")
        let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: files.registryURL)) as? [String: Any])
        let row = try #require((saved["accounts"] as? [[String: Any]])?.first)
        #expect(row["name"] == nil, "the stored app name is dropped")
        #expect((row["identity"] as? [String: Any])?["name"] as? String == "첸징")

        // A read that could not get the profile keeps the name; a renamed account shows its new name.
        account = await refreshed(reporting: nil)
        #expect(account?.title == "첸징")
        account = await refreshed(reporting: AccountProfile(name: "유비온"))
        #expect(account?.title == "유비온" && account?.identity?.organization == "New Org")
        #expect(account?.identity?.stableID == "acct-1" && account?.identity?.email == "a@example.test")
    }
}

private func temporaryFiles() throws -> AccountFiles {
    let files = AccountFiles(root: FileManager.default.temporaryDirectory.appendingPathComponent("agentbar-tests-\(UUID())"))
    try files.createPrivateDirectory(files.root)
    return files
}
