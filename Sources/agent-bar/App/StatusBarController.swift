import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusBarCoordinator {
    private let controllers: [ProviderKind: StatusBarController]

    init(store: UsageStore, settings: AppSettings, providers: [ProviderKind]) {
        self.controllers = Dictionary(
            uniqueKeysWithValues: providers.map { provider in
                (
                    provider,
                    StatusBarController(
                        provider: provider,
                        store: store,
                        settings: settings
                    )
                )
            }
        )
        _ = controllers
    }

    func isStatusItemVisible(for provider: ProviderKind) -> Bool {
        controllers[provider]?.isStatusItemVisible ?? false
    }

    func statusItemLength(for provider: ProviderKind) -> CGFloat {
        controllers[provider]?.statusItemLength ?? 0
    }
}

@MainActor
final class StatusBarController {
    private let provider: ProviderKind
    private let store: UsageStore
    private let settings: AppSettings
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let hostingController: NSHostingController<AnyView>
    private var cancellables = Set<AnyCancellable>()

    init(provider: ProviderKind, store: UsageStore, settings: AppSettings) {
        self.provider = provider
        self.store = store
        self.settings = settings
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
        apply(
            snapshot: store.snapshot(for: provider),
            displaySettings: settings.getProviderDisplaySettings(provider)
        )
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
        popover.contentSize = NSSize(width: 392, height: 380)
    }

    private func subscribe() {
        store.$claudeSnapshot
            .sink { [weak self] snapshot in
                guard let self, self.provider == .claude else { return }
                self.apply(
                    snapshot: snapshot,
                    displaySettings: self.settings.getProviderDisplaySettings(self.provider)
                )
            }
            .store(in: &cancellables)

        store.$codexSnapshot
            .sink { [weak self] snapshot in
                guard let self, self.provider == .codex else { return }
                self.apply(
                    snapshot: snapshot,
                    displaySettings: self.settings.getProviderDisplaySettings(self.provider)
                )
            }
            .store(in: &cancellables)

        settings.$providerSettings
            .sink { [weak self] providerSettings in
                guard let self, let displaySettings = providerSettings[self.provider] else {
                    return
                }
                self.apply(
                    snapshot: self.store.snapshot(for: self.provider),
                    displaySettings: displaySettings
                )
            }
            .store(in: &cancellables)
    }

    private func apply(
        snapshot: ProviderSnapshot,
        displaySettings: ProviderDisplaySettings
    ) {
        statusItem.isVisible = displaySettings.isEnabled
        guard let button = statusItem.button else { return }
        let rendered = StatusItemRenderer.render(
            snapshot: snapshot,
            displaySettings: displaySettings
        )
        statusItem.length = max(rendered.size.width, 28)
        button.image = rendered.image
        button.imagePosition = .imageOnly
        button.toolTip = "\(snapshot.provider.displayName) \(TokenFormatters.percentageString(for: snapshot.fiveHour.utilization))"
    }

    var isStatusItemVisible: Bool {
        statusItem.isVisible
    }

    var statusItemLength: CGFloat {
        statusItem.length
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
