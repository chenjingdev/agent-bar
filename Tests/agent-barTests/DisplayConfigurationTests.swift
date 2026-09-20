import AppKit
import SwiftUI
import Testing
@testable import agent_bar

struct DisplayConfigurationTests {
    private func snapshot(_ provider: ProviderKind, fiveHour: Int? = 18, weekly: Int? = 42, stale: Bool = false) -> ProviderSnapshot {
        ProviderSnapshot(provider: provider, updatedAt: .now,
            fiveHour: fiveHour.map { WindowSummary(tokens: $0, limitTokens: 100, resetAt: .now.addingTimeInterval(3600), displayStyle: .percentage) },
            weekly: weekly.map { WindowSummary(tokens: $0, limitTokens: 100, resetAt: .now.addingTimeInterval(36000), displayStyle: .percentage) },
            modelWeeklies: [], planName: "Pro", sourceDescription: "Fixture", note: nil, isStale: stale, requiresLogin: false)
    }

    @Test func syncAssignsDistinctColorsAndKeepsOrderStable() {
        let work = UsageAccount(id: UUID(), provider: .claude, name: "Work")
        let home = UsageAccount(id: UUID(), provider: .claude, name: "Home")
        let codex = UsageAccount(id: UUID(), provider: .codex, name: "Codex")
        var value = DisplayConfiguration()
        value.sync([work, codex])
        #expect(value.order == [work.id, codex.id])
        #expect(value.display(work).color == .blue)
        #expect(value.display(codex).color == .purple)
        #expect(value.display(work).badge == "CL")
        value.move(codex.id, offset: -1)
        #expect(value.order == [codex.id, work.id])
        value.sync([work, home, codex])
        #expect(value.order == [codex.id, work.id, home.id])
        #expect(value.display(home).color != value.display(work).color)
        #expect(value.display(work).badge == "CL" && value.display(home).badge == "CL2")
        value.setVisible(home.id, false)
        #expect(value.visibleAccountIDs == [codex.id, work.id])
        #expect(value.refreshAccountIDs == [codex.id, work.id])
        value.update(home.id) { $0.group = 1 }; value.update(codex.id) { $0.group = 1 }
        #expect(value.menuBarGroups().map(\.accountIDs) == [[codex.id], [work.id]])
        value.setVisible(home.id, true)
        #expect(value.menuBarGroups().map(\.accountIDs) == [[codex.id, home.id], [work.id]])
        #expect(value.menuBarGroups()[0].key == DisplayConfiguration.groupKey(1))
        value.setVisible(home.id, false)
        value.update(work.id) { $0.badge = "  Work account long  " }
        #expect(value.display(work).badge == "Work acc")
        #expect(value.valid)
        value.sync([home])
        #expect(value.order == [home.id])
        #expect(value.accounts.count == 1)
        let refused = value.setComponent(badge: false, bar: false, percent: false)
        #expect(!refused && value.showsAnything)
        let accepted = value.setComponent(bar: false, percent: false)
        #expect(accepted && value.showBadge && !value.showBar)
    }

    @Test func earlierVersionTwoFilesDecodeWithDefaultStyle() throws {
        let id = UUID()
        let json = """
        {"version":2,"order":["\(id.uuidString)"],"accounts":{"\(id.uuidString)":{"badge":"CL","color":"blue","visible":true}},"showBadge":true,"showBar":true,"showPercent":true,"barMetric":"weekly"}
        """
        let value = try JSONDecoder().decode(DisplayConfiguration.self, from: Data(json.utf8))
        #expect(value.style == .badge)
        #expect(value.rowsPerColumn == 2 && value.accounts[id.uuidString]?.group == 0)
        let compact = try JSONDecoder().decode(DisplayConfiguration.self, from: Data(json.replacingOccurrences(of: "\"version\":2", with: "\"version\":2,\"compact\":true").utf8))
        #expect(compact.accounts[id.uuidString]?.group == 1)
        #expect(value.accounts[id.uuidString]?.bars == AccountDisplay.defaultBars)
        #expect(value.accounts[id.uuidString]?.primary == "weekly")
        let shared = try JSONDecoder().decode(DisplayConfiguration.self, from: Data(json.replacingOccurrences(of: "\"weekly\"", with: "\"fiveHour\"").utf8))
        #expect(shared.accounts[id.uuidString]?.primary == "5h")
        #expect(value.valid)
        var changed = value; changed.style = .ring; changed.rowsPerColumn = 3; changed.update(id) { $0.group = 2 }
        changed.update(id) { $0.bars = ["5h"] }
        let round = try JSONDecoder().decode(DisplayConfiguration.self, from: JSONEncoder().encode(changed))
        #expect(round == changed)
    }

