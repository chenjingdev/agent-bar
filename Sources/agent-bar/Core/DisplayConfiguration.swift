import AppKit
import Foundation
import SwiftUI

enum AccountColor: String, Codable, CaseIterable, Identifiable {
    case blue, purple, green, orange, red, pink, teal, yellow
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var nsColor: NSColor {
        switch self {
        case .blue: return NSColor(red: 0.24, green: 0.37, blue: 0.66, alpha: 1)
        case .purple: return NSColor(red: 0.36, green: 0.31, blue: 0.69, alpha: 1)
        case .green: return NSColor(red: 0.18, green: 0.49, blue: 0.31, alpha: 1)
        case .orange: return NSColor(red: 0.54, green: 0.35, blue: 0.17, alpha: 1)
        case .red: return NSColor(red: 0.64, green: 0.24, blue: 0.24, alpha: 1)
        case .pink: return NSColor(red: 0.62, green: 0.27, blue: 0.48, alpha: 1)
        case .teal: return NSColor(red: 0.16, green: 0.47, blue: 0.50, alpha: 1)
        case .yellow: return NSColor(red: 0.55, green: 0.46, blue: 0.14, alpha: 1)
        }
    }
    // Bars and percentages sit on a dark capsule, so they use a lighter tint of the badge color.
    var barColor: NSColor {
        switch self {
        case .blue: return NSColor(red: 0.66, green: 0.75, blue: 0.95, alpha: 1)
        case .purple: return NSColor(red: 0.79, green: 0.74, blue: 0.97, alpha: 1)
        case .green: return NSColor(red: 0.56, green: 0.84, blue: 0.65, alpha: 1)
        case .orange: return NSColor(red: 0.91, green: 0.72, blue: 0.48, alpha: 1)
        case .red: return NSColor(red: 0.95, green: 0.62, blue: 0.62, alpha: 1)
        case .pink: return NSColor(red: 0.95, green: 0.66, blue: 0.83, alpha: 1)
        case .teal: return NSColor(red: 0.55, green: 0.85, blue: 0.87, alpha: 1)
        case .yellow: return NSColor(red: 0.93, green: 0.84, blue: 0.50, alpha: 1)
        }
    }
    static func preferred(for provider: ProviderKind) -> AccountColor {
        switch provider {
        case .claude: return .blue
        case .codex: return .purple
        case .antigravity: return .teal
        }
    }
    static func next(for provider: ProviderKind, used: [AccountColor]) -> AccountColor {
        let preferred = preferred(for: provider)
        if !used.contains(preferred) { return preferred }
        return allCases.first { !used.contains($0) } ?? preferred
    }
}

struct AccountDisplay: Codable, Equatable {
    /// Claude's limits, from before other services; files without `bars` were Claude's.
    static let defaultBars: Set<String> = ["5h", "weekly", "model:fable"]
    /// Only Claude has a Fable limit.
    static func defaultBars(for provider: ProviderKind) -> Set<String> {
        provider == .claude ? defaultBars : ["5h", "weekly"]
    }
    var visible = true
    var badge: String
    var color: AccountColor
    // The limit this account's gauge and percentage show. Falls back to another limit while it has no data.
    var primary: String = "weekly"
    // Limits this account also draws as extra lines in the Multi Bar style.
    var bars: Set<String> = defaultBars
    // 0 = its own menu bar item. Accounts sharing a group number share one item.
    var group = 0
    init(visible: Bool = true, badge: String, color: AccountColor, primary: String = "weekly", bars: Set<String> = defaultBars, group: Int = 0) {
        self.visible = visible; self.badge = badge; self.color = color; self.primary = primary; self.bars = bars; self.group = group
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        visible = try c.decodeIfPresent(Bool.self, forKey: .visible) ?? true
        badge = try c.decode(String.self, forKey: .badge)
        color = try c.decode(AccountColor.self, forKey: .color)
        primary = try c.decodeIfPresent(String.self, forKey: .primary) ?? "weekly"
        bars = try c.decodeIfPresent(Set<String>.self, forKey: .bars) ?? Self.defaultBars
        group = try c.decodeIfPresent(Int.self, forKey: .group) ?? 0
    }
}

