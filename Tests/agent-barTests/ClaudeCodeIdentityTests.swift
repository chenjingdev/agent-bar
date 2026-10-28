import Foundation
import Testing
@testable import agent_bar

// Pure pieces of the switch: version, identity, credential, failure classification, account UUID fill.
struct ClaudeCodeIdentityTests {
    // MARK: Version

    @Test func versionsFromTwoOneThreeZeroNineUpPass() {
        for output in ["2.1.309 (Claude Code)\n", "2.1.312 (Claude Code)", "3.0.0 (Claude Code)", "2.2.0 (Claude Code)", "10.0.0 (Claude Code)",
                       "2.1.312", "2.1.312-beta.1 (Claude Code)", "  2.1.400 (Claude Code)\nextra line"] {
            let version = ClaudeCodeVersion(output: output)
            #expect(version != nil && version! >= .minimum, "\(output)")
        }
    }

    @Test func olderVersionsAreBlockedWithANumericComparison() throws {
        for output in ["2.1.308 (Claude Code)", "2.0.999 (Claude Code)", "1.99.999 (Claude Code)", "2.1.99 (Claude Code)", "0.0.1"] {
            let version = try #require(ClaudeCodeVersion(output: output))
            #expect(version < .minimum, "\(output)")
        }
        #expect(ClaudeCodeVersion(major: 2, minor: 10, patch: 0) > .minimum)
        #expect(ClaudeCodeVersion.minimum.description == "2.1.309")
    }

    @Test func oddOutputIsNotAVersion() {
        for output in ["", "\n", "claude", "zsh: command not found: claude", "v2.1.312", "2.1 (Claude Code)", "2.1.x (Claude Code)",
                       "Claude Code 2.1.312", "2.1.312.5.6 beyond", "99999999999999999999.1.1", "-2.1.312", "2.1.312abc"] {
            #expect(ClaudeCodeVersion(output: output) == nil, "\(output)")
        }
    }

