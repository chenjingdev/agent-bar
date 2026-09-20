import AppKit
import SwiftUI
import Testing
@testable import agent_bar

@MainActor
struct MenuBarLayoutTests {
    @Test func movingGroupsPreservesTheirSettingsAndHiddenGroups() {
        let a = MenuBarLayout(name: "A")
        let hidden = MenuBarLayout(name: "Hidden", enabled: false)
        let b = MenuBarLayout(name: "B", style: .text)
        var config = DisplayConfiguration(); config.layouts = [a, hidden, b]
        config.moveLayout(a.id, to: b.id)
        #expect(config.layouts == [hidden, b, a])
        config.moveLayout(a.id, to: hidden.id)
        #expect(config.layouts == [a, hidden, b])
        config.moveLayout(UUID(), to: a.id)
        #expect(config.layouts == [a, hidden, b])
    }
    @Test func arrowsMoveIntoEmptySlotsAndSwapOccupiedSlots() {
        let id = UUID()
        let a = MenuBarLine(accountID: id, metricID: "weekly", slot: 1)
        let b = MenuBarLine(accountID: id, metricID: "5h", slot: 2)
        var layout = MenuBarLayout(rows: [a, b])
        layout.moveLine(a.id, offset: -1)
        #expect(layout.rows.map(\.slot) == [0, 2])
        layout.moveLine(b.id, offset: -1)
        layout.moveLine(b.id, offset: -1)
        #expect(layout.rows.map(\.id) == [b.id, a.id])
        #expect(layout.rows.map(\.slot) == [0, 1] && layout.valid)
        layout.moveLine(b.id, offset: -1)
        #expect(layout.rows.first?.slot == 0)
    }

    @Test func emptySlotsKeepTheirPositionAcrossRemovalAndReload() throws {
        let account = UsageAccount(id: UUID(), provider: .claude, name: "A")
        var config = DisplayConfiguration(); config.sync([account])
        let first = MenuBarLine(accountID: account.id, metricID: "weekly")
        let second = MenuBarLine(accountID: account.id, metricID: "5h")
        let group = MenuBarLayout(rows: [first, second])
        config.layouts = [group]
        config.editLayout(group.id) { $0.rows.removeFirst() }
        #expect(config.layouts?[0].rows[0].slot == 1)
        config.editLayout(group.id) { $0.rows.append(MenuBarLine(accountID: account.id, metricID: "weekly", slot: 2)) }
        let loaded = try JSONDecoder().decode(DisplayConfiguration.self, from: JSONEncoder().encode(config))
        #expect(loaded.valid && loaded.layouts?[0].rows.compactMap(\.slot) == [1, 2])
        config.editLayout(group.id) { $0.rows.append(MenuBarLine(accountID: account.id, metricID: "weekly", slot: 2)) }
        #expect(!config.valid)
    }

    @Test func customBadgeIsExactAndIndependentOfLimitAndAccountDefault() throws {
        let account = UsageAccount(id: UUID(), provider: .claude, name: "Work")
        var config = DisplayConfiguration(); config.sync([account])
        let group = MenuBarLayout(rows: [MenuBarLine(accountID: account.id, metricID: "weekly")])
        config.layouts = [group]; config.freezeBadgeLabels()
        #expect(config.layouts?[0].rows[0].badgeText == "CL·WK")
        config.editLayout(group.id) { $0.rows[0].badgeText = "주간"; $0.rows[0].metricID = "5h" }
        config.update(account.id) { $0.badge = "New" }
        config.freezeBadgeLabels()
        let decoded = try JSONDecoder().decode(DisplayConfiguration.self, from: JSONEncoder().encode(config))
        #expect(decoded.layouts?[0].rows[0].badgeText == "주간")
        var entry = MenuBarEntry(account: account, display: config.display(account),
            metric: DisplayMetric(id: "5h", title: "5-Hour Session", window: nil), stale: false, requiresLogin: false)
        entry.badgeText = "주간"
        #expect(entry.badgeLabel == "주간")
        entry.badgeText = ""
        #expect(entry.badgeLabel == "")
    }

