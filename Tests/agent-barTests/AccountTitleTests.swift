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

// A menu bar group is named by its accounts' emails, in line order and once each.
struct MenuBarGroupTitleTests {
    @Test func aGroupIsNamedByItsAccountsEmailsAndShortensToThePartBeforeTheAt() {
        func account(_ provider: ProviderKind, _ email: String?) -> UsageAccount {
            UsageAccount(id: UUID(), provider: provider, identity: AccountIdentity(email: email), credentialID: UUID())
        }
        let home = account(.claude, "chenjingdev@gmail.com")
        let kakao = account(.codex, "chenjing@kakao.com"), work = account(.codex, "chenjing@naddle.net")
        #expect(MenuBarLayout.title(for: [home, home]) == "chenjingdev@gmail.com")
        #expect(MenuBarLayout.title(for: [home, home], short: true) == "chenjingdev")
        #expect(MenuBarLayout.title(for: [kakao, work]) == "chenjing@kakao.com · chenjing@naddle.net")
        #expect(MenuBarLayout.title(for: [kakao, work], short: true) == "chenjing", "the same part before @ is shown once")
        #expect(MenuBarLayout.title(for: [account(.codex, nil)], short: true) == "Codex")
        #expect(MenuBarLayout.title(for: []) == "Empty group")
    }

    @Test @MainActor func theStoreNamesAGroupByTheAccountsOfItsLines() throws {
        let files = AccountFiles(root: FileManager.default.temporaryDirectory.appendingPathComponent("agentbar-tests-\(UUID())"))
        try files.createPrivateDirectory(files.root)
        defer { try? FileManager.default.removeItem(at: files.root) }
        let a = UsageAccount(id: UUID(), provider: .claude, identity: AccountIdentity(email: "a@example.test"), credentialID: UUID())
        let b = UsageAccount(id: UUID(), provider: .codex, identity: AccountIdentity(email: "b@example.test"), credentialID: UUID())
        try files.write(AccountRegistry(accounts: [a, b]), to: files.registryURL)
        let suite = "group-title-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageStore(settings: AppSettings(defaults: defaults), files: files, autoRefresh: false)
        defer { store.shutdown() }
        let group = MenuBarLayout(rows: [MenuBarLine(accountID: b.id, metricID: "weekly"), MenuBarLine(accountID: a.id, metricID: "5h"),
                                         MenuBarLine(accountID: b.id, metricID: "5h")])
        #expect(store.groupTitle(group) == "b@example.test · a@example.test")
        #expect(store.groupTitle(group, short: true) == "b · a")
        #expect(store.groupTitle(MenuBarLayout()) == "Empty group")
    }
}
