import AppKit
import Combine
#if canImport(Sparkle)
import Sparkle
#endif

/// Automatic updates (Sparkle). scripts/build-app.sh links Sparkle and, only when
/// AGENTBAR_SPARKLE_FEED names a feed, writes it (SUFeedURL) and the public key every
/// update must be signed with (SUPublicEDKey) into Info.plist; this fork's builds
/// have neither, so the official Limi feed never replaces them. Sparkle then looks
/// once a day without asking first. A plain `swift build` or `swift test` has no
/// Sparkle and none of this.
///
/// Limi lives in the menu bar and never takes focus from the app a person is
/// using, and an update must not either: with gentle reminders declared, Sparkle
/// (2.2 and later) shows an update it found by itself behind the other apps
/// instead of bringing Limi to the front. A check someone starts with
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
}

/// What Check for Updates… in Settings needs: whether this build updates itself
/// at all (a build without Sparkle, or without a feed and key, shows no button),
/// and whether a check can start now (not while one is under way).
@MainActor
final class UpdateStatus: ObservableObject {
    static let shared = UpdateStatus()
    @Published fileprivate(set) var isAvailable = false
    @Published fileprivate(set) var canCheck = false
}

#if canImport(Sparkle)
@MainActor
private final class UpdateDriver: NSObject, SPUStandardUserDriverDelegate {
    static let shared = UpdateDriver()
    private var controller: SPUStandardUpdaterController?

    func start() {
        // A bundle without a feed and key (made some other way) has nothing to check.
        guard controller == nil,
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil,
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        self.controller = controller
        UpdateStatus.shared.isAvailable = true
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &UpdateStatus.shared.$canCheck)
    }

    func checkNow() {
        controller?.checkForUpdates(nil)
    }

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
}
#endif