    @Test func fourthLineIsRejectedAndOldExcessIsPreservedHidden() {
        let account = UsageAccount(id: UUID(), provider: .claude, name: "A")
        var config = DisplayConfiguration(); config.sync([account])
        let lines = (0..<7).map { MenuBarLine(accountID: account.id, metricID: "model:\($0)") }
        let group = MenuBarLayout(rows: Array(lines.prefix(3)))
        let source = MenuBarLayout(rows: [lines[3]])
        config.layouts = [group, source]
        config.editLayout(group.id) { $0.rows.append(lines[4]) }
        #expect(config.layouts?[0].rows.count == 3)
        config.editLayouts { groups in groups[0].rows.append(groups[1].rows.removeFirst()) }
        #expect(config.layouts?[0].rows.count == 3 && config.layouts?[1].rows.count == 1)
        config.layouts = [MenuBarLayout(rows: lines)]
        config.limitLayoutSizes()
        let groups = config.effectiveLayouts
        #expect(config.valid && groups.map(\.rows.count) == [3, 3, 1])
        #expect(groups.map(\.enabled) == [true, false, false])
        #expect(groups.flatMap(\.rows) == lines)
    }

    @Test func limitSuffixCanBeHiddenWithoutChangingTheSelectedMetric() throws {
        let account = UsageAccount(id: UUID(), provider: .claude, name: "Work")
        let oldJSON = "{\"id\":\"line\",\"accountID\":\"\(account.id)\",\"metricID\":\"weekly\"}"
        var line = try JSONDecoder().decode(MenuBarLine.self, from: Data(oldJSON.utf8))
        #expect(line.includesLimitLabel)
        line.showLimitLabel = false
        let restored = try JSONDecoder().decode(MenuBarLine.self, from: JSONEncoder().encode(line))
        #expect(!restored.includesLimitLabel && restored.metricID == "weekly")
        var entry = MenuBarEntry(account: account, display: AccountDisplay(badge: "Work", color: .blue),
            metric: DisplayMetric(id: "weekly", title: "Weekly Limit", window: nil), stale: false, requiresLogin: false)
        #expect(entry.badgeLabel == "Work·WK")
        entry.showLimitLabel = restored.includesLimitLabel
        #expect(entry.badgeLabel == "Work")
    }

    @Test func originalGroupsKeepMixedAccountsOptionsAndParkedSelections() throws {
        let claude = UsageAccount(id: UUID(), provider: .claude, name: "Work")
        let codex = UsageAccount(id: UUID(), provider: .codex, name: "Personal")
        let parked = UsageAccount(id: UUID(), provider: .claude, name: "Parked")
        let items = [
            LegacyDisplayItem(accountIDs: [codex.id, claude.id], showService: false, showBars: true, showPercent: false, maxRows: 3),
            LegacyDisplayItem(accountIDs: [], showService: true, showBars: false, showPercent: true, maxRows: 1),
            LegacyDisplayItem(accountIDs: []), LegacyDisplayItem(accountIDs: []), LegacyDisplayItem(accountIDs: []),
            LegacyDisplayItem(accountIDs: [parked.id], showService: false, showBars: false, showPercent: true, maxRows: 2)
        ]
        let legacy = LegacyDisplayConfiguration(activeCount: 5, items: items,
            metrics: [codex.id.uuidString: ["weekly"], claude.id.uuidString: ["5h", "model:fable"], parked.id.uuidString: []])
        var value = DisplayConfiguration.migrated(from: legacy, accounts: [claude, codex, parked])
        let groups = value.effectiveLayouts
        #expect(value.valid && groups.count == 6)
        #expect(groups.map(\.id) == items.map(\.id))
        #expect(groups[0].rows.map(\.accountID) == [codex.id, claude.id, claude.id])
        #expect(groups[0].rows.map(\.metricID) == ["weekly", "5h", "model:fable"])
        #expect(!groups[0].showBadge && groups[0].showBar && !groups[0].showPercent)
        #expect(groups[0].rowsPerColumn == 3 && groups[1].rowsPerColumn == 1)
        #expect(!groups[5].enabled && groups[5].rows.isEmpty)
        #expect(value.refreshAccountIDs == [claude.id, codex.id])
        value.editLayout(groups[5].id) { group in
            group.enabled = true
            group.rows.append(MenuBarLine(accountID: parked.id, metricID: "weekly"))
        }
        #expect(value.refreshAccountIDs == [claude.id, codex.id, parked.id])
        let roundTrip = try JSONDecoder().decode(DisplayConfiguration.self, from: JSONEncoder().encode(value))
        #expect(roundTrip == value)
    }