    @Test func theBlockReasonsAreEnglishSentences() {
        #expect(ClaudeCodeVersionCheck.supported(.minimum).blockReason == nil)
        #expect(ClaudeCodeVersionCheck.tooOld(ClaudeCodeVersion(major: 2, minor: 1, patch: 308)).blockReason
                == "Claude Code 2.1.308 is too old. Update to 2.1.309 or newer.")
        #expect(ClaudeCodeVersionCheck.unreadable("Could not find the Claude CLI.").blockReason == "Could not find the Claude CLI.")
    }

    // MARK: Slots

    @Test func aFolderSlotNamesBothVariablesAndTheDefaultSlotNamesNone() {
        let folder = URL(fileURLWithPath: "/tmp/agentbar-slot-test/lend/some-id/../some-id")
        let slot = ClaudeSlot.folder(folder)
        let environment = slot.environment
        #expect(environment["CLAUDE_CONFIG_DIR"] == "/tmp/agentbar-slot-test/lend/some-id")
        #expect(environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == "/tmp/agentbar-slot-test/lend/some-id")
        #expect(slot.identityFile.path == "/tmp/agentbar-slot-test/lend/some-id/.claude.json")
        #expect(slot.service == AccountFiles.claudeService(URL(fileURLWithPath: "/tmp/agentbar-slot-test/lend/some-id")))
        #expect(slot.service.hasPrefix("Claude Code-credentials-") && slot.account == NSUserName())

        let standIn = ClaudeSlot.defaultLogin(identityFile: URL(fileURLWithPath: "/tmp/agentbar-slot-test/.claude.json"), service: "fake-service")
        #expect(standIn.environment["CLAUDE_CONFIG_DIR"] == nil && standIn.environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == nil)
        #expect(standIn.environment == ProviderCLI.processEnvironment())
        #expect(standIn.directory == nil && standIn.service == "fake-service")
        #expect(ClaudeSlot.defaultLogin().service == "Claude Code-credentials")
        #expect(ClaudeSlot.defaultLogin().identityFile.lastPathComponent == ".claude.json")
        #expect(ClaudeSlot.defaultLogin().identityFile.deletingLastPathComponent().path
                == FileManager.default.homeDirectoryForCurrentUser.path)
    }

    // MARK: Identity

    @Test func identityComparesTheAccountUUIDAndTheOrganizationTogether() {
        let account = UsageAccount(id: UUID(), provider: .claude, name: "a",
                                   identity: AccountIdentity(email: "a@example.test", organizationID: "ORG-1", stableID: "ACC-1"))
        func identity(_ acc: String?, _ org: String?, _ email: String? = nil) -> ClaudeSlotIdentity {
            ClaudeSlotIdentity(ClaudeOAuthAccount(claudeJSON: json(account: acc, organization: org, email: email)), hasLogin: true)
        }
        #expect(identity("acc-1", "org-1").matches(account))
        #expect(!identity("acc-1", "org-2").matches(account))
        #expect(!identity("acc-2", "org-1").matches(account))
        #expect(!identity(nil, "org-1").matches(account))
        // The email is display information: with an account UUID on both sides it does not decide.
        #expect(identity("acc-1", "org-1", "other@example.test").matches(account))
    }

    @Test func withoutAnAccountUUIDTheOrganizationAndTheEmailMustBothAgree() {
        let account = UsageAccount(id: UUID(), provider: .claude, name: "a",
                                   identity: AccountIdentity(email: "A@Example.test", organizationID: "org-1"))
        func identity(_ org: String?, _ email: String?) -> ClaudeSlotIdentity {
            ClaudeSlotIdentity(ClaudeOAuthAccount(claudeJSON: json(account: "acc-1", organization: org, email: email)), hasLogin: true)
        }
        #expect(identity("ORG-1", "a@example.test").matches(account))
        #expect(!identity("org-1", "b@example.test").matches(account))
        #expect(!identity("org-2", "a@example.test").matches(account))
        #expect(!identity("org-1", nil).matches(account))
        #expect(!identity(nil, "a@example.test").matches(account))
        let noEmail = UsageAccount(id: UUID(), provider: .claude, name: "n", identity: AccountIdentity(organizationID: "org-1"))
        #expect(!identity("org-1", "a@example.test").matches(noEmail))
        #expect(!ClaudeSlotIdentity.canVerify(noEmail))
        #expect(ClaudeSlotIdentity.canVerify(account))
        #expect(!ClaudeSlotIdentity.canVerify(UsageAccount(id: UUID(), provider: .claude, name: "x")))
        #expect(!ClaudeSlotIdentity.canVerify(UsageAccount(id: UUID(), provider: .codex, name: "x",
                                                           identity: AccountIdentity(email: "e", organizationID: "o", stableID: "s"))))
    }

    @Test func theOAuthAccountBlockIsReadFromTheIdentityFile() throws {
        let full = try #require(ClaudeOAuthAccount(claudeJSON: Data(#"""
        {"numStartups": 9, "projects": {"/a": {}}, "oauthAccount": {"accountUuid": "acc", "emailAddress": "e@example.test",
         "organizationUuid": "org", "organizationName": "Org", "billingType": "stripe"}}
        """#.utf8)))
        #expect(full == ClaudeOAuthAccount(claudeJSON: json(account: "acc", organization: "org", email: "e@example.test")))
        #expect(full.accountUUID == "acc" && full.organizationUUID == "org" && full.email == "e@example.test")
        let empty = try #require(ClaudeOAuthAccount(claudeJSON: Data(#"{"numStartups": 1}"#.utf8)))
        #expect(empty.accountUUID == nil && empty.organizationUUID == nil && empty.email == nil)
        #expect(ClaudeOAuthAccount(claudeJSON: Data("{not json".utf8)) == nil)
        #expect(ClaudeOAuthAccount(claudeJSON: Data("[]".utf8)) == nil)
        let blank = try #require(ClaudeOAuthAccount(claudeJSON: json(account: "", organization: "org", email: nil)))
        #expect(blank.accountUUID == nil && blank.organizationUUID == "org")
    }

    @Test func aSignedOutSlotNeverCountsAsLoggedInToAnAccount() {
        let identity = ClaudeSlotIdentity(ClaudeOAuthAccount(claudeJSON: json(account: "acc", organization: "org", email: "e@example.test")),
                                          hasLogin: false)
        #expect(identity.accountUUID == "acc" && !identity.hasLogin)
    }

    // MARK: Credential

    @Test func aCredentialNeverPrintsItsToken() throws {
        let data = Data(#"{"claudeAiOauth":{"accessToken":"FAKE-ACCESS-9","refreshToken":"FAKE-SECRET-123","scopes":["user:inference","user:profile"]}}"#.utf8)
        let credential = try #require(ClaudeLoginCredential(keychainData: data))
        #expect(credential.refreshToken == "FAKE-SECRET-123" && credential.scopes == ["user:inference", "user:profile"])
        var dumped = ""
        dump(credential, to: &dumped)
        for text in ["\(credential)", String(describing: credential), String(reflecting: credential), dumped, "\([credential])"] {
            #expect(!text.contains("FAKE-SECRET-123") && !text.contains("FAKE-ACCESS-9"))
        }
    }

    @Test func aCredentialNeedsARefreshTokenAndFallsBackToTheDefaultScopes() throws {
        #expect(ClaudeLoginCredential(keychainData: Data(#"{"claudeAiOauth":{"accessToken":"x"}}"#.utf8)) == nil)
        #expect(ClaudeLoginCredential(keychainData: Data(#"{"claudeAiOauth":{"refreshToken":""}}"#.utf8)) == nil)
        #expect(ClaudeLoginCredential(keychainData: Data(#"{"other":{}}"#.utf8)) == nil)
        #expect(ClaudeLoginCredential(keychainData: Data("not json".utf8)) == nil)
        let bare = try #require(ClaudeLoginCredential(keychainData: Data(#"{"claudeAiOauth":{"refreshToken":"t"}}"#.utf8)))
        #expect(bare.scopes == ClaudeLoginCredential.defaultScopes)
        let empty = try #require(ClaudeLoginCredential(keychainData: Data(#"{"claudeAiOauth":{"refreshToken":"t","scopes":[]}}"#.utf8)))
        #expect(empty.scopes == ClaudeLoginCredential.defaultScopes)
    }

    // MARK: Failures

    @Test func onlyInvalidGrantAndFourHundredOrFourHundredOneMeanTheLoginIsDead() {
        for text in ["Login failed: invalid_grant",
                     #"{"error":"invalid_grant","error_description":"Refresh token not found or invalid"}"#,
                     "Request failed with status code 400", "Request failed with status code 401", "HTTP 401 Unauthorized",
                     "status: 400", "HTTP/1.1 400 Bad Request", "400 Bad Request", "401 Unauthorized", "Error: 401",
                     "OAuth error: the refresh token expired", "Refresh token has been revoked", "Unauthorized"] {
            #expect(ClaudeCodeOutput.classify(text) == .invalid, "\(text)")
        }
        for text in ["", "ECONNRESET socket hang up", "getaddrinfo ENOTFOUND platform.claude.com", "fetch failed", "Request timed out",
                     "Request failed with status code 403", "Request failed with status code 429", "Request failed with status code 503",
                     "HTTP 500 Internal Server Error", "listening on port 40001", "took 4000ms", "id 14015", "Login failed: unknown error"] {
            #expect(ClaudeCodeOutput.classify(text) == .transient, "\(text)")
        }
    }

    @Test func scrubbedOutputKeepsTheMessageButNotTheTokens() {
        let text = "Login failed: invalid_grant for FAKE-SECRET-123 and sk-ant-ort01-ABCDEFGHIJKLMNOP and Bearer abcdefgh12345678\n"
        let scrubbed = ClaudeCodeOutput.scrubbed(text, secrets: ["FAKE-SECRET-123", ""])
        #expect(scrubbed == "Login failed: invalid_grant for [redacted] and [redacted] and [redacted]")
        let long = ClaudeCodeOutput.scrubbed(String(repeating: "x", count: 5_000), limit: 100)
        #expect(long.count == 101 && long.hasSuffix("…"))
    }

    // MARK: Filling in the account UUID

    @Test func theAccountUUIDIsTakenFromTheLoginFolderOnlyWhenTheOrganizationIsTheRegisteredOne() {
        func account(stableID: String? = nil, organization: String? = "org-1", provider: ProviderKind = .claude) -> UsageAccount {
            UsageAccount(id: UUID(), provider: provider, name: "a",
                         identity: AccountIdentity(email: "a@example.test", organizationID: organization, stableID: stableID))
        }
        let file = json(account: "acc-1", organization: "org-1", email: "a@example.test")
        #expect(ClaudeAccountUUIDFill.stableID(for: account(), claudeJSON: file) == "acc-1")
        #expect(ClaudeAccountUUIDFill.stableID(for: account(organization: "ORG-1"), claudeJSON: file) == "acc-1")
        // Another organization, no registered organization, a value already there, another provider: nothing to fill.
        #expect(ClaudeAccountUUIDFill.stableID(for: account(organization: "org-2"), claudeJSON: file) == nil)
        #expect(ClaudeAccountUUIDFill.stableID(for: account(organization: nil), claudeJSON: file) == nil)
        #expect(ClaudeAccountUUIDFill.stableID(for: account(stableID: "acc-0"), claudeJSON: file) == nil)
        #expect(ClaudeAccountUUIDFill.stableID(for: account(provider: .codex), claudeJSON: file) == nil)
        #expect(ClaudeAccountUUIDFill.stableID(for: UsageAccount(id: UUID(), provider: .claude, name: "x"), claudeJSON: file) == nil)
        // A file without the block, an unreadable one, or none at all.
        #expect(ClaudeAccountUUIDFill.stableID(for: account(), claudeJSON: Data(#"{"numStartups":1}"#.utf8)) == nil)
        #expect(ClaudeAccountUUIDFill.stableID(for: account(), claudeJSON: Data("{oops".utf8)) == nil)
        #expect(ClaudeAccountUUIDFill.stableID(for: account(), claudeJSON: nil) == nil)
    }

    @Test func theFillReadsTheDotClaudeJSONInTheLoginFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agentbar-fill-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let account = UsageAccount(id: UUID(), provider: .claude, name: "a",
                                   identity: AccountIdentity(email: "a@example.test", organizationID: "org-1"))
        #expect(ClaudeAccountUUIDFill.stableID(for: account, loginDirectory: folder) == nil)
        try json(account: "acc-1", organization: "org-1", email: "a@example.test").write(to: folder.appendingPathComponent(".claude.json"))
        #expect(ClaudeAccountUUIDFill.stableID(for: account, loginDirectory: folder) == "acc-1")
    }
}

private func json(account: String?, organization: String?, email: String?) -> Data {
    var block: [String: Any] = [:]
    if let account { block["accountUuid"] = account }
    if let organization { block["organizationUuid"] = organization }
    if let email { block["emailAddress"] = email }
    return (try? JSONSerialization.data(withJSONObject: ["oauthAccount": block])) ?? Data()
}
