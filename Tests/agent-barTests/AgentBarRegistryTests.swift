import Foundation
import Testing
@testable import agent_bar

// agent-bar saves accounts without a name and calls each by its login email. Limi reads that file as it is.
struct AgentBarRegistryTests {
    @Test func anAccountWithoutANameIsCalledByItsEmail() throws {
        let json = #"""
        {"version":1,"accounts":[
          {"id":"5B2D1F0E-1111-4C3A-9C1D-000000000001","provider":"claude","credentialID":"5B2D1F0E-2222-4C3A-9C1D-000000000001",
           "deletionPending":false,"identity":{"email":"cl@example.test"}},
          {"id":"5B2D1F0E-1111-4C3A-9C1D-000000000002","provider":"codex","deletionPending":false}],
         "cleanupPending":[],"representatives":{"claude":"5B2D1F0E-1111-4C3A-9C1D-000000000001"}}
        """#
        let registry = try JSONDecoder().decode(AccountRegistry.self, from: Data(json.utf8))
        #expect(registry.accounts.map(\.name) == ["cl@example.test", ProviderKind.codex.displayName])
        #expect(registry.accounts.first?.isManaged == true)
    }

    // agent-bar's groups have no `showBadge`; the group reads with its default instead of losing every setting.
    @Test func aGroupAgentBarSavedReads() throws {
        let json = #"""
        {"id":"0B6C8C3A-0000-4C3A-9C1D-000000000001","name":"CL","enabled":true,"style":"bars","badgeMode":"common",
         "commonBadgeColor":"orange","showBar":true,"showPercent":true,"rowsPerColumn":2,"percentageLineID":"line",
         "rows":[{"id":"line","accountID":"5B2D1F0E-1111-4C3A-9C1D-000000000001","metricID":"weekly","slot":0,"badgeText":"CL"}],
         "statusItemPositionID":"0B6C8C3A-0000-4C3A-9C1D-000000000002"}
        """#
        let layout = try JSONDecoder().decode(MenuBarLayout.self, from: Data(json.utf8))
        #expect(layout.name == "CL" && layout.showBadge && layout.rows.count == 1 && layout.rowsPerColumn == 2)
        #expect(layout.valid)
    }

    @Test func agentBarsGroupListsEveryVisibleAccount() throws {
        let one = UUID(), two = UUID(), hidden = UUID()
        let json = """
        {"version":2,"order":["\(one.uuidString)","\(two.uuidString)","\(hidden.uuidString)"],"accounts":{"\(one.uuidString)":{"visible":true,"badge":"A","color":"green","primary":"weekly","bars":["weekly"],"group":0},
         "\(two.uuidString)":{"visible":true,"badge":"B","color":"green","primary":"weekly","bars":["weekly"],"group":0},
         "\(hidden.uuidString)":{"visible":false,"badge":"C","color":"green","primary":"weekly","bars":["weekly"],"group":0}},
         "layouts":[{"id":"\(UUID().uuidString)","name":"CL","rows":[{"id":"l","accountID":"\(two.uuidString)","metricID":"weekly"}]}]}
        """
        var config = try JSONDecoder().decode(DisplayConfiguration.self, from: Data(json.utf8))
        config.adoptAgentBarPanels(raw: Data(json.utf8), accounts: [one, two, hidden])
        #expect(config.layouts?.first?.memberIDs == [one, two])
        // A group Limi saved keeps its own members.
        let limi = try JSONEncoder().encode(config)
        var again = try JSONDecoder().decode(DisplayConfiguration.self, from: limi)
        again.layouts![0].memberIDs = nil
        again.adoptAgentBarPanels(raw: limi, accounts: [one, two, hidden])
        #expect(again.layouts?.first?.memberIDs == nil)
    }
}
