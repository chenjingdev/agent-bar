import CryptoKit
import Foundation

private enum ClaudeUsagePolicy {
    static let successCacheTTL: TimeInterval = 60
    static let failureCacheTTL: TimeInterval = 15
    static let rateLimitedBaseTTL: TimeInterval = 60
    static let rateLimitedMaxTTL: TimeInterval = 5 * 60
}

struct ClaudeUsageProvider: UsageProviding {
    var directory: URL
    var cacheURL: URL? = nil
    var expectedIdentity: AccountIdentity? = nil
    var control = OperationControl()
    var statusReader: @Sendable (URL, OperationControl) throws -> AccountIdentity = {
        try $1.checkCancellation()
        return try ProviderCLI.claudeLocalIdentity(directory: $0)
    }
    var transport: @Sendable (URLRequest) async throws -> (Data, URLResponse) = {
        try await URLSession.shared.data(for: $0)
    }
    var couponUserAgent: @Sendable () -> String = { ClaudeCouponClient.userAgent }

    func load() async -> ProviderSnapshot {
        await Task.detached(priority: .utility) {
            do {
                try control.checkCancellation()
                if let expectedIdentity {
                    let current = try statusReader(directory, control)
                    if current.comparison(to: expectedIdentity) == .different {
                        throw AccountError.message(String(localized: "The linked Claude account has changed. Reconnect to confirm it."))
                    }
                }
                try control.checkCancellation()
                var credentials = try readCredentials(allowExpired: true)
                if credentials.isExpired {
                    try await ClaudeCredentialRefresher.shared.refresh(data: credentials.rawData, directory: directory, transport: transport)
                    try control.checkCancellation()
                    credentials = try readCredentials()
                }
                let remoteResult = try await resolveRemoteUsage(credentials: credentials, withCoupons: couponsDue())
                try control.checkCancellation()
                guard credentials.cacheKey == (try readCredentials(allowExpired: true).cacheKey) else {
                    throw AccountError.message(String(localized: "The CLI account changed during the request. Refresh again."))
                }
                let modelWeeklies: [ModelWeeklySummary] = (remoteResult.data.modelWeeklies ?? []).map { cached in
                    ModelWeeklySummary(
                        label: cached.label,
                        window: cached.usedPercent.map {
                            WindowSummary(tokens: $0, limitTokens: 100, resetAt: cached.resetAt, displayStyle: .percentage)
                        } ?? WindowSummary(tokens: 0, limitTokens: 0, resetAt: cached.resetAt, displayStyle: .percentage)
                    )
                }
                var snapshot = ProviderSnapshot(
                    provider: .claude,
                    updatedAt: remoteResult.updatedAt,
                    fiveHour: WindowSummary(
                        tokens: remoteResult.data.fiveHourUsedPercent ?? 0,
                        limitTokens: remoteResult.data.fiveHourUsedPercent == nil ? 0 : 100,
                        resetAt: remoteResult.data.fiveHourResetAt,
                        displayStyle: .percentage
                    ),
                    weekly: WindowSummary(
                        tokens: remoteResult.data.weeklyUsedPercent ?? 0,
                        limitTokens: remoteResult.data.weeklyUsedPercent == nil ? 0 : 100,
                        resetAt: remoteResult.data.weeklyResetAt,
                        displayStyle: .percentage
                    ),
                    modelWeeklies: modelWeeklies,
                    planName: remoteResult.data.planName,
                    sourceDescription: remoteResult.sourceDescription,
                    note: remoteResult.note,
                    isStale: remoteResult.isStale,
                    requiresLogin: Self.requiresLogin(for: remoteResult.data.apiError)
                )
                if !remoteResult.isStale {
                    snapshot.resetCoupons = noteCoupons(answer: remoteResult.couponAnswer, subscriptionType: credentials.subscriptionType,
                                                         refused: remoteResult.couponsRefused)
                    snapshot.credits = await noteCredits(answer: remoteResult.answer, credentials: credentials)
                } else {
                    // Credits change slowly; while usage is held back (429) the last ones read still show.
                    snapshot.credits = creditsRecord()?.credits
                }
                return snapshot
            } catch {
                let requiresLogin = Self.requiresLogin(for: error)
                let blocked = (error as? AccountError).map { if case .message(let text) = $0 { return text == AnthropicAccessBlock.message }; return false } ?? false
                return ProviderSnapshot(
                    provider: .claude,
                    updatedAt: .now,
                    fiveHour: WindowSummary(tokens: 0, limitTokens: 0, resetAt: nil, displayStyle: .percentage),
                    weekly: WindowSummary(tokens: 0, limitTokens: 0, resetAt: nil, displayStyle: .percentage),
                    modelWeeklies: [],
                    planName: nil,
                    sourceDescription: "Anthropic OAuth usage API + cache",
                    note: blocked ? AnthropicAccessBlock.message
                        : requiresLogin ? String(localized: "Sign-in required. Reconnect this account in Settings › Accounts.")
                        : String(localized: "Couldn't read Anthropic account usage: \(error.localizedDescription)"),
                    isStale: true,
                    requiresLogin: requiresLogin
                )
            }
        }.value
    }

