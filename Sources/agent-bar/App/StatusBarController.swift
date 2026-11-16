import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusBarCoordinator {
    private var controllers: [UUID: StatusBarController] = [:]
    private let store: UsageStore
    private var subscriptions = Set<AnyCancellable>()
    private var lastGroupOrder: [UUID] = []
    private var forceReorder = false
    init(store: UsageStore, providers: [ProviderKind]) {
        self.store = store
        Publishers.CombineLatest3(store.$displayConfiguration, store.$snapshots, store.$registry)
            .receive(on: RunLoop.main).sink { [weak self] _, _, _ in self?.update() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.update() }.store(in: &subscriptions)
        update()
    }
    var physicalStatusItemCount: Int { controllers.count }
    func statusItemLength(for id: UUID) -> CGFloat? { controllers[id]?.width }
    func popoverAccountIDs(for id: UUID) -> [UUID]? { controllers[id]?.popoverAccountIDs }
    func popoverGroupID(for id: UUID) -> UUID? { controllers[id]?.popoverGroupID }
    func positionID(for id: UUID) -> UUID? { controllers[id]?.positionID }
    var groupOrderOnScreen: [UUID] { controllersFromLeftToRight().map(\.popoverGroupID) }
    func removeAll() { controllers.values.forEach { $0.remove() }; controllers.removeAll() }
    private func controllersFromLeftToRight() -> [StatusBarController] {
        let fallback = Dictionary(uniqueKeysWithValues: lastGroupOrder.enumerated().map { ($0.element, $0.offset) })
        return controllers.values.sorted { left, right in
            if let a = left.screenFrame, let b = right.screenFrame, a.width > 0, b.width > 0, abs(a.minX - b.minX) > 1 {
                return a.minX < b.minX
            }
            return (fallback[left.popoverGroupID] ?? Int.max) < (fallback[right.popoverGroupID] ?? Int.max)
        }
    }
    func moveFromMenuBar(_ source: UUID, to target: UUID) -> Bool {
        guard source != target, controllers[source] != nil, controllers[target] != nil else { return false }
        let actualOrder = controllersFromLeftToRight().map(\.popoverGroupID)
        let visibleIDs = Set(actualOrder)
        forceReorder = true
        store.updateDisplay { config in
            // Respect positions the user may previously have moved with macOS.
            config.editLayouts { groups in
                let byID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
                var order = actualOrder.makeIterator()
                for index in groups.indices where visibleIDs.contains(groups[index].id) {
                    if let id = order.next(), let group = byID[id] { groups[index] = group }
                }
            }
            config.moveLayout(source, to: target)
        }
        let changed = store.displayConfiguration.effectiveLayouts.map(\.id).filter(visibleIDs.contains) != actualOrder
        if changed { store.selectMenuBarGroup(source) }
        else { forceReorder = false }
        return changed
    }
    private func update() {
        let config = store.displayConfiguration
        let groups = config.effectiveLayouts.filter { $0.enabled && $0.showsAnything && ($0.rows.isEmpty || !store.entries(for: $0).isEmpty) }
        let keys = Set(groups.map(\.id))
        let nextOrder = groups.map(\.id)
        let reorder = keys == Set(lastGroupOrder) && (forceReorder || nextOrder != lastGroupOrder)
        forceReorder = false
        var positions: [UUID: UUID] = [:]
        if reorder {
            let slots = controllersFromLeftToRight()
            var reordered: [UUID: StatusBarController] = [:]
            for (group, controller) in zip(groups, slots) {
                controller.represent(group.id)
                reordered[group.id] = controller
                positions[group.id] = controller.positionID
            }
            controllers = reordered
        }
        lastGroupOrder = nextOrder
        for id in Array(controllers.keys) where !keys.contains(id) { controllers.removeValue(forKey: id)?.remove() }
        for group in groups.reversed() where controllers[group.id] == nil {
            controllers[group.id] = StatusBarController(key: group.id, store: store, positionID: group.statusItemPositionID,
                moveGroup: { [weak self] source, target in self?.moveFromMenuBar(source, to: target) ?? false })
        }
        for group in groups {
            controllers[group.id]?.apply(store.entries(for: group), config: group.renderingConfiguration(config), explicitRows: true, name: group.name,
                                         panel: store.panelAccountIDs(for: group))
        }
        if !positions.isEmpty {
            store.updateDisplay { config in
                config.editLayouts { layouts in
                    for index in layouts.indices {
                        if let position = positions[layouts[index].id] { layouts[index].statusItemPositionID = position }
                    }
                }
            }
        }
        let width = controllers.values.reduce(CGFloat(0)) { $0 + $1.width }
        let screenWidth = controllers.values.compactMap(\.screenWidth).first ?? NSScreen.main?.frame.width ?? 1440
        let warning = width > screenWidth * 0.4
        if store.displayWidthWarning != warning { store.displayWidthWarning = warning }
    }
}

