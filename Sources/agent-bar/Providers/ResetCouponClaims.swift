import Foundation

// Using one usage-reset coupon. Only a person's confirmed press calls these; a refresh never does.
enum CodexCouponClaim {
    // Uses the coupon in `coupons.claim` through the account's own app-server. `idempotencyKey` names this one attempt.
    // Without a key, an attempt that got no answer in the last 10 minutes is retried under its own key, so a coupon the
    // service did use is not used twice; any answer ends that attempt.
    static func use(_ coupons: UsageResetCoupons, directory: URL, expectedIdentity: AccountIdentity?,
                    idempotencyKey: String? = nil, control: OperationControl = OperationControl(),
                    executable: URL? = nil, environment: [String: String]? = nil) async -> CouponOutcome {
        guard case .codex(let creditID) = coupons.claim else { return .tryLater }
        let attempt = directory.standardizedFileURL.path + "|" + (creditID ?? "*")
        let memory = CodexClaimMemory.shared
        let pending = await memory.pendingKey(for: attempt)
        let idempotencyKey = idempotencyKey ?? pending ?? UUID().uuidString
        await memory.remember(idempotencyKey, for: attempt)
        let outcome = await claim(creditID: creditID, directory: directory, expectedIdentity: expectedIdentity, idempotencyKey: idempotencyKey,
                                  control: control, executable: executable, environment: environment)
        if outcome != .tryLater { await memory.forget(attempt) }
        return outcome
    }

    private static func claim(creditID: String?, directory: URL, expectedIdentity: AccountIdentity?, idempotencyKey: String,
                              control: OperationControl, executable: URL?, environment: [String: String]?) async -> CouponOutcome {
        await Task.detached(priority: .userInitiated) {
            do {
                let rpc = try CodexRPC(directory: directory, control: control, executable: executable, environment: environment)
                defer { rpc.stop() }
                let identity = try rpc.identity()
                if let expectedIdentity, identity.comparison(to: expectedIdentity) == .different { return .signInAgain }
                var params: [String: Any] = ["idempotencyKey": idempotencyKey]
                if let creditID { params["creditId"] = creditID }
                let result = try rpc.request("account/rateLimitResetCredit/consume", params: params)
                return CodexResetCredits.outcome(result)
            } catch AccountError.loginRequired {
                return .signInAgain
            } catch {
                return .tryLater
            }
        }.value
    }
}

// Codex attempts that got no answer, by account folder and credit, for 10 minutes.
actor CodexClaimMemory {
    static let shared = CodexClaimMemory()
    private var pending: [String: (key: String, at: Date)] = [:]

    func pendingKey(for attempt: String, now: Date = .now) -> String? {
        if let held = pending[attempt], now.timeIntervalSince(held.at) < 600 { return held.key }
        pending[attempt] = nil
        return nil
    }
    func remember(_ key: String, for attempt: String, now: Date = .now) { pending[attempt] = (key, now) }
    func forget(_ attempt: String) { pending[attempt] = nil }
}
