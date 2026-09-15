import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?
    var presentationWindow: NSWindow {
        if window == nil { show(accounts: true) }
        return window!
    }
    func show(accounts: Bool = false) {
        let container = AppContainer.shared
        let view: AnyView
        if accounts {
            view = AnyView(DisplayPopoverView(itemID: container.store.displayConfiguration.items[0].id, showAccounts: true)
                .environmentObject(container.store).frame(width: 392, height: 568))
        } else {
            view = AnyView(SettingsView().environmentObject(container.settings).environmentObject(container.store))
        }
        let controller = NSHostingController(rootView: view)
        if window == nil {
            let created = NSWindow(contentViewController: controller)
            created.styleMask = [.titled, .closable, .miniaturizable]
            created.isReleasedWhenClosed = false
            created.center(); window = created
        } else { window?.contentViewController = controller }
        window?.title = accounts ? "AgentBar — Accounts" : "AgentBar — Settings"
        window?.setContentSize(accounts ? NSSize(width: 392, height: 568) : NSSize(width: 430, height: 320))
        SettingsWindowPresenter(
            activateApplication: { NSApplication.shared.activate(ignoringOtherApps: true) },
            openSettings: { self.window?.makeKeyAndOrderFront(nil) }
        ).present()
    }
}