    private func resolveRemoteUsage(credentials: ClaudeCredentials, withCoupons: Bool) async throws -> RemoteUsageResult {
        try control.checkCancellation()
        let cache = ClaudeUsageCache(overrideURL: cacheURL, enabled: cacheURL != nil)
        let now = Date.now
        let previousCache = try? cache.readRaw()

        if let cacheState = try? cache.readState(now: now, credentialCacheKey: credentials.cacheKey), cacheState.isFresh {
            return RemoteUsageResult(
                data: cacheState.data,
                updatedAt: cacheState.updatedAt,
                note: note(for: cacheState.data),
                isStale: cacheState.data.apiUnavailable,
                sourceDescription: sourceDescription(for: cacheState.data)
            )
        }

        let planName = planName(from: credentials.subscriptionType)
        try control.checkCancellation()
        let apiResult = await fetchUsageApi(accessToken: credentials.accessToken, withCoupons: withCoupons)
        try control.checkCancellation()

        if let payload = apiResult.data {
            let selectedWeeklyWindow = Self.selectWeeklyWindow(from: payload)
            let successData = RemoteUsageData(
                planName: planName,
                fiveHourUsedPercent: payload.fiveHour?.utilization.map { Self.parseUtilization($0) },
                weeklyUsedPercent: selectedWeeklyWindow?.window.utilization.map { Self.parseUtilization($0) },
                fiveHourResetAt: payload.fiveHour?.parsedResetAt,
                weeklyResetAt: selectedWeeklyWindow?.window.parsedResetAt,
                modelWeeklies: Self.modelWeeklies(from: payload),
                apiUnavailable: false,
                apiError: nil,
                usageSource: .oauthApi,
                weeklyWindowLabel: selectedWeeklyWindow?.label
            )

            try? cache.write(
                data: successData,
                timestamp: now,
                credentialCacheKey: credentials.cacheKey,
                lastGoodData: successData,
                lastGoodTimestamp: now
            )

            return RemoteUsageResult(
                data: successData,
                updatedAt: now,
                note: note(for: successData),
                isStale: false,
                sourceDescription: sourceDescription(for: successData),
                couponAnswer: withCoupons && !apiResult.couponsRefused ? apiResult.body : nil,
                couponsRefused: apiResult.couponsRefused,
                // The coupon read asks with `skip_spend=1`, which leaves the credits out; only a plain read brings them.
                answer: withCoupons && !apiResult.couponsRefused ? nil : apiResult.body
            )
        }

        let failureData = RemoteUsageData(
            planName: planName,
            fiveHourUsedPercent: nil,
            weeklyUsedPercent: nil,
            fiveHourResetAt: nil,
            weeklyResetAt: nil,
            modelWeeklies: nil,
            apiUnavailable: true,
            apiError: apiResult.error,
            usageSource: .oauthApi,
            weeklyWindowLabel: nil
        )

        let isRateLimited = apiResult.error == "rate-limited"
        let previousRateLimitedCount = previousCache?.rateLimitedCount ?? 0
        let rateLimitedCount = isRateLimited ? previousRateLimitedCount + 1 : 0
        let retryAfterUntil = apiResult.retryAfterSeconds.map { now.addingTimeInterval(TimeInterval($0)) }

        if isRateLimited {
            let goodState = cache.makeLastGoodState(from: previousCache, credentialCacheKey: credentials.cacheKey)
            try? cache.write(
                data: failureData,
                timestamp: now,
                credentialCacheKey: credentials.cacheKey,
                rateLimitedCount: rateLimitedCount,
                retryAfterUntil: retryAfterUntil,
                lastGoodData: goodState?.data,
                lastGoodTimestamp: goodState?.updatedAt
            )

            if let goodState {
                let displayData = goodState.data.with(apiUnavailable: true, apiError: "rate-limited")
                return RemoteUsageResult(
                    data: displayData,
                    updatedAt: goodState.updatedAt,
                    note: note(for: displayData),
                    isStale: true,
                    sourceDescription: sourceDescription(for: displayData)
                )
            }
        }

        if !isRateLimited {
            let goodState = cache.makeLastGoodState(from: previousCache, credentialCacheKey: credentials.cacheKey)
            try? cache.write(data: failureData, timestamp: now, credentialCacheKey: credentials.cacheKey,
                             lastGoodData: goodState?.data, lastGoodTimestamp: goodState?.updatedAt)
        }
        return RemoteUsageResult(
            data: failureData,
            updatedAt: now,
            note: note(for: failureData),
            isStale: true,
            sourceDescription: sourceDescription(for: failureData)
        )
    }

