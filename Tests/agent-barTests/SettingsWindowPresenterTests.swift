import Testing
@testable import agent_bar

@MainActor
struct SettingsWindowPresenterTests {
    @Test
    func opensSettingsBeforeActivatingApplication() {
        var events: [String] = []
        let presenter = SettingsWindowPresenter(
            activateApplication: { events.append("activate") },
            openSettings: { events.append("open") }
        )

        presenter.present()

        #expect(events == ["open", "activate"])
    }

    @Test
    func invokesEachSettingsActionExactlyOnce() {
        var activationCount = 0
        var openCount = 0
        let presenter = SettingsWindowPresenter(
            activateApplication: { activationCount += 1 },
            openSettings: { openCount += 1 }
        )

        presenter.present()

        #expect(activationCount == 1)
        #expect(openCount == 1)
    }
}