enum MenuBarStyle: String, Codable, CaseIterable, Identifiable {
    case badge, ring, capsule, bars, text
    // Keep the old value readable; explicit usage lines make badge and bars identical.
    static let selectableCases: [Self] = [.bars, .ring, .capsule, .text]
    var selection: Self { self == .badge ? .bars : self }
    var id: String { rawValue }
    var title: String {
        switch self {
        case .badge: return String(localized: "Name Badge")
        case .ring: return String(localized: "Ring Gauge")
        case .capsule: return String(localized: "Capsule Fill")
        case .bars: return String(localized: "Multi Bar")
        case .text: return String(localized: "Text Only")
        }
    }
    var summary: String {
        switch self {
        case .badge: return String(localized: "Badge, one bar, percentage.")
        case .ring: return String(localized: "A ring with a full-size percentage beside it.")
        case .capsule: return String(localized: "The badge itself fills up with usage.")
        case .bars: return String(localized: "One line per limit, up to three, each labelled account·limit.")
        case .text: return String(localized: "Every usage percentage, arranged from left to right.")
        }
    }
}

// Account appearance plus ordered display layouts. Legacy account-based fields
// remain readable so existing installations can migrate without losing preferences.
struct DisplayConfiguration: Codable, Equatable {
    static let badgeLimit = 8
    var version = 2
    var order: [UUID] = []
    var accounts: [String: AccountDisplay] = [:]
    var showBadge = true
    var showBar = true
    var showPercent = true
    var style: MenuBarStyle = .badge
    static let groupLimit = 4
    // Grouped items stack one line per account, `rowsPerColumn` per column.
    var rowsPerColumn = 2
    // Explicit groups preserve per-group options and ordered account/limit rows.
    var layouts: [MenuBarLayout]?
    // Transient rendering inputs. Persisted per group in layouts, never shared.
    var commonBadgeText: String? = nil
    var commonBadgeColor: AccountColor = .blue
    var percentageLineID: String? = nil

