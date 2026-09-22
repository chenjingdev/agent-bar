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
        let legacy = $0.appendingPathComponent(".config.json")
        let path = FileManager.default.fileExists(atPath: legacy.path) ? legacy : $0.appendingPathComponent(".claude.json")
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any],
              let account = object["oauthAccount"] as? [String: Any] else { throw AccountError.loginRequired }
        return AccountIdentity(email: account["emailAddress"] as? String,
            organization: account["organizationName"] as? String, organizationID: account["organizationUuid"] as? String,
            stableID: account["accountUuid"] as? String)
    }
    var keychainReader: @Sendable (String, String?) throws -> Data? = {
        try BackgroundKeychain.read(service: $0, account: $1)
    }
    var transport: @Sendable (URLRequest) async throws -> (Data, URLResponse) = {
        try await URLSession.shared.data(for: $0)
    }

    func load() async -> ProviderSnapshot {
        await Task.detached(priority: .utility) {
            do {
                try control.checkCancellation()
                if let expectedIdentity {
                    let current = try statusReader(directory, control)
                    if current.comparison(to: expectedIdentity) == .different {
                        throw AccountError.message("The linked Claude account has changed. Reconnect to confirm it.")
                    }
                }
                try control.checkCancellation()
                var credentials = try readCredentials(allowExpired: true)
                if credentials.isExpired {
                    try await ClaudeCredentialRefresher.shared.refresh(data: credentials.rawData, directory: directory, transport: transport)
                    try control.checkCancellation()
                    credentials = try readCredentials()
                }
                let remoteResult = try await resolveRemoteUsage(credentials: credentials)
                guard credentials.cacheKey == (try readCredentials().cacheKey) else {
                    throw AccountError.message("The CLI account changed during the request. Refresh again.")
                }
                let modelWeeklies: [ModelWeeklySummary] = (remoteResult.data.modelWeeklies ?? []).map { cached in
                    ModelWeeklySummary(
                        label: cached.label,
                        window: cached.usedPercent.map {
                            WindowSummary(tokens: $0, limitTokens: 100, resetAt: cached.resetAt, displayStyle: .percentage)
                        } ?? WindowSummary(tokens: 0, limitTokens: 0, resetAt: cached.resetAt, displayStyle: .percentage)
                    )
                }
                return ProviderSnapshot(
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
            } catch {
                let requiresLogin = Self.requiresLogin(for: error)
                return ProviderSnapshot(
                    provider: .claude,
                    updatedAt: .now,
                    fiveHour: WindowSummary(tokens: 0, limitTokens: 0, resetAt: nil, displayStyle: .percentage),
                    weekly: WindowSummary(tokens: 0, limitTokens: 0, resetAt: nil, displayStyle: .percentage),
                    modelWeeklies: [],
                    planName: nil,
                    sourceDescription: "Anthropic OAuth usage API + cache",
                    note: requiresLogin
                        ? "Sign-in required. Reconnect this account in Settings › Accounts."
                        : "Couldn't read Anthropic account usage: \(error.localizedDescription)",
                    isStale: true,
                    requiresLogin: requiresLogin
                )
            }
        }.value
    }

    private func resolveRemoteUsage(credentials: ClaudeCredentials) async throws -> RemoteUsageResult {
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
        let apiResult = await fetchUsageApi(accessToken: credentials.accessToken)

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
                sourceDescription: sourceDescription(for: successData)
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
            try? cache.write(data: failureData, timestamp: now, credentialCacheKey: credentials.cacheKey)
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
            if Self.requiresLogin(for: data.apiError) {
                return "Claude login required. Sign in to Claude Code, then refresh."
            }
            if data.apiError == "rate-limited" {
                return "The Anthropic usage API is rate-limited. Showing the last known good value and retrying automatically."
            }
            return "Couldn't read the Anthropic usage API (\(data.apiError ?? "unknown"))."
        }
        switch data.usageSource {
        case .statusLine:
            return "Showing Claude Code live rate_limits from your active status line session."
        case .oauthApi:
            if let weeklyWindowLabel = data.weeklyWindowLabel {
                return "Anthropic did not return an account-wide weekly window, so Weekly is following the \(weeklyWindowLabel) window."
            }
            return "Showing account-wide Anthropic usage API data."
        case nil:
            return "Showing account-wide Anthropic usage API data."
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

    private func fetchUsageApi(accessToken: String) async -> UsageApiResult {
        do {
            let request = try makeUsageRequest(accessToken: accessToken)
            try control.checkCancellation()
            let (data, response) = try await transport(request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return UsageApiResult(data: nil, error: "invalid-response", retryAfterSeconds: nil)
            }

            guard httpResponse.statusCode == 200 else {
                let error = httpResponse.statusCode == 429 ? "rate-limited" : "http-\(httpResponse.statusCode)"
                let retryAfterSeconds = httpResponse.statusCode == 429
                    ? Self.parseRetryAfterSeconds(httpResponse.value(forHTTPHeaderField: "Retry-After"))
                    : nil
                return UsageApiResult(data: nil, error: error, retryAfterSeconds: retryAfterSeconds)
            }

            do {
                let payload = try JSONDecoder().decode(UsageApiResponse.self, from: data)
                return UsageApiResult(data: payload, error: nil, retryAfterSeconds: nil)
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

    private func makeUsageRequest(accessToken: String) throws -> URLRequest {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            throw ClaudeUsageError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func readCredentials(allowExpired: Bool = false) throws -> ClaudeCredentials {
        // Every reader has an explicit account-owned directory. There is no
        // fallback to ~/.claude, environment overrides, or the shared Keychain.
        if let credentials = try? readFileCredentials(configDirectory: directory, allowExpired: allowExpired) {
            return credentials
        }
        let service = AccountFiles.claudeService(directory)
        let loaded = try loadKeychainCredentials(serviceName: service, accountName: NSUserName(), allowExpired: allowExpired)
            ?? loadKeychainCredentials(serviceName: service, accountName: nil, allowExpired: allowExpired)
        guard let loaded else { throw ClaudeUsageError.missingCredentials }
        let file = directory.appendingPathComponent(".credentials.json")
        try loaded.data.write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return loaded.credentials
    }

    private func loadKeychainCredentials(
        serviceName: String,
        accountName: String?, allowExpired: Bool
    ) throws -> (credentials: ClaudeCredentials, data: Data)? {
        try control.checkCancellation()
        guard let data = try keychainReader(serviceName, accountName), !data.isEmpty else { return nil }

        let credentialsFile = try JSONDecoder().decode(CredentialsFile.self, from: data)
        guard let accessToken = credentialsFile.claudeAiOauth?.accessToken, accessToken.isEmpty == false else {
            return nil
        }

        if !allowExpired, let expiresAt = credentialsFile.claudeAiOauth?.expiresAt, expiresAt <= Int(Date().timeIntervalSince1970 * 1000) {
            return nil
        }

        return (ClaudeCredentials(
            accessToken: accessToken,
            subscriptionType: credentialsFile.claudeAiOauth?.subscriptionType ?? "",
            cacheKey: Self.cacheKey(for: data), rawData: data, expiresAt: credentialsFile.claudeAiOauth?.expiresAt
        ), data)
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
        if case BackgroundKeychain.ReadError.authorizationRequired = error { return true }
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
            return "Invalid usage URL"
        case .missingCredentials:
            return "Couldn't find a Claude OAuth token."
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
            isFresh: now.timeIntervalSince(cache.timestamp) < ttl
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
        lastGoodTimestamp: Date? = nil
    ) throws {
        guard enabled else { return }
        let record = ClaudeUsageCacheRecord(
            data: data,
            timestamp: timestamp,
            credentialCacheKey: credentialCacheKey,
            rateLimitedCount: rateLimitedCount,
            retryAfterUntil: retryAfterUntil,
            lastGoodData: lastGoodData,
            lastGoodTimestamp: lastGoodTimestamp
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