    @Test func layoutsPreserveOrderAcrossMovesAndAccountDeletion() throws {
        let a = UsageAccount(id: UUID(), provider: .claude, name: "A")
        let b = UsageAccount(id: UUID(), provider: .codex, name: "B")
        var config = DisplayConfiguration(); config.sync([a, b])
        let first = MenuBarLayout(rows: [MenuBarLine(accountID: a.id, metricID: "weekly"), MenuBarLine(accountID: b.id, metricID: "5h"), MenuBarLine(accountID: a.id, metricID: "model:fable")])
        let second = MenuBarLayout(enabled: false)
        config.layouts = [first, second]
        config.editLayout(first.id) { $0.rows.swapAt(0, 2) }
        config.editLayouts { groups in groups[1].rows.append(groups[0].rows.remove(at: 1)) }
        #expect(config.effectiveLayouts[0].rows.map(\.metricID) == ["model:fable", "weekly"])
        #expect(config.effectiveLayouts[1].rows.map(\.accountID) == [b.id])
        #expect(config.refreshAccountIDs == [a.id])
        config.editLayout(second.id) { $0.enabled = true }
        #expect(config.refreshAccountIDs == [a.id, b.id])
        config.editLayout(first.id) { $0.enabled = false }
        #expect(config.refreshAccountIDs == [b.id])
        config.sync([a])
        #expect(config.effectiveLayouts[1].rows.isEmpty && config.valid)
        #expect(config.refreshAccountIDs.isEmpty)
    }

    @Test func currentCLIAccountCannotCollideWithNumberedGroup() throws {
        let claudeID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let codexID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let claude = UsageAccount(id: claudeID, provider: .claude, name: "Claude CLI")
        let codex = UsageAccount(id: codexID, provider: .codex, name: "Codex CLI")
        var config = DisplayConfiguration(); config.sync([claude, codex])
        config.update(codexID) { $0.group = 1 }
        let groups = config.effectiveLayouts
        #expect(groups.count == 2)
        #expect(Set(groups.map(\.id)).count == 2)
        #expect(groups[0].rows.map(\.accountID) == [claudeID])
        #expect(groups[1].rows.map(\.accountID) == [codexID])
        config.editLayouts { $0[0].name = "Claude" }
        #expect(config.valid)
    }

    @Test func versionTwoConversionKeepsHiddenAccountsAndStableLineIdentities() {
        let a = UsageAccount(id: UUID(), provider: .claude, name: "A")
        let b = UsageAccount(id: UUID(), provider: .codex, name: "B")
        var config = DisplayConfiguration(); config.sync([a, b]); config.style = .bars
        config.update(a.id) { $0.group = 2; $0.primary = "model:fable"; $0.bars = ["weekly"] }
        config.update(b.id) { $0.group = 2; $0.primary = "5h"; $0.bars = []; $0.visible = false }
        #expect(!config.display(b).bars.contains("model:fable"))
        let groups = config.effectiveLayouts
        #expect(groups.count == 1)
        #expect(groups[0].rows.map(\.metricID) == ["model:fable", "weekly", "5h"])
        #expect(groups == config.effectiveLayouts)
        config.editLayouts { $0[0].name = "Mixed" }
        #expect(config.refreshAccountIDs == [a.id])
        config.setVisible(b.id, true)
        #expect(config.refreshAccountIDs == [a.id, b.id])
    }