    init() {}
    // Files written before a field existed decode with that field's default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        order = try c.decode([UUID].self, forKey: .order)
        accounts = try c.decode([String: AccountDisplay].self, forKey: .accounts)
        showBadge = try c.decodeIfPresent(Bool.self, forKey: .showBadge) ?? true
        showBar = try c.decodeIfPresent(Bool.self, forKey: .showBar) ?? true
        showPercent = try c.decodeIfPresent(Bool.self, forKey: .showPercent) ?? true
        style = try c.decodeIfPresent(MenuBarStyle.self, forKey: .style) ?? .badge
        rowsPerColumn = try c.decodeIfPresent(Int.self, forKey: .rowsPerColumn) ?? 2
        layouts = try c.decodeIfPresent([MenuBarLayout].self, forKey: .layouts)
        // The earlier all-or-nothing Compact switch becomes group 1 for everyone.
        if try c.decodeIfPresent(Bool.self, forKey: .legacyCompact) == true {
            for key in accounts.keys { accounts[key]?.group = 1 }
        }
        // Files from before the per-account main limit carried one shared choice.
        if try c.decodeIfPresent(String.self, forKey: .legacyBarMetric) == "fiveHour" {
            for key in accounts.keys { accounts[key]?.primary = "5h" }
        }
    }
    private enum CodingKeys: String, CodingKey {
        case version, order, accounts, showBadge, showBar, showPercent, style, rowsPerColumn, layouts
        case legacyBarMetric = "barMetric"
        case legacyCompact = "compact"
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version); try c.encode(order, forKey: .order); try c.encode(accounts, forKey: .accounts)
        try c.encode(showBadge, forKey: .showBadge); try c.encode(showBar, forKey: .showBar); try c.encode(showPercent, forKey: .showPercent)
        try c.encode(style, forKey: .style); try c.encode(rowsPerColumn, forKey: .rowsPerColumn)
        try c.encodeIfPresent(layouts, forKey: .layouts)
    }

    func display(_ account: UsageAccount) -> AccountDisplay {
        accounts[account.id.uuidString] ?? AccountDisplay(badge: account.provider.shortName, color: .preferred(for: account.provider),
                                                          bars: AccountDisplay.defaultBars(for: account.provider))
    }
    func isVisible(_ id: UUID) -> Bool { accounts[id.uuidString]?.visible ?? true }
    var visibleAccountIDs: [UUID] {
        let assigned = layouts.map { Set($0.filter { $0.enabled && $0.showsAnything }.flatMap(\.displayedRows).map(\.accountID)) }
        return order.filter { isVisible($0) && (assigned?.contains($0) ?? true) }
    }
    // Visible accounts arranged into menu bar items: a shared group appears where its first member does.
    func menuBarGroups() -> [(key: UUID, accountIDs: [UUID])] {
        var result: [(key: UUID, accountIDs: [UUID])] = []
        for id in visibleAccountIDs {
            let group = accounts[id.uuidString]?.group ?? 0
            if group > 0, let index = result.firstIndex(where: { $0.key == Self.groupKey(group) }) {
                result[index].accountIDs.append(id)
            } else {
                result.append((group > 0 ? Self.groupKey(group) : id, [id]))
            }
        }
        return result
    }
    static func groupKey(_ group: Int) -> UUID { UUID(uuidString: String(format: "A6E17BA0-0000-4000-8000-%012X", group))! }
    // Every account listed by the panel of a group the menu bar shows; a group switched off has no panel.
    var refreshAccountIDs: Set<UUID> {
        guard let layouts else { return Set(visibleAccountIDs) }
        return Set(layouts.filter { $0.enabled && $0.showsAnything }.flatMap(\.refreshedAccountIDs).filter(isVisible))
    }
    var showsAnything: Bool { showBadge || showBar || showPercent }

    static func trimmedBadge(_ text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(badgeLimit))
    }
    mutating func update(_ id: UUID, _ change: (inout AccountDisplay) -> Void) {
        guard var value = accounts[id.uuidString] else { return }
        change(&value)
        value.badge = Self.trimmedBadge(value.badge)
        accounts[id.uuidString] = value
    }
    mutating func setVisible(_ id: UUID, _ visible: Bool) { update(id) { $0.visible = visible } }
    mutating func move(_ id: UUID, offset: Int) {
        guard let index = order.firstIndex(of: id), order.indices.contains(index + offset) else { return }
        order.swapAt(index, index + offset)
    }
    @discardableResult
    mutating func setComponent(badge: Bool? = nil, bar: Bool? = nil, percent: Bool? = nil) -> Bool {
        let next = (badge ?? showBadge, bar ?? showBar, percent ?? showPercent)
        guard next.0 || next.1 || next.2 else { return false }
        (showBadge, showBar, showPercent) = next
        return true
    }
    // Registers accounts that appeared since the last save and forgets deleted ones.
    mutating func sync(_ live: [UsageAccount]) {
        let ids = Set(live.map(\.id))
        if layouts != nil {
            for i in layouts!.indices {
                layouts![i].rows.removeAll { !ids.contains($0.accountID) }
                // A deleted account leaves the groups holding it; a group left with none uses its lines' accounts again.
                if let members = layouts![i].memberIDs?.filter(ids.contains) { layouts![i].memberIDs = members.isEmpty ? nil : members }
            }
            normalizeTextLineSlots()
            for account in live where accounts[account.id.uuidString] == nil {
                let line = MenuBarLine(accountID: account.id, metricID: "weekly")
                // Fill a group left empty (e.g. by deleting its account) before adding
                // another one, so a re-added account doesn't sit beside a bare "+" item.
                // A group holding accounts of its own is not empty: a line there would need its account as a member.
                if let empty = layouts!.firstIndex(where: { $0.enabled && $0.rows.isEmpty && $0.memberIDs == nil }) {
                    layouts![empty].rows = [line]
                } else {
                    layouts!.append(MenuBarLayout(name: account.title, rows: [line]))
                }
            }
        }
        order.removeAll { !ids.contains($0) }
        accounts = accounts.filter { UUID(uuidString: $0.key).map(ids.contains) ?? false }
        for account in live where accounts[account.id.uuidString] == nil {
            let used = live.compactMap { accounts[$0.id.uuidString]?.color }
            // A second account of the same provider gets a numbered badge so the
            // pair is readable before the user names them. Existing badges never change.
            let taken = Set(live.filter { $0.provider == account.provider }.compactMap { accounts[$0.id.uuidString]?.badge })
            var badge = account.provider.shortName
            // The lowest number no sibling uses, so a deleted account's number does not make two badges alike.
            if taken.contains(badge), let number = (2...).first(where: { !taken.contains(badge + "\($0)") }) { badge += "\(number)" }
            accounts[account.id.uuidString] = AccountDisplay(badge: badge, color: .next(for: account.provider, used: used),
                                                             bars: AccountDisplay.defaultBars(for: account.provider))
        }
        // Earlier versions gave every new account Claude's extra limits. Only
        // Claude has Fable, so do not let that dormant choice become a row.
        for account in live where account.provider != .claude {
            accounts[account.id.uuidString]?.bars.remove("model:fable")
        }
        for account in live where !order.contains(account.id) { order.append(account.id) }
    }
    /// Gives an account just added its first lines in place of the single
    /// weekly line `sync` gave it, as far as its group has room.
    mutating func setFirstLines(_ id: UUID, _ metricIDs: [String]) {
        guard let first = metricIDs.first else { return }
        accounts[id.uuidString]?.primary = first
        accounts[id.uuidString]?.bars = Set(metricIDs)
        guard let index = layouts?.firstIndex(where: { $0.rows.contains { $0.accountID == id } }) else { return }
        var layout = layouts![index]
        let others = layout.rows.filter { $0.accountID != id }
        let room = layout.style == .text ? metricIDs.count : max(1, MenuBarLayout.maximumLines - others.count)
        layout.rows = others + metricIDs.prefix(room).map { MenuBarLine(accountID: id, metricID: $0) }
        layouts![index] = layout
    }
    var valid: Bool {
        (layouts.map { groups in Set(groups.map(\.id)).count == groups.count && groups.allSatisfy { group in
            group.valid && (group.rows.map(\.accountID) + (group.memberIDs ?? [])).allSatisfy { accounts[$0.uuidString] != nil }
        } } ?? true)
            && version == 2 && Set(order).count == order.count && order.allSatisfy { accounts[$0.uuidString] != nil }
            && accounts.values.allSatisfy { !$0.badge.isEmpty && $0.badge.count <= Self.badgeLimit }
            && (1...6).contains(rowsPerColumn) && accounts.values.allSatisfy { (0...Self.groupLimit).contains($0.group) }
    }

    @MainActor static func initial(_ registry: AccountRegistry, settings: AppSettings? = nil) -> Self {
        var value = Self()
        let live = registry.accounts.filter { !$0.deletionPending }
        value.sync(live)
        guard let settings else { return value }
        for account in live where !settings.getProviderDisplaySettings(account.provider).isEnabled {
            value.setVisible(account.id, false)
        }
        if let provider = ProviderKind.allCases.first(where: { settings.getProviderDisplaySettings($0).isEnabled }) {
            let preference = settings.getProviderDisplaySettings(provider)
            value.setComponent(badge: preference.showsBadge, bar: preference.showsUsageBars, percent: preference.showsPercentage)
        }
        return value
    }
    // Preserve original item layouts alongside the account appearance metadata.
    static func migrated(from legacy: LegacyDisplayConfiguration, accounts live: [UsageAccount]) -> Self {
        var value = Self()
        let active = legacy.items.prefix(legacy.activeCount)
        let shown = active.flatMap(\.accountIDs)
        let hidden = legacy.items.dropFirst(legacy.activeCount).flatMap(\.accountIDs)
        let ordered = (shown + hidden).filter { id in live.contains { $0.id == id } } + live.map(\.id)
        var seen = Set<UUID>()
        value.sync(ordered.filter { seen.insert($0).inserted }.compactMap { id in live.first { $0.id == id } })
        for account in live where !shown.contains(account.id) { value.setVisible(account.id, false) }
        if let first = active.first(where: { !$0.accountIDs.isEmpty }) ?? active.first {
            value.setComponent(badge: first.showService, bar: first.showBars, percent: first.showPercent)
        }
        for (key, selection) in legacy.metrics {
            guard let id = UUID(uuidString: key) else { continue }
            value.update(id) {
                $0.bars = selection
                if !selection.contains("weekly"), let first = ["5h", "model:fable"].first(where: selection.contains) { $0.primary = first }
            }
        }
        // Items that held several accounts stay together as a group.
        var group = 0
        for item in active where item.accountIDs.count > 1 && group < Self.groupLimit {
            group += 1
            for id in item.accountIDs { value.update(id) { $0.group = group } }
            value.rowsPerColumn = min(6, max(1, item.maxRows))
        }
        value.layouts = legacy.items.enumerated().map { index, item in
            MenuBarLayout(id: item.id, name: String(localized: "Group \(index + 1)"), enabled: index < legacy.activeCount,
                style: .bars, showBadge: item.showService, showBar: item.showBars, showPercent: item.showPercent,
                rowsPerColumn: min(3, max(1, item.maxRows)), rows: item.accountIDs.flatMap { id -> [MenuBarLine] in
                    guard let account = live.first(where: { $0.id == id }) else { return [] }
                    let selection = legacy.metrics[id.uuidString] ?? (account.provider == .claude ? ["5h", "weekly", "model:fable"] : ["5h", "weekly"])
                    return orderedMetrics(selection).map { MenuBarLine(accountID: id, metricID: $0) }
                })
        }
        // Group visibility controls polling; parked accounts remain available when their group is enabled.
        for id in legacy.items.flatMap(\.accountIDs) { value.setVisible(id, true) }
        value.limitLayoutSizes()
        return value
    }
}

