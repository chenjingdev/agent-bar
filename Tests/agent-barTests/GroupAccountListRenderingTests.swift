import AppKit
import Foundation
import SwiftUI
import Testing
@testable import agent_bar

@MainActor
struct GroupAccountListRenderingTests {
    private static let now = Date()
    private static let appearances: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]

    @Test func listDrawsEveryRowState() async throws {
        let output = ProcessInfo.processInfo.environment["AGENTBAR_QA_ARTIFACT_DIR"].map { URL(fileURLWithPath: $0) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }

        // The cells: what the service reports, in its order; "--" for both usual limits before anything is read.
        #expect(GroupAccountRow.cellMetrics(Self.usage(.claude, 42, 21, models: [("Fable", 40)])).map(\.cellTitle) == ["5h", "Week", "Fable"])
        #expect(GroupAccountRow.cellMetrics(Self.usage(.claude, 42, 21)).map(\.cellTitle) == ["5h", "Week"])
        #expect(GroupAccountRow.cellMetrics(Self.antigravity).map(\.cellTitle) == ["Gemini 5h", "Gemini wk", "Claude/GPT 5h", "Claude/GPT wk"])
        let unread = GroupAccountRow.cellMetrics(.placeholder(for: .codex))
        #expect(unread.map(\.cellTitle) == ["5h", "Week"] && unread.allSatisfy { $0.window?.utilization == nil })

        // Rows line up: the pointer, a Claude Code button or its absence never change a row's height. A fourth limit
        // starts a second line of cells.
        let states = Self.rowStates()
        func height(_ name: String, highlighted: Bool? = nil) throws -> CGFloat {
            var row = try #require(states.first { $0.0 == name }?.1)
            if let highlighted { row.highlighted = highlighted }
            return NSHostingView(rootView: row.frame(width: GroupAccountListView.width)).fittingSize.height
        }
        for name in ["Over 90% · pointer on Use", "Set Up · pointer"] {
            #expect(try height(name, highlighted: false) == height(name, highlighted: true), "\(name)")
        }
        #expect(try height("Claude · In use · three limits") == height("Over 90% · pointer on Use"))
        #expect(try height("Codex · two limits") == height("Claude · In use · three limits"))
        #expect(try height("Antigravity · four limits") > height("Codex · two limits") + 20)

        for (name, appearance) in Self.appearances {
            let sheet = VStack(alignment: .leading, spacing: 2) {
                ForEach(states.indices, id: \.self) { index in
                    Text(verbatim: states[index].0).font(.caption2).foregroundStyle(.tertiary).padding(.leading, 14).padding(.top, 6)
                    states[index].1
                }
            }
            .padding(.horizontal, 6).padding(.bottom, 8)
            .frame(width: GroupAccountListView.width)
            try await draw(sheet, appearance: appearance, to: output?.appendingPathComponent("group-list-rows-\(name).png"))
        }
    }

    @Test func twelveAccountsListInTheGroupsOrderAndScrollWhenTheScreenIsShort() async throws {
        let output = ProcessInfo.processInfo.environment["AGENTBAR_QA_ARTIFACT_DIR"].map { URL(fileURLWithPath: $0) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        // Seven Claude and five Codex accounts, badged CL, CL2… and CX, CX2… as new accounts are.
        let f = try SwitchFixture()
        let claude = ["cl", "cl2", "cl3", "cl4", "cl5", "cl6", "cl7"].map { f.addAccount($0) }
        let codex = ["cx", "cx2", "cx3", "cx4", "cx5"].map {
            UsageAccount(id: UUID(), provider: .codex, name: $0, identity: .init(email: "\($0)@example.test"), credentialID: UUID())
        }
        // Claude Code uses CL2, and CL4 is ready to take over.
        f.signInDefault(claude[1])
        try f.saveLogin(for: claude[3])
        var registry = AccountRegistry(accounts: f.accounts + codex); registry.repairRepresentatives()
        try f.files.write(registry, to: f.files.registryURL)
        let usage: [UUID: ProviderSnapshot] = [
            claude[3].id: Self.usage(.claude, 92, 64, models: [("Fable", 40)], plan: "Max"),
            claude[1].id: Self.usage(.claude, 88, 64, models: [("Fable", 40)], plan: "Max"),
            codex[2].id: Self.usage(.codex, 64, 22, plan: "Team"),
            claude[0].id: Self.usage(.claude, 42, 21, plan: "Team"),
            codex[1].id: Self.usage(.codex, 30, 48, plan: "Plus"),
            claude[4].id: Self.usage(.claude, 17, 9, plan: "Pro"),
            codex[0].id: Self.usage(.codex, 12, 5, plan: "Team"),
            claude[2].id: Self.usage(.claude, 35, 18, plan: "Pro", updated: Self.now.addingTimeInterval(-300), stale: true,
                                     note: "Too many requests. Showing cached usage."),
            claude[5].id: Self.usage(.claude, 55, 30, models: [("Fable", 12)], plan: "Max"),
            codex[3].id: Self.usage(.codex, 40, 10, plan: "Plus", stale: true, login: true, note: "Sign in again in Settings › Accounts."),
            claude[6].id: Self.usage(.claude, 8, 3, plan: "Pro"),
            codex[4].id: ProviderSnapshot.placeholder(for: .codex).failed("Codex did not answer. Try again later."),
        ]
        let suite = "group-list-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        let store = UsageStore(settings: AppSettings(defaults: defaults), files: f.files, autoRefresh: false,
                               loadAccount: { account, _ in usage[account.id] ?? .placeholder(for: account.provider) },
                               claudeCode: f.switcher, claudeCodeBrowser: BrowserLoginLauncher(openURL: { _ in true }))
        defer { store.shutdown(); defaults.removePersistentDomain(forName: suite) }
        await store.runClaudeCodeStartup()

        // The order chips were dragged into; the lines draw three of the twelve.
        let order = [claude[3], claude[1], codex[2], claude[0], codex[1], claude[4], codex[0],
                     claude[2], claude[5], codex[3], claude[6], codex[4]].map(\.id)
        let all = MenuBarLayout(name: "ALL", style: .bars, rows: [
            MenuBarLine(accountID: claude[3].id, metricID: "5h", slot: 0),
            MenuBarLine(accountID: claude[1].id, metricID: "5h", slot: 1),
            MenuBarLine(accountID: codex[2].id, metricID: "weekly", slot: 2)], memberIDs: order)
        store.updateDisplay { $0.editLayouts { $0 = [all] } }
        store.refreshNow()
        for _ in 0..<250 where store.snapshots.count < order.count { try await Task.sleep(for: .milliseconds(20)) }
        #expect(store.snapshots.count == order.count)
        let layout = try #require(store.displayConfiguration.effectiveLayouts.first { $0.id == all.id })
        let panel = store.panelAccountIDs(for: layout)
        #expect(panel == order)
        #expect(store.claudeCodeListRow(for: claude[1]).control == .inClaudeCode)
        guard case .use(enabled: true, _) = store.claudeCodeListRow(for: claude[3]).control else {
            Issue.record("CL4 should be ready for Claude Code"); return
        }

        // The pointer rests on CL4, the first row, so its Use button shows.
        let list = GroupAccountListView(accountIDs: panel, groupID: all.id, hovered: claude[3].id).environmentObject(store)
        for (name, appearance) in Self.appearances {
            let whole = try await draw(list, appearance: appearance, to: output?.appendingPathComponent("group-list-\(name).png"))
            #expect(whole.width == GroupAccountListView.width)
            // A screen shorter than the list: the rows scroll between the header and the footer, which stay.
            #expect(whole.height > 560)
            try await draw(list, appearance: appearance, height: 560, to: output?.appendingPathComponent("group-list-scroll-\(name).png"))
        }
    }

    @Test func autoScrollMovesOneRowTowardTheEdge() {
        // Near an edge, or past it, the list scrolls that way; in between it does not.
        #expect(ListAutoScroll.direction(pointerY: 10, viewportHeight: 300) == .up)
        #expect(ListAutoScroll.direction(pointerY: -40, viewportHeight: 300) == .up)
        #expect(ListAutoScroll.direction(pointerY: 290, viewportHeight: 300) == .down)
        #expect(ListAutoScroll.direction(pointerY: 340, viewportHeight: 300) == .down)
        for y: CGFloat in [28, 150, 272] { #expect(ListAutoScroll.direction(pointerY: y, viewportHeight: 300) == nil, "\(y)") }
        #expect(ListAutoScroll.direction(pointerY: 10, viewportHeight: 0) == nil)
        // Too short for two edges: the half the pointer is in.
        #expect(ListAutoScroll.direction(pointerY: 10, viewportHeight: 40) == .up)
        #expect(ListAutoScroll.direction(pointerY: 30, viewportHeight: 40) == .down)

        // Six rows of different heights a point apart, as the list lays them out, seen 200 points at a time.
        let heights: [CGFloat] = [60, 80, 60, 100, 60, 60]
        let ids = heights.map { _ in UUID() }
        var frames: [UUID: CGRect] = [:], y: CGFloat = 4
        for (id, height) in zip(ids, heights) { frames[id] = CGRect(x: 6, y: y, width: 388, height: height); y += height + 1 }
        func next(_ direction: ListAutoScroll.Direction, from top: CGFloat) -> UUID? {
            ListAutoScroll.nextRow(direction, order: ids, frames: frames, visible: top...(top + 200))
        }
        // At the top: going down brings in the row the bottom edge cuts; going up has nowhere to go.
        #expect(next(.down, from: 0) == ids[2])
        #expect(next(.up, from: 0) == nil)
        // Midway, one row each way: the next one past each edge.
        #expect(next(.down, from: 150) == ids[4])
        #expect(next(.up, from: 150) == ids[2])
        // Step by step as the list does it (the row's edge to the view's edge), every row in turn, then a stop at the end.
        var top: CGFloat = 0, passed: [UUID] = []
        while let id = next(.down, from: top), passed.count < 10 { passed.append(id); top = frames[id]!.maxY - 200 }
        #expect(passed == Array(ids[2...]))
        #expect(next(.down, from: top) == nil)
        passed = []
        while let id = next(.up, from: top), passed.count < 10 { passed.append(id); top = frames[id]!.minY }
        #expect(passed == Array(ids[0...3].reversed()))
        #expect(next(.up, from: top) == nil)
    }

    @Test func aDraggedRowMakesRoomForItsOwnHeight() {
        // A tall row over two short ones, a point apart.
        let tall = UUID(), first = UUID(), second = UUID()
        let frames = [tall: CGRect(x: 6, y: 4, width: 388, height: 100), first: CGRect(x: 6, y: 105, width: 388, height: 60),
                      second: CGRect(x: 6, y: 166, width: 388, height: 60)]
        var drag = ListRowDrag(source: tall, order: [tall, first, second], frames: frames, pointer: CGPoint(x: 100, y: 54),
                               start: CGPoint(x: 100, y: 50), origin: .zero)
        #expect(drag.preview.translation == CGSize(width: 0, height: 4))
        // Onto the last row: the others move up by the tall row's height, and its slot opens where it really lands, not
        // in the last row's place, which is too short for it.
        drag.pointer = CGPoint(x: 100, y: 190)
        drag.follow(origin: .zero)
        #expect(drag.target == second)
        #expect(drag.offset(for: first) == CGSize(width: 0, height: -101))
        #expect(drag.offset(for: second) == CGSize(width: 0, height: -101))
        #expect(drag.placeholder == CGRect(x: 6, y: 126, width: 388, height: 100))
        #expect(drag.landingTranslation == CGSize(width: 0, height: 122))
        // The list scrolls 40 points under a pointer that stays still: the dragged row and the drop follow the content.
        drag.follow(origin: CGPoint(x: 0, y: -40))
        #expect(drag.preview.location == CGPoint(x: 100, y: 230))
        #expect(drag.preview.translation == CGSize(width: 0, height: 180))
        // Off every row nothing moves, and the row would go back to its place.
        drag.pointer = CGPoint(x: 100, y: 400)
        drag.follow(origin: .zero)
        #expect(drag.target == nil && drag.offset(for: first) == .zero && drag.placeholder == frames[tall])
    }

    // The list driven by the mouse, as in the panel: a press stays a press, a drag reorders the group, a row held at an edge
    // scrolls the list to its end, and once a drop settles, the row under the pointer has its buttons back.
    @Test func draggingARowReordersTheGroupAndScrollsAtTheEdges() async throws {
        let f = try SwitchFixture()
        let accounts = (1...7).map { f.addAccount("cl\($0)") }
        // Claude Code uses CL1, and CL2 is ready to take over.
        f.signInDefault(accounts[0])
        try f.saveLogin(for: accounts[1])
        var registry = AccountRegistry(accounts: f.accounts); registry.repairRepresentatives()
        try f.files.write(registry, to: f.files.registryURL)
        let suite = "group-list-drag-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        let store = UsageStore(settings: AppSettings(defaults: defaults), files: f.files, autoRefresh: false,
                               claudeCode: f.switcher, claudeCodeBrowser: BrowserLoginLauncher(openURL: { _ in true }))
        defer { store.shutdown(); defaults.removePersistentDomain(forName: suite) }
        await store.runClaudeCodeStartup()
        let ids = accounts.map(\.id)
        let group = MenuBarLayout(name: "ALL", rows: [MenuBarLine(accountID: ids[0], metricID: "5h")], memberIDs: ids)
        store.updateDisplay { $0.editLayouts { $0 = [group] } }
        func order() -> String { (store.groupMembers(group.id) ?? []).map { id in accounts.first { $0.id == id }?.name ?? "?" }.joined(separator: " ") }

        // Shorter than its rows, so they scroll, a step at a time without the glide. The panel would hand the view each new
        // order; it does not wait for that.
        let view = GroupAccountListView(accountIDs: ids, groupID: group.id, stepAnimation: nil).environmentObject(store)
        let window = ListWindow(view, height: 360)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        let list = try #require(window.scrollView)
        let content = try #require(list.documentView?.frame.size)
        let viewport = list.convert(list.bounds, to: nil)
        let maxScroll = content.height - viewport.height
        // Rows of one height a point apart, between 4-point margins.
        let rowHeight = (content.height - 8 - CGFloat(ids.count - 1)) / CGFloat(ids.count)
        // A point in the list's content, or in the part in view, from the window's top left.
        func inView(_ y: CGFloat, x: CGFloat = 100) -> CGPoint { CGPoint(x: viewport.minX + x, y: window.height - viewport.maxY + y) }
        func row(_ index: Int) -> CGPoint { inView(4 + CGFloat(index) * (rowHeight + 1) + rowHeight / 2 - list.contentView.bounds.minY) }
        #expect(maxScroll > 2 * rowHeight)

        // A press that moves 2 points is a press: nothing moves.
        try await window.drag(from: row(1), to: row(1).moved(0, 2))
        #expect(order() == "cl1 cl2 cl3 cl4 cl5 cl6 cl7")
        // Dragged onto the third row, the first goes there.
        try await window.drag(from: row(0), to: row(2))
        try #require(await until { order() == "cl2 cl3 cl1 cl4 cl5 cl6 cl7" }, "\(order())")
        // Held near the bottom, the list scrolls a row at a time to its end; the drop puts the row last.
        let bottom = inView(viewport.height - 10)
        try await window.drag(from: row(0), to: bottom, release: false)
        try #require(await until { abs(list.contentView.bounds.minY - maxScroll) < 1 }, "\(list.contentView.bounds.minY)")
        // The row floats under the pointer over the dashed slot it would drop into.
        if let output = ProcessInfo.processInfo.environment["AGENTBAR_QA_ARTIFACT_DIR"].map({ URL(fileURLWithPath: $0) }) {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try await Task.sleep(for: .milliseconds(300))
            try window.picture(to: output.appendingPathComponent("group-list-drag.png"))
        }
        try await window.send(.leftMouseUp, bottom)
        try #require(await until { order() == "cl3 cl1 cl4 cl5 cl6 cl7 cl2" }, "\(order())")
        // CL2, now the last row in view, held near the top: the list scrolls back, and CL2 goes first.
        let top = inView(8)
        try await window.drag(from: row(6), to: top, release: false)
        try #require(await until { list.contentView.bounds.minY < 0.5 }, "\(list.contentView.bounds.minY)")
        try await window.send(.leftMouseUp, top)
        try #require(await until { order() == "cl2 cl3 cl1 cl4 cl5 cl6 cl7" }, "\(order())")

        // The pointer rests on CL2, so its Use button is back without the pointer moving, and a click that wobbles a
        // point uses the account rather than dragging it.
        let titleHeight = NSHostingView(rootView: GroupAccountRow.buttonHeightTemplate).fittingSize.height
        let use = inView(4 + 7 + titleHeight / 2, x: content.width - 6 - 8 - 10)
        try await window.drag(from: use, to: use.moved(1, 1))
        try #require(await until { store.claudeCodeAccountID == accounts[1].id }, "Use did not switch Claude Code")
        #expect(f.defaultEmail == "cl2@example.test")
        #expect(order() == "cl2 cl3 cl1 cl4 cl5 cl6 cl7")
    }

    // A sorted list moves its rows only at a moment to sort: when the panel opens, when the sort changes and when a refresh
    // round ends. Numbers that come in between leave the rows where they are, so nothing jumps under someone reading.
    @Test func aSortedListMovesItsRowsOnlyWhenItOpensItsSortChangesOrARoundEnds() async throws {
        let output = ProcessInfo.processInfo.environment["AGENTBAR_QA_ARTIFACT_DIR"].map { URL(fileURLWithPath: $0) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        let f = try SwitchFixture()
        let claude = ["cl", "cl2", "cl3"].map { f.addAccount($0) }
        let codex = UsageAccount(id: UUID(), provider: .codex, name: "cx", identity: .init(email: "cx@example.test"), credentialID: UUID())
        let accounts = claude + [codex]
        var registry = AccountRegistry(accounts: f.accounts + [codex]); registry.repairRepresentatives()
        try f.files.write(registry, to: f.files.registryURL)
        // The soonest 5 hours to refill is not the soonest week. Codex is read beside Claude, so a round can hold it back
        // alone.
        let usage: [UUID: ProviderSnapshot] = [
            claude[0].id: Self.reading(.claude, 20, fiveHour: 4, week: 1), claude[1].id: Self.reading(.claude, 60, fiveHour: 1, week: 5),
            claude[2].id: Self.reading(.claude, 40, fiveHour: 3, week: 3), codex.id: Self.reading(.codex, 90, fiveHour: 2, week: 2),
        ]
        let gate = Gate()
        let suite = "group-list-sort-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        let store = UsageStore(settings: AppSettings(defaults: defaults), files: f.files, autoRefresh: false,
                               loadAccount: { account, _ in
                                   if account.provider == .codex { await gate.wait() }
                                   return usage[account.id] ?? .placeholder(for: account.provider)
                               },
                               claudeCode: f.switcher, claudeCodeBrowser: BrowserLoginLauncher(openURL: { _ in true }))
        defer { gate.open(); store.shutdown(); defaults.removePersistentDomain(forName: suite) }
        let ids = accounts.map(\.id)
        let group = MenuBarLayout(name: "ALL", rows: [MenuBarLine(accountID: ids[0], metricID: "5h")], memberIDs: ids)
        store.updateDisplay { $0.editLayouts { $0 = [group] } }
        store.setListSort(.fiveHourReset, for: group.id)

        // The panel, opened once, telling the test the order of its rows.
        let rows = ListRows()
        func panel(openings: Int) -> ListReadingRows {
            ListReadingRows(list: GroupAccountListView(accountIDs: ids, groupID: group.id, openings: openings), store: store, rows: rows)
        }
        let host = NSHostingView(rootView: panel(openings: 1))
        let window = ListWindow(host: host, height: 640)
        defer { window.close() }
        func shown() -> String { rows.order.map { id in accounts.first { $0.id == id }?.name ?? "?" }.joined(separator: " ") }
        // Nothing read yet: no reset to go by, so the rows keep the group's order.
        try #require(await until { shown() == "cl cl2 cl3 cx" }, "\(shown())")

        // A round reads Claude while Codex waits. The new numbers would sort the rows, but the list keeps them still.
        store.refreshNow()
        try #require(await until { store.snapshots.count == 3 }, "\(store.snapshots.count)")
        try await Task.sleep(for: .milliseconds(200))
        #expect(store.isRefreshing)
        #expect(shown() == "cl cl2 cl3 cx")
        // The panel opens again: the rows go in the order of the numbers there are, CX last with none yet.
        host.rootView = panel(openings: 2)
        try #require(await until { shown() == "cl2 cl3 cl cx" }, "\(shown())")
        // The round ends with CX read: the rows sort again.
        gate.open()
        try #require(await until { !store.isRefreshing && shown() == "cl2 cx cl3 cl" }, "\(shown())")
        // Another sort puts them in its order at once, and Manual back in the group's own.
        for (sort, order) in [(GroupListSort.weeklyReset, "cl cx cl3 cl2"), (.fiveHourReset, "cl2 cx cl3 cl")] {
            store.setListSort(sort, for: group.id)
            try #require(await until { shown() == order }, "\(sort): \(shown())")
            for (name, appearance) in Self.appearances {
                let list = GroupAccountListView(accountIDs: ids, groupID: group.id).environmentObject(store)
                try await draw(list, appearance: appearance, to: output?.appendingPathComponent("group-list-sort-\(sort.rawValue)-\(name).png"))
            }
        }
        store.setListSort(.manual, for: group.id)
        try #require(await until { shown() == "cl cl2 cl3 cx" }, "\(shown())")

        // The header's sort button names the sort in use: pictures of the list under each sort differ in the header only
        // in its right half, where the button stands before the refresh and settings buttons.
        let pictures = try [GroupListSort.manual, .fiveHourReset, .weeklyReset].map { sort in
            store.setListSort(sort, for: group.id)
            return try picture(GroupAccountListView(accountIDs: ids, groupID: group.id).environmentObject(store)).bitmap
        }
        store.setListSort(.manual, for: group.id)
        for other in pictures.dropFirst() {
            let columns = Self.headerColumns(differingBetween: pictures[0], other)
            #expect(!columns.isEmpty && columns.allSatisfy { $0 > GroupAccountListView.width / 2 }, "\(columns.first ?? -1)…\(columns.last ?? -1)")
        }
    }

    // Only the group's own order is set by hand. Sorted by 5-hour reset, a row dragged onto another stays where it was,
    // and a click on Use still uses the account.
    @Test func aSortedListStartsNoDrag() async throws {
        let f = try SwitchFixture()
        let accounts = (1...7).map { f.addAccount("cl\($0)") }
        // Claude Code uses CL2, and CL1 is ready to take over.
        f.signInDefault(accounts[1])
        try f.saveLogin(for: accounts[0])
        var registry = AccountRegistry(accounts: f.accounts); registry.repairRepresentatives()
        try f.files.write(registry, to: f.files.registryURL)
        let suite = "group-list-sorted-drag-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        let store = UsageStore(settings: AppSettings(defaults: defaults), files: f.files, autoRefresh: false,
                               claudeCode: f.switcher, claudeCodeBrowser: BrowserLoginLauncher(openURL: { _ in true }))
        defer { store.shutdown(); defaults.removePersistentDomain(forName: suite) }
        await store.runClaudeCodeStartup()
        let ids = accounts.map(\.id)
        let group = MenuBarLayout(name: "ALL", rows: [MenuBarLine(accountID: ids[0], metricID: "5h")], memberIDs: ids)
        store.updateDisplay { $0.editLayouts { $0 = [group] } }
        store.setListSort(.fiveHourReset, for: group.id)
        func order() -> String { (store.groupMembers(group.id) ?? []).map { id in accounts.first { $0.id == id }?.name ?? "?" }.joined(separator: " ") }

        // Nothing read yet, so the sort keeps the group's order. The pointer rests on CL1, the first row, so its Use shows.
        let view = GroupAccountListView(accountIDs: ids, groupID: group.id, hovered: ids[0], stepAnimation: nil).environmentObject(store)
        let window = ListWindow(view, height: 360)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        let list = try #require(window.scrollView)
        let content = try #require(list.documentView?.frame.size)
        let viewport = list.convert(list.bounds, to: nil)
        let rowHeight = (content.height - 8 - CGFloat(ids.count - 1)) / CGFloat(ids.count)
        func inView(_ y: CGFloat, x: CGFloat = 100) -> CGPoint { CGPoint(x: viewport.minX + x, y: window.height - viewport.maxY + y) }
        func row(_ index: Int) -> CGPoint { inView(4 + CGFloat(index) * (rowHeight + 1) + rowHeight / 2 - list.contentView.bounds.minY) }

        // Dragged onto the third row, the first stays.
        try await window.drag(from: row(0), to: row(2))
        try await Task.sleep(for: .milliseconds(400))
        #expect(order() == "cl1 cl2 cl3 cl4 cl5 cl6 cl7")
        // A click on CL1's Use switches Claude Code to it.
        let titleHeight = NSHostingView(rootView: GroupAccountRow.buttonHeightTemplate).fittingSize.height
        let use = inView(4 + 7 + titleHeight / 2, x: content.width - 6 - 8 - 10)
        try await window.drag(from: use, to: use.moved(1, 1))
        try #require(await until { store.claudeCodeAccountID == accounts[0].id }, "Use did not switch Claude Code")
        #expect(f.defaultEmail == "cl1@example.test")
        #expect(order() == "cl1 cl2 cl3 cl4 cl5 cl6 cl7")
    }

    private func until(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    // MARK: Fixtures

    private static func usage(_ provider: ProviderKind, _ fiveHour: Int?, _ weekly: Int?, models: [(String, Int)] = [], plan: String? = nil,
                              groups: [LimitGroupSummary]? = nil, updated: Date = now.addingTimeInterval(-60), stale: Bool = false,
                              login: Bool = false, note: String? = nil) -> ProviderSnapshot {
        ProviderSnapshot(provider: provider, updatedAt: updated, fiveHour: window(fiveHour, hours: 2.7), weekly: window(weekly, hours: 130),
                         modelWeeklies: models.compactMap { model in window(model.1, hours: 74).map { ModelWeeklySummary(label: model.0, window: $0) } },
                         planName: plan, sourceDescription: "Fixture", note: note, isStale: stale, requiresLogin: login, limitGroups: groups)
    }

    // A reading with the 5-hour limit `percent` used and refilling in `hours`, and the weekly limit half that used and
    // refilling in `days`.
    private static func reading(_ provider: ProviderKind, _ percent: Int, fiveHour hours: Double, week days: Double) -> ProviderSnapshot {
        ProviderSnapshot(provider: provider, updatedAt: now.addingTimeInterval(-60), fiveHour: window(percent, hours: hours),
                         weekly: window(percent / 2, hours: days * 24), modelWeeklies: [], planName: nil, sourceDescription: "Fixture",
                         note: nil, isStale: false, requiresLogin: false)
    }

    private static func window(_ used: Int?, hours: Double) -> WindowSummary? {
        used.map { WindowSummary(tokens: $0, limitTokens: 100, resetAt: now.addingTimeInterval(hours * 3600), displayStyle: .percentage) }
    }

    private static var antigravity: ProviderSnapshot {
        let gemini = LimitGroupSummary(label: "Gemini", fiveHour: window(30, hours: 3), weekly: window(12, hours: 100))
        let claude = LimitGroupSummary(label: "Claude/GPT", fiveHour: window(55, hours: 1), weekly: window(91, hours: 40))
        return usage(.antigravity, 30, 12, plan: "Pro", groups: [gemini, claude])
    }

    // Every state a row can be in, as the plan's tables list them: limits and their alert, unread, cached and signed-out
    // usage, then each Claude Code state.
    private static func rowStates() -> [(String, GroupAccountRow)] {
        let claude = usage(.claude, 42, 21, models: [("Fable", 40)], plan: "Max")
        let switching = String(localized: "Claude Code is being switched. Wait for it to finish.")
        let reconnect = String(localized: "Reconnect this account before using it in Claude Code.")
        let useHelp = "Use this account in Claude Code. Open sessions switch within 30 s."
        func row(_ badge: String, _ address: String, _ snapshot: ProviderSnapshot, _ control: ClaudeCodePanel.Control = .hidden,
                 _ lines: [ClaudeCodePanel.Line] = [], pointer: Bool = false, refreshing: Bool = false) -> GroupAccountRow {
            GroupAccountRow(provider: snapshot.provider, name: badge, address: address, snapshot: snapshot, refreshing: refreshing,
                            claudeCode: ClaudeCodePanel(control: control, lines: lines), highlighted: pointer)
        }
        return [
            ("Claude · In use · three limits", row("CL2", "me@example.com", claude, .inClaudeCode)),
            ("Codex · two limits", row("CX3", "ops@example.com", usage(.codex, 64, 22, plan: "Team"))),
            ("Antigravity · four limits", row("AG", "studio@example.com", antigravity)),
            ("Over 90% · pointer on Use", row("CL4", "team4@example.com", usage(.claude, 92, 64, models: [("Fable", 40)], plan: "Max"),
                                              .use(enabled: true, help: useHelp), pointer: true)),
            ("Long address · pointer on Use", row("CL5", "a-very-long-address-for-a-team-account@example-company.com",
                                                  usage(.claude, 17, 9, plan: "Pro"), .use(enabled: true, help: useHelp), pointer: true)),
            ("Loading", row("CX4", "new@example.com", .placeholder(for: .codex), refreshing: true)),
            ("Could not load", row("CX5", "lab@example.com", ProviderSnapshot.placeholder(for: .codex).failed("Codex did not answer. Try again later."))),
            ("Cached", row("CL3", "lab@example.com", usage(.claude, 35, 18, models: [("Fable", 20)], plan: "Pro", updated: now.addingTimeInterval(-300),
                                                         stale: true, note: "Too many requests. Showing cached usage."))),
            ("Sign-in required", row("CX2", "dev@example.com", usage(.codex, 40, 10, plan: "Plus", stale: true, login: true,
                                                                    note: "Sign in again in Settings › Accounts."))),
            ("Use · checking · pointer", row("CL6", "six@example.com", claude, .use(enabled: false, help: String(localized: "Checking Claude Code…")), pointer: true)),
            ("Use · reconnect first · pointer", row("CL7", "seven@example.com", claude, .use(enabled: false, help: reconnect), [.notice(reconnect)], pointer: true)),
            ("Set Up · pointer", row("CL", "work@example.com", claude,
                                     .setUp(help: String(localized: "Sign in once in Settings › Accounts so Claude Code can use this account.")), pointer: true)),
            ("Switching · this account", row("CL4", "team4@example.com", claude, .use(enabled: false, help: switching),
                                             [.progress(String(localized: "Reading the current Claude Code login…"))])),
            ("Switching · another account · pointer", row("CL5", "lab@example.com", claude, .use(enabled: false, help: switching), pointer: true)),
            ("Question", row("CL4", "team4@example.com", claude, .use(enabled: true, help: useHelp), [.confirmation(email: "old@example.com")])),
            ("Switched", row("CL4", "team4@example.com", claude, .inClaudeCode, [.result(succeeded: true, message: "Claude Code now uses team4@example.com.")])),
            ("Switch failed", row("CL4", "team4@example.com", claude, .use(enabled: true, help: useHelp),
                                  [.result(succeeded: false, message: "Couldn't switch Claude Code. Its login was not changed.")])),
        ]
    }

    // Gives the main actor back before each picture, so tests running alongside are not kept waiting on it.
    @discardableResult
    private func draw<V: View>(_ view: V, appearance: NSAppearance.Name, height: CGFloat? = nil, to url: URL?) async throws -> NSSize {
        await Task.yield()
        let (bitmap, size) = try picture(view, appearance: appearance, height: height)
        #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
        if let url { try bitmap.representation(using: .png, properties: [:])?.write(to: url) }
        return size
    }

    // The view drawn on the panel's background, cut to `height` if given, and the size it asks for.
    private func picture<V: View>(_ view: V, appearance: NSAppearance.Name = .aqua, height: CGFloat? = nil) throws -> (bitmap: NSBitmapImageRep, size: NSSize) {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: appearance)
        let size = host.fittingSize
        host.frame = NSRect(x: 0, y: 0, width: size.width, height: height ?? size.height)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return (bitmap, size)
    }

    // The columns, in points from the left, where two pictures of a list differ in its header: the top 36 points, which
    // hold the group's name and the buttons beside it.
    private static func headerColumns(differingBetween a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> [CGFloat] {
        let scale = CGFloat(a.pixelsWide) / a.size.width
        var columns = Set<Int>()
        for y in 0..<min(Int(36 * scale), a.pixelsHigh, b.pixelsHigh) {
            for x in 0..<min(a.pixelsWide, b.pixelsWide) where a.colorAt(x: x, y: y) != b.colorAt(x: x, y: y) { columns.insert(x) }
        }
        return columns.sorted().map { CGFloat($0) / scale }
    }
}