    @Test func selectedMissingLimitStaysUnknownAndGroupPopoverDeduplicatesAccounts() async throws {
        let f = try LayoutFixture(); defer { f.close() }
        let group = MenuBarLayout(name: "Mixed", rows: [
            MenuBarLine(accountID: f.a.id, metricID: "weekly"),
            MenuBarLine(accountID: f.b.id, metricID: "5h"),
            MenuBarLine(accountID: f.a.id, metricID: "model:future")
        ])
        f.store.updateDisplay { $0.layouts = [group] }
        await f.store.refresh()
        let entries = f.store.entries(for: group)
        #expect(entries.map(\.metric.id) == ["weekly", "5h", "model:future"])
        #expect(entries[0].metric.window?.utilization != nil)
        #expect(entries[1].metric.window?.utilization == nil && entries[2].metric.window?.utilization == nil)
        #expect(f.store.displayConfiguration.refreshAccountIDs == [f.a.id, f.b.id])
        let coordinator = StatusBarCoordinator(store: f.store, providers: [])
        defer { coordinator.removeAll() }
        #expect(coordinator.physicalStatusItemCount == 1)
        #expect(coordinator.popoverAccountIDs(for: group.id) == [f.a.id, f.b.id])
    }

    @Test func ringUsesOnlyTheFirstConfiguredLineAndMultiBarRestoresAllThree() async throws {
        let f = try LayoutFixture(); defer { f.close() }
        await f.store.refresh()
        var group = MenuBarLayout(name: "Ring", style: .ring, rows: [
            MenuBarLine(accountID: f.a.id, metricID: "weekly", slot: 0, badgeText: "A"),
            MenuBarLine(accountID: f.b.id, metricID: "weekly", slot: 1, badgeText: "B"),
            MenuBarLine(accountID: f.a.id, metricID: "5h", slot: 2, badgeText: "C")
        ])
        f.store.updateDisplay { $0.layouts = [group] }
        #expect(group.displayedRows.map(\.badgeText) == ["A"])
        #expect(f.store.entries(for: group).map(\.badgeLabel) == ["A"])
        #expect(f.store.displayConfiguration.refreshAccountIDs == [f.a.id])
        group.style = .bars
        f.store.updateDisplay { $0.layouts = [group] }
        #expect(group.displayedRows.map(\.badgeText) == ["A", "B", "C"])
        #expect(f.store.entries(for: group).count == 3)
        #expect(f.store.displayConfiguration.refreshAccountIDs == [f.a.id, f.b.id])
    }

    @Test func multiBarShowsOnlyTheChosenRepresentativePercentage() {
        let account = UsageAccount(id: UUID(), provider: .claude, name: "Work")
        let first = MenuBarLine(accountID: account.id, metricID: "5h", slot: 0)
        let second = MenuBarLine(accountID: account.id, metricID: "weekly", slot: 1)
        let third = MenuBarLine(accountID: account.id, metricID: "model:fable", slot: 2)
        var group = MenuBarLayout(style: .bars, rows: [first, second, third])
        #expect(group.effectivePercentageLineID == first.id)
        group.percentageLineID = second.id
        var config = group.renderingConfiguration(DisplayConfiguration())
        let entries = [first, second, third].map { line in
            MenuBarEntry(account: account, display: AccountDisplay(badge: "CL", color: .blue),
                metric: DisplayMetric(id: line.metricID, title: line.metricID, window: nil),
                stale: false, requiresLogin: false, lineID: line.id)
        }
        #expect(entries.map { DisplayStatusRenderer.showsPercentage(for: $0, config: config) } == [false, true, false])
        group.moveLine(second.id, offset: 1)
        config = group.renderingConfiguration(DisplayConfiguration())
        #expect(config.percentageLineID == second.id)
        group.rows.removeAll { $0.id == second.id }
        group.percentageLineID = nil
        #expect(group.effectivePercentageLineID == first.id)
        config = group.renderingConfiguration(DisplayConfiguration())
        #expect(DisplayStatusRenderer.showsPercentage(for: entries[0], config: config))
        group.showPercent = false
        config = group.renderingConfiguration(DisplayConfiguration())
        #expect(!DisplayStatusRenderer.showsPercentage(for: entries[0], config: config))
    }

