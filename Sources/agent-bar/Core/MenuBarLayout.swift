import Foundation

struct MenuBarLine: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var accountID: UUID
    var metricID: String
    var slot: Int? = nil
    var badgeText: String? = nil
    var showLimitLabel: Bool? = nil
    var includesLimitLabel: Bool { showLimitLabel ?? true }
}

enum BadgeDisplayMode: String, Codable, CaseIterable, Identifiable {
    case none, common, individual, both
    static let selectableCases: [Self] = [.none, .common]
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "None"
        case .common: return "Common"
        case .individual: return "Individual"
        case .both: return "Both"
        }
    }
    var includesCommon: Bool { self == .common || self == .both }
    var includesIndividual: Bool { self == .individual || self == .both }
    var withoutIndividual: Self { includesCommon ? .common : .none }
}

struct MenuBarLayout: Codable, Equatable, Identifiable {
    static let maximumLines = 3
    var id = UUID()
    var name = "Group"
    var enabled = true
    var style: MenuBarStyle = .bars
    var showBadge = true // Legacy visibility; used only until a badge mode is chosen.
    var badgeMode: BadgeDisplayMode? = nil
    var commonBadgeText: String? = nil
    var commonBadgeColor: AccountColor? = nil
    // Individual/both remain decodable so existing settings migrate without
    // failing. Tiny per-line badges are no longer rendered; both becomes common.
    var effectiveBadgeMode: BadgeDisplayMode { (badgeMode ?? .none).withoutIndividual }
    var commonBadgeLabel: String { commonBadgeText ?? name }
    var showBar = true
    var showPercent = true
    var percentageLineID: String? = nil
    var rowsPerColumn = 3
    var rows: [MenuBarLine] = []
    // The native menu bar slot is independent of which group is displayed in it.
    // Reordering groups reuses these slots, preserving other apps' positions.
    var statusItemPositionID: UUID? = nil
    var displayedRows: [MenuBarLine] {
        let ordered = rows.enumerated().sorted {
            ($0.element.slot ?? $0.offset) < ($1.element.slot ?? $1.offset)
        }.map(\.element)
        if style == .ring { return Array(ordered.prefix(1)) }
        if style == .text { return ordered }
        return Array(ordered.prefix(Self.maximumLines))
    }
    var effectivePercentageLineID: String? {
        if let percentageLineID, displayedRows.contains(where: { $0.id == percentageLineID }) {
            return percentageLineID
        }
        return displayedRows.first?.id
    }
    var showsAnything: Bool { (style.selection == .bars && !displayedRows.isEmpty) || style == .capsule || style == .ring || style == .text || (effectiveBadgeMode.includesCommon && !commonBadgeLabel.isEmpty) || showPercent }
    var valid: Bool {
        (style == .text || rows.count <= Self.maximumLines) && (1...3).contains(rowsPerColumn) && Set(rows.map(\.id)).count == rows.count
            && rows.allSatisfy { !$0.metricID.isEmpty }
            && rows.enumerated().allSatisfy {
                let slot = $0.element.slot ?? $0.offset
                return style == .text ? slot >= 0 : (0..<Self.maximumLines).contains(slot)
            }
            && Set(rows.enumerated().map { $0.element.slot ?? $0.offset }).count == rows.count
    }
    mutating func compactLineSlots() {
        rows = rows.enumerated().sorted { left, right in
            let leftSlot = left.element.slot ?? left.offset
            let rightSlot = right.element.slot ?? right.offset
            return leftSlot == rightSlot ? left.offset < right.offset : leftSlot < rightSlot
        }.map(\.element)
        for index in rows.indices { rows[index].slot = index }
    }
    mutating func moveLine(_ id: String, offset: Int) {
        if style == .text { compactLineSlots() }
        for i in rows.indices where rows[i].slot == nil { rows[i].slot = i }
        guard let i = rows.firstIndex(where: { $0.id == id }), let source = rows[i].slot else { return }
        let target = source + offset
        let upperBound = style == .text ? rows.count : Self.maximumLines
        guard (0..<upperBound).contains(target) else { return }
        if let other = rows.firstIndex(where: { $0.slot == target }) { rows[other].slot = source }
        rows[i].slot = target
        rows.sort { ($0.slot ?? 0) < ($1.slot ?? 0) }
    }
    func renderingConfiguration(_ base: DisplayConfiguration) -> DisplayConfiguration {
        var value = base
        value.style = style
        value.showBadge = false
        value.commonBadgeText = effectiveBadgeMode.includesCommon ? commonBadgeLabel : nil
        value.commonBadgeColor = commonBadgeColor ?? .blue
        value.showBar = style.selection == .bars ? true : showBar
        value.showPercent = style == .text ? true : showPercent
        value.percentageLineID = style == .bars || style == .text ? effectivePercentageLineID : nil
        value.rowsPerColumn = rowsPerColumn
        return value
    }
}

