import AppKit
import SwiftUI

final class AgentBarAppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: StatusBarCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        coordinator = StatusBarCoordinator(
            store: AppContainer.shared.store,
            settings: AppContainer.shared.settings,
            providers: AppContainer.shared.availableProviders
        )
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
