import AppKit
import Combine
#if canImport(Sparkle)
import Sparkle
#endif

/// Automatic updates (Sparkle). scripts/build-app.sh links Sparkle and writes
/// AgentBar's feed (SUFeedURL, the appcast.xml of the latest GitHub release of
/// chenjingdev/agent-bar) and the public key every update must be signed with
/// (SUPublicEDKey) into Info.plist. Sparkle then looks once a day without asking first. A plain `swift build` or `swift test` has no
/// Sparkle and none of this.
///
/// AgentBar lives in the menu bar and never takes focus from the app a person is
/// using, and an update must not either: with gentle reminders declared, Sparkle
/// (2.2 and later) shows an update it found by itself behind the other apps
/// instead of bringing AgentBar to the front. A check someone starts with
/// Check for Updates… in Settings › General answers in front, up to date or not.
enum Updates {
    @MainActor static func start() {
        #if canImport(Sparkle)
        UpdateDriver.shared.start()
        #endif
    }

    /// Looks for a new version now: Check for Updates… in Settings › General.
    @MainActor static func checkNow() {
        #if canImport(Sparkle)
        UpdateDriver.shared.checkNow()
        #endif
    }

    /// Asks the feed whether a new version exists without any window, for `agentbar update`: Sparkle's own answer is
    /// a modal alert, and while it waits for a click nothing else on the main thread runs, the command socket included.
    @MainActor static func probe() {
        #if canImport(Sparkle)
        UpdateDriver.shared.probe()
        #endif
    }
}

/// What Check for Updates… in Settings needs: whether this build updates itself
/// at all (a build without Sparkle, or without a feed and key, shows no button),
/// and whether a check can start now (not while one is under way).
@MainActor
final class UpdateStatus: ObservableObject {
    static let shared = UpdateStatus()
    @Published fileprivate(set) var isAvailable = false
    @Published fileprivate(set) var canCheck = false
    // What the last check found, for `agentbar update`: "available", "up-to-date", "failed" or "installing"; nil
    // before a check has answered since AgentBar started.
    @Published fileprivate(set) var outcome: String?
    @Published fileprivate(set) var foundVersion: String?
    @Published fileprivate(set) var failure: String?
    @Published fileprivate(set) var answeredAt: Date?
    // When Sparkle last looked, by itself or when asked (kept across launches by Sparkle).
    fileprivate(set) var lastCheckDate: () -> Date? = { nil }
    // Whether a check or an update is running now.
    fileprivate(set) var sessionInProgress: () -> Bool = { false }

    fileprivate func answer(_ outcome: String, version: String? = nil, failure: String? = nil) {
        self.outcome = outcome
        foundVersion = version
        self.failure = failure
        answeredAt = Date()
    }
}

#if canImport(Sparkle)
@MainActor
private final class UpdateDriver: NSObject, SPUStandardUserDriverDelegate, SPUUpdaterDelegate {
    static let shared = UpdateDriver()
    private var controller: SPUStandardUpdaterController?

    func start() {
        // A bundle without a feed and key (made some other way) has nothing to check.
        guard controller == nil,
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil,
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        UpdateStatus.shared.isAvailable = true
        UpdateStatus.shared.lastCheckDate = { [weak controller] in controller?.updater.lastUpdateCheckDate }
        UpdateStatus.shared.sessionInProgress = { [weak controller] in controller?.updater.sessionInProgress ?? false }
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &UpdateStatus.shared.$canCheck)
    }

    func checkNow() {
        controller?.checkForUpdates(nil)
    }

    func probe() {
        controller?.updater.checkForUpdateInformation()
    }

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    // What each check found, so `agentbar update --wait` can say it (the window still shows it to a person).
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Task { @MainActor in UpdateStatus.shared.answer("available", version: version) }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in UpdateStatus.shared.answer("up-to-date") }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let message = error.localizedDescription
        // Not finding an update also ends a check with an error; that one is answered above.
        if (error as NSError).code == Int(SUError.noUpdateError.rawValue) { return }
        Task { @MainActor in UpdateStatus.shared.answer("failed", failure: message) }
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Task { @MainActor in UpdateStatus.shared.answer("installing", version: version) }
    }
}
#endif
