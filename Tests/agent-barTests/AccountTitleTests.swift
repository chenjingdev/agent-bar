import Foundation
import Testing
@testable import agent_bar

// Everywhere an account is named it is named by its login email; only an account without one shows its provider.
struct AccountTitleTests {
    @Test func anAccountIsNamedByItsEmailElseItsProvider() {
        let claude = UsageAccount(id: UUID(), provider: .claude,
                                  identity: AccountIdentity(email: "a@example.test", organization: "Team"), credentialID: UUID())
        #expect(claude.title == "a@example.test")
        #expect(UsageAccount(id: UUID(), provider: .codex, identity: AccountIdentity(email: ""), credentialID: UUID()).title == "Codex")
        #expect(UsageAccount(id: UUID(), provider: .claude).title == "Claude")
    }

    @Test func theUsageLinePickerPutsTheProviderTagBeforeTheEmail() {
        let codex = UsageAccount(id: UUID(), provider: .codex, identity: AccountIdentity(email: "a@example.test"), credentialID: UUID())
        #expect(codex.providerTaggedTitle == "CX a@example.test")
        #expect(UsageAccount(id: UUID(), provider: .claude).providerTaggedTitle == "CL Claude")
    }

    @Test func aNameSavedByAnEarlierVersionIsNotReadAndIsDroppedOnSave() throws {
        let files = AccountFiles(root: FileManager.default.temporaryDirectory.appendingPathComponent("agentbar-tests-\(UUID())"))
        try files.createPrivateDirectory(files.root)
        defer { try? FileManager.default.removeItem(at: files.root) }
        let id = UUID()
        let legacy = """
        {"version":1,"representatives":{},"cleanupPending":[],"accounts":[{"id":"\(id.uuidString)","provider":"claude",
        "name":"PB1","deletionPending":false,"identity":{"email":"a@example.test","name":"첸징"}}]}
        """
        try Data(legacy.utf8).write(to: files.registryURL)
        let registry = try files.load()
        #expect(registry.accounts.first?.title == "a@example.test")
        try files.write(registry, to: files.registryURL)
        let text = try String(contentsOf: files.registryURL, encoding: .utf8)
        #expect(!text.contains("PB1") && !text.contains("첸징"))
    }
}
