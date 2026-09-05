import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusBarCoordinator {
    private let controller: StatusBarController

    init(store: UsageStore, settings: AppSettings, providers: [ProviderKind]) {
        self.controller = StatusBarController(
            providers: providers,
            store: store,
            settings: settings
        )
    }

    func isStatusItemVisible(for provider: ProviderKind) -> Bool {
        controller.isStatusItemVisible(for: provider)
    }

    func statusItemLength(for provider: ProviderKind) -> CGFloat {
        controller.statusItemLength(for: provider)
    }

    func statusItemAccessibilityLabel(for provider: ProviderKind) -> String? {
        controller.statusItemAccessibilityLabel(for: provider)
    }

    func statusItemAccessibilityValue(for provider: ProviderKind) -> String? {
        controller.statusItemAccessibilityValue(for: provider)
    }

    var physicalStatusItemCount: Int {
        controller.physicalStatusItemCount
    }

    var combinedStatusItemLength: CGFloat {
        controller.combinedStatusItemLength
    }

    var visibleProviderOrder: [ProviderKind] {
        controller.visibleProviderOrder
    }

    func statusItemFrame(for provider: ProviderKind) -> NSRect? {
        controller.statusItemFrame(for: provider)
    }

    func provider(atStatusItemImageX x: CGFloat) -> ProviderKind? {
        controller.provider(atStatusItemImageX: x)
    }
}

@MainActor
final class StatusBarController {
    static let interProviderSpacing: CGFloat = 4

    private struct ProviderPresentation {
        let isVisible: Bool
        let length: CGFloat
        let accessibilityLabel: String
        let accessibilityValue: String
        let toolTip: String
    }

    private let providers: [ProviderKind]
    private let store: UsageStore
    private let settings: AppSettings
    private let statusItem: NSStatusItem
    private var popovers: [ProviderKind: NSPopover] = [:]
    private var presentations: [ProviderKind: ProviderPresentation] = [:]
    private var currentRender: CombinedStatusItemRender?
    private var cancellables = Set<AnyCancellable>()

    init(providers: [ProviderKind], store: UsageStore, settings: AppSettings) {
        self.providers = providers
        self.store = store
        self.settings = settings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureStatusItem()
        configurePopovers()
        subscribe()
        apply()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
    }

    private func configurePopovers() {
        for provider in providers {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = true
            popover.contentViewController = NSHostingController(
                rootView: AnyView(
                    ProviderPopoverContainerView(provider: provider)
                        .environmentObject(store)
                )
            )
            popover.contentSize = NSSize(width: 392, height: 380)
            popovers[provider] = popover
        }
    }

    private func subscribe() {
        store.$claudeSnapshot
            .sink { [weak self] snapshot in
                self?.apply(snapshotOverrides: [.claude: snapshot])
            }
            .store(in: &cancellables)

        store.$codexSnapshot
            .sink { [weak self] snapshot in
                self?.apply(snapshotOverrides: [.codex: snapshot])
            }
            .store(in: &cancellables)

        settings.$providerSettings
            .sink { [weak self] providerSettings in
                self?.apply(providerSettingsOverride: providerSettings)
            }
            .store(in: &cancellables)
    }

    private func apply(
        snapshotOverrides: [ProviderKind: ProviderSnapshot] = [:],
        providerSettingsOverride: [ProviderKind: ProviderDisplaySettings]? = nil
    ) {
        var nextPresentations: [ProviderKind: ProviderPresentation] = [:]
        var visibleSegments: [ProviderStatusItemRender] = []

        for provider in providers.reversed() {
            let snapshot = snapshotOverrides[provider] ?? store.snapshot(for: provider)
            let displaySettings = providerSettingsOverride?[provider]
                ?? settings.getProviderDisplaySettings(provider)
            let rendered = StatusItemRenderer.render(
                snapshot: snapshot,
                displaySettings: displaySettings
            )
            let length = max(rendered.size.width, 28)
            let accessibility = accessibilityDescription(for: snapshot)

            nextPresentations[provider] = ProviderPresentation(
                isVisible: displaySettings.isEnabled,
                length: length,
                accessibilityLabel: accessibility.label,
                accessibilityValue: accessibility.value,
                toolTip: "\(accessibility.label) \(accessibility.value)"
            )

            if displaySettings.isEnabled {
                visibleSegments.append(
                    ProviderStatusItemRender(
                        provider: provider,
                        image: rendered.image,
                        imageSize: rendered.size,
                        length: length
                    )
                )
            }
        }

        presentations = nextPresentations
        guard visibleSegments.isEmpty == false else {
            currentRender = nil
            statusItem.isVisible = false
            statusItem.button?.image = nil
            return
        }

        let combined = StatusItemRenderer.combine(
            visibleSegments,
            spacing: Self.interProviderSpacing
        )
        currentRender = combined
        statusItem.isVisible = true
        statusItem.length = max(combined.size.width, 28)

        guard let button = statusItem.button else { return }
        button.image = combined.image
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        let visiblePresentations = combined.segments.compactMap { presentations[$0.provider] }
        button.toolTip = visiblePresentations.map(\.toolTip).joined(separator: "  •  ")
        button.setAccessibilityLabel("AgentBar usage")
        button.setAccessibilityValue(
            combined.segments.compactMap { segment in
                guard let presentation = presentations[segment.provider] else { return nil }
                return "\(segment.provider.displayName) \(presentation.accessibilityValue)"
            }.joined(separator: ", ")
        )
        updateOpenPopoverAnchor(button: button)
    }