    @Test func textOnlyKeepsEveryValueAndRendersThemHorizontally() {
        let account = UsageAccount(id: UUID(), provider: .claude, name: "Work")
        let lines = (0..<6).map { (index: Int) in MenuBarLine(accountID: account.id, metricID: "metric:\(index)", slot: index) }
        let group = MenuBarLayout(style: .text, rows: lines)
        #expect(group.valid)
        #expect(group.displayedRows.count == 6)
        let entries = lines.enumerated().map { index, line in
            MenuBarEntry(account: account, display: AccountDisplay(badge: "CL", color: .blue),
                metric: DisplayMetric(id: line.metricID, title: line.metricID,
                    window: WindowSummary(tokens: 10 + index * 10, limitTokens: 100, resetAt: nil, displayStyle: .percentage)),
                stale: false, requiresLogin: false, lineID: line.id)
        }
        let config = group.renderingConfiguration(DisplayConfiguration())
        let one = DisplayStatusRenderer.render(entries: [entries[0]], config: config, explicitRows: true)
        let all = DisplayStatusRenderer.render(entries: entries, config: config, explicitRows: true)
        #expect(all.size.width > one.size.width * 4)
    }

    @Test func deletingTextRowsFromAnyPositionAllowsSwitchingToEveryOtherStyle() throws {
        for removed in [[0, 1], [1, 3], [4, 3]] {
            let f = try LayoutFixture(); defer { f.close() }
            let lines = (0..<5).map { (index: Int) in
                MenuBarLine(accountID: f.a.id, metricID: "model:\(index)", slot: index)
            }
            let group = MenuBarLayout(style: .text, percentageLineID: lines[2].id, rows: lines)
            f.store.updateDisplay { $0.layouts = [group] }
            for index in removed {
                f.store.updateDisplay { $0.editLayout(group.id) { $0.rows.removeAll { $0.id == lines[index].id } } }
            }
            let expectedIDs = lines.enumerated().filter { !removed.contains($0.offset) }.map(\.element.id)
            let remaining = try #require(f.store.displayConfiguration.layouts?.first)
            #expect(remaining.rows.map(\.id) == expectedIDs)
            #expect(remaining.rows.compactMap(\.slot) == [0, 1, 2])
            for style in [MenuBarStyle.bars, .ring, .capsule] {
                f.store.updateDisplay { $0.editLayout(group.id) { $0.style = .text } }
                f.store.updateDisplay { $0.editLayout(group.id) { $0.style = style } }
                let changed = try #require(f.store.displayConfiguration.layouts?.first)
                #expect(changed.style == style && changed.valid)
                #expect(changed.rows.map(\.id) == expectedIDs)
                #expect(changed.percentageLineID == lines[2].id)
                let persisted = try f.files.read(DisplayConfiguration.self, at: f.files.root.appendingPathComponent("display-v2.json"))
                #expect(persisted.layouts?.first?.style == style)
            }
        }
    }