struct LegacyDisplayItem: Codable {
    var id = UUID()
    var accountIDs: [UUID] = []
    var showService = true
    var showBars = true
    var showPercent = true
    var maxRows = 2
}
struct LegacyDisplayConfiguration: Codable {
    var version = 1
    var activeCount = 2
    var items: [LegacyDisplayItem] = []
    var metrics: [String: Set<String>] = [:]
    var valid: Bool {
        let accounts = items.flatMap(\.accountIDs)
        return version == 1 && activeCount >= 1 && activeCount <= items.count
            && Set(items.map(\.id)).count == items.count && Set(accounts).count == accounts.count
            && items.allSatisfy { (1...6).contains($0.maxRows) }
    }
}

struct DisplayMetric: Identifiable {
    var id: String
    var title: String
    var window: WindowSummary?
    /// The Antigravity model group a limit belongs to, named in its titles.
    var group: String? = nil
    private var isFiveHour: Bool { id == "5h" || id.hasSuffix(":5h") }
    // Badge text for a limit's own line in the Multi Bar style.
    var shortLabel: String {
        switch id {
        case "5h": return "5H"
        case "weekly": return "WK"
        default: return String(title.prefix(3)).uppercased()
        }
    }
    /// The metric's name as the popover and Settings show it. `title` stays
    /// the English name the rest of the app reads.
    var localizedTitle: String {
        if let group { return isFiveHour ? String(localized: "\(group) 5-hour limit") : String(localized: "\(group) weekly limit") }
        switch id {
        case "5h": return String(localized: "5-Hour Session")
        case "weekly": return String(localized: "Weekly Limit")
        default: return String(localized: "\(modelName) Weekly")
        }
    }
    /// The name on a limit choice. Model limits say they are weekly.
    var choiceTitle: String {
        if let group { return isFiveHour ? String(localized: "\(group) 5 hours") : String(localized: "\(group) weekly") }
        switch id {
        case "5h": return String(localized: "5 hours")
        case "weekly": return String(localized: "Weekly")
        default: return String(localized: "\(modelName) weekly")
        }
    }
    /// The same name without the window, for rows too narrow for it.
    var compactChoiceTitle: String {
        if let group { return isFiveHour ? String(localized: "\(group) 5h") : String(localized: "\(group) wk") }
        switch id {
        case "5h", "weekly": return choiceTitle
        default: return modelName
        }
    }
    /// A model limit's model, from its title ("Fable Weekly") or, for a line
    /// whose data has not loaded, its id ("model:fable").
    private var modelName: String {
        if title.hasSuffix(" Weekly") { return String(title.dropLast(" Weekly".count)) }
        if id.hasPrefix("model:") { return String(id.dropFirst("model:".count)).capitalized }
        return title
    }
    static func all(_ snapshot: ProviderSnapshot) -> [Self] {
        // Antigravity: one 5-hour and one weekly limit per model group. The
        // first group keeps the plain ids, so the line a new account starts
        // with ("weekly") shows it; the rest are named by group.
        if let groups = snapshot.limitGroups, !groups.isEmpty {
            var result: [Self] = []
            for (index, group) in groups.enumerated() {
                var key: String?
                if index > 0 {
                    let slug = "group:" + group.label.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
                    key = result.contains { $0.id.hasPrefix(slug + ":") } ? slug + "-\(index)" : slug
                }
                if let fiveHour = group.fiveHour {
                    result.append(Self(id: key.map { $0 + ":5h" } ?? "5h", title: group.label + " 5-Hour", window: fiveHour, group: group.label))
                }
                if let weekly = group.weekly {
                    result.append(Self(id: key.map { $0 + ":weekly" } ?? "weekly", title: group.label + " Weekly", window: weekly, group: group.label))
                }
            }
            return result
        }
        var result = [Self(id: "5h", title: "5-Hour Session", window: snapshot.fiveHour), Self(id: "weekly", title: "Weekly Limit", window: snapshot.weekly)]
        for model in snapshot.displayedModelWeeklies {
            let key = "model:" + model.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !result.contains(where: { $0.id == key }) { result.append(Self(id: key, title: model.label + " Weekly", window: model.window)) }
        }
        return result
    }
    /// The lines a newly added account starts with: its weekly limit, and for
    /// Antigravity each model group's, since every group has its own limits.
    static func firstLines(_ snapshot: ProviderSnapshot?) -> [String] {
        guard let snapshot, let groups = snapshot.limitGroups, groups.count > 1 else { return ["weekly"] }
        let metrics = all(snapshot)
        let lines = groups.compactMap { group in
            (metrics.first { $0.group == group.label && $0.id.hasSuffix("weekly") } ?? metrics.first { $0.group == group.label })?.id
        }
        return Array((lines.isEmpty ? ["weekly"] : lines).prefix(MenuBarLayout.maximumLines))
    }
    // The menu bar draws the chosen metric, or another one while it has no data.
    static func menuBar(_ snapshot: ProviderSnapshot, preferred: String) -> Self {
        let metrics = all(snapshot)
        let chosen = metrics.first { $0.id == preferred }
        if chosen?.window?.utilization != nil { return chosen! }
        return metrics.first { $0.id != "model:fable" && $0.window?.utilization != nil } ?? chosen ?? metrics[0]
    }
}

struct MenuBarEntry: Identifiable {
    var account: UsageAccount
    var display: AccountDisplay
    var metric: DisplayMetric
    var metrics: [DisplayMetric] = []
    var stale: Bool
    var requiresLogin: Bool
    var showLimitLabel = true
    var badgeText: String? = nil
    var lineID: String? = nil
    var badgeLabel: String { badgeText ?? (display.badge + (showLimitLabel ? "·" + metric.shortLabel : "")) }
    var id: UUID { account.id }
    var percentage: String { TokenFormatters.percentageString(for: metric.window?.utilization) }
    // Every other selected limit with data, in card order, for the Multi Bar style.
    var secondary: [DisplayMetric] {
        metrics.filter { $0.id != metric.id && display.bars.contains($0.id) && $0.window?.utilization != nil }
    }
}
