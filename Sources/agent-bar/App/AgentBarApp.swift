import AppKit
import SwiftUI

final class AgentBarAppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: StatusBarCoordinator?

    // A switch that is handing a login to Claude Code finishes before the app quits, so the login it holds only in memory
    // is not lost. Quit, Restart Now and an update all come through here. After 90 s it quits anyway; the next launch then
    // finishes or undoes the switch.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let store = AppContainer.shared.store
        guard store.claudeCodeActivity != nil else { return .terminateNow }
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(90)
            while store.claudeCodeActivity != nil && Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

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
        Updates.start()
        // `agentbar` commands reach this app through its socket.
        CLIServer.shared.start(root: AppContainer.shared.store.files.root)
        CLIInstaller.linkAtLaunch()
        if AppRelauncher.takeReopenSettingsRequest() {
            // Back where the language was changed, now in that language.
            SettingsWindowController.shared.show(tab: .general)
        } else if AppContainer.shared.settings.consumeDisplaySetupNotice() || !AppContainer.shared.store.accounts.contains(where: { $0.isManaged }) {
            SettingsWindowController.shared.show(tab: .accounts)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show(tab: .accounts)
        return true
    }
}

// The executable is both the app and the `agentbar` command: started with a command word it runs the command.
@main
enum AgentBarMain {
    static func main() {
        if CLI.isCommand(CommandLine.arguments) { exit(CLIClient.main(CommandLine.arguments)) }
        AgentBarApp.main()
    }
}

struct AgentBarApp: App {
    @NSApplicationDelegateAdaptor(AgentBarAppDelegate.self) private var appDelegate

    init() {
        // Before any text is looked up, so this launch already uses the chosen
        // language (English unless chosen) rather than the Mac's. The choice is
        // read straight from defaults: building the app container first would
        // look up text in the Mac's language.
        let environment = ProcessInfo.processInfo.environment
        let defaults = environment["AGENTBAR_DEFAULTS_SUITE"].flatMap(UserDefaults.init(suiteName:)) ?? .standard
        AppLanguage.stored(in: defaults).apply()
    }

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(AppContainer.shared.settings)
                .environmentObject(AppContainer.shared.store)
        }
    }
}
