import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?
    var presentationWindow: NSWindow {
        if window == nil { show(tab: .accounts) }
        return window!
    }
    func show(tab: SettingsTab = .accounts, groupID: UUID? = nil) {
        let container = AppContainer.shared
        if let groupID { container.store.selectMenuBarGroup(groupID) }
        let view = SettingsView(tab: tab).environmentObject(container.settings).environmentObject(container.store)
        let controller = NSHostingController(rootView: view)
        if window == nil {
            let created = NSWindow(contentViewController: controller)
            created.styleMask = [.titled, .closable, .miniaturizable]
            created.isReleasedWhenClosed = false
            created.center(); window = created
        } else { window?.contentViewController = controller }
        window?.title = "AgentBar — Settings"
        window?.setContentSize(NSSize(width: 540, height: 660))
        SettingsWindowPresenter(
            activateApplication: { NSApplication.shared.activate(ignoringOtherApps: true) },
            openSettings: { self.window?.makeKeyAndOrderFront(nil) }
        ).present()
    }
}