    private func note(for data: RemoteUsageData) -> String {
        if data.apiUnavailable {
            if data.apiError == "blocked" { return AnthropicAccessBlock.message }
            if Self.requiresLogin(for: data.apiError) {
                return String(localized: "Claude login required. Sign in to Claude Code, then refresh.")
            }
            if data.apiError == "rate-limited" {
                return String(localized: "The Anthropic usage API is rate-limited. Showing the last known good value and retrying automatically.")
            }
            return String(localized: "Couldn't read the Anthropic usage API (\(data.apiError ?? "unknown")).")
        }
        switch data.usageSource {
        case .statusLine:
            return String(localized: "Showing Claude Code live rate_limits from your active status line session.")
        case .oauthApi:
            if let weeklyWindowLabel = data.weeklyWindowLabel {
                return String(localized: "Anthropic did not return an account-wide weekly window, so Weekly is following the \(weeklyWindowLabel) window.")
            }
            return String(localized: "Showing account-wide Anthropic usage API data.")
        case nil:
            return String(localized: "Showing account-wide Anthropic usage API data.")
        }
    }

    private func sourceDescription(for data: RemoteUsageData) -> String {
        switch data.usageSource {
        case .statusLine:
            return "Claude Code live rate_limits"
        case .oauthApi:
            return "Anthropic OAuth usage API + cache"
        case nil:
            return "Anthropic OAuth usage API + cache"
        }
    }

    // Usage matters more than coupons, as in agent-bar: if the coupon flag is refused (a 4xx other than 401, 403 and
    // 429), read plain usage instead.
    private func fetchUsageApi(accessToken: String, withCoupons: Bool) async -> UsageApiResult {
        let result = await fetchUsageApiOnce(accessToken: accessToken, withCoupons: withCoupons)
        guard withCoupons, let status = result.httpStatus, (400..<500).contains(status), ![401, 403, 429].contains(status) else {
            return result
        }
        var plain = await fetchUsageApiOnce(accessToken: accessToken, withCoupons: false)
        plain.couponsRefused = true
        return plain
    }

    private func fetchUsageApiOnce(accessToken: String, withCoupons: Bool) async -> UsageApiResult {
        do {
            let request = try makeUsageRequest(accessToken: accessToken, withCoupons: withCoupons)
            try control.checkCancellation()
            let (data, response) = try await transport(request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return UsageApiResult(data: nil, error: "invalid-response", retryAfterSeconds: nil)
            }

            guard httpResponse.statusCode == 200 else {
                let error = AnthropicAccessBlock.matches(status: httpResponse.statusCode, body: data) ? "blocked"
                    : httpResponse.statusCode == 429 ? "rate-limited" : "http-\(httpResponse.statusCode)"
                let retryAfterSeconds = httpResponse.statusCode == 429
                    ? Self.parseRetryAfterSeconds(httpResponse.value(forHTTPHeaderField: "Retry-After"))
                    : nil
                return UsageApiResult(data: nil, error: error, retryAfterSeconds: retryAfterSeconds,
                                      httpStatus: httpResponse.statusCode)
            }

            do {
                let payload = try JSONDecoder().decode(UsageApiResponse.self, from: data)
                return UsageApiResult(data: payload, error: nil, retryAfterSeconds: nil, body: data)
            } catch {
                return UsageApiResult(data: nil, error: "parse", retryAfterSeconds: nil)
            }
        } catch let urlError as URLError {
            if urlError.code == .timedOut {
                return UsageApiResult(data: nil, error: "timeout", retryAfterSeconds: nil)
            }
            return UsageApiResult(data: nil, error: "network", retryAfterSeconds: nil)
        } catch {
            return UsageApiResult(data: nil, error: "network", retryAfterSeconds: nil)
        }
    }

    // With `withCoupons` the same read also brings the account's coupons: the answer holds the usage as well. A second
    // read right after the first is refused (429), so the coupons never get a request of their own. Every read names
    // the installed Claude Code (`ClaudeCouponClient`).
    private func makeUsageRequest(accessToken: String, withCoupons: Bool) throws -> URLRequest {
        guard let url = withCoupons ? ClaudeCedar.readURL : URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            throw ClaudeUsageError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(couponUserAgent(), forHTTPHeaderField: "User-Agent")
        return request
    }

    private func readCredentials(allowExpired: Bool = false) throws -> ClaudeCredentials {
        // The account's own file is the only source. Sign-in copies Claude Code's Keychain item
        // here once; that item keeps the refresh token the first renewal spends, so reading it
        // later would sign the account out. An unreadable file is retried on the next refresh.
        do {
            return try readFileCredentials(configDirectory: directory, allowExpired: allowExpired)
        } catch CocoaError.fileReadNoSuchFile {
            throw ClaudeUsageError.missingCredentials
        }
    }