    @Test func previouslyGappedTextRowsRecoverOnLoadWithoutLosingHiddenValues() throws {
        let f = try LayoutFixture(); defer { f.close() }
        let first = MenuBarLine(accountID: f.a.id, metricID: "weekly", slot: 2)
        let second = MenuBarLine(accountID: f.b.id, metricID: "5h", slot: 5)
        var config = f.store.displayConfiguration
        let group = MenuBarLayout(style: .text, percentageLineID: second.id, rows: [second, first])
        config.layouts = [group]
        let path = f.files.root.appendingPathComponent("display-v2.json")
        try f.files.write(config, to: path)
        let before = try Data(contentsOf: path)
        let loaded = UsageStore(settings: f.settings, availableProviders: [], files: f.files, autoRefresh: false)
        defer { loaded.shutdown() }
        let repaired = try #require(loaded.displayConfiguration.layouts?.first)
        #expect(repaired.rows.map(\.id) == [first.id, second.id])
        #expect(repaired.rows.compactMap(\.slot) == [0, 1])
        #expect(repaired.percentageLineID == second.id)
        let backup = try #require(FileManager.default.contentsOfDirectory(at: f.files.root, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("display-before-three-lines-") })
        #expect(try Data(contentsOf: backup) == before)
        loaded.updateDisplay { $0.editLayout(group.id) { $0.style = .bars } }
        #expect(loaded.displayConfiguration.layouts?.first?.style == .bars)
        let saved = try f.files.read(DisplayConfiguration.self, at: path)
        #expect(saved.valid && saved.layouts?.first?.rows.map(\.id) == [first.id, second.id])
    }

    @Test func textRowsStayContiguousAfterAccountRemovalAndCanAppendAgain() throws {
        let f = try LayoutFixture(); defer { f.close() }
        var config = f.store.displayConfiguration
        let first = MenuBarLine(accountID: f.a.id, metricID: "5h", slot: 0)
        let second = MenuBarLine(accountID: f.b.id, metricID: "weekly", slot: 1)
        let third = MenuBarLine(accountID: f.b.id, metricID: "5h", slot: 2)
        let group = MenuBarLayout(style: .text, rows: [first, second, third])
        config.layouts = [group]
        config.sync([f.b])
        #expect(config.layouts?.first?.rows.compactMap(\.slot) == [0, 1])
        let added = MenuBarLine(accountID: f.b.id, metricID: "weekly", slot: 2)
        config.editLayout(group.id) { $0.rows.append(added) }
        #expect(config.valid && config.layouts?.first?.rows.map(\.id) == [second.id, third.id, added.id])
        config.editLayout(group.id) { $0.rows.removeAll() }
        config.editLayout(group.id) { $0.rows.append(added) }
        #expect(config.valid && config.layouts?.first?.rows.compactMap(\.slot) == [0])
    }

    @Test func restoringOriginalLayoutBacksUpCurrentPreferencesAndRetainsNames() throws {
        let f = try LayoutFixture(); defer { f.close() }
        let legacy = LegacyDisplayConfiguration(activeCount: 1, items: [
            LegacyDisplayItem(accountIDs: [f.b.id, f.a.id], showService: false, maxRows: 3)
        ], metrics: [f.a.id.uuidString: ["5h"], f.b.id.uuidString: ["weekly"]])
        let legacyURL = f.files.root.appendingPathComponent("display-v1.json")
        try f.files.write(legacy, to: legacyURL)
        let original = try Data(contentsOf: legacyURL)
        f.store.updateDisplay { $0.update(f.a.id) { $0.badge = "Work"; $0.color = .teal } }
        let before = try Data(contentsOf: f.files.root.appendingPathComponent("display-v2.json"))
        f.store.restoreOriginalDisplayConfiguration()
        #expect(f.store.displayConfiguration.display(f.a).badge == "Work")
        #expect(f.store.displayConfiguration.display(f.a).color == .teal)
        #expect(f.store.displayConfiguration.effectiveLayouts[0].rows.map(\.accountID) == [f.b.id, f.a.id])
        #expect(f.store.displayConfiguration.effectiveLayouts[0].rows.map(\.metricID) == ["weekly", "5h"])
        #expect(try Data(contentsOf: legacyURL) == original)
        let backup = try #require(FileManager.default.contentsOfDirectory(at: f.files.root, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("display-before-restore-") })
        #expect(try Data(contentsOf: backup) == before)
        let reloaded = UsageStore(settings: f.settings, availableProviders: [], files: f.files, autoRefresh: false)
        #expect(reloaded.displayConfiguration == f.store.displayConfiguration)
    }

