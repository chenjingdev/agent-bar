import Foundation
import Testing
@testable import agent_bar

// Whether a run of the app may change Claude Code's own login. These tests never ask for the shared container, never
// build the system switcher (a container is only made for environments that turn it off), and never point a store at
// the real data folder.
@MainActor
struct AppContainerTests {
    @Test func aRunWithItsOwnDataFolderOrDefaultsGetsNoSwitcher() {
        #expect(AppContainer.claudeCodeAllowed([:]))
        #expect(AppContainer.claudeCodeAllowed(["HOME": "/Users/someone", "PATH": "/usr/bin:/bin", "AGENTBAR_OTHER": "1"]))

        #expect(!AppContainer.claudeCodeAllowed(["AGENTBAR_DATA_DIR": "/tmp/agentbar-dev"]))
        #expect(!AppContainer.claudeCodeAllowed(["AGENTBAR_DEFAULTS_SUITE": "agentbar-dev"]))
        #expect(!AppContainer.claudeCodeAllowed(["AGENTBAR_DATA_DIR": "/tmp/agentbar-dev", "AGENTBAR_DEFAULTS_SUITE": "agentbar-dev"]))
        // A variable that is there counts, whatever it holds.
        #expect(!AppContainer.claudeCodeAllowed(["AGENTBAR_DATA_DIR": ""]))
        #expect(!AppContainer.claudeCodeAllowed(["AGENTBAR_DEFAULTS_SUITE": ""]))
    }

    @Test func theContainerOfADevelopmentRunBuildsItsStoreWithoutOne() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentbar-container-\(UUID())")
        let suite = "agentbar-container-\(UUID())"
        defer {
            try? FileManager.default.removeItem(at: root)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        // The data folder is a temporary one in both, so nothing here reaches the real one. With the suite variable the
        // defaults are a throwaway suite too; without it `AppSettings` reads the test process's own defaults, not the app's.
        for environment in [["AGENTBAR_DATA_DIR": root.path, "AGENTBAR_DEFAULTS_SUITE": suite], ["AGENTBAR_DATA_DIR": root.path]] {
            let container = AppContainer(environment: environment)
            defer { container.store.shutdown() }
            #expect(container.store.files.root.path == root.path)
            #expect(!container.store.claudeCodeEnabled)
        }
    }
}