    private func accessibilityDescription(
        for snapshot: ProviderSnapshot
    ) -> (label: String, value: String) {
        let label: String
        if snapshot.fiveHour != nil {
            label = "\(snapshot.provider.displayName) 5-hour usage"
        } else if snapshot.weekly != nil {
            label = "\(snapshot.provider.displayName) weekly usage"
        } else {
            label = "\(snapshot.provider.displayName) usage"
        }
        return (
            label,
            TokenFormatters.percentageString(for: snapshot.primaryWindow?.utilization)
        )
    }

    func isStatusItemVisible(for provider: ProviderKind) -> Bool {
        presentations[provider]?.isVisible ?? false
    }

    func statusItemLength(for provider: ProviderKind) -> CGFloat {
        presentations[provider]?.length ?? 0
    }

    func statusItemAccessibilityLabel(for provider: ProviderKind) -> String? {
        presentations[provider]?.accessibilityLabel
    }

    func statusItemAccessibilityValue(for provider: ProviderKind) -> String? {
        presentations[provider]?.accessibilityValue
    }

    var physicalStatusItemCount: Int {
        providers.isEmpty ? 0 : 1
    }

    var combinedStatusItemLength: CGFloat {
        statusItem.length
    }

    var visibleProviderOrder: [ProviderKind] {
        currentRender?.segments.map(\.provider) ?? []
    }

    func statusItemFrame(for provider: ProviderKind) -> NSRect? {
        currentRender?.segments.first { $0.provider == provider }?.frame
    }

    func provider(atStatusItemImageX x: CGFloat) -> ProviderKind? {
        currentRender?.provider(atImageX: x)
    }

