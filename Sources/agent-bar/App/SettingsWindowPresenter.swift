import AppKit

@MainActor
struct SettingsWindowPresenter {
    let activateApplication: () -> Void
    let openSettings: () -> Void

    func present() {
        activateApplication()
        openSettings()
    }
}
