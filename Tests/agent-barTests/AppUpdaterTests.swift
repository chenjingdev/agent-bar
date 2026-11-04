import Combine
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