extension DisplayConfiguration {
    mutating func normalizeTextLineSlots() {
        guard layouts != nil else { return }
        for index in layouts!.indices where layouts![index].style == .text {
            layouts![index].compactLineSlots()
        }
    }
    static func orderedMetrics(_ values: Set<String>) -> [String] {
        let standard = ["5h", "weekly", "model:fable"]
        return standard.filter(values.contains) + values.filter { !standard.contains($0) }.sorted()
    }
    // Old v2 preferences remain readable. Materialize only when the user edits a layout.
    var effectiveLayouts: [MenuBarLayout] {
        if let layouts { return layouts }
        var result: [MenuBarLayout] = []
        for id in order {
            guard let display = accounts[id.uuidString] else { continue }
            let key = display.group > 0 ? Self.groupKey(display.group) : id
            var metrics = [display.primary]
            if style == .bars { metrics += Self.orderedMetrics(display.bars.subtracting([display.primary])) }
            let lines = metrics.map { MenuBarLine(id: id.uuidString + ":" + $0, accountID: id, metricID: $0) }
            if let index = result.firstIndex(where: { $0.id == key }) { result[index].rows += lines }
            else {
                result.append(MenuBarLayout(id: key, name: display.group > 0 ? "Group \(display.group)" : display.badge,
                    style: style, showBadge: showBadge, showBar: showBar, showPercent: showPercent,
                    rowsPerColumn: min(3, max(1, rowsPerColumn)), rows: lines))
            }
        }
        return result
    }
    // Keep old excess selections as hidden groups, never as extra visible columns.
    mutating func limitLayoutSizes() {
        let groups = effectiveLayouts
        guard groups.contains(where: { $0.rows.count > MenuBarLayout.maximumLines }) else { return }
        var result: [MenuBarLayout] = []
        for var group in groups {
            if group.style == .text { result.append(group); continue }
            let excess = Array(group.rows.dropFirst(MenuBarLayout.maximumLines))
            group.rows = Array(group.rows.prefix(MenuBarLayout.maximumLines))
            result.append(group)
            for start in stride(from: 0, to: excess.count, by: MenuBarLayout.maximumLines) {
                var saved = group
                saved.id = UUID(); saved.name += " · saved lines"; saved.enabled = false
                saved.statusItemPositionID = nil
                saved.rows = Array(excess[start..<min(start + MenuBarLayout.maximumLines, excess.count)])
                result.append(saved)
            }
        }
        layouts = result
    }
    mutating func freezeBadgeLabels() {
        var groups = effectiveLayouts
        for i in groups.indices {
            for j in groups[i].rows.indices where groups[i].rows[j].badgeText == nil {
                let line = groups[i].rows[j]
                guard let appearance = accounts[line.accountID.uuidString] else { continue }
                let metric = DisplayMetric(id: line.metricID, title: line.metricID.replacingOccurrences(of: "model:", with: "").capitalized, window: nil)
                groups[i].rows[j].badgeText = appearance.badge + (line.includesLimitLabel ? "·" + metric.shortLabel : "")
            }
        }
        layouts = groups
    }
    mutating func editLayouts(_ change: (inout [MenuBarLayout]) -> Void) {
        var groups = effectiveLayouts
        let textGroupIDs = Set(groups.filter { $0.style == .text }.map(\.id))
        change(&groups)
        guard groups.allSatisfy({ $0.style == .text || $0.rows.count <= MenuBarLayout.maximumLines }) else { return }
        // Text Only has a contiguous list, unlike the fixed slots in other
        // styles. Compact on edits and when leaving Text Only, preserving IDs
        // and visible order so a former fourth/fifth row can occupy a fixed slot.
        for index in groups.indices where groups[index].style == .text || textGroupIDs.contains(groups[index].id) {
            groups[index].compactLineSlots()
        }
        layouts = groups
    }
    mutating func editLayout(_ id: UUID, _ change: (inout MenuBarLayout) -> Void) {
        editLayouts { groups in
            guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
            for row in groups[index].rows.indices where groups[index].rows[row].slot == nil {
                groups[index].rows[row].slot = row
            }
            change(&groups[index])
        }
    }
    mutating func moveLayout(_ id: UUID, to targetID: UUID) {
        guard id != targetID else { return }
        editLayouts { groups in
            guard let source = groups.firstIndex(where: { $0.id == id }),
                  let target = groups.firstIndex(where: { $0.id == targetID }) else { return }
            let moved = groups.remove(at: source)
            groups.insert(moved, at: target)
        }
    }
}

extension UsageStore {
    func entries(for layout: MenuBarLayout) -> [MenuBarEntry] {
        layout.displayedRows.compactMap { line in
            guard displayConfiguration.isVisible(line.accountID), var entry = menuBarEntry(for: line.accountID) else { return nil }
            // Keep the selected limit even when unavailable. Never silently substitute another limit.
            entry.badgeText = line.badgeText
            entry.lineID = line.id
            entry.showLimitLabel = line.includesLimitLabel
            entry.metric = entry.metrics.first { $0.id == line.metricID }
                ?? DisplayMetric(id: line.metricID, title: line.metricID.hasPrefix("model:") ? String(line.metricID.dropFirst(6)).capitalized + " Weekly" : line.metricID, window: nil)
            return entry
        }
    }
}
