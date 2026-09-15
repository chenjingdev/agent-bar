import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusBarCoordinator {
    private var controllers: [UUID: StatusBarController] = [:]
    private let store: UsageStore
    private var subscriptions = Set<AnyCancellable>()
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
    func popoverItemID(for id: UUID) -> UUID? { controllers[id]?.popoverItemID }
    func removeAll() { controllers.values.forEach { $0.remove() }; controllers.removeAll() }
    private func update() {
        let items = store.displayConfiguration.activeItems
        let ids = Set(items.map(\.id))
        for id in Array(controllers.keys) where !ids.contains(id) { controllers.removeValue(forKey: id)?.remove() }
        for (index, item) in items.enumerated() {
            if controllers[item.id] == nil { controllers[item.id] = StatusBarController(itemID: item.id, store: store) }
            controllers[item.id]?.apply(item, number: index + 1)
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
    private let itemID: UUID
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    var width: CGFloat { statusItem.length }
    var accessibilityLabel: String? { statusItem.button?.accessibilityLabel() }
    var popoverItemID: UUID? { (popover.contentViewController as? NSHostingController<DisplayPopoverRoot>)?.rootView.itemID }
    var screenWidth: CGFloat? { statusItem.button?.window?.screen?.frame.width }
    init(itemID: UUID, store: UsageStore) {
        self.store = store; self.itemID = itemID
        statusItem.autosaveName = "display-" + itemID.uuidString
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggle(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.imageScaling = .scaleNone
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: DisplayPopoverRoot(itemID: itemID, store: store))
    }
    func apply(_ item: DisplayItem, number: Int) {
        let rows = store.displayRows(item)
        let image = DisplayStatusRenderer.render(item: item, rows: rows, number: number,
            height: max(18, NSStatusBar.system.thickness - 2), scale: statusItem.button?.window?.backingScaleFactor ?? 2)
        statusItem.length = image.size.width
        statusItem.button?.image = image
        let description = rows.map { "\($0.account.title) · \($0.metric.title): \(TokenFormatters.percentageString(for: $0.metric.window?.utilization))\($0.stale ? " (cached)" : "")" }.joined(separator: "\n")
        statusItem.button?.toolTip = description.isEmpty ? "Item \(number) · Choose accounts and limits" : description
        statusItem.button?.setAccessibilityLabel("Item \(number) · " + description)
    }
    func remove() { popover.close(); NSStatusBar.system.removeStatusItem(statusItem) }
    @objc private func toggle(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        if popover.isShown { popover.performClose(sender) }
        else {
            let height = min(CGFloat(568), max(240, (button.window?.screen?.visibleFrame.height ?? 768) - 40))
            popover.contentSize = NSSize(width: 392, height: height)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

private struct DisplayPopoverRoot: View {
    let itemID: UUID
    let store: UsageStore
    var body: some View { DisplayPopoverView(itemID: itemID).environmentObject(store) }
}

@MainActor
enum DisplayStatusRenderer {
    static func badgeStarts(_ columns: [[DisplayRow]]) -> [[Int]] {
        var seen = Set<UUID>()
        return columns.map { values in
            values.indices.filter { seen.insert(values[$0].account.id).inserted }
        }
    }
    static func render(item: DisplayItem, rows: [DisplayRow], number: Int, height: CGFloat = 22, scale: CGFloat = 2) -> NSImage {
        let originalColumns = DisplayRow.columns(rows, maximum: item.maxRows)
        let originalStarts = badgeStarts(originalColumns)
        // Badge-only display must not reserve columns containing only an account continuation.
        let visibleColumns = originalColumns.indices.filter {
            item.showBars || item.showPercent || !originalStarts[$0].isEmpty
        }
        let columns = visibleColumns.map { originalColumns[$0] }
        let starts = visibleColumns.map { originalStarts[$0] }
        let empty = rows.isEmpty || (!item.showService && !item.showBars && !item.showPercent)
        let rowCount = max(1, min(item.maxRows, rows.count))
        let pitch = (height - 2) / CGFloat(rowCount)
        let font = min(CGFloat(11), pitch * 0.78)
        let badgeFont = min(CGFloat(8), font)
        let badgeWidths: [CGFloat] = columns.enumerated().map { column, values in
            guard item.showService, !starts[column].isEmpty else { return 0 }
            return ceil(starts[column].map { index in
                (values[index].badge as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: badgeFont, weight: .bold)]).width
            }.max() ?? 0) + 4
        }
        let percentageWidths: [CGFloat] = columns.map { values in
            guard item.showPercent else { return 0 }
            return ceil(values.map {
                (TokenFormatters.percentageString(for: $0.metric.window?.utilization) as NSString)
                    .size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: font, weight: .bold)]).width
            }.max() ?? 0)
        }
        let columnWidths: [CGFloat] = columns.indices.map { index in
            let widths: [CGFloat] = [badgeWidths[index], item.showBars ? 28 : 0, percentageWidths[index]].filter { $0 > 0 }
            return widths.reduce(0, +) + CGFloat(max(0, widths.count - 1)) * 3
        }
        let placeholder = "AB · \(number)"
        let placeholderWidth = (placeholder as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold)]).width
        let width: CGFloat = ceil(6 + (empty ? placeholderWidth : columnWidths.reduce(0, +) + CGFloat(max(0, columns.count - 1)) * 7))
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(width * scale)), pixelsHigh: Int(ceil(height * scale)), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor(calibratedWhite: 0.14, alpha: 0.65).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: height), xRadius: height / 2, yRadius: height / 2).fill()
        func draw(_ text: String, x: CGFloat, center: CGFloat, font: CGFloat, color: NSColor) {
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: font, weight: .bold), .foregroundColor: color]
            let size = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(at: NSPoint(x: x, y: center - size.height / 2), withAttributes: attributes)
        }
        if empty { draw(placeholder, x: 3, center: height / 2, font: 10, color: .white) }
        else {
            for (column, values) in columns.enumerated() {
                for (index, row) in values.enumerated() {
                    var x = CGFloat(3) + columnWidths.prefix(column).reduce(0, +) + CGFloat(column) * 7
                    let center = height - 1 - (CGFloat(index) + 0.5) * pitch
                    let color: NSColor = row.account.provider == .claude ? .systemGreen : .systemOrange
                    if item.showService && badgeWidths[column] > 0 {
                        if starts[column].contains(index) {
                            let count = values[index...].prefix { $0.account.id == row.account.id }.count
                            let badgeCenter = center - CGFloat(count - 1) * pitch / 2
                            let badgeHeight = min(CGFloat(13), pitch * 0.88)
                            NSColor(AppTheme.accent(for: row.account.provider)).setFill()
                            NSBezierPath(roundedRect: NSRect(x: x, y: badgeCenter - badgeHeight / 2, width: badgeWidths[column], height: badgeHeight), xRadius: min(4, badgeHeight / 3), yRadius: min(4, badgeHeight / 3)).fill()
                            let textWidth = (row.badge as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: badgeFont, weight: .bold)]).width
                            draw(row.badge, x: x + (badgeWidths[column] - textWidth) / 2, center: badgeCenter, font: badgeFont, color: .white)
                        }
                        x += badgeWidths[column] + ((item.showBars || item.showPercent) ? 3 : 0)
                    }
                    if item.showBars {
                        // All rows share geometry; snap to device pixels so fractional
                        // row positions cannot make equal bars look differently thick.
                        let barHeight = max(1, (min(CGFloat(5), pitch * 0.45) * scale).rounded()) / scale
                        let barY = ((center - barHeight / 2) * scale).rounded() / scale
                        let rect = NSRect(x: x, y: barY, width: 28, height: barHeight)
                        NSColor.white.withAlphaComponent(0.22).setFill(); NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
                        let value = min(1, max(0, row.metric.window?.utilization ?? 0))
                        color.withAlphaComponent(row.stale ? 0.5 : 1).setFill()
                        NSBezierPath(roundedRect: NSRect(x: x, y: rect.minY, width: 28 * value, height: barHeight), xRadius: 2, yRadius: 2).fill()
                        x += 28 + (item.showPercent ? 3 : 0)
                    }
                    if item.showPercent { draw(TokenFormatters.percentageString(for: row.metric.window?.utilization), x: x, center: center, font: font, color: color.withAlphaComponent(row.stale ? 0.6 : 1)) }
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: width, height: height)); image.addRepresentation(bitmap)
        return image
    }
}
