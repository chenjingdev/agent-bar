import AppKit
import SwiftUI
import Testing
@testable import agent_bar

struct DisplayConfigurationTests {
    @Test func inactiveAssignmentsRestoreUnlessMoved() {
        var value = DisplayConfiguration()
        let account = UUID(), other = UUID(), first = value.items[0].id, second = value.items[1].id
        value.assign(account, to: second)
        value.assign(account, to: first)
        #expect(value.items[0].accountIDs.isEmpty)
        value.resize(1)
        #expect(value.available(account, for: first))
        value.resize(2)
        #expect(value.items[1].accountIDs == [account])
        value.resize(1); value.assign(account, to: first); value.resize(2)
        #expect(value.items[1].accountIDs.isEmpty)
        value.assign(other, to: first); value.reorder(other, in: first, offset: -1)
        #expect(value.items[0].accountIDs == [other, account])
        value.assign(account, to: second, moving: true)
        #expect(value.items[0].accountIDs == [other])
        #expect(value.items[1].accountIDs == [account])
        value.prune([account]); #expect(value.items[0].accountIDs.isEmpty)
        #expect(value.valid)
    }
    @Test func fiveHourAppearsOnlyWhenSelectedAndAvailable() {
        let account = UsageAccount(id: UUID(), provider: .codex, name: "Personal")
        var config = DisplayConfiguration(); config.assign(account.id, to: config.items[0].id)
        var snapshot = ProviderSnapshot.placeholder(for: .codex)
        snapshot = ProviderSnapshot(provider: .codex, updatedAt: .now, fiveHour: nil, weekly: WindowSummary(tokens: 0, limitTokens: 100, resetAt: nil, displayStyle: .percentage), modelWeeklies: [], planName: "Pro", sourceDescription: "Fixture", note: nil, isStale: false, requiresLogin: false)
        var rows = DisplayRow.make(item: config.items[0], accounts: [account], snapshots: [account.id: snapshot], config: config)
        #expect(rows.map(\.metric.id) == ["weekly"])
        #expect(rows.first?.metric.window?.utilization == 0)
        let appeared = ProviderSnapshot(provider: .codex, updatedAt: .now, fiveHour: WindowSummary(tokens: 18, limitTokens: 100, resetAt: nil, displayStyle: .percentage), weekly: snapshot.weekly, modelWeeklies: [], planName: "Pro", sourceDescription: "Fixture", note: nil, isStale: false, requiresLogin: false)
        rows = DisplayRow.make(item: config.items[0], accounts: [account], snapshots: [account.id: appeared], config: config)
        #expect(rows.map(\.metric.id) == ["5h", "weekly"])
        config.metrics[account.id.uuidString] = ["weekly"]
        #expect(DisplayRow.make(item: config.items[0], accounts: [account], snapshots: [account.id: appeared], config: config).count == 1)
    }
    @Test @MainActor func persistenceRecoveryAndNativeRendering() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentbar-display-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let files = AccountFiles(root: root)
        let suite = "agentbar-display-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let a = UsageAccount(id: UUID(), provider: .codex, name: "Codex Personal", credentialID: UUID())
        let b = UsageAccount(id: UUID(), provider: .claude, name: "Claude Work", credentialID: UUID())
        var registry = AccountRegistry(accounts: [a,b]); registry.repairRepresentatives()
        try files.write(registry, to: files.registryURL)
        for account in [a,b] {
            let snapshot = ProviderSnapshot(provider: account.provider, updatedAt: .now,
                fiveHour: WindowSummary(tokens: 18, limitTokens: 100, resetAt: .now.addingTimeInterval(3600), displayStyle: .percentage),
                weekly: WindowSummary(tokens: 42, limitTokens: 100, resetAt: .now.addingTimeInterval(36000), displayStyle: .percentage),
                modelWeeklies: [], planName: "Pro", sourceDescription: "Fixture", note: nil, isStale: false, requiresLogin: false)
            try files.write(snapshot, to: files.cache(account).deletingLastPathComponent().appendingPathComponent("last-good.json"))
        }
        let store = UsageStore(settings: settings, availableProviders: [], files: files, autoRefresh: false)
        let id = store.displayConfiguration.items[0].id
        store.updateDisplay { $0.assign(a.id, to: id, moving: true); $0.resize(1); $0.items[0].maxRows = 4 }
        let again = UsageStore(settings: settings, availableProviders: [], files: files, autoRefresh: false)
        #expect(again.displayConfiguration == store.displayConfiguration)
        let rows = store.displayRows(store.displayConfiguration.items[0])
        #expect(rows.count == 4)
        #expect(DisplayStatusRenderer.badgeStarts([rows]).flatMap { $0 }.count == 2)
        #expect(DisplayStatusRenderer.badgeStarts(DisplayRow.columns(rows, maximum: 1)).flatMap { $0 }.count == 2)
        let out = ProcessInfo.processInfo.environment["AGENTBAR_QA_ARTIFACT_DIR"].map { URL(fileURLWithPath: $0) }
        if let out { try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true) }
        let extra = rows.suffix(2).map { original -> DisplayRow in
            var row = original
            row.account = UsageAccount(id: UUID(), provider: original.account.provider, name: "Third fixture account")
            return row
        }
        let densityRows = rows + extra
        #expect(densityRows.count == 6)
        for maximum in 1...6 {
            var item = store.displayConfiguration.items[0]; item.maxRows = maximum
            #expect(DisplayRow.columns(rows, maximum: maximum).flatMap { $0 }.map(\.id) == rows.map(\.id))
            for scale: CGFloat in [1,2] {
                let image = DisplayStatusRenderer.render(item: item, rows: densityRows, number: 1, scale: scale)
                #expect(image.size.height == 22)
                #expect(image.size.width > 0)
                if let out, let rep = image.representations.first as? NSBitmapImageRep {
                    try rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("status-\(maximum)-\(Int(scale))x.png"))
                }
            }
        }
        // Every toggle combination is sized from its visible contents, not fixed slots.
        for mask in 0..<8 {
            var item = store.displayConfiguration.items[0]
            item.showService = mask & 1 != 0; item.showBars = mask & 2 != 0; item.showPercent = mask & 4 != 0
            let image = DisplayStatusRenderer.render(item: item, rows: rows, number: 1)
            #expect(image.size.width > 0)
            if mask == 2 { #expect(image.size.width == 34) } // 28pt track + equal 3pt margins
            if mask == 4 { #expect(image.size.width < 32) } // no former fixed percentage slot
            if let out, let rep = image.representations.first as? NSBitmapImageRep {
                try rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("combination-\(mask).png"))
            }
        }
        let view = NSHostingView(rootView: DisplayPopoverView(itemID: id).environmentObject(store))
        view.frame = NSRect(x: 0, y: 0, width: 392, height: 568); view.layoutSubtreeIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: rep)
        if let out { try rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("display-detail.png")) }
        let url = root.appendingPathComponent("display-v1.json")
        let broken = Data("{bad".utf8); try broken.write(to: url)
        let recovered = UsageStore(settings: settings, availableProviders: [], files: files, autoRefresh: false)
        #expect(recovered.accounts.count == 2)
        #expect(recovered.displayError != nil)
        #expect(try Data(contentsOf: url) == broken)
        recovered.updateDisplay { $0.resize(3) }
        #expect(try files.read(DisplayConfiguration.self, at: url).activeCount == 3)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix("display-preserved-") })
    }
}