@MainActor
final class StatusBarController {
    private let store: UsageStore
    private var groupID: UUID
    let positionID: UUID
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel: MenuBarPanel<GroupPanelRoot>
    private var dragSurface: BadgeDragSurface?
    var button: NSStatusBarButton? { statusItem.button }
    var width: CGFloat { statusItem.length }
    var accessibilityLabel: String? { statusItem.button?.accessibilityLabel() }
    var popoverAccountIDs: [UUID] { panel.rootView.accountIDs }
    var popoverGroupID: UUID { panel.rootView.groupID }
    var screenWidth: CGFloat? { statusItem.button?.window?.screen?.frame.width }
    var screenFrame: NSRect? { statusItem.button?.window?.frame }
    init(key: UUID, store: UsageStore, positionID: UUID? = nil, moveGroup: ((UUID, UUID) -> Bool)? = nil) {
        self.store = store
        groupID = key
        self.positionID = positionID ?? key
        panel = MenuBarPanel(rootView: GroupPanelRoot(accountIDs: [], groupID: key, store: store))
        // A Claude Code result line is cleared once a panel that showed its account closes.
        panel.onClose = { [weak self] in
            guard let self else { return }
            self.store.claudeCodePanelDidClose(group: self.groupID)
        }
        statusItem.autosaveName = "account-" + self.positionID.uuidString
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggle(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.imageScaling = .scaleNone
        if let button = statusItem.button {
            let surface = BadgeDragSurface(groupID: key, frame: button.bounds)
            surface.onClick = { [weak self] in self?.toggle(nil) }
            surface.onDrag = { [weak self] in self?.panel.close() }
            surface.acceptsGroup = { [weak store] id in store?.displayConfiguration.effectiveLayouts.contains { $0.id == id } == true }
            surface.onDropGroup = moveGroup ?? { [weak store] source, target in store?.moveMenuBarGroup(source, to: target) ?? false }
            button.addSubview(surface)
            dragSurface = surface
        }
    }
    func represent(_ id: UUID) {
        guard groupID != id else { return }
        panel.close()
        groupID = id
        dragSurface?.groupID = id
        panel.rootView = GroupPanelRoot(accountIDs: [], groupID: id, store: store)
    }
    // `listed` is the accounts the group's panel lists (`UsageStore.panelAccountIDs(for:)`). Without it the panel lists
    // the accounts the lines draw.
    func apply(_ entries: [MenuBarEntry], config: DisplayConfiguration, explicitRows: Bool = false, name: String = String(localized: "Group"),
               panel listed: [UUID]? = nil) {
        // The picture follows whatever appearance draws it, so a menu bar that turns light or dark, and the copies on
        // other screens' menu bars, need no new picture.
        let image = DisplayStatusRenderer.adaptiveImage(entries: entries, config: config,
            height: max(18, NSStatusBar.system.thickness - 2), scale: statusItem.button?.window?.backingScaleFactor ?? 2, explicitRows: explicitRows)
        statusItem.length = image.size.width
        statusItem.button?.image = image
        dragSurface?.badgeImage = image
        let shown = listed ?? MenuBarLayout.unique(entries.map(\.account.id))
        // An item without lines says what a click opens: the group's list, named as its header names it, or, listing no
        // account, Settings to add a line.
        let empty = shown.isEmpty ? String(localized: "\(name) · Click to add a usage line") : name + " · " + GroupListWords.accounts(shown.count)
        let description = entries.isEmpty ? empty : entries.map {
            "\(store.accountLabel(for: $0.account)) · \($0.metric.localizedTitle): \($0.percentage)" + ($0.stale ? " " + String(localized: "(cached)") : "")
        }.joined(separator: "\n")
        let common = config.commonBadgeText.flatMap { $0.isEmpty ? nil : $0 }
        let accessibleDescription = common.map { $0 + "\n" + description } ?? description
        statusItem.button?.toolTip = accessibleDescription
        dragSurface?.toolTip = accessibleDescription
        statusItem.button?.setAccessibilityLabel(accessibleDescription)
        if panel.rootView.accountIDs != shown {
            panel.rootView = GroupPanelRoot(accountIDs: shown, groupID: groupID, store: store, openings: panel.rootView.openings)
        }
    }
    func remove() { panel.close(); NSStatusBar.system.removeStatusItem(statusItem) }
    @objc private func toggle(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        store.selectMenuBarGroup(groupID)
        // Nothing to list: a group without accounts. One with accounts but no lines has no entries and still opens its list.
        if panel.rootView.accountIDs.isEmpty { SettingsWindowController.shared.show(tab: .menuBar, groupID: groupID); return }
        // The panel sizes itself to its content.
        if panel.isShown { panel.close() } else {
            // The login Claude Code uses may have been changed in a terminal since it was last read.
            store.claudeCodePanelWillOpen(group: groupID)
            // A sorted list puts its rows in order afresh, by the numbers there are now.
            panel.rootView.openings += 1
            panel.show(below: button)
        }
    }
}

// A group's panel: its accounts on one list, even a single one.
struct GroupPanelRoot: View {
    let accountIDs: [UUID]
    let groupID: UUID
    let store: UsageStore
    // How many times the panel has opened.
    var openings = 0
    var body: some View {
        GroupAccountListView(accountIDs: accountIDs, groupID: groupID, openings: openings).environmentObject(store)
    }
}

// Draws accounts inside a dark capsule. The style decides how each gauge is
// drawn; the capsule, badge colors and stale dimming are shared. Compact mode
// stacks one account per row and flows extra rows into further columns.
@MainActor
enum DisplayStatusRenderer {
    static let barWidth: CGFloat = 28
    static let gap: CGFloat = 4
    static let inset: CGFloat = 4
    static let columnGap: CGFloat = 7
    static let alertThreshold = 0.9
    static let alertColor = NSColor(red: 0.98, green: 0.45, blue: 0.42, alpha: 1)

