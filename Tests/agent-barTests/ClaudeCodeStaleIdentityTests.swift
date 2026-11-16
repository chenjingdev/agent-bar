import Foundation
import Testing
@testable import agent_bar

// 2026-11-13 20:05 (t1d1's report): ~/.claude.json named account `a` while the default slot held `d`'s token. Handing
// that token back to `a` replaced a's own unused lend login and then threw both away.
struct ClaudeCodeStaleIdentityTests {
    @Test func aStaleIdentityFileDoesNotCostTheAccountsOwnLendLogin() throws {
        let f = try SwitchFixture()
        let a = f.addAccount("a"), d = f.addAccount("d"), c = f.addAccount("c")
        f.signInDefault(d)
        let person = f.world.person("a@example.test")
        let stale: [String: Any] = ["oauthAccount": ["accountUuid": person.accountUUID, "emailAddress": "a@example.test",
                                                       "organizationUuid": person.organizationUUID]]
        try JSONSerialization.data(withJSONObject: stale).write(to: f.defaultSlot.identityFile)
        try f.saveLogin(for: a)
        try f.saveLogin(for: c)

        let result = f.switchTo(c)

        #expect(f.defaultEmail == "c@example.test")
        guard case .switched(let switched) = result.outcome else { Issue.record("not switched: \(result.outcome)"); return }
        #expect(switched.needsLogin.isEmpty)
        #expect(f.switcher.hasLendLogin(for: a))
        // The hand-back went in, was found to be d's, and a's own login was put back.
        #expect(f.world.events.filter { $0.hasPrefix("login lend(a)") }.count == 2)
    }
}