    private func readFileCredentials(configDirectory: URL, allowExpired: Bool = false) throws -> ClaudeCredentials {
        let credentialsURL = configDirectory.appendingPathComponent(".credentials.json")
        let data = try Data(contentsOf: credentialsURL)
        let credentialsFile = try JSONDecoder().decode(CredentialsFile.self, from: data)

        guard let accessToken = credentialsFile.claudeAiOauth?.accessToken, accessToken.isEmpty == false else {
            throw ClaudeUsageError.missingCredentials
        }

        if !allowExpired, let expiresAt = credentialsFile.claudeAiOauth?.expiresAt, expiresAt <= Int(Date().timeIntervalSince1970 * 1000) {
            throw ClaudeUsageError.missingCredentials
        }

        return ClaudeCredentials(
            accessToken: accessToken,
            subscriptionType: credentialsFile.claudeAiOauth?.subscriptionType ?? "",
            cacheKey: Self.cacheKey(for: data), rawData: data, expiresAt: credentialsFile.claudeAiOauth?.expiresAt
        )
    }

    private static func cacheKey(for data: Data) -> String {
        SHA256.hash(data: data)
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func planName(from subscriptionType: String) -> String? {
        let normalized = subscriptionType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.isEmpty == false else { return nil }
        if normalized.contains("max") { return "Max" }
        if normalized.contains("pro") { return "Pro" }
        if normalized.contains("team") { return "Team" }
        if normalized.contains("enterprise") { return "Enterprise" }
        return subscriptionType.capitalized
    }

    private static func parseUtilization(_ value: Double?) -> Int {
        PercentageNormalizer.normalize(value)
    }

    private static func requiresLogin(for apiError: String?) -> Bool {
        switch apiError {
        case "missing-credentials", "http-401", "http-403":
            return true
        default:
            return false
        }
    }

    private static func requiresLogin(for error: Error) -> Bool {
        if case AccountError.loginRequired = error { return true }
        guard let usageError = error as? ClaudeUsageError else {
            return false
        }

        switch usageError {
        case .missingCredentials:
            return true
        case .invalidURL:
            return false
        }
    }

    private static func selectWeeklyWindow(from payload: UsageApiResponse) -> SelectedUsageWindow? {
        if let window = payload.sevenDay {
            return SelectedUsageWindow(window: window, label: nil)
        }

        if let limit = payload.limits?.first(where: { $0.kind == "weekly_all" }) {
            return SelectedUsageWindow(
                window: UsageWindowPayload(utilization: limit.percent, resetsAt: limit.resetsAt),
                label: nil
            )
        }

        if let window = payload.sevenDayOauthApps {
            return SelectedUsageWindow(window: window, label: "OAuth Apps 7-day")
        }

        if let window = payload.sevenDaySonnet {
            return SelectedUsageWindow(window: window, label: "Sonnet 7-day")
        }

        if let window = payload.sevenDayOpus {
            return SelectedUsageWindow(window: window, label: "Opus 7-day")
        }

        return nil
    }

    private static func modelWeeklies(from payload: UsageApiResponse) -> [CachedModelWeekly] {
        if let scoped = payload.limits?.filter({ $0.kind == "weekly_scoped" }), scoped.isEmpty == false {
            return scoped.map { limit in
                CachedModelWeekly(
                    label: limit.scope?.model?.displayName ?? "Model",
                    usedPercent: limit.percent.map { parseUtilization($0) },
                    resetAt: limit.parsedResetAt
                )
            }
        }

        var fallback: [CachedModelWeekly] = []
        if let sonnet = payload.sevenDaySonnet {
            fallback.append(
                CachedModelWeekly(
                    label: "Sonnet",
                    usedPercent: sonnet.utilization.map { parseUtilization($0) },
                    resetAt: sonnet.parsedResetAt
                )
            )
        }
        if let opus = payload.sevenDayOpus {
            fallback.append(
                CachedModelWeekly(
                    label: "Opus",
                    usedPercent: opus.utilization.map { parseUtilization($0) },
                    resetAt: opus.parsedResetAt
                )
            )
        }
        return fallback
    }

    private static func parseRetryAfterSeconds(_ raw: String?) -> Int? {
        guard let raw else { return nil }

        if let seconds = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)), seconds > 0 {
            return seconds
        }

        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: raw) {
            let delta = Int(ceil(date.timeIntervalSinceNow))
            return delta > 0 ? delta : nil
        }

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dateFormatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        if let date = dateFormatter.date(from: raw) {
            let delta = Int(ceil(date.timeIntervalSinceNow))
            return delta > 0 ? delta : nil
        }

        return nil
    }

}

struct RemoteUsageData: Codable {
    let planName: String?
    let fiveHourUsedPercent: Int?
    let weeklyUsedPercent: Int?
    let fiveHourResetAt: Date?
    let weeklyResetAt: Date?
    let modelWeeklies: [CachedModelWeekly]?
    let apiUnavailable: Bool
    let apiError: String?
    let usageSource: ClaudeUsageSource?
    let weeklyWindowLabel: String?

    func with(apiUnavailable: Bool, apiError: String?) -> RemoteUsageData {
        RemoteUsageData(
            planName: planName,
            fiveHourUsedPercent: fiveHourUsedPercent,
            weeklyUsedPercent: weeklyUsedPercent,
            fiveHourResetAt: fiveHourResetAt,
            weeklyResetAt: weeklyResetAt,
            modelWeeklies: modelWeeklies,
            apiUnavailable: apiUnavailable,
            apiError: apiError,
            usageSource: usageSource,
            weeklyWindowLabel: weeklyWindowLabel
        )
    }
}

