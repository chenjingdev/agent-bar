import AppKit
import SwiftUI

// What the account list says that the rest of the app does not. Its Claude Code words are `ClaudeCodeWords`.
enum GroupListWords {
    // Separate sentences for one and many, since Korean does not add an "s".
    static func accounts(_ count: Int) -> String {
        count == 1 ? String(localized: "1 account") : String(localized: "\(count) accounts")
    }
    static var sortBy: String { String(localized: "Sort by") }
    static var sortHelp: String { String(localized: "Sort the list") }
    /// The list's sort button: the sort in use, in words.
    static func sortButton(_ sort: GroupListSort) -> String { String(localized: "Sort: \(sort.title)") }
}

extension GroupListSort {
    /// The order's name on the list's sort button and in its menu.
    var title: String {
        switch self {
        case .manual: String(localized: "Manual")
        case .fiveHourReset: String(localized: "5-hour reset")
        case .weeklyReset: String(localized: "Weekly reset")
        }
    }
}

// A group's panel shows all its accounts on one sheet, in the group's order: a row per account with every limit its
// service reports. There is no detail view behind a row.
struct GroupAccountListView: View {
    static let width: CGFloat = 400
    // A drag is measured in two places: the list's content, which scrolls, and the part of it in view.
    private static let content = "list-content"
    private static let viewport = "list-viewport"

    let accountIDs: [UUID]
    let groupID: UUID
    // How many times the panel has opened. A sorted list puts its rows in order afresh each time.
    let openings: Int
    @EnvironmentObject private var store: UsageStore
    @State private var hovered: UUID?
    // The order a sort by 5-hour or weekly reset last made, kept until the next moment to sort, so rows do not jump as new
    // numbers come in while someone reads them.
    @State private var sorted: SortedRows?
    // Dragging a row reorders the group's accounts, the order of its chips in Settings.
    @State private var drag: ListRowDrag?
    @State private var settling = false
    @GestureState private var dragging = false
    // Where the rows are in the content, where the content sits in view, and the size of the part in view.
    @State private var frames: [UUID: CGRect] = [:]
    @State private var origin: CGPoint = .zero
    @State private var viewport: CGSize = .zero
    private let stepAnimation: Animation?

    // `hovered` is the row the pointer starts over, for drawing that look. `stepAnimation` nil scrolls each step at once:
    // a scroll animates only while the display is on, which a test cannot count on.
    init(accountIDs: [UUID], groupID: UUID, openings: Int = 0, hovered: UUID? = nil,
         stepAnimation: Animation? = ListAutoScroll.stepAnimation) {
        self.accountIDs = accountIDs
        self.groupID = groupID
        self.openings = openings
        self.stepAnimation = stepAnimation
        _hovered = State(initialValue: hovered)
    }

    private var accounts: [UsageAccount] {
        var ids = MenuBarLayout.unique(accountIDs)
        // The store's order once it holds the same rows: a dropped row stays where it was put, though the panel hands
        // this view the new order a moment later. A sort by 5-hour or weekly reset puts the same rows in its order.
        if let live = liveOrder, live.count == ids.count, Set(live) == Set(ids) { ids = sortedOrder ?? live }
        return ids.compactMap { id in store.accounts.first { $0.id == id && !$0.deletionPending } }
    }

    private var layout: MenuBarLayout? { store.displayConfiguration.effectiveLayouts.first { $0.id == groupID } }
    private var sort: GroupListSort { layout?.effectiveListSort ?? .manual }

    /// The rows the store gives this list now, in the group's own order, as the panel will show them.
    private var liveOrder: [UUID]? { layout.map { store.panelAccountIDs(for: $0) } }

    /// The rows in the order of a sort by 5-hour or weekly reset, nil for manual: the order made at the last moment to sort
    /// while that moment stands, otherwise the order the sort makes now, which `keepSortedOrder` then keeps.
    private var sortedOrder: [UUID]? {
        guard let layout, layout.effectiveListSort != .manual else { return nil }
        if let sorted, sorted.moment == sortMoment(layout) { return sorted.order }
        return store.sortedPanelAccountIDs(for: layout)
    }

