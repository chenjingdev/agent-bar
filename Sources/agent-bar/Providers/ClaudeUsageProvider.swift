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
    // Skips a fresh cached reply, but not a rate-limit backoff. Used right after a reset.
    var forceFetch = false
    var resetLog: LimitResetLog? = nil
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
                    requiresLogin: Self.requiresLogin(for: remoteResult.data.apiError),
                    usageLimitResets: remoteResult.data.usageLimitResets,
                    claudeCredits: remoteResult.data.claudeCredits
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

        if let cacheState = try? cache.readState(now: now, credentialCacheKey: credentials.cacheKey), cacheState.isFresh,
           !forceFetch || cacheState.data.apiError == "rate-limited" {
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
                weeklyWindowLabel: selectedWeeklyWindow?.label,
                usageLimitResets: payload.resetStatus?.usageLimitResets(),
                claudeCredits: apiResult.credits
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
        let result = await fetchUsageApi(accessToken: accessToken, url: Self.usageWithResetsURL)
        // Usage matters more than resets. If the reset flag is refused, read plain usage.
        guard let status = result.httpStatus, (400..<500).contains(status), ![401, 403, 429].contains(status) else {
            return result
        }
        resetLog?.recordStatus("reset flag refused (HTTP \(status))", ["url": Self.usageWithResetsURL, "httpStatus": status])
        return await fetchUsageApi(accessToken: accessToken, url: Self.usageURL)
    }

    private func fetchUsageApi(accessToken: String, url: String) async -> UsageApiResult {
        do {
            let request = try makeUsageRequest(accessToken: accessToken, url: url)
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
                return UsageApiResult(data: nil, error: error, retryAfterSeconds: retryAfterSeconds,
                                      httpStatus: httpResponse.statusCode)
            }

            do {
                let payload = try JSONDecoder().decode(UsageApiResponse.self, from: data)
                let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                if url == Self.usageWithResetsURL { recordResetStatus(payload.resetStatus, raw: reply?["cedar_ember"]) }
                return UsageApiResult(data: payload, error: nil, retryAfterSeconds: nil, httpStatus: 200,
                                      credits: reply.flatMap(ClaudeCredits.parse))
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

    // Refresh reports any refusal or malformed reset block once, until it changes.
    private func recordResetStatus(_ status: ClaudeResetStatus?, raw: Any?) {
        guard let resetLog else { return }
        let summary = status.map { String(describing: $0.usageLimitResets()) }
            ?? (raw == nil || raw is NSNull ? "not reported" : "unreadable")
        resetLog.recordStatus(summary, ["cedar_ember": raw as Any])
    }

    private static let usageURL = "https://api.anthropic.com/api/oauth/usage"
    // The same usage reply plus Claude's usage limit reset program (`cedar_ember`).
    private static let usageWithResetsURL = usageURL + "?cedar_ember=1"
    // Claude Code reads the program this way before it uses a reset; skip_spend leaves out
    // the extra-usage spend it does not need.
    private static let resetStatusURL = usageURL + "?cedar_ember=1&skip_spend=1"

    // Claude Code's API client sends this header to the usage and reset endpoints, and the reset
    // program reads the CLI version (`cli_version`) and surface (`surface`) from it. Without it
    // Claude reports the account ineligible with reason `surface` and lists no grants. Below some
    // version it reports reason `cli_version` (2.1.200 and an unreadable "2.1" were refused on
    // 2026-10-09; 2.1.295 was accepted), so an older or undetected CLI sends that version.
    static var userAgent: String { "claude-cli/\(userAgentVersion(installed: installedVersion)) (external, cli)" }

    static let minimumResetVersion = "2.1.295"

    static func userAgentVersion(installed: String?) -> String {
        guard let installed else { return minimumResetVersion }
        let parts = { (version: String) in version.split(separator: ".").map { Int($0) ?? 0 } }
        return parts(installed).lexicographicallyPrecedes(parts(minimumResetVersion)) ? minimumResetVersion : installed
    }

    private static var installedVersion: String? {
        guard let executable = try? ProviderCLI.executable(.claude) else { return nil }
        let pattern = #"^\d+\.\d+\.\d+$"#
        if let version = executable.pathComponents.reversed().first(where: { $0.range(of: pattern, options: .regularExpression) != nil }) {
            return version
        }
        // npm and Bun installs keep the version in the package beside the entry point.
        let package = executable.deletingLastPathComponent().appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: package),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? String,
              version.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return version
    }

    private func makeUsageRequest(accessToken: String, url: String) throws -> URLRequest {
        guard let url = URL(string: url) else {
            throw ClaudeUsageError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
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
    var usageLimitResets: UsageLimitResets? = nil
    var claudeCredits: ClaudeCredits? = nil

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
            weeklyWindowLabel: weeklyWindowLabel,
            usageLimitResets: usageLimitResets,
            claudeCredits: claudeCredits
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
    let resetStatus: ClaudeResetStatus?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOauthApps = "seven_day_oauth_apps"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case limits
        case resetStatus = "cedar_ember"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fiveHour = try c.decodeIfPresent(UsageWindowPayload.self, forKey: .fiveHour)
        sevenDay = try c.decodeIfPresent(UsageWindowPayload.self, forKey: .sevenDay)
        sevenDayOauthApps = try c.decodeIfPresent(UsageWindowPayload.self, forKey: .sevenDayOauthApps)
        sevenDayOpus = try c.decodeIfPresent(UsageWindowPayload.self, forKey: .sevenDayOpus)
        sevenDaySonnet = try c.decodeIfPresent(UsageWindowPayload.self, forKey: .sevenDaySonnet)
        limits = try c.decodeIfPresent([UsageLimitPayload].self, forKey: .limits)
        // Resets are an extra. A changed shape must not hide the usage windows.
        resetStatus = try? c.decodeIfPresent(ClaudeResetStatus.self, forKey: .resetStatus)
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
    var httpStatus: Int? = nil
    var credits: ClaudeCredits? = nil
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

extension ClaudeUsageProvider {
    // Uses the reset grant the person picked the way Claude Code uses one: read the reset
    // program, then claim that grant with a fresh request ID. Claude only takes the grant it
    // names next, so any other grant is not claimed.
    func redeemLimitReset(couponID: String, log: LimitResetLog) async -> LimitResetResult {
        await Task.detached(priority: .userInitiated) {
            var step = "account"
            do {
                let identity = try statusReader(directory, control)
                if let expectedIdentity, identity.comparison(to: expectedIdentity) == .different {
                    log.record("stopped", ["step": step, "reason": "The signed-in Claude account differs from the linked one."])
                    return LimitResetResult(succeeded: false, message: "The linked Claude account has changed. Reconnect it in Settings › Accounts.")
                }
                guard let organization = identity.organizationID ?? expectedIdentity?.organizationID,
                      UUID(uuidString: organization) != nil else {
                    log.record("stopped", ["step": step, "reason": "No organization UUID for this account.",
                                           "organization": identity.organizationID as Any])
                    return LimitResetResult(succeeded: false, message: "Claude did not record this account's organization. Reconnect it in Settings › Accounts.")
                }

                step = "credentials"
                var credentials = try readCredentials(allowExpired: true)
                if credentials.isExpired {
                    log.record("credentials", ["action": "Refreshing an expired sign-in."])
                    try await ClaudeCredentialRefresher.shared.refresh(data: credentials.rawData, directory: directory, transport: transport)
                    credentials = try readCredentials()
                }

                step = "status"
                let statusRequest = try makeUsageRequest(accessToken: credentials.accessToken, url: Self.resetStatusURL)
                let (statusData, statusResponse) = try await transport(statusRequest)
                let statusCode = (statusResponse as? HTTPURLResponse)?.statusCode
                log.record("status", ["method": "GET", "url": Self.resetStatusURL, "httpStatus": statusCode as Any,
                                      "headers": Self.headers(statusResponse), "body": LimitResetLog.body(statusData)])
                guard statusCode == 200 else { return Self.failure(httpStatus: statusCode, while: "reading the resets") }
                guard let status = (try? JSONDecoder().decode(UsageApiResponse.self, from: statusData))?.resetStatus else {
                    return LimitResetResult(succeeded: false, message: "Claude did not report usage limit resets for this account.")
                }
                guard status.eligible else {
                    return LimitResetResult(succeeded: false,
                        message: "Resets are not available for this account (\(status.ineligibleReason ?? "unknown")).")
                }
                // The next grant is always a listed one.
                guard status.nextGrantID == couponID else {
                    let listed = status.grants.contains { $0.id == couponID }
                    log.record("stopped", ["step": step, "grant": couponID, "listed": listed, "nextGrant": status.nextGrantID as Any,
                                           "reason": "The chosen grant is not the one Claude takes next."])
                    return LimitResetResult(succeeded: false, message: !listed ? "Claude no longer lists that reset. Refresh and pick another."
                        : status.nextGrantID == nil ? "Claude has no reset to use right now."
                        : "Claude uses another reset first. Refresh to see which one.")
                }

                step = "claim"
                let body = ["program": "cedar_ember", "grant_id": couponID, "request_id": UUID().uuidString.lowercased()]
                var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/organizations/\(organization)/reset_rate_limits")!)
                request.httpMethod = "POST"
                request.timeoutInterval = 25
                request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
                request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
                request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                log.record("request", ["method": "POST", "url": request.url as Any, "body": body,
                                       "headers": (request.allHTTPHeaderFields ?? [:]).filter { $0.key.lowercased() != "authorization" }])
                let (data, response) = try await transport(request)
                let code = (response as? HTTPURLResponse)?.statusCode
                log.record("response", ["httpStatus": code as Any, "headers": Self.headers(response), "body": LimitResetLog.body(data)])
                guard let code, (200..<300).contains(code) else { return Self.failure(httpStatus: code, while: "using the reset") }
                guard let claim = try? JSONDecoder().decode(ClaudeResetClaim.self, from: data) else {
                    return LimitResetResult(succeeded: false, message: "Claude's answer could not be read. Refresh to see whether the reset applied.")
                }
                return claim.outcome()
            } catch {
                log.record("error", ["step": step, "error": String(describing: error), "message": error.localizedDescription])
                if step == "claim" {
                    return LimitResetResult(succeeded: false,
                        message: "The reset request did not complete: \(error.localizedDescription) Refresh to see whether it applied.")
                }
                return LimitResetResult(succeeded: false, message: error.localizedDescription)
            }
        }.value
    }

    private static func headers(_ response: URLResponse) -> [String: Any] {
        guard let response = response as? HTTPURLResponse else { return [:] }
        var headers: [String: Any] = [:]
        for (key, value) in response.allHeaderFields { headers[String(describing: key)] = String(describing: value) }
        return headers
    }

    private static func failure(httpStatus: Int?, while action: String) -> LimitResetResult {
        let message: String
        switch httpStatus {
        case 429?: message = "Claude is limiting requests. Try again in a few minutes."
        case let code? where code == 401 || code == 403:
            message = "Claude refused the request (HTTP \(code)). Refresh, or reconnect the account in Settings › Accounts."
        case let code?: message = "Claude returned HTTP \(code) while \(action)."
        case nil: message = "Claude sent no readable reply while \(action)."
        }
        return LimitResetResult(succeeded: false, message: message)
    }
}

// Claude's usage limit reset program (`cedar_ember` in the usage reply), read as leniently as
// Claude Code reads it: a malformed grant is skipped and a malformed optional field is absent.
struct ClaudeResetStatus: Decodable {
    let eligible: Bool
    let ineligibleReason: String?
    let atLimit: Bool
    let grants: [Grant]
    let nextGrantID: String?
    let cooldownUntil: String?

    struct Grant: Decodable {
        let id: String
        let label: String?
        let resetsLeft: Int
        let endsAt: String?
        let clears: [String]
        let paused: Bool
        let useRequiresLimit: Bool

        enum CodingKeys: String, CodingKey {
            case id, label, clears, paused
            case resetsLeft = "resets_left"
            case endsAt = "ends_at"
            case useRequiresLimit = "use_requires_limit"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            resetsLeft = try c.decode(Int.self, forKey: .resetsLeft)
            guard ClaudeResetStatus.isGrantID(id), resetsLeft >= 0 else {
                throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "Malformed grant.")
            }
            label = (try? c.decodeIfPresent(String.self, forKey: .label)).flatMap { $0.isEmpty ? nil : $0 }
            endsAt = try? c.decodeIfPresent(String.self, forKey: .endsAt)
            clears = (try? c.decodeIfPresent([String].self, forKey: .clears)) ?? []
            paused = (try? c.decodeIfPresent(Bool.self, forKey: .paused)) ?? false
            useRequiresLimit = (try? c.decodeIfPresent(Bool.self, forKey: .useRequiresLimit)) ?? true
        }
    }

    private struct Lenient<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }

    enum CodingKeys: String, CodingKey {
        case eligible, grants
        case ineligibleReason = "ineligible_reason"
        case atLimit = "at_limit"
        case nextGrantID = "next_grant_id"
        case cooldownUntil = "cooldown_until"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        eligible = try c.decode(Bool.self, forKey: .eligible)
        ineligibleReason = try? c.decodeIfPresent(String.self, forKey: .ineligibleReason)
        atLimit = (try? c.decodeIfPresent(Bool.self, forKey: .atLimit)) ?? false
        let listed = ((try? c.decodeIfPresent([Lenient<Grant>].self, forKey: .grants)) ?? []).compactMap(\.value)
        grants = listed
        // Like Claude Code, only a listed grant can be the next one.
        let next = try? c.decodeIfPresent(String.self, forKey: .nextGrantID)
        nextGrantID = next.flatMap { id in listed.contains { $0.id == id } ? id : nil }
        cooldownUntil = try? c.decodeIfPresent(String.self, forKey: .cooldownUntil)
    }

    static func isGrantID(_ id: String) -> Bool {
        id.range(of: #"^[a-z0-9_-]{1,40}$"#, options: .regularExpression) != nil
    }

    // Claude Code counts the remaining resets of every listed grant, and uses only the grant the
    // program names next. Each grant with resets left is a coupon.
    func usageLimitResets(now: Date = .now) -> UsageLimitResets {
        let open = eligible && !(Self.date(cooldownUntil).map { $0 > now } ?? false)
        let coupons = grants.filter { $0.resetsLeft > 0 }.map { grant in
            var coupon = UsageLimitResets.Coupon(id: grant.id, title: grant.label, count: min(grant.resetsLeft, 9_999),
                                                 expiresAt: Self.date(grant.endsAt), usable: false,
                                                 clears: grant.clears.isEmpty ? nil : grant.clears.compactMap(Self.metricID))
            if open, let nextGrantID {
                if grant.id != nextGrantID { coupon.note = "Claude uses another reset first." }
                else if grant.paused { coupon.note = "Paused." }
                else if grant.useRequiresLimit && !atLimit { coupon.note = "Usable once a usage limit is reached." }
                else { coupon.usable = true }
            }
            return coupon
        }
        let available = coupons.reduce(0) { $0 + $1.count }
        return UsageLimitResets(available: available, unsorted: coupons, notice: notice(available: available, now: now))
    }

    // What keeps every coupon from being used; a single coupon's reason is its note.
    private func notice(available: Int, now: Date) -> String? {
        if ineligibleReason == "cli_version" { return "Not available until Claude Code is updated (cli_version)." }
        if !eligible { return "Not available for this account (\(ineligibleReason ?? "unknown"))." }
        if let cooldown = Self.date(cooldownUntil), cooldown > now {
            return "Cooling down until \(TokenFormatters.expiryDateString(cooldown))."
        }
        if available > 0 && nextGrantID == nil { return "No reset can be used right now." }
        return nil
    }

    // The popover metric for a limit a grant clears. Claude Code calls seven_day_overage_included
    // the Fable limit.
    static func metricID(_ limit: String) -> String? {
        switch limit {
        case "five_hour": return "5h"
        case "seven_day": return "weekly"
        case "seven_day_overage_included": return "model:fable"
        case "seven_day_opus": return "model:opus"
        case "seven_day_sonnet": return "model:sonnet"
        default: return nil
        }
    }

    static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = precise.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}

extension ClaudeCredits {
    // Reads the reply the way Claude Code's /usage screen does: a window priced in dollars, other
    // than the plan's 5-hour and weekly limits, is a one-time credit titled by its label or
    // "Credit"; `extra_usage` amounts are minor units; `spend.balance` is the prepaid balance.
    // Nil when the reply reports none of them.
    static func parse(_ reply: [String: Any]) -> ClaudeCredits? {
        var credits = ClaudeCredits()
        for (key, value) in reply.sorted(by: { $0.key < $1.key }) where !key.hasPrefix("five_hour") && !key.hasPrefix("seven_day") {
            guard let window = value as? [String: Any], let limit = number(window["limit_dollars"]) else { continue }
            let used = number(window["used_dollars"]) ?? 0
            let label = (window["label"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            credits.oneTime.append(OneTime(title: label ?? "Credit", used: used, limit: limit,
                remaining: number(window["remaining_dollars"]) ?? max(0, limit - used),
                expiresAt: ClaudeResetStatus.date(window["resets_at"] as? String),
                lockedReason: window["locked_reason"] as? String))
        }
        if let extra = reply["extra_usage"] as? [String: Any], let enabled = extra["is_enabled"] as? Bool {
            let scale = pow(10, number(extra["decimal_places"]) ?? 2)
            credits.extraUsage = ExtraUsage(enabled: enabled, used: number(extra["used_credits"]).map { $0 / scale },
                monthlyLimit: number(extra["monthly_limit"]).map { $0 / scale },
                currency: extra["currency"] as? String ?? "USD")
        }
        if let balance = (reply["spend"] as? [String: Any])?["balance"] as? [String: Any],
           let minor = number(balance["amount_minor"]) {
            credits.prepaidBalance = minor / pow(10, number(balance["exponent"]) ?? 2)
            credits.prepaidCurrency = balance["currency"] as? String ?? "USD"
        }
        return credits.isEmpty ? nil : credits
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else {
            return nil
        }
        return number.doubleValue
    }
}

// Claude's answer to a reset claim. An unknown result is kept so the message can name it.
struct ClaudeResetClaim: Decodable {
    let result: String
    let reason: String?
    let resetsLeft: Int?
    let cleared: [String]
    let cooldownUntil: String?

    enum CodingKeys: String, CodingKey {
        case result, reason, cleared
        case resetsLeft = "resets_left"
        case cooldownUntil = "cooldown_until"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        result = (try? c.decode(String.self, forKey: .result)) ?? "unavailable"
        reason = try? c.decodeIfPresent(String.self, forKey: .reason)
        resetsLeft = try? c.decodeIfPresent(Int.self, forKey: .resetsLeft)
        cleared = (try? c.decodeIfPresent([String].self, forKey: .cleared)) ?? []
        cooldownUntil = try? c.decodeIfPresent(String.self, forKey: .cooldownUntil)
    }

    func outcome() -> LimitResetResult {
        switch result {
        case "reset":
            var message = "Usage limits reset"
            if !cleared.isEmpty { message += ": " + cleared.map(Self.limitName).joined(separator: ", ") }
            if let resetsLeft { message += " · \(resetsLeft) left" }
            return LimitResetResult(succeeded: true, message: message + ".")
        case "already_used": return LimitResetResult(succeeded: false, message: "That reset was already used.")
        case "not_limited": return LimitResetResult(succeeded: false, message: "Nothing to reset: no usage limit is reached.")
        case "cooldown":
            let until = ClaudeResetStatus.date(cooldownUntil).map { " until \(TokenFormatters.expiryDateString($0))" } ?? ""
            return LimitResetResult(succeeded: false, message: "Resets are cooling down\(until).")
        case "ineligible":
            return LimitResetResult(succeeded: false, message: "Not eligible for a reset (\(reason ?? "unknown")).")
        case "unavailable":
            return LimitResetResult(succeeded: false, message: "Resets are unavailable right now (\(reason ?? "unknown")).")
        default:
            return LimitResetResult(succeeded: false, message: "Claude gave an unexpected answer (\(result)). Details are in the reset log.")
        }
    }

    static func limitName(_ limit: String) -> String {
        switch limit {
        case "five_hour": return "5-hour"
        case "seven_day": return "weekly"
        case "seven_day_opus": return "Opus weekly"
        case "seven_day_sonnet": return "Sonnet weekly"
        case "seven_day_overage_included": return "Fable weekly"
        default: return limit.replacingOccurrences(of: "_", with: " ")
        }
    }
}
