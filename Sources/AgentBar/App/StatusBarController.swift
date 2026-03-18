import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusBarCoordinator {
    private let controllers: [StatusBarController]

    init(store: UsageStore) {
        self.controllers = ProviderKind.allCases.map { StatusBarController(provider: $0, store: store) }
        _ = controllers
    }
}

@MainActor
final class StatusBarController {
    private let provider: ProviderKind
    private let store: UsageStore
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let hostingController: NSHostingController<AnyView>
    private var cancellables = Set<AnyCancellable>()

    init(provider: ProviderKind, store: UsageStore) {
        self.provider = provider
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        self.hostingController = NSHostingController(
            rootView: AnyView(
                ProviderPopoverContainerView(provider: provider)
                    .environmentObject(store)
            )
        )
        configureStatusItem()
        configurePopover()
        subscribe()
        apply(snapshot: store.snapshot(for: provider))
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = hostingController
        popover.contentSize = NSSize(width: 392, height: 568)
    }

    private func subscribe() {
        store.$claudeSnapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in
                guard let self, self.provider == .claude else { return }
                self.apply(snapshot: snapshot)
            }
            .store(in: &cancellables)

        store.$codexSnapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in
                guard let self, self.provider == .codex else { return }
                self.apply(snapshot: snapshot)
            }
            .store(in: &cancellables)
    }

    private func apply(snapshot: ProviderSnapshot) {
        guard let button = statusItem.button else { return }
        let rendered = StatusItemRenderer.render(snapshot: snapshot)
        statusItem.length = max(rendered.size.width, 28)
        button.image = rendered.image
        button.imagePosition = .imageOnly
        button.toolTip = "\(snapshot.provider.displayName) \(TokenFormatters.percentageString(for: snapshot.fiveHour.utilization))"
    }

    @objc
    private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
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

@MainActor
private enum StatusItemRenderer {
    static func render(snapshot: ProviderSnapshot) -> (image: NSImage, size: NSSize) {
        let rootView = MenuBarLabelView(snapshot: snapshot)
            .background(Color.clear)
        let hostingView = NSHostingView(rootView: rootView)
        let size = hostingView.fittingSize
        hostingView.frame = NSRect(origin: .zero, size: size)
        let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) ?? NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: max(Int(size.width), 1),
            pixelsHigh: max(Int(size.height), 1),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        image.isTemplate = false
        return (image, size)
    }
}
