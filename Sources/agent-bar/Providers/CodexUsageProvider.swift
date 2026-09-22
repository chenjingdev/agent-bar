import Foundation

struct CodexUsageProvider: UsageProviding {
    var directory: URL
    var expectedIdentity: AccountIdentity? = nil
    var control = OperationControl()

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
                return ProviderSnapshot(provider: .codex, updatedAt: .now,
                    fiveHour: result.fiveHourUsedPercent.map { WindowSummary(tokens: $0, limitTokens: 100, resetAt: result.fiveHourResetAt, displayStyle: .percentage) },
                    weekly: result.weeklyUsedPercent.map { WindowSummary(tokens: $0, limitTokens: 100, resetAt: result.weeklyResetAt, displayStyle: .percentage) },
                    modelWeeklies: [], planName: result.planName,
                    sourceDescription: "Codex app-server account/rateLimits/read",
                    note: "Account-wide Codex usage limits.", isStale: false, requiresLogin: false)
            } catch {
                var failed = ProviderSnapshot.placeholder(for: .codex).failed(error.localizedDescription,
                    requiresLogin: (error as? AccountError).map { if case .loginRequired = $0 { return true }; return false } ?? false)
                if case AccountError.rateLimited(let seconds) = error { failed.retryAt = Date().addingTimeInterval(seconds) }
                return failed
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

        enum CodingKeys: String, CodingKey {
            case rateLimits
        }
    }

    struct RateLimitSnapshot: Decodable {
        let planType: String?
        let primary: RateLimitWindow?
        let secondary: RateLimitWindow?
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
}
