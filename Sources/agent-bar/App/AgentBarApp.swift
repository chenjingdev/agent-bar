import AppKit
import SwiftUI

final class AgentBarAppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: StatusBarCoordinator?

    func applicationWillTerminate(_ notification: Notification) {
        AppContainer.shared.store.shutdown()
        ProcessSession.stopAll()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        coordinator = StatusBarCoordinator(
            store: AppContainer.shared.store,
            providers: AppContainer.shared.availableProviders
        )
        if AppContainer.shared.settings.consumeDisplaySetupNotice() || !AppContainer.shared.store.accounts.contains(where: { $0.isManaged }) {
            SettingsWindowController.shared.show(tab: .accounts)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show(tab: .accounts)
        return true
    }
}

@main
struct AgentBarApp: App {
    @NSApplicationDelegateAdaptor(AgentBarAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(AppContainer.shared.settings)
                .environmentObject(AppContainer.shared.store)
        }
    }
}