    @Test func mixedGroupAndSettingsRenderWithEveryStyle() async throws {
        let f = try LayoutFixture(); defer { f.close() }
        await f.store.refresh()
        var group = MenuBarLayout(name: "Mixed", rows: [
            MenuBarLine(accountID: f.a.id, metricID: "weekly"), MenuBarLine(accountID: f.b.id, metricID: "weekly"),
            MenuBarLine(accountID: f.a.id, metricID: "5h")])
        let out = ProcessInfo.processInfo.environment["AGENTBAR_QA_ARTIFACT_DIR"].map { URL(fileURLWithPath: $0) }
        if let out { try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true) }
        for style in MenuBarStyle.allCases {
            group.style = style
            group.rowsPerColumn = style == .ring ? 1 : 3
            f.store.updateDisplay { $0.layouts = [group] }
            let entries = f.store.entries(for: group)
            let config = group.renderingConfiguration(f.store.displayConfiguration)
            let image = DisplayStatusRenderer.render(entries: entries, config: config, explicitRows: true)
            let overflow = DisplayStatusRenderer.render(entries: entries + [entries[0]], config: config, explicitRows: true)
            #expect(image.size.height == 22)
            if style == .ring {
                #expect(entries.count == 1)
            } else if style == .text {
                #expect(overflow.size.width > image.size.width)
            } else {
                #expect(image.size.width == overflow.size.width)
            }
            if let out, let rep = image.representations.first as? NSBitmapImageRep {
                try rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("mixed-\(style.rawValue).png"))
            }
        }
        group.style = .bars; group.rowsPerColumn = 3
        f.store.updateDisplay { $0.layouts = [group] }
        for tab in SettingsTab.allCases {
            let view = NSHostingView(rootView: SettingsView(tab: tab).environmentObject(f.settings).environmentObject(f.store))
            view.frame = NSRect(x: 0, y: 0, width: 540, height: 660); view.layoutSubtreeIfNeeded()
            #expect(view.fittingSize.width == 540)
            if let out {
                let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("settings-\(tab.rawValue).png"))
            }
        }
    }
}

@MainActor
private final class LayoutFixture {
    let files = AccountFiles(root: FileManager.default.temporaryDirectory.appendingPathComponent("layout-\(UUID())"))
    let suite = "layout-\(UUID())"
    let defaults: UserDefaults
    let settings: AppSettings
    let a = UsageAccount(id: UUID(), provider: .claude, name: "Claude Work")
    let b = UsageAccount(id: UUID(), provider: .codex, name: "Codex Personal")
    let store: UsageStore
    init() throws {
        defaults = UserDefaults(suiteName: suite)!
        settings = AppSettings(defaults: defaults)
        var registry = AccountRegistry(accounts: [a, b]); registry.repairRepresentatives()
        try files.write(registry, to: files.registryURL)
        store = UsageStore(settings: settings, availableProviders: [], files: files, autoRefresh: false, loadAccount: { account, _ in
            ProviderSnapshot(provider: account.provider, updatedAt: .now, fiveHour: nil,
                weekly: WindowSummary(tokens: account.provider == .claude ? 42 : 71, limitTokens: 100, resetAt: nil, displayStyle: .percentage),
                modelWeeklies: [], planName: "Fixture", sourceDescription: "Fixture", note: nil, isStale: false, requiresLogin: false)
        })
    }
    func close() { store.shutdown(); try? FileManager.default.removeItem(at: files.root); defaults.removePersistentDomain(forName: suite) }
}