    static let maxBars = 3
    // A drawn line: one account and one of its limits. Multi Bar gives an
    // account up to `maxBars` lines, each labelled by its limit; other styles one.
    struct Row {
        var entry: MenuBarEntry
        var metric: DisplayMetric
        var label: String
        var percentage: String { TokenFormatters.percentageString(for: metric.window?.utilization) }
    }
    static func rows(_ entry: MenuBarEntry, config: DisplayConfiguration) -> [Row] {
        guard config.style == .bars else { return [Row(entry: entry, metric: entry.metric, label: entry.display.badge)] }
        let extra = entry.secondary.prefix(maxBars - 1)
        // Account first, limit second, so two providers never read alike.
        return ([entry.metric] + extra).map { Row(entry: entry, metric: $0, label: entry.display.badge + "·" + $0.shortLabel) }
    }

    static func render(entry: MenuBarEntry, config: DisplayConfiguration, height: CGFloat = 22, scale: CGFloat = 2) -> NSImage {
        render(entries: [entry], config: config, height: height, scale: scale)
    }
    // The status item's picture, drawn for the appearance that draws it. A wallpaper or theme change flips the menu bar
    // between light and dark, and with a menu bar on each screen AppKit draws the copies on the other screens by giving
    // the button each screen's appearance in turn. Drawing whatever appearance is current serves all of them without
    // watching the button: drawing the picture again from such a watch made AppKit copy it to the screens again, which
    // changed the appearance again, and the item redrew without end (one core at 100% with several screens).
    static func adaptiveImage(entries: [MenuBarEntry], config: DisplayConfiguration, height: CGFloat, scale: CGFloat,
                              explicitRows: Bool) -> NSImage {
        let current = NSAppearance.currentDrawing()
        let first = render(entries: entries, config: config, height: height, scale: scale, explicitRows: explicitRows, appearance: current)
        var drawn: [NSAppearance.Name: NSImage] = [current.name: first]
        func picture(for appearance: NSAppearance) -> NSImage {
            if let picture = drawn[appearance.name] { return picture }
            let picture = render(entries: entries, config: config, height: height, scale: scale, explicitRows: explicitRows, appearance: appearance)
            drawn[appearance.name] = picture
            return picture
        }
        // Light and dark pictures have the same size.
        let image = NSImage(size: first.size, flipped: false) { rect in
            if Thread.isMainThread {
                MainActor.assumeIsolated { picture(for: NSAppearance.currentDrawing()).draw(in: rect) }
            } else {
                first.draw(in: rect)
            }
            return true
        }
        // Drawn afresh each time, so a cached picture never shows one screen's appearance on another.
        image.cacheMode = .never
        return image
    }
    static func render(entries: [MenuBarEntry], config: DisplayConfiguration, height: CGFloat = 22, scale: CGFloat = 2, explicitRows: Bool = false,
                       appearance: NSAppearance? = nil) -> NSImage {
        let visibleEntries = config.style == .text ? entries[...] : entries.prefix(MenuBarLayout.maximumLines)
        let allRows = explicitRows ? visibleEntries.map { Row(entry: $0, metric: $0.metric, label: $0.badgeLabel) } : entries.flatMap { rows($0, config: config) }
        // A single account keeps its lines in one column; a grouped item wraps at the configured row count.
        let perColumn = explicitRows || config.style == .text ? max(1, allRows.count) : (entries.count > 1 ? max(1, config.rowsPerColumn) : max(1, allRows.count))
        let columns = stride(from: 0, to: allRows.count, by: perColumn).map { Array(allRows[$0..<min(allRows.count, $0 + perColumn)]) }
        let rowCount = max(1, min(perColumn, allRows.count))
        let pitch = (height - 2) / CGFloat(rowCount)
        let metrics = Metrics(pitch: pitch)
        // Parts of the same index line up within a column, like a table.
        let laidOut: [[[Part]]] = columns.map { $0.map { layout(row: $0, config: config, metrics: metrics) } }
        let columnWidths: [[CGFloat]] = laidOut.map { rows in
            let count = rows.map(\.count).max() ?? 0
            return (0..<count).map { index in rows.compactMap { $0.indices.contains(index) ? $0[index].width : nil }.max() ?? 0 }
        }
        let columnTotals = columnWidths.map { $0.reduce(0, +) + CGFloat(max(0, $0.count - 1)) * gap }
        let rowContent = columnTotals.reduce(0, +) + CGFloat(max(0, columns.count - 1)) * columnGap
        let representativeRow: Row? = if config.style.selection == .bars && config.showPercent {
            config.percentageLineID.flatMap { selected in allRows.first { $0.entry.lineID == selected } } ?? allRows.first
        } else { nil }
        let representativeFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        let percentageRows = config.style == .text ? allRows : representativeRow.map { [$0] } ?? []
        let gaugeWidth: CGFloat = config.style == .text ? gaugeSize + 2 : 0
        let percentageWidths = percentageRows.map { gaugeWidth + Self.width($0.percentage, representativeFont) }
        let percentageContent = percentageWidths.reduce(0, +) + CGFloat(max(0, percentageWidths.count - 1)) * gap
        let percentageGap: CGFloat = percentageContent > 0 && rowContent > 0 ? gap : 0
        let content = rowContent + percentageGap + percentageContent
        let commonText = config.commonBadgeText ?? ""
        let commonFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
        // The group label is plain menu bar text, like a native status item title.
        let commonWidth = commonText.isEmpty ? 0 : Self.width(commonText, commonFont)
        let commonGap: CGFloat = commonWidth > 0 && content > 0 ? gap : 0
        let width = ceil(inset * 2 + (commonWidth > 0 ? commonWidth + commonGap + content : max(content, 10)))
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(width * scale)), pixelsHigh: Int(ceil(height * scale)), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        // Text and tracks resolve against the menu bar's light or dark appearance.
        (appearance ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
        if allRows.isEmpty && commonWidth == 0 {
            text("+", font: .systemFont(ofSize: 12, weight: .bold), color: .labelColor,
                 in: NSRect(x: 0, y: 0, width: width, height: height), align: .center)
        }
        if commonWidth > 0 {
            text(commonText, font: commonFont, color: .labelColor,
                 in: NSRect(x: inset, y: 0, width: commonWidth, height: height))
        }
        var columnX = inset + commonWidth + commonGap
        for (column, rows) in laidOut.enumerated() {
            for (row, parts) in rows.enumerated() {
                let center = height - 1 - (CGFloat(row) + 0.5) * pitch
                var x = columnX
                for (index, part) in parts.enumerated() {
                    let partWidth = columnWidths[column][index]
                    part.draw(NSRect(x: x, y: center - pitch / 2, width: partWidth, height: pitch), scale)
                    x += partWidth + gap
                }
            }
            columnX += columnTotals[column] + columnGap
        }
        var percentageX = inset + commonWidth + commonGap + rowContent + percentageGap
        for (index, row) in percentageRows.enumerated() {
            let color = foreground(stale: row.entry.stale)
            if gaugeWidth > 0 {
                drawGauge(for: row.metric.window?.utilization, color: color,
                          in: NSRect(x: percentageX, y: (height - gaugeSize) / 2, width: gaugeSize, height: gaugeSize))
            }
            text(row.percentage, font: representativeFont, color: color,
                 in: NSRect(x: percentageX + gaugeWidth, y: 0, width: percentageWidths[index] - gaugeWidth, height: height))
            percentageX += percentageWidths[index] + gap
        }
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: width, height: height)); image.addRepresentation(bitmap)
        return image
    }

    // Sizes shrink with the row pitch so stacked rows stay inside the capsule.
    private struct Metrics {
        let pitch: CGFloat
        var badgeFont: NSFont { .monospacedDigitSystemFont(ofSize: min(9, pitch * 0.55), weight: .bold) }
        var percentFont: NSFont { .monospacedDigitSystemFont(ofSize: min(11, pitch * 0.78), weight: .bold) }
        var badgeHeight: CGFloat { min(14, pitch * 0.88) }
        var barThickness: CGFloat { min(5, pitch * 0.45) }
        var ringDiameter: CGFloat { min(20, pitch) }
        var capsuleHeight: CGFloat { min(16, pitch - 1) }
    }
    private struct Part {
        var width: CGFloat
        var draw: (NSRect, CGFloat) -> Void
    }
    private static func text(_ string: String, font: NSFont, color: NSColor, in rect: NSRect, align: NSTextAlignment = .left) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (string as NSString).size(withAttributes: attributes)
        let x = align == .center ? rect.midX - size.width / 2 : (align == .right ? rect.maxX - size.width : rect.minX)
        (string as NSString).draw(at: NSPoint(x: x, y: rect.midY - size.height / 2), withAttributes: attributes)
    }
    private static var isDarkDrawing: Bool {
        NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
    private static func foreground(stale: Bool) -> NSColor {
        stale ? .secondaryLabelColor : .labelColor
    }
    static let gaugeSize: CGFloat = 13
    // The fork's five-step gauge in front of each Text Only percentage.
    static func gaugeSymbolName(for utilization: Double?) -> String {
        let pct = (utilization ?? 0) * 100
        switch pct {
        case ..<20: return "gauge.with.dots.needle.0percent"
        case ..<40: return "gauge.with.dots.needle.33percent"
        case ..<60: return "gauge.with.dots.needle.50percent"
        case ..<80: return "gauge.with.dots.needle.67percent"
        default: return "gauge.with.dots.needle.100percent"
        }
    }
    private static func drawGauge(for utilization: Double?, color: NSColor, in rect: NSRect) {
        let configuration = NSImage.SymbolConfiguration(pointSize: rect.height - 1, weight: .regular)
            .applying(.init(paletteColors: [color]))
        guard let symbol = NSImage(systemSymbolName: gaugeSymbolName(for: utilization), accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        let size = symbol.size
        let scale = min(rect.width / size.width, rect.height / size.height)
        let drawn = NSSize(width: size.width * scale, height: size.height * scale)
        symbol.draw(in: NSRect(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2, width: drawn.width, height: drawn.height))
    }
    private static func width(_ string: String, _ font: NSFont) -> CGFloat {
        ceil((string as NSString).size(withAttributes: [.font: font]).width)
    }
    private static func fillColor(_ row: Row) -> NSColor {
        let value = row.metric.window?.utilization ?? 0
        // Pastel bar colors are made for dark menu bars; light ones need the deeper tone.
        let accent = isDarkDrawing ? row.entry.display.color.barColor : row.entry.display.color.nsColor
        let base = value >= alertThreshold ? alertColor : accent
        return base.withAlphaComponent(row.entry.stale ? 0.55 : 1)
    }
    static func showsPercentage(for entry: MenuBarEntry, config: DisplayConfiguration) -> Bool {
        guard config.showPercent else { return false }
        guard config.style == .badge || config.style == .bars,
              let selected = config.percentageLineID else { return true }
        return entry.lineID == selected
    }
    private static func snapped(_ value: CGFloat, _ scale: CGFloat) -> CGFloat { (value * scale).rounded() / scale }

    private static func layout(row: Row, config: DisplayConfiguration, metrics m: Metrics) -> [Part] {
        let entry = row.entry
        let badge = row.label
        let percent = row.percentage
        let badgeColor = entry.display.color.nsColor.withAlphaComponent(entry.stale ? 0.7 : 1)
        let percentColor = foreground(stale: entry.stale)
        let value = CGFloat(min(1, max(0, row.metric.window?.utilization ?? 0)))
        let badgePart = Part(width: width(badge, m.badgeFont) + 8) { rect, _ in
            badgeColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.midY - m.badgeHeight / 2, width: rect.width, height: m.badgeHeight), xRadius: min(4, m.badgeHeight / 3), yRadius: min(4, m.badgeHeight / 3)).fill()
            text(badge, font: m.badgeFont, color: .white, in: rect, align: .center)
        }
        let percentPart = Part(width: width(percent, m.percentFont)) { rect, _ in
            text(percent, font: m.percentFont, color: percentColor, in: rect)
        }
        func bar(_ utilization: Double?, thickness: CGFloat, y: CGFloat, color: NSColor, in rect: NSRect, scale: CGFloat) {
            let h = max(1, snapped(thickness, scale)), barY = snapped(y - h / 2, scale)
            NSColor.labelColor.withAlphaComponent(0.22).setFill()
            NSBezierPath(roundedRect: NSRect(x: rect.minX, y: barY, width: barWidth, height: h), xRadius: h / 2, yRadius: h / 2).fill()
            color.setFill()
            let fill = CGFloat(min(1, max(0, utilization ?? 0)))
            NSBezierPath(roundedRect: NSRect(x: rect.minX, y: barY, width: barWidth * fill, height: h), xRadius: h / 2, yRadius: h / 2).fill()
        }
        switch config.style {
        case .badge, .bars:
            // Multi Bar is this same line repeated once per limit, so every bar is equal.
            var parts: [Part] = []
            if config.showBadge && !badge.isEmpty { parts.append(badgePart) }
            if config.showBar {
                parts.append(Part(width: barWidth) { rect, scale in
                    bar(row.metric.window?.utilization, thickness: m.barThickness, y: rect.midY, color: fillColor(row), in: rect, scale: scale)
                })
            }
            return parts
        case .ring:
            let diameter = m.ringDiameter
            let ring = Part(width: diameter) { rect, _ in
                let line: CGFloat = diameter < 12 ? 1.5 : 2.75
                let circle = NSRect(x: rect.minX + line / 2, y: rect.midY - diameter / 2 + line / 2, width: diameter - line, height: diameter - line)
                let track = NSBezierPath(ovalIn: circle); track.lineWidth = line
                NSColor.labelColor.withAlphaComponent(0.25).setStroke(); track.stroke()
                if value > 0 {
                    let arc = NSBezierPath(); arc.lineWidth = line; arc.lineCapStyle = .round
                    arc.appendArc(withCenter: NSPoint(x: circle.midX, y: circle.midY), radius: circle.width / 2, startAngle: 90, endAngle: 90 - 360 * value, clockwise: true)
                    fillColor(row).setStroke(); arc.stroke()
                }
            }
            var parts = config.showBadge && !badge.isEmpty ? [badgePart, ring] : [ring]
            if config.showPercent { parts.append(percentPart) }
            return parts
        case .capsule:
            let pillFont = m.badgeFont
            let visibleBadge = config.showBadge ? badge : ""
            let pad: CGFloat = 8
            let pillWidth = barWidth
            return [Part(width: pillWidth) { rect, _ in
                let pillHeight = m.capsuleHeight
                let pill = NSRect(x: rect.minX, y: rect.midY - pillHeight / 2, width: rect.width, height: pillHeight)
                let path = NSBezierPath(roundedRect: pill, xRadius: pillHeight / 2, yRadius: pillHeight / 2)
                // A self-contained dark pill keeps the white label readable on any menu bar.
                NSColor(calibratedWhite: 0.14, alpha: 0.65).setFill(); path.fill()
                NSGraphicsContext.saveGraphicsState(); path.addClip()
                let fill = value >= alertThreshold ? NSColor(red: 0.80, green: 0.30, blue: 0.28, alpha: 1) : entry.display.color.nsColor
                fill.withAlphaComponent(entry.stale ? 0.55 : 0.95).setFill()
                NSRect(x: pill.minX, y: pill.minY, width: pill.width * value, height: pill.height).fill()
                NSGraphicsContext.restoreGraphicsState()
                text(visibleBadge, font: pillFont, color: .white, in: pill.insetBy(dx: pad, dy: 0))
                text(percent, font: pillFont, color: .white.withAlphaComponent(0.92), in: pill.insetBy(dx: pad, dy: 0),
                     align: visibleBadge.isEmpty ? .center : .right)
            }]
        case .text:
            // The selected row's full-size percentage is drawn once outside the row grid.
            return []
        }
    }
}
