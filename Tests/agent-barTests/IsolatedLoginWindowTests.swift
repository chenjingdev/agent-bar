import Foundation
import Testing
@testable import agent_bar

struct IsolatedLoginWindowTests {
    @Test @MainActor func authenticationCompletionCanArriveOnBackgroundQueue() async {
        let delivered = await withCheckedContinuation { continuation in
            let callback = IsolatedLoginWindow.completionOnMainActor { error in
                MainActor.assertIsolated()
                continuation.resume(returning: (error as NSError?)?.code)
            }
            DispatchQueue.global().async {
                callback(nil, NSError(domain: "AuthenticationSessionRegression", code: 17))
            }
        }
        #expect(delivered == 17)
    }
}
