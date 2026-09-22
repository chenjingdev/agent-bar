import AppKit
import Testing
@testable import agent_bar

@MainActor
struct StatusBarClickTests {
    @Test("Every visible account owns one status item that opens its own popover")
    func accountsRouteToTheirOwnPopoverAndRestoreAfterHiding() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("item-routing-\(UUID())")
        let suite = "item-routing-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let files = AccountFiles(root: root)
        let a = UsageAccount(id: UUID(), provider: .claude, name: "A")
        let b = UsageAccount(id: UUID(), provider: .codex, name: "B")
        var registry = AccountRegistry(accounts: [a,b]); registry.repairRepresentatives()
        try files.write(registry, to: files.registryURL)
        let store = UsageStore(settings: AppSettings(defaults: defaults), files: files, autoRefresh: false)
        let coordinator = StatusBarCoordinator(store: store, providers: [.claude, .codex])
        defer { coordinator.removeAll() }
        #expect(coordinator.physicalStatusItemCount == 2)
        #expect(coordinator.popoverAccountIDs(for: a.id) == [a.id])
        #expect(coordinator.popoverAccountIDs(for: b.id) == [b.id])
        #expect(coordinator.popoverGroupID(for: a.id) == a.id)
        #expect(coordinator.popoverGroupID(for: b.id) == b.id)
        store.updateDisplay { $0.setVisible(b.id, false) }
        try await waitFor { coordinator.physicalStatusItemCount == 1 }
        #expect(coordinator.popoverAccountIDs(for: a.id) == [a.id])
        #expect(coordinator.popoverAccountIDs(for: b.id) == nil)
        #expect(store.visibleAccounts.map(\.id) == [a.id])
        store.updateDisplay { $0.setVisible(b.id, true) }
        try await waitFor { coordinator.physicalStatusItemCount == 2 }
        #expect(coordinator.popoverAccountIDs(for: b.id) == [b.id])
        #expect((coordinator.statusItemLength(for: b.id) ?? 0) > 0)
        #expect(store.visibleAccounts.map(\.id) == [a.id, b.id])
        // Turning off every component is refused so an item never renders empty.
        store.updateDisplay { $0.setComponent(badge: false, bar: false, percent: false) }
        #expect(store.displayConfiguration.showsAnything)
        // Accounts sharing a group fold into one item whose popover lists them all.
        let group = DisplayConfiguration.groupKey(1)
        store.updateDisplay { $0.update(a.id) { $0.group = 1 }; $0.update(b.id) { $0.group = 1 } }
        try await waitFor { coordinator.physicalStatusItemCount == 1 }
        #expect(coordinator.popoverAccountIDs(for: group) == [a.id, b.id])
        #expect(coordinator.popoverGroupID(for: group) == group)
        #expect(coordinator.popoverAccountIDs(for: a.id) == nil)
        store.updateDisplay { $0.setVisible(a.id, false) }
        try await waitFor { coordinator.popoverAccountIDs(for: group) == [b.id] }
        store.updateDisplay { $0.update(b.id) { $0.group = 0 } }
        try await waitFor { coordinator.popoverAccountIDs(for: b.id) == [b.id] }
        #expect(coordinator.physicalStatusItemCount == 1)
    }

    @Test func settingsContextIdentifiesTheClickedGroupEvenWhenAccountsOverlap() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("group-settings-routing-\(UUID())")
        let suite = "group-settings-routing-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let files = AccountFiles(root: root)
        let account = UsageAccount(id: UUID(), provider: .claude, name: "Shared account")
        let other = UsageAccount(id: UUID(), provider: .codex, name: "Other account")
        var registry = AccountRegistry(accounts: [account, other]); registry.repairRepresentatives()
        try files.write(registry, to: files.registryURL)
        let store = UsageStore(settings: AppSettings(defaults: defaults), files: files, autoRefresh: false)
        defer { store.shutdown() }
        let first = MenuBarLayout(name: "Week", rows: [MenuBarLine(accountID: account.id, metricID: "weekly")])
        let second = MenuBarLayout(name: "Session", rows: [MenuBarLine(accountID: account.id, metricID: "5h")])
        let empty = MenuBarLayout(name: "Empty")
        store.updateDisplay { $0.layouts = [first, second, empty] }
        let coordinator = StatusBarCoordinator(store: store, providers: [.claude, .codex])
        defer { coordinator.removeAll() }
        #expect(coordinator.popoverAccountIDs(for: first.id) == coordinator.popoverAccountIDs(for: second.id))
        #expect(coordinator.popoverGroupID(for: first.id) == first.id)
        #expect(coordinator.popoverGroupID(for: second.id) == second.id)
        #expect(coordinator.popoverGroupID(for: empty.id) == empty.id)

        store.selectMenuBarGroup(try #require(coordinator.popoverGroupID(for: second.id)))
        store.updateDisplay { $0.editLayout(second.id) { $0.name = "Renamed"; $0.rows[0].accountID = other.id } }
        try await waitFor { coordinator.popoverAccountIDs(for: second.id) == [other.id] }
        #expect(coordinator.popoverGroupID(for: second.id) == second.id)
        #expect(store.selectedMenuBarGroupID == second.id)
        store.updateDisplay { $0.editLayouts { $0.reverse() } }
        #expect(store.selectedMenuBarGroupID == second.id)

        // A deleted group must not strand the settings editor on a missing ID.
        store.updateDisplay { $0.editLayouts { $0.removeAll { $0.id == second.id } } }
        #expect(store.selectedMenuBarGroupID == empty.id)
        store.selectMenuBarGroup(UUID())
        #expect(store.selectedMenuBarGroupID == empty.id)
        store.updateDisplay { $0.layouts = [] }
        #expect(store.selectedMenuBarGroupID == nil)
    }

    @Test func draggingReusesNativePositionsAndPersistsGroupRouting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("badge-reorder-\(UUID())")
        let suite = "badge-reorder-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let files = AccountFiles(root: root)
        let account = UsageAccount(id: UUID(), provider: .claude, name: "Shared")
        let registry = AccountRegistry(accounts: [account])
        try files.write(registry, to: files.registryURL)
        let settings = AppSettings(defaults: defaults)
        let store = UsageStore(settings: settings, files: files, autoRefresh: false)
        defer { store.shutdown() }
        let groups = ["weekly", "5h", "model:fable"].map {
            MenuBarLayout(name: $0, rows: [MenuBarLine(accountID: account.id, metricID: $0)])
        }
        store.updateDisplay { $0.layouts = groups }
        let coordinator = StatusBarCoordinator(store: store, providers: [.claude])
        defer { coordinator.removeAll() }
        let before = coordinator.groupOrderOnScreen
        let slots = before.compactMap { coordinator.positionID(for: $0) }
        let first = try #require(before.first), last = try #require(before.last)
        #expect(coordinator.moveFromMenuBar(last, to: first))
        let expectedOrder = [last] + before.dropLast()
        try await waitFor { store.displayConfiguration.effectiveLayouts.map(\.statusItemPositionID).compactMap { $0 } == slots }
        #expect(store.displayConfiguration.effectiveLayouts.map(\.id) == expectedOrder)
        #expect(expectedOrder.compactMap { coordinator.positionID(for: $0) } == slots)
        #expect(coordinator.physicalStatusItemCount == 3)
        for id in expectedOrder {
            #expect(coordinator.popoverGroupID(for: id) == id)
            #expect(coordinator.popoverAccountIDs(for: id) == [account.id])
        }
        #expect(store.selectedMenuBarGroupID == last)
        let saved = try files.read(DisplayConfiguration.self, at: files.root.appendingPathComponent("display-v2.json"))
        #expect(saved.effectiveLayouts.map(\.id) == expectedOrder)
        #expect(saved.effectiveLayouts.compactMap(\.statusItemPositionID) == slots)
        coordinator.removeAll()
        let restoredStore = UsageStore(settings: settings, files: files, autoRefresh: false)
        defer { restoredStore.shutdown() }
        let restored = StatusBarCoordinator(store: restoredStore, providers: [.claude])
        defer { restored.removeAll() }
        #expect(expectedOrder.compactMap { restored.positionID(for: $0) } == slots)
        #expect(!restored.moveFromMenuBar(first, to: first))
        #expect(!restored.moveFromMenuBar(UUID(), to: first))
    }

    @Test func onlyTaggedGroupPayloadsCanReorderBadges() {
        let id = UUID()
        #expect(BadgeDragPayload.groupID(BadgeDragPayload.string(id)) == id)
        #expect(BadgeDragPayload.groupID(id.uuidString) == nil)
        #expect(BadgeDragPayload.groupID("unrelated text") == nil)
        #expect(BadgeDragPayload.groupID(nil) == nil)
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition() {
            if Date() >= deadline { throw AccountError.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