    /// When a sorted list puts its rows in order afresh: the panel opens, it shows another group or other accounts, the
    /// sort changes, or a refresh round ends. Numbers that come in between leave the rows where they are.
    private struct SortMoment: Equatable {
        var openings: Int
        var group: UUID
        var sort: GroupListSort
        var rows: Set<UUID>
        var round: Date?
    }

    private struct SortedRows {
        var moment: SortMoment
        var order: [UUID]
    }

    private func sortMoment(_ layout: MenuBarLayout) -> SortMoment {
        SortMoment(openings: openings, group: groupID, sort: layout.effectiveListSort,
                   rows: Set(store.panelAccountIDs(for: layout)), round: store.lastRefresh)
    }

    private func keepSortedOrder() {
        guard let layout, layout.effectiveListSort != .manual else { sorted = nil; return }
        let order = store.sortedPanelAccountIDs(for: layout)
        // The rows moved under a pointer that did not: no row shows the pointer's look or buttons until it moves, rather
        // than the row it was over showing them somewhere else.
        if let previous = sorted?.order, previous != order { hovered = nil }
        sorted = SortedRows(moment: sortMoment(layout), order: order)
    }

    var body: some View {
        let accounts = accounts
        let claudeCode = Dictionary(accounts.map { ($0.id, store.claudeCodeListRow(for: $0)) }, uniquingKeysWith: { first, _ in first })
        VStack(alignment: .leading, spacing: 0) {
            header(accounts)
            ScrollViewReader { proxy in
                // Scroll only when the rows outgrow the screen; the header and footer stay put.
                ViewThatFits(in: .vertical) {
                    rowList(accounts, claudeCode: claudeCode)
                    ScrollView { rowList(accounts, claudeCode: claudeCode) }
                }
                .coordinateSpace(name: Self.viewport)
                .background(GeometryReader { Color.clear.preference(key: ListViewportSize.self, value: $0.size) })
                .onPreferenceChange(ListRowFrames.self) { frames = $0 }
                .onPreferenceChange(ListContentFrame.self) { contentMoved(to: $0.origin) }
                .onPreferenceChange(ListViewportSize.self) { viewport = $0 }
                // A row that comes to hold a result or a question is scrolled into view, so it counts as seen for real.
                .onChange(of: Self.rowsAsking(accounts, claudeCode: claudeCode)) { old, new in
                    guard let id = new.first(where: { !old.contains($0) }) else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id) }
                }
                .onChange(of: accounts.filter { store.couponPanel(for: $0).line == .choosing }.map(\.id)) { old, new in
                    guard let id = new.first(where: { !old.contains($0) }) else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id) }
                }
                // Dragged near the top or bottom, the list scrolls toward that edge.
                .task(id: autoScroll) { await scrollWhileDragging(proxy) }
            }
            // The dragged row floats over the footer.
            .zIndex(drag == nil ? 0 : 1)
            Divider().padding(.horizontal, 14)
            footer(accounts)
        }
        .frame(width: Self.width, alignment: .topLeading)
        // The list shows all of its Claude accounts at once, for the Claude Code result lines; one that comes to hold a
        // result is scrolled to above. The group is part of the key: a menu bar item that comes to show another group
        // keeps this view.
        .onChange(of: [groupID] + accountIDs, initial: true) { _, _ in
            store.claudeCodePanelShows(self.accounts.filter { $0.provider == .claude }.map(\.id), group: groupID)
        }
        .onChange(of: layout.map(sortMoment), initial: true) { _, _ in keepSortedOrder() }
        // The gesture ended without a drop, as when its row went away.
        .onChange(of: dragging) { _, now in if !now { dragStopped() } }
        .onDisappear { drag = nil; settling = false }
    }

    private static func rowsAsking(_ accounts: [UsageAccount], claudeCode: [UUID: ClaudeCodePanel]) -> [UUID] {
        accounts.map(\.id).filter { id in
            claudeCode[id]?.lines.contains { line in
                switch line {
                case .confirmation, .result: return true
                case .progress, .notice: return false
                }
            } == true
        }
    }

    private func header(_ accounts: [UsageAccount]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    let name = layout?.name ?? ""
                    Group { if name.isEmpty { Text("Untitled") } else { Text(verbatim: name) } }
                        .font(.title3.weight(.bold)).lineLimit(1)
                    Text(GroupListWords.accounts(accounts.count))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                }
                Spacer(minLength: 8)
                // Side by side, so their hover backgrounds touch.
                HStack(spacing: 0) {
                    sortMenu
                    if accounts.contains(where: { store.refreshingAccounts.contains($0.id) }) {
                        // The room the refresh button takes, so the header does not shift while it turns.
                        ProgressView().controlSize(.small).frame(width: 24, height: 24)
                    } else {
                        // Both icons take the same square, so their hover backgrounds are as wide as each other.
                        Button { store.refreshNow() } label: { Image(systemName: "arrow.clockwise").frame(width: 16, height: 16) }
                            .help("Refresh now")
                    }
                    Button { SettingsWindowController.shared.show(tab: .menuBar, groupID: groupID) } label: { Image(systemName: "gearshape").frame(width: 16, height: 16) }
                        .help("Settings")
                }
                .buttonStyle(PanelButtonStyle(kind: .icon))
                .padding(.trailing, -4)
            }
            if let error = store.displayError {
                Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            // Said once for every Claude account, such as a Claude Code too old to switch.
            if let notice = store.claudeCodeListNotice, accounts.contains(where: { $0.provider == .claude }) {
                Text(notice).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    // The sort in use in words ("Sort: Manual") and a small chevron; a click opens the sorts, the one in use checked. No
    // up-down arrow, which would read as a button that flips the order.
    private var sortMenu: some View {
        let sort = sort
        return Menu {
            Section(GroupListWords.sortBy) {
                Picker(GroupListWords.sortBy, selection: Binding(get: { sort }, set: { store.setListSort($0, for: groupID) })) {
                    ForEach(GroupListSort.allCases) { Text(verbatim: $0.title).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        } label: {
            HStack(spacing: 3) {
                Text(verbatim: GroupListWords.sortButton(sort)).font(.callout).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
            }
            // As tall as the icons beside it, a little wider on each side for the words.
            .frame(height: 16)
            .padding(.horizontal, 2)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(GroupListWords.sortHelp)
        .accessibilityLabel(GroupListWords.sortBy)
        .accessibilityValue(sort.title)
    }

    private func rowList(_ accounts: [UsageAccount], claudeCode: [UUID: ClaudeCodePanel]) -> some View {
        let refreshed = store.refreshAccountIDs
        let order = accounts.map(\.id)
        // Only the group's own order is set by hand. A sorted list starts no drag; presses and Use work as ever.
        let draggable: GestureMask = sort == .manual ? .all : .subviews
        return VStack(spacing: 0) {
            ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                // One view for the divider and the row: two would share the row's id, and scrolling to it would find the
                // divider.
                VStack(spacing: 0) {
                    if index > 0 {
                        // Gone beside the row under the pointer, whose background marks it instead, and while rows move
                        // past them in a drag.
                        Divider().padding(.horizontal, 8)
                            .opacity(drag != nil || hovered == account.id || hovered == accounts[index - 1].id ? 0 : 1)
                    }
                    row(account, refreshed: refreshed.contains(account.id), claudeCode: claudeCode[account.id] ?? .hidden)
                        // Like the chips in Settings: a press that moves less than 4 points stays a press, so Use works.
                        .highPriorityGesture(DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.viewport))
                            .updating($dragging) { _, state, _ in state = true }
                            .onChanged { dragMoved(account.id, $0, order: order) }
                            .onEnded { dragEnded($0) }, including: draggable)
                        .opacity(drag?.source == account.id ? 0 : 1)
                        .offset(drag?.offset(for: account.id) ?? .zero)
                        .animation(.snappy(duration: 0.18), value: drag?.target)
                        // Measured where the row sits in the list, not where a drag shows it.
                        .background(GeometryReader { proxy in
                            Color.clear.preference(key: ListRowFrames.self, value: [account.id: proxy.frame(in: .named(Self.content))])
                        })
                        .onHover { inside in
                            if inside { hovered = account.id } else if hovered == account.id { hovered = nil }
                        }
                }
                // The list's top and bottom margins go with the first and last rows, so scrolling to them reaches the ends.
                .padding(.top, index == 0 ? 4 : 0)
                .padding(.bottom, index == accounts.count - 1 ? 4 : 0)
                .id(account.id)
            }
        }
        .padding(.horizontal, 6)
        .coordinateSpace(name: Self.content)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: ListContentFrame.self, value: proxy.frame(in: .named(Self.viewport)))
        })
        .overlay(alignment: .topLeading) {
            dragOverlay(accounts, refreshed: refreshed, claudeCode: claudeCode).allowsHitTesting(false)
        }
    }

    // Where the dragged row will land, and the row itself following the pointer.
    @ViewBuilder private func dragOverlay(_ accounts: [UsageAccount], refreshed: Set<UUID>, claudeCode: [UUID: ClaudeCodePanel]) -> some View {
        if let drag, let account = accounts.first(where: { $0.id == drag.source }) {
            DragSlotPlaceholder(cornerRadius: 8)
                .frame(width: drag.placeholder.width, height: drag.placeholder.height)
                .offset(x: drag.placeholder.minX, y: drag.placeholder.minY)
                .animation(.snappy(duration: 0.18), value: drag.target)
            row(account, refreshed: refreshed.contains(account.id), claudeCode: claudeCode[account.id] ?? .hidden)
                .frame(width: drag.floatingFrame.width, height: drag.floatingFrame.height)
                .modifier(FloatingDragCard(settling: settling, liftScale: 1.02, cornerRadius: 8))
                .offset(x: drag.floatingFrame.minX, y: drag.floatingFrame.minY)
        }
    }

    private func row(_ account: UsageAccount, refreshed: Bool, claudeCode: ClaudeCodePanel) -> some View {
        GroupAccountRow(
            provider: account.provider,
            badge: store.displayConfiguration.display(account).badge,
            address: account.identity?.email.flatMap { $0.isEmpty ? nil : $0 } ?? store.accountLabel(for: account),
            snapshot: store.snapshot(for: account),
            refreshed: refreshed,
            refreshing: store.refreshingAccounts.contains(account.id),
            claudeCode: claudeCode,
            // Not while a row is dragged: its buttons would show on whatever row the pointer passes.
            highlighted: hovered == account.id && drag == nil,
            coupon: store.couponPanel(for: account),
            actions: .init(use: { store.useInClaudeCode(account) },
                           setUp: { SettingsWindowController.shared.show(tab: .accounts, groupID: groupID) },
                           confirm: { store.confirmClaudeCodeSwitch() },
                           decline: { store.cancelClaudeCodeConfirmation() },
                           openLog: { store.openClaudeCodeLog() },
                           useCoupon: { store.askToUseCoupon(account) },
                           chooseCoupon: { store.chooseCoupon($0, for: account) },
                           confirmCoupon: { store.confirmCoupon(account) },
                           cancelCoupon: { store.cancelCoupon(account) }))
    }

    // MARK: Drag

    private func dragMoved(_ id: UUID, _ value: DragGesture.Value, order: [UUID]) {
        guard !settling else { return }
        if drag?.source == id {
            drag?.pointer = value.location
            drag?.follow(origin: origin)
        } else {
            drag = ListRowDrag(source: id, order: order, frames: frames, pointer: value.location, start: value.startLocation,
                               origin: origin)
            hovered = nil
        }
    }

    // The content moved under the pointer: the list scrolled, by itself during a drag or by hand.
    private func contentMoved(to point: CGPoint) {
        origin = point
        if !settling { drag?.follow(origin: point) }
    }

    private func dragEnded(_ value: DragGesture.Value) {
        guard var current = drag, !settling else { return }
        current.pointer = value.location
        current.follow(origin: origin)
        let target = current.target
        drag = current
        withAnimation(.easeOut(duration: 0.16)) {
            settling = true
            drag?.preview.translation = current.landingTranslation
        } completion: {
            guard drag?.source == current.source, settling else { return }
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) {
                // Dropped on an order changed elsewhere meanwhile: the drop no longer means anything.
                var moved = false
                if let target, liveOrder == current.preview.order {
                    moved = store.moveGroupMember(current.source, to: target, in: groupID)
                }
                hovered = rowUnderPointer(current, moved: moved)
                drag = nil
                settling = false
            }
        }
    }

    // The gesture ended without a drop, as when the panel closed or the row went away: everything goes back.
    private func dragStopped() {
        guard drag != nil, !settling else { return }
        drag = nil
        hovered = nil
    }

    // The row the pointer rests on once the rows have settled, so its look and buttons come back without waiting for the
    // pointer to move.
    private func rowUnderPointer(_ drag: ListRowDrag, moved: Bool) -> UUID? {
        let pointer = drag.pointer
        guard (0...viewport.width).contains(pointer.x), (0...viewport.height).contains(pointer.y) else { return nil }
        let point = CGPoint(x: pointer.x - origin.x, y: pointer.y - origin.y)
        let rows = moved ? drag.landedFrames : drag.preview.frames
        return rows.first { $0.value.contains(point) }?.key
    }

    private var autoScroll: ListAutoScroll.Direction? {
        guard let drag, !settling else { return nil }
        return ListAutoScroll.direction(pointerY: drag.pointer.y, viewportHeight: viewport.height)
    }

    // A row a step until the pointer leaves the edge, the drag ends or the end of the list is in view. A list that fits
    // has nothing out of view, so it never scrolls.
    private func scrollWhileDragging(_ proxy: ScrollViewProxy) async {
        guard let direction = autoScroll else { return }
        while !Task.isCancelled, let current = drag, !settling {
            let visible = -origin.y...(-origin.y + viewport.height)
            guard let next = ListAutoScroll.nextRow(direction, order: current.preview.order, frames: current.preview.frames,
                                                    visible: visible) else { return }
            withAnimation(stepAnimation) { proxy.scrollTo(next, anchor: ListAutoScroll.anchor(direction)) }
            try? await Task.sleep(for: ListAutoScroll.step)
        }
    }

    private func footer(_ accounts: [UsageAccount]) -> some View {
        HStack {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(verbatim: updated(accounts, now: context.date))
                    .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 4)
            HStack(spacing: 0) {
                Button("Accounts") { SettingsWindowController.shared.show(tab: .accounts, groupID: groupID) }
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(PanelButtonStyle(kind: .text))
            .padding(.trailing, -6)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // The oldest time among the accounts that are up to date: every one of them is at least that fresh. Accounts that
    // could not be refreshed say so in their own rows.
    private func updated(_ accounts: [UsageAccount], now: Date) -> String {
        if store.isRefreshing { return String(localized: "Refreshing…") }
        let freshSnapshots = accounts.map { store.snapshot(for: $0) }.filter { !$0.isStale && $0.hasKnownUpdateTime }
        guard let oldest = freshSnapshots.map(\.updatedAt).min() else { return "" }
        return String(localized: "Updated \(TokenFormatters.relativeUpdateString(from: now, updatedAt: oldest))")
    }
}

// MARK: Dragging rows

// Each row's place in the list's content, which stays put as the list scrolls. Read from outside too: the rows from top
// to bottom are the order the list shows.
struct ListRowFrames: PreferenceKey {
    static var defaultValue: [UUID: CGRect] { [:] }
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

// Where the content sits in the part of the list in view (it moves up as the list scrolls down), and that part's size.
// Views beside the one that measures hand in the empty default too; taking the last value would keep that instead.
private struct ListContentFrame: PreferenceKey {
    static var defaultValue: CGRect { .zero }
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { let next = nextValue(); if next != .zero { value = next } }
}

private struct ListViewportSize: PreferenceKey {
    static var defaultValue: CGSize { .zero }
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { let next = nextValue(); if next != .zero { value = next } }
}

/// A row being dragged. The preview works in the list's content; the pointer is kept where it is in the part in view, so
/// when the list scrolls under a pointer that stays still, the drop follows the content.
struct ListRowDrag {
    var preview: ReorderDragPreview<UUID>
    var pointer: CGPoint
    // Where the pointer started, in the content.
    let start: CGPoint

    /// `pointer` and `start` are in the part in view, where the content's corner is at `origin`.
    init(source: UUID, order: [UUID], frames: [UUID: CGRect], pointer: CGPoint, start: CGPoint, origin: CGPoint) {
        preview = ReorderDragPreview(source: source, order: order, frames: frames, location: .zero, translation: .zero,
                                     hitPadding: CGSize(width: 3, height: 6))
        self.pointer = pointer
        self.start = CGPoint(x: start.x - origin.x, y: start.y - origin.y)
        follow(origin: origin)
    }

    var source: UUID { preview.source }
    var target: UUID? { preview.target }

    /// After the pointer moves, or the content moves under it.
    mutating func follow(origin: CGPoint) {
        let location = CGPoint(x: pointer.x - origin.x, y: pointer.y - origin.y)
        preview.location = location
        preview.translation = CGSize(width: location.x - start.x, height: location.y - start.y)
    }

    /// Where each row goes in the new order. Rows keep their own heights and the gaps between them: the shared preview
    /// moves a row into another row's slot, which only fits rows of one height, and these differ (a fourth limit, a
    /// status line, Claude Code lines).
    var landedFrames: [UUID: CGRect] {
        let order = preview.order, frames = preview.frames
        guard let first = order.first, var y = frames[first]?.minY else { return [:] }
        var result: [UUID: CGRect] = [:]
        for (index, id) in preview.previewOrder.enumerated() {
            guard let frame = frames[id] else { continue }
            result[id] = CGRect(origin: CGPoint(x: frame.minX, y: y), size: frame.size)
            var gap: CGFloat = 0
            if index + 1 < order.count, let upper = frames[order[index]], let lower = frames[order[index + 1]] {
                gap = max(0, lower.minY - upper.maxY)
            }
            y += frame.height + gap
        }
        return result
    }

    func offset(for id: UUID) -> CGSize {
        guard id != source, let landed = landedFrames[id], let frame = preview.frames[id] else { return .zero }
        return CGSize(width: landed.minX - frame.minX, height: landed.minY - frame.minY)
    }

    var placeholder: CGRect { landedFrames[source] ?? preview.frames[source] ?? .zero }
    var floatingFrame: CGRect { preview.floatingFrame }
    var landingTranslation: CGSize {
        let frame = preview.frames[source] ?? .zero
        return CGSize(width: placeholder.minX - frame.minX, height: placeholder.minY - frame.minY)
    }
}

/// While a row is dragged near the top or bottom of a list that scrolls, the list scrolls toward that edge, a row at a
/// time: SwiftUI on macOS 14 scrolls only to a view (`ScrollViewReader`), so a step brings the next row into view.
enum ListAutoScroll {
    enum Direction: Equatable { case up, down }

    // How near an edge the pointer starts the scrolling, how often it steps, and how each step glides.
    static let edge: CGFloat = 28
    static let step: Duration = .milliseconds(150)
    static let stepAnimation: Animation = .linear(duration: 0.15)

    /// Up within `edge` of the top or above it, down within `edge` of the bottom or below it; nothing in between.
    static func direction(pointerY y: CGFloat, viewportHeight height: CGFloat) -> Direction? {
        guard height > 0 else { return nil }
        if y < min(edge, height / 2) { return .up }
        if y > max(height - edge, height / 2) { return .down }
        return nil
    }

    /// The row the next step scrolls to, from the rows' frames in the content and the part of the content in view:
    /// going down, the first row that reaches below it; going up, the last that reaches above it. Nil once the list's
    /// end is in view, which stops the scrolling.
    static func nextRow<ID: Hashable>(_ direction: Direction, order: [ID], frames: [ID: CGRect], visible: ClosedRange<CGFloat>) -> ID? {
        let slack: CGFloat = 0.5
        switch direction {
        case .down: return order.first { frames[$0].map { $0.maxY > visible.upperBound + slack } ?? false }
        case .up: return order.last { frames[$0].map { $0.minY < visible.lowerBound - slack } ?? false }
        }
    }

    /// Where the row lands: at the bottom going down, at the top going up.
    static func anchor(_ direction: Direction) -> UnitPoint { direction == .down ? .bottom : .top }
}
