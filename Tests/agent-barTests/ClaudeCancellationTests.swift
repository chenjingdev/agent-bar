import Foundation
import Testing
@testable import agent_bar

struct ClaudeCancellationTests {
    @Test func preCancelledLoadDoesNotStartStatusOrHTTP() async {
        let control = OperationControl(); control.cancel()
        let statusCalls = LockedCalls(), httpCalls = LockedCalls()
        let provider = ClaudeUsageProvider(directory: URL(fileURLWithPath: "/unused-test-directory"),
            expectedIdentity: AccountIdentity(email: "fixture@example.invalid"), control: control,
            statusReader: { _, _ in statusCalls.increment(); return AccountIdentity() },
            transport: { _ in httpCalls.increment(); throw URLError(.cancelled) })
        _ = await provider.load()
        #expect(statusCalls.count == 0)
        #expect(httpCalls.count == 0)
    }

    @Test func cancellationAfterStatusPreventsCredentialAndHTTPRequestSteps() async {
        let control = OperationControl(), httpCalls = LockedCalls()
        let identity = AccountIdentity(email: "fixture@example.invalid")
        let provider = ClaudeUsageProvider(directory: URL(fileURLWithPath: "/unused-test-directory"),
            expectedIdentity: identity, control: control,
            statusReader: { _, passedControl in
                #expect(passedControl === control)
                passedControl.cancel()
                return identity
            },
            transport: { _ in httpCalls.increment(); throw URLError(.cancelled) })
        let result = await provider.load()
        #expect(control.cancelled)
        #expect(httpCalls.count == 0)
        #expect(result.isStale)
        #expect(result.note?.contains(AccountError.cancelled.localizedDescription) == true)
    }
}

private final class LockedCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func increment() { lock.lock(); value += 1; lock.unlock() }
}