    @objc
    private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button,
              let provider = currentRender?.provider(atScreenPoint: NSEvent.mouseLocation, in: button) else {
            return
        }
        togglePopover(for: provider, sender: sender)
    }

    private func togglePopover(for provider: ProviderKind, sender: AnyObject?) {
        guard let button = statusItem.button,
              let popover = popovers[provider],
              let anchor = segmentRectInButton(for: provider, button: button) else {
            return
        }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            for (otherProvider, otherPopover) in popovers where otherProvider != provider && otherPopover.isShown {
                otherPopover.performClose(sender)
            }
            popover.show(relativeTo: anchor, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func segmentRectInButton(
        for provider: ProviderKind,
        button: NSStatusBarButton
    ) -> NSRect? {
        guard let render = currentRender,
              let segment = render.segments.first(where: { $0.provider == provider }) else {
            return nil
        }
        let imageRect = button.cell?.imageRect(forBounds: button.bounds) ?? button.bounds
        guard render.size.width > 0, render.size.height > 0 else { return nil }
        return NSRect(
            x: imageRect.minX + segment.frame.minX * imageRect.width / render.size.width,
            y: imageRect.minY + segment.frame.minY * imageRect.height / render.size.height,
            width: segment.frame.width * imageRect.width / render.size.width,
            height: segment.frame.height * imageRect.height / render.size.height
        )
    }

    private func updateOpenPopoverAnchor(button: NSStatusBarButton) {
        for (provider, popover) in popovers where popover.isShown {
            guard presentations[provider]?.isVisible == true,
                  let anchor = segmentRectInButton(for: provider, button: button) else {
                popover.performClose(nil)
                continue
            }
            popover.positioningRect = anchor
        }
    }
}

private struct ProviderPopoverContainerView: View {
    let provider: ProviderKind

    @EnvironmentObject private var store: UsageStore

    var body: some View {
        ProviderPopoverView(snapshot: store.snapshot(for: provider))
            .frame(width: 392, height: 568, alignment: .topLeading)
    }
}

struct ProviderStatusItemRender {
    let provider: ProviderKind
    let image: NSImage
    let imageSize: NSSize
    let length: CGFloat
}

struct StatusItemSegment {
    let provider: ProviderKind
    let frame: NSRect
}

struct CombinedStatusItemRender {
    let image: NSImage
    let size: NSSize
    let segments: [StatusItemSegment]

    @MainActor
    func provider(atScreenPoint screenPoint: NSPoint, in button: NSButton) -> ProviderKind? {
        guard let window = button.window else { return nil }
        // Status-bar actions may arrive with a current event from another window
        // (or no mouse event). Resolve the pointer through the button's own window.
        let point = button.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        guard button.bounds.contains(point) else { return nil }
        let imageRect = button.cell?.imageRect(forBounds: button.bounds) ?? button.bounds
        guard imageRect.width > 0 else { return nil }
        let clampedX = min(max(point.x, imageRect.minX), imageRect.maxX)
        let imageX = (clampedX - imageRect.minX) * size.width / imageRect.width
        return provider(atImageX: imageX)
    }

    func provider(atImageX x: CGFloat) -> ProviderKind? {
        guard segments.isEmpty == false, x >= 0, x <= size.width else {
            return nil
        }

        for (index, segment) in segments.enumerated() {
            let leftBoundary: CGFloat
            if index == segments.startIndex {
                leftBoundary = 0
            } else {
                leftBoundary = (segments[index - 1].frame.maxX + segment.frame.minX) / 2
            }

            let rightBoundary: CGFloat
            if index == segments.index(before: segments.endIndex) {
                rightBoundary = size.width
            } else {
                rightBoundary = (segment.frame.maxX + segments[index + 1].frame.minX) / 2
            }

            if x >= leftBoundary && x <= rightBoundary {
                return segment.provider
            }
        }
        return nil
    }
}

@MainActor
enum StatusItemRenderer {
    static let renderScale: CGFloat = 2

    static func render(
        snapshot: ProviderSnapshot,
        displaySettings: ProviderDisplaySettings
    ) -> (image: NSImage, size: NSSize) {
        let rootView = MenuBarLabelView(
            snapshot: snapshot,
            displaySettings: displaySettings
        )
            .background(Color.clear)
        let hostingView = NSHostingView(rootView: rootView)
        let size = hostingView.fittingSize
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: max(Int(ceil(size.width * renderScale)), 1),
            pixelsHigh: max(Int(ceil(size.height * renderScale)), 1),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        rep.size = size
        hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        image.isTemplate = false
        return (image, size)
    }

    static func combine(
        _ providerRenders: [ProviderStatusItemRender],
        spacing: CGFloat
    ) -> CombinedStatusItemRender {
        guard providerRenders.isEmpty == false else {
            return CombinedStatusItemRender(
                image: NSImage(size: .zero),
                size: .zero,
                segments: []
            )
        }

        let height = providerRenders.map(\.imageSize.height).max() ?? 0
        let width = providerRenders.reduce(0) { $0 + $1.length }
            + spacing * CGFloat(max(providerRenders.count - 1, 0))
        let size = NSSize(width: width, height: height)
        var segments: [StatusItemSegment] = []
        var x: CGFloat = 0

        for providerRender in providerRenders {
            segments.append(
                StatusItemSegment(
                    provider: providerRender.provider,
                    frame: NSRect(
                        x: x,
                        y: 0,
                        width: providerRender.length,
                        height: height
                    )
                )
            )
            x += providerRender.length + spacing
        }

        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: max(Int(ceil(size.width * renderScale)), 1),
            pixelsHigh: max(Int(ceil(size.height * renderScale)), 1),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        rep.size = size

        if let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.imageInterpolation = .high

            for (providerRender, segment) in zip(providerRenders, segments) {
                let drawRect = NSRect(
                    x: segment.frame.midX - providerRender.imageSize.width / 2,
                    y: segment.frame.midY - providerRender.imageSize.height / 2,
                    width: providerRender.imageSize.width,
                    height: providerRender.imageSize.height
                )
                providerRender.image.draw(
                    in: drawRect,
                    from: NSRect(origin: .zero, size: providerRender.imageSize),
                    operation: .sourceOver,
                    fraction: 1,
                    respectFlipped: false,
                    hints: [.interpolation: NSImageInterpolation.high]
                )
            }

            context.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
        }

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        image.isTemplate = false
        return CombinedStatusItemRender(
            image: image,
            size: size,
            segments: segments
        )
    }
}
