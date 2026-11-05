import AppKit
import Combine
import Sparkle

@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate, @MainActor SPUStandardUserDriverDelegate {
    static let shared = AppUpdater()

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticUpdates = true
    private var controller: SPUStandardUpdaterController?
    private var idleSubscription: AnyCancellable?
    private var isIdle = true
    private var pendingInstallation: (() -> Void)?

    func start(store: UsageStore) {
        guard controller == nil else { return }
        observeUserActivity(store)
        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .combineLatest(controller.updater.publisher(for: \.automaticallyDownloadsUpdates))
            .map { $0 && $1 }
            .assign(to: &$automaticUpdates)
        controller.startUpdater()
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    func setAutomaticUpdates(_ enabled: Bool) {
        controller?.updater.automaticallyDownloadsUpdates = enabled
        controller?.updater.automaticallyChecksForUpdates = enabled
    }

    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        // AgentBar may stay open for weeks. Install and relaunch once Sparkle
        // has downloaded and verified the update, rather than waiting for quit.
        scheduleInstallation(immediateInstallHandler)
        return true
    }

    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        guard !isIdle else { return false }
        scheduleInstallation(installHandler)
        return true
    }

    func observeUserActivity(_ store: UsageStore) {
        let usageIdle = store.$isLoggingIn
            .combineLatest(store.$pendingLogin, store.$redeemingCoupons)
            .map { !$0 && $1 == nil && $2.isEmpty }
        let claudeCodeIdle = store.$claudeCodeStarting
            .combineLatest(store.$claudeCodeActivity, store.$claudeCodePreparation, store.$claudeCodeConfirmation)
            .map { !$0 && $1 == nil && $2 == nil && $3 == nil }
        observeIdleState(usageIdle.combineLatest(claudeCodeIdle).map { $0 && $1 }.eraseToAnyPublisher())
    }

    func observeIdleState(_ publisher: AnyPublisher<Bool, Never>) {
        idleSubscription = publisher.removeDuplicates().sink { [weak self] idle in
            self?.isIdle = idle
            self?.installIfIdle()
        }
    }

    func scheduleInstallation(_ handler: @escaping () -> Void) {
        pendingInstallation = handler
        installIfIdle()
    }

    private func installIfIdle() {
        guard isIdle, pendingInstallation != nil else { return }
        Task { @MainActor [weak self] in
            guard let self, self.isIdle, let install = self.pendingInstallation else { return }
            self.pendingInstallation = nil
            install()
        }
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        if handleShowingUpdate {
            NSApplication.shared.setActivationPolicy(.regular)
        }
    }

    func standardUserDriverWillFinishUpdateSession() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}
