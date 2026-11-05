import Combine
import Sparkle
import Testing
@testable import agent_bar

@MainActor
struct AppUpdaterTests {
    @Test("A downloaded update waits until user actions finish", .timeLimit(.minutes(1)))
    func waitsUntilIdle() async {
        let updater = AppUpdater()
        let idle = CurrentValueSubject<Bool, Never>(false)
        updater.observeIdleState(idle.eraseToAnyPublisher())
        let (installed, continuation) = AsyncStream<Void>.makeStream()
        var installations = 0
        updater.scheduleInstallation {
            installations += 1
            continuation.yield()
            continuation.finish()
        }

        await Task.yield()
        #expect(installations == 0)
        idle.send(true)
        for await _ in installed { }
        #expect(installations == 1)
        idle.send(false)
        idle.send(true)
        await Task.yield()
        #expect(installations == 1)
    }

    @Test("A Claude Code account switch finishes before an automatic update", .timeLimit(.minutes(1)))
    func waitsForClaudeCodeSwitch() async throws {
        let fixture = try StoreFixture(["a", "b"], signedIn: "a", saved: ["b"])
        defer { fixture.close() }
        await fixture.start()
        let updater = AppUpdater()
        updater.observeUserActivity(fixture.store)
        let hold = fixture.world.hold(login: "default")
        fixture.press("b")
        #expect(fixture.store.claudeCodeActivity != nil)
        let (installed, continuation) = AsyncStream<Void>.makeStream()
        var installations = 0
        updater.scheduleInstallation {
            installations += 1
            continuation.yield()
            continuation.finish()
        }

        await Task.yield()
        #expect(installations == 0)
        hold.release.signal()
        await fixture.finish()
        for await _ in installed { }
        #expect(installations == 1)
        #expect(fixture.store.claudeCodeAccountID == fixture.account("b").id)
    }

    @Test("A Claude Code browser sign-in finishes before an automatic update", .timeLimit(.minutes(1)))
    func waitsForClaudeCodePreparation() async throws {
        let fixture = try StoreFixture(["a", "b"], signedIn: "a")
        defer { fixture.close() }
        fixture.world.plan(.signIn("b@example.test"))
        await fixture.start()
        let updater = AppUpdater()
        updater.observeUserActivity(fixture.store)
        let hold = fixture.gates.holdBrowser()
        fixture.signIn("b")
        #expect(fixture.store.claudeCodePreparation != nil)
        let (installed, continuation) = AsyncStream<Void>.makeStream()
        var installations = 0
        updater.scheduleInstallation {
            installations += 1
            continuation.yield()
            continuation.finish()
        }

        await Task.yield()
        #expect(installations == 0)
        hold.release.signal()
        await fixture.finish()
        for await _ in installed { }
        #expect(installations == 1)
        #expect(fixture.store.claudeCodeReady.contains(fixture.account("b").id))
    }

    @Test("The final relaunch gate holds manual installs until user actions finish", .timeLimit(.minutes(1)))
    func postponesFinalRelaunchUntilIdle() async {
        let updater = AppUpdater()
        let idle = CurrentValueSubject<Bool, Never>(false)
        updater.observeIdleState(idle.eraseToAnyPublisher())
        let (resumed, continuation) = AsyncStream<Void>.makeStream()
        var relaunches = 0
        let sparkle = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        let postponed = updater.updater(sparkle.updater, shouldPostponeRelaunchForUpdate: SUAppcastItem.empty()) {
            relaunches += 1
            continuation.yield()
            continuation.finish()
        }

        #expect(postponed)
        await Task.yield()
        #expect(relaunches == 0)
        idle.send(true)
        for await _ in resumed { }
        #expect(relaunches == 1)
    }

    @Test("The final relaunch gate lets Sparkle continue directly when idle")
    func allowsFinalRelaunchWhenIdle() {
        let updater = AppUpdater()
        let sparkle = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        #expect(!updater.updater(sparkle.updater, shouldPostponeRelaunchForUpdate: SUAppcastItem.empty()) {
            Issue.record("Sparkle owns continuation when the delegate returns false")
        })
    }

    @Test("A user action started before relaunch defers the pending update", .timeLimit(.minutes(1)))
    func rechecksIdleBeforeInstalling() async {
        let updater = AppUpdater()
        let idle = CurrentValueSubject<Bool, Never>(true)
        updater.observeIdleState(idle.eraseToAnyPublisher())
        let (installed, continuation) = AsyncStream<Void>.makeStream()
        var installations = 0
        updater.scheduleInstallation {
            installations += 1
            continuation.yield()
            continuation.finish()
        }
        idle.send(false)

        await Task.yield()
        #expect(installations == 0)
        idle.send(true)
        for await _ in installed { }
        #expect(installations == 1)
    }
}
