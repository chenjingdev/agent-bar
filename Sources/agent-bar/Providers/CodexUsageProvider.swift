import Foundation

struct CodexUsageProvider: UsageProviding {
    var directory: URL
    var expectedIdentity: AccountIdentity? = nil
    var control = OperationControl()
    var resetLog: LimitResetLog? = nil

    func load() async -> ProviderSnapshot {
        await Task.detached(priority: .utility) {
            do {
                let rpc = try CodexRPC(directory: directory, control: control)
                defer { rpc.stop() }
                let identity = try rpc.identity()
                if let expectedIdentity, identity.comparison(to: expectedIdentity) == .different {
                    throw AccountError.message("The linked account has changed. Reconnect to confirm the account.")
                }
                let response: [String: Any]
                do { response = try rpc.request("account/rateLimits/read") }
                catch {
                    guard case AccountError.loginRequired = error else { throw error }
                    _ = try rpc.identity(refresh: true)
                    response = try rpc.request("account/rateLimits/read")
                }
                let data = try JSONSerialization.data(withJSONObject: ["result": response])
                let payload = try JSONDecoder().decode(CodexRateLimitResponse.self, from: data)
                let result = CodexRateLimitMapper.map(payload.result.rateLimits)
                let resets = CodexRateLimitMapper.resets(payload.result.rateLimitResetCredits)
                resetLog?.recordStatus(resets.map { String(describing: $0) } ?? "not reported",
                                       ["rateLimitResetCredits": response["rateLimitResetCredits"] as Any])
                return ProviderSnapshot(provider: .codex, updatedAt: .now,
                    fiveHour: result.fiveHourUsedPercent.map { WindowSummary(tokens: $0, limitTokens: 100, resetAt: result.fiveHourResetAt, displayStyle: .percentage) },
                    weekly: result.weeklyUsedPercent.map { WindowSummary(tokens: $0, limitTokens: 100, resetAt: result.weeklyResetAt, displayStyle: .percentage) },
                    modelWeeklies: [], planName: result.planName,
                    sourceDescription: "Codex app-server account/rateLimits/read",
                    note: "Account-wide Codex usage limits.", isStale: false, requiresLogin: false,
                    usageLimitResets: resets,
                    credits: CodexRateLimitMapper.credits(payload.result.rateLimits.credits))
            } catch {
                var failed = ProviderSnapshot.placeholder(for: .codex).failed(error.localizedDescription,
                    requiresLogin: (error as? AccountError).map { if case .loginRequired = $0 { return true }; return false } ?? false)
                if case AccountError.rateLimited(let seconds) = error { failed.retryAt = Date().addingTimeInterval(seconds) }
                return failed
            }
        }.value
    }
}