struct CachedModelWeekly: Codable, Equatable {
    let label: String
    let usedPercent: Int?
    let resetAt: Date?
}

private struct RemoteUsageResult {
    let data: RemoteUsageData
    let updatedAt: Date
    let note: String
    let isStale: Bool
    let sourceDescription: String
    // The answer, when the read also asked for coupons.
    var couponAnswer: Data? = nil
    var couponsRefused = false
    // The usage answer itself, when the read was not answered from the cache.
    var answer: Data? = nil
}

enum ClaudeUsageSource: String, Codable {
    case oauthApi = "oauth_api"
    case statusLine = "status_line"
}

private struct ClaudeCredentials {
    let accessToken: String
    var subscriptionType: String
    let cacheKey: String
    let rawData: Data
    let expiresAt: Int?
    var isExpired: Bool { expiresAt.map { $0 <= Int(Date().timeIntervalSince1970 * 1000) } ?? false }
}

private struct CredentialsFile: Decodable {
    let claudeAiOauth: ClaudeAiOauthCredentials?

    struct ClaudeAiOauthCredentials: Decodable {
        let accessToken: String?
        let subscriptionType: String?
        let expiresAt: Int?
    }
}

private struct UsageApiResponse: Decodable {
    let fiveHour: UsageWindowPayload?
    let sevenDay: UsageWindowPayload?
    let sevenDayOauthApps: UsageWindowPayload?
    let sevenDayOpus: UsageWindowPayload?
    let sevenDaySonnet: UsageWindowPayload?
    let limits: [UsageLimitPayload]?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOauthApps = "seven_day_oauth_apps"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case limits
    }
}

private struct UsageLimitPayload: Decodable {
    let kind: String?
    let percent: Double?
    let resetsAt: String?
    let scope: UsageLimitScope?

    enum CodingKeys: String, CodingKey {
        case kind
        case percent
        case resetsAt = "resets_at"
        case scope
    }

    var parsedResetAt: Date? {
        guard let resetsAt else { return nil }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: resetsAt) {
            return date
        }

        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: resetsAt)
    }
}

private struct UsageLimitScope: Decodable {
    let model: UsageLimitScopeModel?
}

private struct UsageLimitScopeModel: Decodable {
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
    }
}

private struct UsageApiResult {
    let data: UsageApiResponse?
    let error: String?
    let retryAfterSeconds: Int?
    var body: Data? = nil
    var httpStatus: Int? = nil
    // The coupon flag was refused and this is the plain read that followed.
    var couponsRefused = false
}

private struct UsageWindowPayload: Decodable {
    let utilization: Double?
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    var parsedResetAt: Date? {
        guard let resetsAt else { return nil }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: resetsAt) {
            return date
        }

        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: resetsAt)
    }
}

private struct SelectedUsageWindow {
    let window: UsageWindowPayload
    let label: String?
}

private enum ClaudeUsageError: LocalizedError {
    case invalidURL
    case missingCredentials

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return String(localized: "Invalid usage URL")
        case .missingCredentials:
            return String(localized: "Couldn't find a Claude OAuth token.")
        }
    }
}

struct ClaudeUsageCacheRecord: Codable {
    let data: RemoteUsageData
    let timestamp: Date
    let credentialCacheKey: String?
    let rateLimitedCount: Int?
    let retryAfterUntil: Date?
    let lastGoodData: RemoteUsageData?
    let lastGoodTimestamp: Date?
    /// Read again at the next refresh whatever the age (`expire()`); the next write drops it.
    var forceRefresh: Bool? = nil
}

private struct LegacyClaudeUsageCacheRecord: Decodable {
    let timestamp: Date
    let cooldownUntil: Date?
    let planName: String?
    let fiveHourUsedPercent: Int?
    let weeklyUsedPercent: Int?
    let fiveHourResetAt: Date?
    let weeklyResetAt: Date?

    var upgraded: ClaudeUsageCacheRecord {
        let data = RemoteUsageData(
            planName: planName,
            fiveHourUsedPercent: fiveHourUsedPercent,
            weeklyUsedPercent: weeklyUsedPercent,
            fiveHourResetAt: fiveHourResetAt,
            weeklyResetAt: weeklyResetAt,
            modelWeeklies: nil,
            apiUnavailable: false,
            apiError: nil,
            usageSource: nil,
            weeklyWindowLabel: nil
        )

        return ClaudeUsageCacheRecord(
            data: data,
            timestamp: timestamp,
            credentialCacheKey: nil,
            rateLimitedCount: nil,
            retryAfterUntil: cooldownUntil,
            lastGoodData: data,
            lastGoodTimestamp: timestamp
        )
    }
}