// A view in a borderless window far off screen: never seen and never made key, yet AppKit hands it the mouse events a
// panel gets.
@MainActor
private final class ListWindow {
    private let window: NSWindow

    convenience init<V: View>(_ view: V, height: CGFloat) {
        self.init(host: NSHostingView(rootView: view), height: height)
    }

    // `host` stays the caller's, to hand the view new values as the panel does.
    init(host: NSView, height: CGFloat) {
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: GroupAccountListView.width, height: height), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
        window.contentView?.layoutSubtreeIfNeeded()
    }

    var height: CGFloat { window.frame.height }
    var scrollView: NSScrollView? { window.contentView.flatMap(Self.scrollView(in:)) }

    func close() { window.orderOut(nil) }

    func picture(to url: URL) throws {
        let view = try #require(window.contentView)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// A point from the window's top left.
    func send(_ type: NSEvent.EventType, _ point: CGPoint) async throws {
        let event = try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: point.x, y: height - point.y), modifierFlags: [],
                                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        window.sendEvent(event)
        try await Task.sleep(for: .milliseconds(16))
    }

    /// Presses at `start`, moves to `end` 16 points at a time, and lets go there unless `release` is false.
    func drag(from start: CGPoint, to end: CGPoint, release: Bool = true) async throws {
        try await send(.leftMouseDown, start)
        let distance = hypot(end.x - start.x, end.y - start.y)
        let steps = max(1, Int((distance / 16).rounded(.up)))
        for step in 1...steps {
            let part = CGFloat(step) / CGFloat(steps)
            try await send(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * part, y: start.y + (end.y - start.y) * part))
        }
        if release { try await send(.leftMouseUp, end) }
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        (view as? NSScrollView) ?? view.subviews.lazy.compactMap(scrollView(in:)).first
    }
}

private extension CGPoint {
    func moved(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint { CGPoint(x: x + dx, y: y + dy) }
}

// Where the list's rows are, as it measures them: from top to bottom, the order it shows.
@MainActor
private final class ListRows {
    var frames: [UUID: CGRect] = [:]
    var order: [UUID] { frames.sorted { $0.value.minY < $1.value.minY }.map(\.key) }
}

// A group's list as its panel shows it, handing the test where its rows are.
private struct ListReadingRows: View {
    let list: GroupAccountListView
    let store: UsageStore
    let rows: ListRows
    var body: some View {
        list.environmentObject(store)
            .onPreferenceChange(ListRowFrames.self) { frames in MainActor.assumeIsolated { rows.frames = frames } }
    }
}

// Holds back a reading until the test lets it go.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    func open() { lock.withLock { isOpen = true } }
    func wait() async {
        while !lock.withLock({ isOpen }) { try? await Task.sleep(for: .milliseconds(10)) }
    }
}