extension CodexUsageProvider {
    // Uses the reset the person picked, named by its credit ID so the backend does not pick
    // another. Codex must still list it as available just before; otherwise nothing is sent. A
    // fresh idempotency key marks this as one logical attempt.
    func redeemLimitReset(couponID: String, log: LimitResetLog) async -> LimitResetResult {
        await Task.detached(priority: .userInitiated) {
            var step = "launch"
            do {
                let rpc = try CodexRPC(directory: directory, control: control)
                defer { rpc.stop() }
                step = "identity"
                let identity = try rpc.identity()
                if let expectedIdentity, identity.comparison(to: expectedIdentity) == .different {
                    log.record("stopped", ["step": step, "reason": "The signed-in Codex account differs from the linked one."])
                    return LimitResetResult(succeeded: false, message: "The linked account has changed. Reconnect it in Settings › Accounts.")
                }
                step = "status"
                let status = try rpc.response("account/rateLimits/read")
                log.record("status", ["method": "account/rateLimits/read", "reply": status])
                let credits = (try? JSONSerialization.data(withJSONObject: status))
                    .flatMap { try? JSONDecoder().decode(CodexRateLimitResponse.self, from: $0) }?
                    .result.rateLimitResetCredits?.credits
                let listed = credits?.first { $0.id == couponID }
                guard let listed, listed.status == "available" else {
                    log.record("stopped", ["step": step, "creditId": couponID, "listedStatus": listed?.status as Any,
                                           "reason": "The chosen credit is not listed as available."])
                    let message = credits == nil ? "Codex did not list its resets, so none was used. Details are in the reset log."
                        : listed == nil ? "Codex no longer lists that reset. Refresh and pick another."
                        : "Codex lists that reset as \(listed?.status ?? "unknown"), so it was not used."
                    return LimitResetResult(succeeded: false, message: message)
                }
                step = "consume"
                let params = ["idempotencyKey": UUID().uuidString, "creditId": couponID]
                log.record("request", ["method": "account/rateLimitResetCredit/consume", "params": params])
                let reply = try rpc.response("account/rateLimitResetCredit/consume", params: params)
                log.record("response", ["reply": reply])
                if let error = reply["error"] as? [String: Any] {
                    let code = (error["code"] as? Int).map { " (error \($0))" } ?? ""
                    return LimitResetResult(succeeded: false, message: "Codex refused the reset request\(code). Details are in the reset log.")
                }
                return CodexRateLimitMapper.resetResult((reply["result"] as? [String: Any])?["outcome"] as? String)
            } catch {
                log.record("error", ["step": step, "error": String(describing: error), "message": error.localizedDescription])
                if step == "consume", case AccountError.timeout = error {
                    return LimitResetResult(succeeded: false, message: "Codex did not answer in time. Refresh to see whether the reset applied.")
                }
                return LimitResetResult(succeeded: false, message: error.localizedDescription)
            }
        }.value
    }
}

struct RemoteRateLimitData: Codable {
    let planName: String?
    let fiveHourUsedPercent: Int?
    let weeklyUsedPercent: Int?
    let fiveHourResetAt: Date?
    let weeklyResetAt: Date?
    let apiUnavailable: Bool
    let apiError: String?

    var visibleWindowTitles: [String] {
        var titles: [String] = []
        if fiveHourUsedPercent != nil {
            titles.append("5-Hour Session")
        }
        if weeklyUsedPercent != nil {
            titles.append("Weekly Limit")
        }
        return titles
    }

    func with(apiUnavailable: Bool, apiError: String?) -> RemoteRateLimitData {
        return RemoteRateLimitData(
            planName: planName,
            fiveHourUsedPercent: fiveHourUsedPercent,
            weeklyUsedPercent: weeklyUsedPercent,
            fiveHourResetAt: fiveHourResetAt,
            weeklyResetAt: weeklyResetAt,
            apiUnavailable: apiUnavailable,
            apiError: apiError
        )
    }
}

private struct RemoteRateLimitResult {
    let data: RemoteRateLimitData
    let updatedAt: Date
    let note: String
    let isStale: Bool
}

struct CodexRateLimitResponse: Decodable {
    let result: ResultPayload

    struct ResultPayload: Decodable {
        let rateLimits: RateLimitSnapshot
        let rateLimitResetCredits: ResetCreditsSummary?

        enum CodingKeys: String, CodingKey {
            case rateLimits, rateLimitResetCredits
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            rateLimits = try c.decode(RateLimitSnapshot.self, forKey: .rateLimits)
            // Resets and credits are extras. A changed shape must not hide the usage windows.
            rateLimitResetCredits = try? c.decodeIfPresent(ResetCreditsSummary.self, forKey: .rateLimitResetCredits)
        }
    }

    struct ResetCreditsSummary: Decodable {
        let availableCount: Int
        let credits: [ResetCredit]?

        enum CodingKeys: String, CodingKey {
            case availableCount, credits
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            availableCount = try c.decode(Int.self, forKey: .availableCount)
            // Details are optional. A malformed list must not drop the count.
            credits = try? c.decodeIfPresent([ResetCredit].self, forKey: .credits)
        }
    }

    struct ResetCredit: Decodable {
        let id: String?
        let status: String?
        let title: String?
        let expiresAt: Double?
    }

    struct RateLimitSnapshot: Decodable {
        let planType: String?
        let primary: RateLimitWindow?
        let secondary: RateLimitWindow?
        let credits: CreditsSnapshot?