struct ClaudeUsageCacheState {
    let data: RemoteUsageData
    let updatedAt: Date
    let isFresh: Bool
}

struct ClaudeUsageCache {
    var overrideURL: URL?
    var enabled: Bool

    private let fileManager = FileManager.default

    private var cacheURL: URL {
        if let overrideURL { return overrideURL }
        let base = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".agentbar", isDirectory: true)
        return base.appendingPathComponent("claude-usage-cache.json")
    }

    func readRaw() throws -> ClaudeUsageCacheRecord {
        guard enabled else { throw ClaudeUsageError.missingCredentials }
        let data = try Data(contentsOf: cacheURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let record = try? decoder.decode(ClaudeUsageCacheRecord.self, from: data) {
            return record
        }
        return try decoder.decode(LegacyClaudeUsageCacheRecord.self, from: data).upgraded
    }

    func readState(now: Date, credentialCacheKey: String?) throws -> ClaudeUsageCacheState {
        let cache = try readRaw()
        if credentialCacheKey == nil || cache.credentialCacheKey == nil || cache.credentialCacheKey != credentialCacheKey {
            return ClaudeUsageCacheState(data: cache.data, updatedAt: cache.timestamp, isFresh: false)
        }

        let displayState = displayState(from: cache)

        if let retryUntil = rateLimitedRetryUntil(for: cache), now < retryUntil {
            return ClaudeUsageCacheState(
                data: displayState.data,
                updatedAt: displayState.updatedAt,
                isFresh: true
            )
        }

        let ttl = cache.data.apiUnavailable ? ClaudeUsagePolicy.failureCacheTTL : ClaudeUsagePolicy.successCacheTTL
        return ClaudeUsageCacheState(
            data: displayState.data,
            updatedAt: displayState.updatedAt,
            isFresh: cache.forceRefresh != true && now.timeIntervalSince(cache.timestamp) < ttl
        )
    }

    func makeLastGoodState(from cache: ClaudeUsageCacheRecord?, credentialCacheKey: String?) -> ClaudeUsageCacheState? {
        guard let cache else { return nil }
        if credentialCacheKey == nil || cache.credentialCacheKey == nil || cache.credentialCacheKey != credentialCacheKey {
            return nil
        }

        if cache.data.apiUnavailable == false {
            return ClaudeUsageCacheState(data: cache.data, updatedAt: cache.timestamp, isFresh: false)
        }
        guard let lastGoodData = cache.lastGoodData else { return nil }
        return ClaudeUsageCacheState(
            data: lastGoodData,
            updatedAt: cache.lastGoodTimestamp ?? cache.timestamp,
            isFresh: false
        )
    }

    func write(
        data: RemoteUsageData,
        timestamp: Date,
        credentialCacheKey: String? = nil,
        rateLimitedCount: Int? = nil,
        retryAfterUntil: Date? = nil,
        lastGoodData: RemoteUsageData? = nil,
        lastGoodTimestamp: Date? = nil,
        forceRefresh: Bool? = nil
    ) throws {
        guard enabled else { return }
        let record = ClaudeUsageCacheRecord(
            data: data,
            timestamp: timestamp,
            credentialCacheKey: credentialCacheKey,
            rateLimitedCount: rateLimitedCount,
            retryAfterUntil: retryAfterUntil,
            lastGoodData: lastGoodData,
            lastGoodTimestamp: lastGoodTimestamp,
            forceRefresh: forceRefresh
        )
        let directory = cacheURL.deletingLastPathComponent()
        if fileManager.fileExists(atPath: directory.path) == false {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        try data.write(to: cacheURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
    }

    // After a coupon cleared the limits: the next refresh asks again instead of showing the last minute's numbers. A
    // wait the service asked for still holds. The time of the last read stays, so if that next read is refused (429)
    // the numbers still say when they are from, not "56 years ago" (jsiksn/limi#1 by chenjingdev).
    func expire() {
        guard let cache = try? readRaw(), cache.data.apiError != "rate-limited" else { return }
        try? write(data: cache.data, timestamp: cache.timestamp, credentialCacheKey: cache.credentialCacheKey,
                   lastGoodData: cache.lastGoodData, lastGoodTimestamp: cache.lastGoodTimestamp, forceRefresh: true)
    }

    private func displayState(from cache: ClaudeUsageCacheRecord) -> ClaudeUsageCacheState {
        if cache.data.apiError == "rate-limited", let lastGoodData = cache.lastGoodData {
            return ClaudeUsageCacheState(
                data: lastGoodData.with(apiUnavailable: true, apiError: "rate-limited"),
                updatedAt: cache.lastGoodTimestamp ?? cache.timestamp,
                isFresh: false
            )
        }

        return ClaudeUsageCacheState(
            data: cache.data,
            updatedAt: cache.timestamp,
            isFresh: false
        )
    }

    private func rateLimitedRetryUntil(for cache: ClaudeUsageCacheRecord) -> Date? {
        guard cache.data.apiError == "rate-limited" else { return nil }

        if let retryAfterUntil = cache.retryAfterUntil, retryAfterUntil > cache.timestamp {
            return retryAfterUntil
        }

        guard let rateLimitedCount = cache.rateLimitedCount, rateLimitedCount > 0 else {
            return nil
        }

        let exponent = max(0, rateLimitedCount - 1)
        let backoff = min(
            ClaudeUsagePolicy.rateLimitedBaseTTL * pow(2.0, Double(exponent)),
            ClaudeUsagePolicy.rateLimitedMaxTTL
        )
        return cache.timestamp.addingTimeInterval(backoff)
    }
}

// Credits: from the usage answer, plus the prepaid balance for Pro and Max, kept next to the usage cache so a read
// answered from the cache still shows them.
extension ClaudeUsageProvider {
    private var creditsRecordURL: URL? { cacheURL.map { ClaudeCreditsRecord.url(nextTo: $0) } }

    func creditsRecord() -> ClaudeCreditsRecord? {
        guard let url = creditsRecordURL, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ClaudeCreditsRecord.self, from: data)
    }

    fileprivate func noteCredits(answer: Data?, credentials: ClaudeCredentials, now: Date = .now) async -> AccountCredits? {
        let previous = creditsRecord()
        var record = previous ?? ClaudeCreditsRecord()
        if let answer { record.usageItems = ClaudeCredits.credits(fromUsage: answer) }
        let plan = credentials.subscriptionType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let due = record.prepaidChecked.map { now.timeIntervalSince($0) >= ClaudeCreditsRecord.prepaidInterval } ?? true
        if cacheURL != nil, plan == "max" || plan == "pro", due,
           let organization = (try? statusReader(directory, control))?.organizationID,
           let url = URL(string: "https://api.anthropic.com/api/oauth/organizations/\(organization)/prepaid/credits") {
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue(couponUserAgent(), forHTTPHeaderField: "User-Agent")
            if let (data, response) = try? await transport(request) {
                record.prepaidChecked = now
                if (response as? HTTPURLResponse)?.statusCode == 200 { record.prepaid = ClaudeCredits.prepaid(from: data) }
            }
        }
        // An Admin API key kept next to the account's login (`anthropic-admin-key`) brings this month's Console API spend.
        let apiDue = record.apiSpendChecked.map { now.timeIntervalSince($0) >= ClaudeCreditsRecord.prepaidInterval } ?? true
        if cacheURL != nil, apiDue,
           let key = (try? String(contentsOf: directory.appendingPathComponent("anthropic-admin-key"), encoding: .utf8))?
               .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            let start = calendar.dateInterval(of: .month, for: now)?.start ?? now
            let stamp = ISO8601DateFormatter().string(from: start)
            if let url = URL(string: "https://api.anthropic.com/v1/organizations/cost_report?starting_at=\(stamp)&bucket_width=1d&limit=31") {
                var request = URLRequest(url: url)
                request.timeoutInterval = 15
                request.setValue(key, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                if let (data, response) = try? await transport(request) {
                    record.apiSpendChecked = now
                    if (response as? HTTPURLResponse)?.statusCode == 200 { record.apiSpend = ClaudeCredits.apiSpend(fromCostReport: data) }
                }
            }
        }
        if record != previous, let url = creditsRecordURL {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(record) {
                try? data.write(to: url, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        }
        return record.credits
    }
}

// Usage-reset coupons ("cedar_ember"). The usage read asks for them too now and then (`ClaudeCouponRecord`), only for an
// account with a usage cache, which is every account in the app; one is used only when a person confirms.
extension ClaudeUsageProvider {
    private var couponRecordURL: URL? { cacheURL.map { ClaudeCouponRecord.url(nextTo: $0) } }

    func couponRecord() -> ClaudeCouponRecord? {
        guard let url = couponRecordURL, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        // A record read with another Claude Code version still shows; `couponsDue` reads it again with this one.
        guard let record = try? decoder.decode(ClaudeCouponRecord.self, from: data),
              record.includesConditions == true else { return nil }
        return record
    }

    // Whether this read should also ask for the coupons. Never without a usage cache, so tests and the claim do not.
    func couponsDue(now: Date = .now) -> Bool {
        guard cacheURL != nil else { return false }
        guard let record = couponRecord(), record.userAgent == couponUserAgent() else { return true }
        return now >= record.nextCheck || (record.coupons != nil && record.coupons?.options == nil)
    }

    // The coupons to show after a read: from its answer when it asked for them, else what was last known, less any
    // whose last day has passed.
    func noteCoupons(answer: Data?, subscriptionType: String = "", refused: Bool = false, now: Date = .now) -> UsageResetCoupons? {
        let agent = couponUserAgent()
        let plan = subscriptionType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // The usage response can omit the 5h window before it has data.
        let planHasFiveHour = plan == "max" || plan == "pro"
        let previous = couponRecord()
        var record = ClaudeCouponRecord(coupons: previous?.coupons, nextCheck: previous?.nextCheck ?? now,
                                        userAgent: agent, includesConditions: true)
        record.coupons = record.coupons?.pruningExpired(now: now)
        // A refused coupon flag says nothing about the coupons; ask again a little later, not with every read.
        if refused { record.nextCheck = now.addingTimeInterval(ClaudeCouponRecord.failureInterval) }
        if let answer {
            let block = ClaudeCedar.block(from: answer)
            if let block, block.eligible != true, block.ineligibleReason == "unavailable" {
                // A service fault says nothing about the coupons; keep what was known.
                record.nextCheck = now.addingTimeInterval(ClaudeCouponRecord.failureInterval)
            } else {
                let hasFiveHour = (try? JSONDecoder().decode(UsageApiResponse.self, from: answer))?.fiveHour != nil
                    || planHasFiveHour
                record.coupons = block.flatMap { ClaudeCedar.coupons($0, hasFiveHour: hasFiveHour, now: now) }
                if block?.eligible == true {
                    let waiting = record.coupons?.options?.contains(where: { !$0.canRedeem }) == true
                    record.nextCheck = now.addingTimeInterval(waiting ? ClaudeCouponRecord.failureInterval
                                                                    : ClaudeCouponRecord.interval)
                } else {
                    record.nextCheck = now.addingTimeInterval(ClaudeCouponRecord.ineligibleInterval)
                }
            }
        }
        if record != previous, let url = couponRecordURL {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(record) {
                try? data.write(to: url, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        }
        return record.coupons
    }

    // Uses the grant in `coupons.claim` for the account in `directory`. Its organization comes from the account's own
    // config file, the way Claude Code finds it.
    func useCoupon(_ coupons: UsageResetCoupons) async -> CouponOutcome {
        guard coupons.canRedeem, case .claudeGrant(let grant) = coupons.claim else { return .tryLater }
        let couponAgent = couponUserAgent()
        return await Task.detached(priority: .userInitiated) { () -> CouponOutcome in
            guard let identity = try? statusReader(directory, control),
                  expectedIdentity?.comparison(to: identity) != .different,
                  let organization = identity.organizationID,
                  let url = ClaudeCedar.claimURL(organization: organization) else { return .signInAgain }
            let credentials: ClaudeCredentials
            do {
                var read = try readCredentials(allowExpired: true)
                if read.isExpired {
                    try await ClaudeCredentialRefresher.shared.refresh(data: read.rawData, directory: directory, transport: transport)
                    read = try readCredentials()
                }
                credentials = read
            } catch {
                return Self.requiresLogin(for: error) ? .signInAgain : .tryLater
            }
            let claimKey = organization + ":" + grant
            let retryID = await ClaudeClaimMemory.shared.pendingRequestID(for: claimKey)
            if retryID == nil {
                do {
                    let check = try makeUsageRequest(accessToken: credentials.accessToken, withCoupons: true)
                    try control.checkCancellation()
                    let (data, response) = try await transport(check)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if status == 401 { return .signInAgain }
                    // A read right after the panel's own read is refused (429), and the coupons were chosen from that
                    // fresh read: go on without the check, as Claude Code does. Claude still checks the grant itself.
                    if status != 429 {
                        guard status == 200, let block = ClaudeCedar.block(from: data) else { return .tryLater }
                        let current = noteCoupons(answer: data, subscriptionType: credentials.subscriptionType)
                        let options = current.map { $0.options ?? [$0.selectedOption] } ?? []
                        guard ClaudeCedar.canRedeem(grant, in: block),
                              let selected = options.first(where: { $0.claim == coupons.claim && $0.scope == coupons.scope }),
                              selected.canRedeem,
                              selected.affectedUsagePercent != 0 || coupons.affectedUsagePercent == 0 else { return .conditionsChanged }
                    }
                } catch {
                    return .tryLater
                }
            }
            guard (try? readCredentials().cacheKey) == credentials.cacheKey else { return .signInAgain }
            let requestID = retryID ?? UUID().uuidString.lowercased()
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 25
            request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(couponAgent, forHTTPHeaderField: "User-Agent")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["program": "cedar_ember", "grant_id": grant, "request_id": requestID])
            do {
                try control.checkCancellation()
                let (data, response) = try await transport(request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                switch status {
                case 200...299:
                    let answer = ClaudeCedar.outcome(data)
                    if answer.unconfirmed { await ClaudeClaimMemory.shared.remember(requestID, for: claimKey) }
                    else { await ClaudeClaimMemory.shared.forget(claimKey) }
                    return answer.outcome
                case 401: return .signInAgain
                case 403: return AnthropicAccessBlock.matches(status: status, body: data) ? .tryLater : .signInAgain
                case 429: return .tryLater
                default:
                    // It may have gone through; a second press sends the same request id.
                    await ClaudeClaimMemory.shared.remember(requestID, for: claimKey)
                    return .tryLater
                }
            } catch {
                await ClaudeClaimMemory.shared.remember(requestID, for: claimKey)
                return .tryLater
            }
        }.value
    }
}
