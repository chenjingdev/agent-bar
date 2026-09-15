import AppKit
import Testing
@testable import agent_bar

@MainActor
struct StatusBarClickTests {
    @Test("Every physical item opens its own configured account group")
    func itemsRouteToTheirOwnPopoverAndRestoreAfterHiding() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("item-routing-\(UUID())")
        let suite = "item-routing-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let files = AccountFiles(root: root)
        let a = UsageAccount(id: UUID(), provider: .claude, name: "A")
        let b = UsageAccount(id: UUID(), provider: .codex, name: "B")
        var registry = AccountRegistry(accounts: [a,b]); registry.repairRepresentatives()
        try files.write(registry, to: files.registryURL)
        let store = UsageStore(settings: AppSettings(defaults: defaults), availableProviders: [], files: files, autoRefresh: false)
        let coordinator = StatusBarCoordinator(store: store, providers: [.claude, .codex])
        defer { coordinator.removeAll() }
        let first = store.displayConfiguration.items[0].id
        let second = store.displayConfiguration.items[1].id
        #expect(coordinator.physicalStatusItemCount == 2)
        #expect(coordinator.popoverItemID(for: first) == first)
        #expect(coordinator.popoverItemID(for: second) == second)
        store.updateDisplay { $0.assign(b.id, to: first, moving: true); $0.resize(1) }
        try await waitFor { coordinator.physicalStatusItemCount == 1 }
        #expect(store.displayConfiguration.items[0].accountIDs == [a.id,b.id])
        #expect(coordinator.popoverItemID(for: first) == first)
        #expect(coordinator.popoverItemID(for: second) == nil)
        // An empty item remains a clickable recovery target after restoration.
        store.updateDisplay { $0.resize(2) }
        try await waitFor { coordinator.physicalStatusItemCount == 2 }
        #expect(coordinator.popoverItemID(for: second) == second)
        #expect((coordinator.statusItemLength(for: second) ?? 0) > 0)
        #expect(store.displayConfiguration.items[1].accountIDs.isEmpty)
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition() {
            if Date() >= deadline { throw AccountError.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