        enum CodingKeys: String, CodingKey {
            case planType, primary, secondary, credits
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            planType = try c.decodeIfPresent(String.self, forKey: .planType)
            primary = try c.decodeIfPresent(RateLimitWindow.self, forKey: .primary)
            secondary = try c.decodeIfPresent(RateLimitWindow.self, forKey: .secondary)
            credits = try? c.decodeIfPresent(CreditsSnapshot.self, forKey: .credits)
        }
    }

    struct CreditsSnapshot: Decodable {
        let hasCredits: Bool
        let unlimited: Bool
        let balance: String?
    }

    struct RateLimitWindow: Decodable {
        let usedPercent: Int
        let windowDurationMins: Int?
        let resetsAt: Int64?

        var resetsAtDate: Date? {
            guard let resetsAt else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(resetsAt))
        }
    }
}

enum CodexRateLimitMapper {
    static func map(_ rateLimits: CodexRateLimitResponse.RateLimitSnapshot) -> RemoteRateLimitData {
        let fiveHour = [rateLimits.primary, rateLimits.secondary]
            .compactMap { $0 }
            .first { $0.windowDurationMins == 300 }
            ?? rateLimits.primary.flatMap { $0.windowDurationMins == nil ? $0 : nil }
        let weekly = [rateLimits.primary, rateLimits.secondary]
            .compactMap { $0 }
            .first { $0.windowDurationMins == 10_080 }
            ?? rateLimits.secondary.flatMap { $0.windowDurationMins == nil ? $0 : nil }

        return RemoteRateLimitData(
            planName: rateLimits.planType?.capitalized,
            fiveHourUsedPercent: fiveHour?.usedPercent,
            weeklyUsedPercent: weekly?.usedPercent,
            fiveHourResetAt: fiveHour?.resetsAtDate,
            weeklyResetAt: weekly?.resetsAtDate,
            apiUnavailable: false,
            apiError: nil
        )
    }

    // One coupon per listed credit that is neither used nor being used; Codex may list fewer
    // resets than it counts. Only a credit listed as available can be used.
    static func resets(_ summary: CodexRateLimitResponse.ResetCreditsSummary?) -> UsageLimitResets? {
        guard let summary else { return nil }
        let coupons = (summary.credits ?? []).compactMap { credit -> UsageLimitResets.Coupon? in
            guard let id = credit.id, !id.isEmpty, credit.status != "redeemed", credit.status != "redeeming" else { return nil }
            let usable = credit.status == "available"
            return UsageLimitResets.Coupon(id: id, title: credit.title.flatMap { $0.isEmpty ? nil : $0 },
                                           expiresAt: credit.expiresAt.map(Date.init(timeIntervalSince1970:)),
                                           usable: usable, note: usable ? nil : "Codex lists it as \(credit.status ?? "unknown").")
        }
        return UsageLimitResets(available: summary.availableCount, unsorted: coupons)
    }

    static func resetResult(_ outcome: String?) -> LimitResetResult {
        switch outcome {
        case "reset": return LimitResetResult(succeeded: true, message: "Usage limits reset.")
        case "nothingToReset": return LimitResetResult(succeeded: false, message: "Nothing to reset: no usage limit is reached.")
        case "noCredit": return LimitResetResult(succeeded: false, message: "No usage limit reset is available.")
        case "alreadyRedeemed": return LimitResetResult(succeeded: false, message: "That reset was already used.")
        default:
            return LimitResetResult(succeeded: false,
                message: "Codex gave an unexpected answer (\(outcome ?? "none")). Details are in the reset log.")
        }
    }

    // An account without credits reports no balance; that is a known zero.
    static func credits(_ snapshot: CodexRateLimitResponse.CreditsSnapshot?) -> CreditBalance? {
        guard let snapshot else { return nil }
        if snapshot.unlimited { return CreditBalance(unlimited: true) }
        if let balance = snapshot.balance.flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }), balance.isFinite {
            return CreditBalance(balance: balance)
        }
        return CreditBalance(balance: snapshot.hasCredits ? nil : 0)
    }
}