    @Test @MainActor func everyStyleRendersAndOnlyMultiBarDrawsSecondaryLimits() throws {
        let account = UsageAccount(id: UUID(), provider: .claude, name: "Work")
        var config = DisplayConfiguration(); config.sync([account]); config.update(account.id) { $0.badge = "Work" }
        let full = ProviderSnapshot(provider: .claude, updatedAt: .now,
            fiveHour: WindowSummary(tokens: 18, limitTokens: 100, resetAt: nil, displayStyle: .percentage),
            weekly: WindowSummary(tokens: 92, limitTokens: 100, resetAt: nil, displayStyle: .percentage),
            modelWeeklies: [ModelWeeklySummary(label: "Fable", window: WindowSummary(tokens: 64, limitTokens: 100, resetAt: nil, displayStyle: .percentage))],
            planName: "Max", sourceDescription: "Fixture", note: nil, isStale: false, requiresLogin: false)
        let entry = MenuBarEntry(account: account, display: config.display(account), metric: .menuBar(full, preferred: "weekly"),
                                 metrics: DisplayMetric.all(full), stale: false, requiresLogin: false)
        #expect(entry.secondary.map(\.id) == ["5h", "model:fable"])
        var narrowed = entry; narrowed.display.bars = ["weekly", "model:fable"]
        #expect(narrowed.secondary.map(\.id) == ["model:fable"])
        let out = ProcessInfo.processInfo.environment["AGENTBAR_QA_ARTIFACT_DIR"].map { URL(fileURLWithPath: $0) }
        if let out { try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true) }
        var widths: [MenuBarStyle: CGFloat] = [:]
        for style in MenuBarStyle.allCases {
            config.style = style
            let image = DisplayStatusRenderer.render(entry: entry, config: config)
            #expect(image.size.height == 22 && image.size.width > 0)
            widths[style] = image.size.width
            if let out, let rep = image.representations.first as? NSBitmapImageRep {
                try rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("style-\(style.rawValue).png"))
            }
        }
        // Capsule stays compact. Ring reserves room for a readable full-size percentage beside the gauge.
        #expect(widths[.capsule]! < widths[.badge]!)
        #expect(widths[.ring]! > widths[.capsule]!)
        #expect(widths[.capsule]! == DisplayStatusRenderer.barWidth + DisplayStatusRenderer.inset * 2)
        config.style = .bars
        #expect(DisplayStatusRenderer.rows(entry, config: config).map(\.label) == ["Work·WK", "Work·5H", "Work·FAB"])
        var single = entry; single.display.bars = []
        #expect(DisplayStatusRenderer.rows(single, config: config).count == 1)
        var many = entry; many.metrics += [DisplayMetric(id: "model:opus", title: "Opus Weekly", window: full.weekly)]; many.display.bars.insert("model:opus")
        #expect(DisplayStatusRenderer.rows(many, config: config).count == DisplayStatusRenderer.maxBars)
        config.style = .capsule; config.showPercent = false
        #expect(DisplayStatusRenderer.render(entry: entry, config: config).size.width == widths[.capsule])
        // Compact stacks rows: two accounts in one column are no wider than one, three overflow into a second column.
        var second = entry; second.account = UsageAccount(id: UUID(), provider: .codex, name: "Codex")
        second.display = AccountDisplay(badge: "CX", color: .purple)
        var third = entry; third.account = UsageAccount(id: UUID(), provider: .claude, name: "Home")
        third.display = AccountDisplay(badge: "Home", color: .orange)
        for style in MenuBarStyle.allCases {
            config.style = style; config.showPercent = true; config.rowsPerColumn = style == .bars ? 6 : 2
            let single = DisplayStatusRenderer.render(entries: [entry], config: config)
            let stacked = DisplayStatusRenderer.render(entries: [entry, second], config: config)
            let overflow = DisplayStatusRenderer.render(entries: [entry, second, third], config: config)
            if style == .text {
                #expect(stacked.size.height == 22 && stacked.size.width > single.size.width)
                #expect(overflow.size.width > stacked.size.width)
            } else {
                #expect(stacked.size.height == 22 && stacked.size.width <= single.size.width + 1)
                #expect(overflow.size.width > stacked.size.width + DisplayStatusRenderer.columnGap)
            }
            if let out, let rep = overflow.representations.first as? NSBitmapImageRep {
                try rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("compact-\(style.rawValue).png"))
            }
        }
        config.rowsPerColumn = 1
        #expect(DisplayStatusRenderer.render(entries: [entry, second], config: config).size.width > DisplayStatusRenderer.render(entries: [entry], config: config).size.width)
    }

    @Test func menuBarMetricFallsBackWhenPreferredHasNoData() {
        let weeklyOnly = snapshot(.codex, fiveHour: nil)
        #expect(DisplayMetric.menuBar(weeklyOnly, preferred: "5h").id == "weekly")
        #expect(DisplayMetric.menuBar(weeklyOnly, preferred: "weekly").id == "weekly")
        let both = snapshot(.claude)
        #expect(DisplayMetric.menuBar(both, preferred: "5h").id == "5h")
        let placeholder = ProviderSnapshot.placeholder(for: .claude)
        #expect(DisplayMetric.menuBar(placeholder, preferred: "weekly").id == "weekly")
        #expect(DisplayMetric.menuBar(placeholder, preferred: "weekly").window?.utilization == nil)
    }

    @Test func legacyItemsMigrateToPerAccountVisibility() throws {
        let shown = UsageAccount(id: UUID(), provider: .claude, name: "Shown")
        let grouped = UsageAccount(id: UUID(), provider: .claude, name: "Grouped")
        let parked = UsageAccount(id: UUID(), provider: .codex, name: "Parked")
        let unknown = UsageAccount(id: UUID(), provider: .codex, name: "Unassigned")
        let legacy = LegacyDisplayConfiguration(activeCount: 1, items: [
            LegacyDisplayItem(accountIDs: [shown.id, grouped.id], showService: false, showBars: true, showPercent: true),
            LegacyDisplayItem(accountIDs: [parked.id]),
        ], metrics: [shown.id.uuidString: ["5h"]])
        let value = DisplayConfiguration.migrated(from: legacy, accounts: [unknown, parked, grouped, shown])
        #expect(value.rowsPerColumn == 2)
        #expect(value.display(shown).group == 1 && value.display(grouped).group == 1 && value.display(parked).group == 0)
        #expect(value.menuBarGroups().map(\.accountIDs) == [[shown.id, grouped.id]])
        #expect(value.display(shown).bars == ["5h"])
        #expect(value.display(shown).badge == "CL" && value.display(grouped).badge == "CL2")
        #expect(value.display(grouped).bars == AccountDisplay.defaultBars)
        #expect(value.order == [shown.id, grouped.id, parked.id, unknown.id])
        #expect(value.visibleAccountIDs == [shown.id, grouped.id])
        #expect(!value.showBadge && value.showBar && value.showPercent)
        #expect(value.display(shown).primary == "5h")
        #expect(value.display(grouped).primary == "weekly")
        #expect(value.valid)
    }

    @Test @MainActor func persistenceMigrationRecoveryAndRendering() throws {
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
            try files.write(snapshot(account.provider), to: files.cache(account).deletingLastPathComponent().appendingPathComponent("last-good.json"))
        }
        // An existing item-based file is migrated once and left in place.
        let legacyURL = root.appendingPathComponent("display-v1.json")
        let legacy = LegacyDisplayConfiguration(activeCount: 1, items: [LegacyDisplayItem(accountIDs: [b.id]), LegacyDisplayItem(accountIDs: [a.id])])
        try files.write(legacy, to: legacyURL)
        let legacyData = try Data(contentsOf: legacyURL)
        let store = UsageStore(settings: settings, availableProviders: [], files: files, autoRefresh: false)
        #expect(store.displayConfiguration.visibleAccountIDs == [b.id])
        #expect(store.displayConfiguration.order == [b.id, a.id])
        #expect(try Data(contentsOf: legacyURL) == legacyData)
        let url = root.appendingPathComponent("display-v2.json")
        #expect(FileManager.default.fileExists(atPath: url.path))

        store.updateDisplay { $0.setVisible(a.id, true); $0.update(a.id) { $0.badge = "Home"; $0.color = .orange; $0.primary = "5h" } }
        let again = UsageStore(settings: settings, availableProviders: [], files: files, autoRefresh: false)
        #expect(again.displayConfiguration == store.displayConfiguration)

        let out = ProcessInfo.processInfo.environment["AGENTBAR_QA_ARTIFACT_DIR"].map { URL(fileURLWithPath: $0) }
        if let out { try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true) }
        let entry = store.menuBarEntry(for: a)
        #expect(entry.display.badge == "Home")
        #expect(entry.metric.id == "5h")
        // Every toggle combination is sized from its visible contents, not fixed slots.
        var widths: [CGFloat] = []
        for mask in 1..<8 {
            var config = store.displayConfiguration
            config.showBadge = mask & 1 != 0; config.showBar = mask & 2 != 0; config.showPercent = mask & 4 != 0
            for scale: CGFloat in [1, 2] {
                let image = DisplayStatusRenderer.render(entry: entry, config: config, scale: scale)
                #expect(image.size.height == 22)
                #expect(image.size.width > 0)
                if scale == 2 { widths.append(image.size.width) }
                if mask == 2 { #expect(image.size.width == DisplayStatusRenderer.barWidth + DisplayStatusRenderer.inset * 2) }
                if let out, scale == 2, let rep = image.representations.first as? NSBitmapImageRep {
                    try rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("combination-\(mask).png"))
                }
            }
        }
        #expect(widths.max() == widths.last) // all three components is the widest
        let stale = MenuBarEntry(account: b, display: store.displayConfiguration.display(b),
                                 metric: .menuBar(snapshot(.claude, stale: true), preferred: "weekly"), stale: true, requiresLogin: false)
        let staleImage = DisplayStatusRenderer.render(entry: stale, config: store.displayConfiguration)
        if let out, let rep = staleImage.representations.first as? NSBitmapImageRep {
            try rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("status-stale.png"))
        }
        let view = NSHostingView(rootView: AccountPopoverView(accountID: b.id).environmentObject(store))
        view.frame = NSRect(x: 0, y: 0, width: 392, height: 520); view.layoutSubtreeIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: rep)
        if let out { try rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("popover.png")) }

        let broken = Data("{bad".utf8); try broken.write(to: url)
        let recovered = UsageStore(settings: settings, availableProviders: [], files: files, autoRefresh: false)
        #expect(recovered.accounts.count == 2)
        #expect(recovered.displayError != nil)
        #expect(try Data(contentsOf: url) == broken)
        recovered.updateDisplay { $0.setVisible(a.id, false) }
        #expect(try files.read(DisplayConfiguration.self, at: url).visibleAccountIDs == [b.id])
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix("display-preserved-") })
    }
}
