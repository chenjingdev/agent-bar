import Foundation
import Testing
@testable import agent_bar

// A group's list in Manual, 5-hour reset or Weekly reset order, by what each account's row shows, and each group
// remembering its own.
@MainActor
struct GroupListSortTests {
    @Test func eachSortOrdersTheRowsByWhatTheyShow() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let rows: [UUID: ProviderSnapshot] = [
            a: snapshot(fiveHour: window(30, resetsIn: 120), weekly: window(50, resetsIn: 4_320)),
            b: snapshot(fiveHour: window(80, resetsIn: 200), weekly: window(20, resetsIn: 4_000)),
            c: snapshot(.codex, fiveHour: window(10, resetsIn: 30), weekly: window(60, resetsIn: 5_000)),
            d: snapshot(fiveHour: window(5, resetsIn: 250), weekly: window(95, resetsIn: 1_000)),
        ]
        let manual = [a, b, c, d]
        // Each row's 5-hour limit, soonest to refill first; then each row's weekly limit, which puts them otherwise.
        // How much is used plays no part.
        #expect(GroupListSort.fiveHourReset.ordered(manual, now: now) { rows[$0] } == [c, a, b, d])
        #expect(GroupListSort.weeklyReset.ordered(manual, now: now) { rows[$0] } == [d, b, a, c])
        // Manual: the group's own order, whatever the rows show.
        #expect(GroupListSort.manual.ordered(manual, now: now) { rows[$0] } == manual)
        #expect(GroupListSort.manual.ordered([d, c, b, a], now: now) { rows[$0] } == [d, c, b, a])
        #expect(GroupListSort.manual.soonestReset(rows[a]!, now: now) == nil)
        // The menu lists them in this order, and a group saves them by these names.
        #expect(GroupListSort.allCases.map(\.rawValue) == ["manual", "fiveHourReset", "weeklyReset"])
    }

    @Test func aModelsOwnWeekCountsForNeither() {
        let a = UUID(), b = UUID(), c = UUID()
        let rows: [UUID: ProviderSnapshot] = [
            // A's Fable week refills before anything else.
            a: snapshot(fiveHour: window(40, resetsIn: 300), weekly: window(50, resetsIn: 6_000),
                        models: [ModelWeeklySummary(label: "Fable", window: window(97, resetsIn: 50))]),
            b: snapshot(fiveHour: window(90, resetsIn: 100), weekly: window(30, resetsIn: 5_000)),
            // C has a model's week and no week of its own.
            c: snapshot(fiveHour: window(10, resetsIn: 200), models: [ModelWeeklySummary(label: "Opus", window: window(70, resetsIn: 10))]),
        ]
        #expect(GroupListSort.fiveHourReset.soonestReset(rows[a]!, now: now) == now.addingTimeInterval(300 * 60))
        #expect(GroupListSort.weeklyReset.soonestReset(rows[a]!, now: now) == now.addingTimeInterval(6_000 * 60))
        #expect(GroupListSort.weeklyReset.soonestReset(rows[c]!, now: now) == nil)
        #expect(GroupListSort.fiveHourReset.ordered([a, b, c], now: now) { rows[$0] } == [b, c, a])
        #expect(GroupListSort.weeklyReset.ordered([c, a, b], now: now) { rows[$0] } == [b, a, c])
    }

    // Antigravity has a 5-hour and a weekly limit for each model group: the soonest of each kind counts.
    @Test func antigravityGoesByItsSoonestModelGroup() {
        let agy = UUID(), claude = UUID()
        let rows: [UUID: ProviderSnapshot] = [
            agy: antigravity([("Gemini", window(20, resetsIn: 100), window(30, resetsIn: 2_000)),
                              ("Claude/GPT", window(85, resetsIn: 50), window(10, resetsIn: 3_000))]),
            claude: snapshot(fiveHour: window(60, resetsIn: 70), weekly: window(40, resetsIn: 2_500)),
        ]
        // The second group's 5 hours and the first group's week refill before Claude's.
        #expect(GroupListSort.fiveHourReset.ordered([claude, agy], now: now) { rows[$0] } == [agy, claude])
        #expect(GroupListSort.weeklyReset.ordered([claude, agy], now: now) { rows[$0] } == [agy, claude])
        // A group without a value has nothing to go by; another group's limit still counts.
        let half = antigravity([("Gemini", window(20, resetsIn: 100), nil), ("Claude/GPT", nil, window(10, resetsIn: 3_000))])
        #expect(GroupListSort.fiveHourReset.soonestReset(half, now: now) == now.addingTimeInterval(100 * 60))
        #expect(GroupListSort.weeklyReset.soonestReset(half, now: now) == now.addingTimeInterval(3_000 * 60))
    }

    @Test func tiesKeepTheGroupsOrder() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()
        let week = window(40, resetsIn: 3_000)
        let rows: [UUID: ProviderSnapshot] = [
            // Ten seconds after and before the hour read the same minute.
            a: snapshot(fiveHour: window(10, resetsIn: 60 + 10.0 / 60), weekly: week),
            b: snapshot(fiveHour: window(90, resetsIn: 60 - 10.0 / 60), weekly: week),
            c: snapshot(fiveHour: window(50, resetsIn: 59), weekly: week),
            // Resets already past all read "Resets soon", however long ago: now, ahead of every other.
            d: snapshot(fiveHour: window(46, resetsIn: -5), weekly: week),
            e: snapshot(fiveHour: window(20, resetsIn: -90), weekly: window(40, resetsIn: -1)),
        ]
        #expect(GroupListSort.fiveHourReset.soonestReset(rows[e]!, now: now) == now)
        #expect(GroupListSort.fiveHourReset.ordered([a, b, c, d, e], now: now) { rows[$0] } == [d, e, c, a, b])
        // E's week is past; the others' weeks refill in the same minute.
        #expect(GroupListSort.weeklyReset.ordered([a, b, c, d, e], now: now) { rows[$0] } == [e, a, b, c, d])
        // The same rows in another order keep that order among the ties.
        #expect(GroupListSort.fiveHourReset.ordered([c, b, a, e, d], now: now) { rows[$0] } == [e, d, c, b, a])
        #expect(GroupListSort.weeklyReset.ordered([c, b, a, e, d], now: now) { rows[$0] } == [e, c, b, a, d])
    }

    @Test func rowsWithNothingToGoByGoLast() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID(), f = UUID(), g = UUID()
        let rows: [UUID: ProviderSnapshot] = [
            a: .placeholder(for: .claude), // Nothing read yet: "--".
            b: snapshot(fiveHour: window(20, resetsIn: 100), weekly: window(5, resetsIn: 4_000)),
            c: ProviderSnapshot.placeholder(for: .codex).failed("Codex did not answer."), // Could not read: "--".
            // D has no row at all.
            e: snapshot(.codex, weekly: window(10, resetsIn: 2_000)), // A weekly limit alone, without 5 hours.
            // Cached values still show, dimmed. Its week has a value without a reset time.
            f: snapshot(fiveHour: window(70, resetsIn: 400), weekly: window(30), stale: true),
            g: snapshot(fiveHour: window(10), weekly: window(50, resetsIn: 3_000)), // 5 hours without a reset time.
        ]
        let manual = [a, b, c, d, e, f, g]
        #expect(GroupListSort.fiveHourReset.ordered(manual, now: now) { rows[$0] } == [b, f, a, c, d, e, g])
        #expect(GroupListSort.weeklyReset.ordered(manual, now: now) { rows[$0] } == [e, g, b, a, c, d, f])
    }

    // The sort reads the cells a row draws (`GroupAccountRow.cellMetrics`): the ones it names "5h" or a model group's
    // "… 5h", and "Week" or "… wk".
    @Test func theSortGoesByTheRowsOwnCells() {
        let snapshots = [
            snapshot(fiveHour: window(12, resetsIn: 30), weekly: window(64.6, resetsIn: 900),
                     models: [ModelWeeklySummary(label: "Opus", window: window(70, resetsIn: 800))]),
            snapshot(.codex, fiveHour: window(99.5), weekly: window(3, resetsIn: 20)),
            antigravity([("Gemini", window(20, resetsIn: 100), window(30, resetsIn: 2_000)),
                         ("Claude/GPT", window(85.4, resetsIn: 50), nil)]),
            .placeholder(for: .claude),
            ProviderSnapshot.placeholder(for: .codex).failed("Codex did not answer."),
        ]
        for snapshot in snapshots {
            let cells = GroupAccountRow.cellMetrics(snapshot).filter { $0.window != nil }
            #expect(DisplayMetric.reported(snapshot).map(\.id) == cells.map(\.id))
            func soonest(_ named: (String) -> Bool) -> Date? {
                cells.filter { named($0.cellTitle) }.compactMap { $0.window?.resetAt }.min()
            }
            // Every reset here is a whole number of minutes ahead, so it reads exactly as the cell has it.
            #expect(GroupListSort.fiveHourReset.soonestReset(snapshot, now: now) == soonest { $0 == "5h" || $0.hasSuffix(" 5h") })
            #expect(GroupListSort.weeklyReset.soonestReset(snapshot, now: now) == soonest { $0 == "Week" || $0.hasSuffix(" wk") })
        }
        func minutes(_ values: [Double?]) -> [Date?] { values.map { $0.map { now.addingTimeInterval($0 * 60) } } }
        #expect(snapshots.map { GroupListSort.fiveHourReset.soonestReset($0, now: now) } == minutes([30, nil, 50, nil, nil]))
        #expect(snapshots.map { GroupListSort.weeklyReset.soonestReset($0, now: now) } == minutes([900, 20, 2_000, nil, nil]))
    }

    @Test func aGroupReadsAndSavesItsSort() throws {
        let account = UUID(), group = UUID()
        // A file from before groups had a sort reads as manual and saves without one.
        let old = try JSONDecoder().decode(DisplayConfiguration.self, from: file(account, group))
        let layout = try #require(old.layouts?.first)
        #expect(layout.listSort == nil && layout.effectiveListSort == .manual && old.valid)
        #expect(!String(decoding: try JSONEncoder().encode(old), as: UTF8.self).contains("listSort"))
        // Each choice reads back as it was saved, by its name.
        for sort in GroupListSort.allCases {
            var config = old
            config.layouts?[0].listSort = sort
            let data = try JSONEncoder().encode(config)
            #expect(String(decoding: data, as: UTF8.self).contains("\"listSort\":\"\(sort.rawValue)\""))
            let read = try JSONDecoder().decode(DisplayConfiguration.self, from: data)
            #expect(read.layouts == config.layouts && read.layouts?.first?.effectiveListSort == sort)
        }
        // One this version does not know, saved by a later version or broken, reads as manual; the rest of the file still reads.
        for value in ["\"name\"", "7", "null", "{}"] {
            let read = try JSONDecoder().decode(DisplayConfiguration.self, from: file(account, group, ",\"listSort\":\(value)"))
            #expect(read.layouts?.first?.effectiveListSort == .manual && read.layouts?.first?.name == "Work" && read.valid)
        }
    }

    @Test func eachGroupKeepsItsSortAcrossLaunches() throws {
        let f = try SortFixture(); defer { f.close() }
        let one = MenuBarLayout(name: "One", rows: [line(f.accounts[0], slot: 0)], memberIDs: [f.accounts[0].id, f.accounts[1].id])
        let two = MenuBarLayout(name: "Two", rows: [line(f.accounts[2], slot: 0)])
        f.store.updateDisplay { $0.layouts = [one, two] }
        #expect(f.store.listSort(for: one.id) == .manual && f.store.listSort(for: two.id) == .manual)
        #expect(f.store.listSort(for: UUID()) == nil)

        f.store.setListSort(.fiveHourReset, for: one.id)
        f.store.setListSort(.weeklyReset, for: two.id)
        #expect(f.store.listSort(for: one.id) == .fiveHourReset && f.store.listSort(for: two.id) == .weeklyReset)
        let reopened = f.reopened(); defer { reopened.shutdown() }
        #expect(reopened.listSort(for: one.id) == .fiveHourReset && reopened.listSort(for: two.id) == .weeklyReset)
        // Nothing else about the groups changed.
        #expect(reopened.displayConfiguration.layouts?.map(\.memberIDs) == [one.memberIDs, nil])
        #expect(reopened.displayConfiguration.layouts?.map(\.name) == ["One", "Two"])

        // Manual again is saved as no choice, as for a group that never chose.
        f.store.setListSort(.manual, for: one.id)
        #expect(f.store.displayConfiguration.layouts?.first?.listSort == nil)
        let again = f.reopened(); defer { again.shutdown() }
        #expect(again.listSort(for: one.id) == .manual && again.listSort(for: two.id) == .weeklyReset)
        // A group that does not exist changes nothing.
        let before = f.store.displayConfiguration
        f.store.setListSort(.fiveHourReset, for: UUID())
        #expect(f.store.displayConfiguration == before)
    }

    @Test func groupsOfOlderSettingsStartManual() throws {
        let f = try SortFixture(); defer { f.close() }
        // Settings without groups saved: each account shows as its own group, in its own order.
        #expect(f.store.displayConfiguration.layouts == nil)
        let groups = f.store.displayConfiguration.effectiveLayouts
        #expect(!groups.isEmpty && groups.allSatisfy { f.store.listSort(for: $0.id) == .manual })
        // Choosing manual changes nothing, so the settings stay as they were.
        f.store.setListSort(.manual, for: groups[0].id)
        #expect(f.store.displayConfiguration.layouts == nil)
        // Another choice saves the groups, and that group alone remembers it.
        f.store.setListSort(.weeklyReset, for: groups[0].id)
        let reopened = f.reopened(); defer { reopened.shutdown() }
        #expect(reopened.displayConfiguration.layouts?.map(\.id) == groups.map(\.id))
        #expect(groups.map { reopened.listSort(for: $0.id) } == [.weeklyReset] + Array(repeating: .manual, count: groups.count - 1))
    }

    @Test func thePanelListsAGroupsAccountsInItsSort() async throws {
        let work = account(.claude, "Claude Work"), personal = account(.codex, "Codex Personal"), side = account(.claude, "Claude Side")
        let hidden = account(.claude, "Claude Hidden")
        // Never signed in to AgentBar, so its row reads "--".
        let old = UsageAccount(id: UUID(), provider: .codex, name: "Codex Old")
        let f = try SortFixture([work, personal, side, old, hidden], usage: [
            work.id: snapshot(fiveHour: window(30, resetsIn: 200), weekly: window(40, resetsIn: 3_000)),
            personal.id: snapshot(.codex, fiveHour: window(5, resetsIn: 90), weekly: window(90, resetsIn: 6_000)),
            side.id: snapshot(fiveHour: window(60, resetsIn: 20)),
            hidden.id: snapshot(fiveHour: window(99, resetsIn: 1)),
        ]); defer { f.close() }
        let group = MenuBarLayout(name: "All", rows: [line(work, slot: 0)], memberIDs: [work, personal, side, old, hidden].map(\.id))
        f.store.updateDisplay { $0.layouts = [group]; $0.setVisible(hidden.id, false) }
        await f.store.refresh()
        #expect(f.store.snapshots.count == 3)
        func listed() throws -> [UUID] {
            f.store.sortedPanelAccountIDs(for: try #require(f.store.displayConfiguration.layouts?.first), now: now)
        }
        // Manual is the panel's list as it was: the group's order, without the hidden account.
        let panel = f.store.panelAccountIDs(for: try #require(f.store.displayConfiguration.layouts?.first))
        #expect(panel == [work, personal, side, old].map(\.id))
        #expect(try listed() == panel)
        f.store.setListSort(.fiveHourReset, for: group.id)
        #expect(try listed() == [side, personal, work, old].map(\.id))
        // Side has no weekly limit, so it joins Old at the bottom, in the group's order.
        f.store.setListSort(.weeklyReset, for: group.id)
        #expect(try listed() == [work, personal, side, old].map(\.id))
    }
}

// A whole minute, so a reset a whole number of minutes away reads exactly as set.
private let now = Date(timeIntervalSinceReferenceDate: 13_000_000 * 60)

/// A limit `percent` used, resetting `minutes` from `now` (before it when negative), or without a reset time.
private func window(_ percent: Double, resetsIn minutes: Double? = nil) -> WindowSummary {
    WindowSummary(tokens: Int((percent * 10).rounded()), limitTokens: 1_000,
                  resetAt: minutes.map { now.addingTimeInterval($0 * 60) }, displayStyle: .percentage)
}

private func snapshot(_ provider: ProviderKind = .claude, fiveHour: WindowSummary? = nil, weekly: WindowSummary? = nil,
                      models: [ModelWeeklySummary] = [], stale: Bool = false) -> ProviderSnapshot {
    ProviderSnapshot(provider: provider, updatedAt: now, fiveHour: fiveHour, weekly: weekly, modelWeeklies: models,
                     planName: nil, sourceDescription: "Test", note: nil, isStale: stale, requiresLogin: false)
}

/// An Antigravity reading: a 5-hour and a weekly limit for each model group, nil where the group has no value.
private func antigravity(_ groups: [(String, WindowSummary?, WindowSummary?)]) -> ProviderSnapshot {
    ProviderSnapshot(provider: .antigravity, updatedAt: now, fiveHour: groups.first?.1, weekly: groups.first?.2, modelWeeklies: [],
                     planName: nil, sourceDescription: "Test", note: nil, isStale: false, requiresLogin: false,
                     limitGroups: groups.map { LimitGroupSummary(label: $0.0, fiveHour: $0.1, weekly: $0.2) })
}

private func account(_ provider: ProviderKind, _ name: String) -> UsageAccount {
    UsageAccount(id: UUID(), provider: provider, name: name, credentialID: UUID())
}

/// A line that already carries its badge, so reading a file does not change it.
private func line(_ account: UsageAccount, slot: Int) -> MenuBarLine {
    MenuBarLine(accountID: account.id, metricID: "weekly", slot: slot, badgeText: account.name)
}

/// A display file with one group, `extra` added to the group.
private func file(_ account: UUID, _ group: UUID, _ extra: String = "") -> Data {
    Data("""
    {"version":2,"order":["\(account)"],"accounts":{"\(account)":{"badge":"CL","color":"blue"}},
     "layouts":[{"id":"\(group)","name":"Work","enabled":true,"style":"bars","showBadge":true,"showBar":true,
       "showPercent":true,"rowsPerColumn":3,"rows":[{"id":"line","accountID":"\(account)","metricID":"weekly","slot":0}]\(extra)}]}
    """.utf8)
}

@MainActor
private final class SortFixture {
    let files = AccountFiles(root: FileManager.default.temporaryDirectory.appendingPathComponent("list-sort-\(UUID())"))
    let suite = "list-sort-\(UUID())"
    let defaults: UserDefaults
    let settings: AppSettings
    let accounts: [UsageAccount]
    let store: UsageStore
    init(_ accounts: [UsageAccount] = [account(.claude, "Claude Work"), account(.codex, "Codex Personal"), account(.claude, "Claude Side")],
         usage: [UUID: ProviderSnapshot] = [:]) throws {
        self.accounts = accounts
        defaults = UserDefaults(suiteName: suite)!
        settings = AppSettings(defaults: defaults)
        var registry = AccountRegistry(accounts: accounts); registry.repairRepresentatives()
        try files.write(registry, to: files.registryURL)
        store = UsageStore(settings: settings, files: files, autoRefresh: false, loadAccount: { account, _ in
            usage[account.id] ?? .placeholder(for: account.provider)
        })
    }
    /// Another store reading what has been saved, as the next launch does.
    func reopened() -> UsageStore { UsageStore(settings: settings, files: files, autoRefresh: false) }
    func close() { store.shutdown(); try? FileManager.default.removeItem(at: files.root); defaults.removePersistentDomain(forName: suite) }
}
