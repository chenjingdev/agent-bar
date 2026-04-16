import CryptoKit
import Foundation

private enum ClaudeUsagePolicy {
    static let successCacheTTL: TimeInterval = 60
    static let failureCacheTTL: TimeInterval = 15
    static let rateLimitedBaseTTL: TimeInterval = 60
    static let rateLimitedMaxTTL: TimeInterval = 5 * 60
    static let statusLineCacheTTL: TimeInterval = 2 * 60
}

struct ClaudeUsageProvider: UsageProviding {
    func load() async -> ProviderSnapshot {
        await Task.detached(priority: .utility) {
            let localData = (try? scanLocalLogs()) ?? .empty

            do {
                let remoteResult = try await resolveRemoteUsage(localData: localData)
                let sonnetWeekly: WindowSummary? = remoteResult.data.sonnetWeeklyUsedPercent.map {
                    WindowSummary(tokens: $0, limitTokens: 100, resetAt: remoteResult.data.sonnetWeeklyResetAt, displayStyle: .percentage)
                }
                return ProviderSnapshot(
                    provider: .claude,
                    updatedAt: remoteResult.updatedAt,
                    fiveHour: WindowSummary(
                        tokens: remoteResult.data.fiveHourUsedPercent,
                        limitTokens: 100,
                        resetAt: remoteResult.data.fiveHourResetAt,
                        displayStyle: .percentage
                    ),
                    weekly: WindowSummary(
                        tokens: remoteResult.data.weeklyUsedPercent,
                        limitTokens: 100,
                        resetAt: remoteResult.data.weeklyResetAt,
                        displayStyle: .percentage
                    ),
                    sonnetWeekly: sonnetWeekly,
                    planName: remoteResult.data.planName,
                    todayTokens: localData.todayTokens,
                    monthTokens: localData.monthTokens,
                    recentSessions: localData.recentSessions,
                    modelBreakdown: localData.modelBreakdown,
                    sourceDescription: remoteResult.sourceDescription,
                    note: remoteResult.note,
                    isStale: remoteResult.isStale
                )
            } catch {
                return ProviderSnapshot(
                    provider: .claude,
                    updatedAt: .now,
                    fiveHour: WindowSummary(tokens: 0, limitTokens: 100, resetAt: nil, displayStyle: .percentage),
                    weekly: WindowSummary(tokens: 0, limitTokens: 100, resetAt: nil, displayStyle: .percentage),
                    sonnetWeekly: nil,
                    planName: nil,
                    todayTokens: localData.todayTokens,
                    monthTokens: localData.monthTokens,
                    recentSessions: localData.recentSessions,
                    modelBreakdown: localData.modelBreakdown,
                    sourceDescription: "Anthropic OAuth usage API + cache + ~/.claude/projects",
                    note: "Couldn't read Anthropic account usage: \(error.localizedDescription)",
                    isStale: true
                )
            }
        }.value
    }

    private func resolveRemoteUsage(localData: LocalUsageData) async throws -> RemoteUsageResult {
        let cache = ClaudeUsageCache()
        let now = Date.now

        let credentials = try? readCredentials()
        let resolvedPlanName = credentials.flatMap { self.planName(from: $0.subscriptionType) }

        if let statusLineUsage = try? readStatusLineUsage(now: now) {
            let statusLineData = RemoteUsageData(
                planName: resolvedPlanName,
                fiveHourUsedPercent: statusLineUsage.fiveHourUsedPercent,
                weeklyUsedPercent: statusLineUsage.weeklyUsedPercent,
                fiveHourResetAt: statusLineUsage.fiveHourResetAt,
                weeklyResetAt: statusLineUsage.weeklyResetAt,
                sonnetWeeklyUsedPercent: nil,
                sonnetWeeklyResetAt: nil,
                apiUnavailable: false,
                apiError: nil,
                usageSource: .statusLine,
                weeklyWindowLabel: nil
            )

            try? cache.write(
                data: statusLineData,
                timestamp: statusLineUsage.updatedAt,
                lastGoodData: statusLineData,
                lastGoodTimestamp: statusLineUsage.updatedAt
            )

            return RemoteUsageResult(
                data: statusLineData,
                updatedAt: statusLineUsage.updatedAt,
                note: note(for: statusLineData),
                isStale: false,
                sourceDescription: sourceDescription(for: statusLineData)
            )
        }

        if let cacheState = try? cache.readState(now: now), cacheState.isFresh {
            return RemoteUsageResult(
                data: cacheState.data,
                updatedAt: cacheState.updatedAt,
                note: note(for: cacheState.data),
                isStale: cacheState.data.apiUnavailable,
                sourceDescription: sourceDescription(for: cacheState.data)
            )
        }

        guard let credentials else {
            throw ClaudeUsageError.missingCredentials
        }

        let planName = resolvedPlanName ?? planName(from: credentials.subscriptionType)
        let apiResult = await fetchUsageApi(accessToken: credentials.accessToken)

        if let payload = apiResult.data {
            let mainWeekly = payload.sevenDay ?? payload.sevenDayOpus
            let successData = RemoteUsageData(
                planName: planName,
                fiveHourUsedPercent: Self.parseUtilization(payload.fiveHour?.utilization),
                weeklyUsedPercent: Self.parseUtilization(mainWeekly?.utilization),
                fiveHourResetAt: payload.fiveHour?.parsedResetAt,
                weeklyResetAt: mainWeekly?.parsedResetAt,
                sonnetWeeklyUsedPercent: payload.sevenDaySonnet.map { Self.parseUtilization($0.utilization) },
                sonnetWeeklyResetAt: payload.sevenDaySonnet?.parsedResetAt,
                apiUnavailable: false,
                apiError: nil,
                usageSource: .oauthApi,
                weeklyWindowLabel: nil
            )

            try? cache.write(
                data: successData,
                timestamp: now,
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
            fiveHourUsedPercent: 0,
            weeklyUsedPercent: 0,
            fiveHourResetAt: nil,
            weeklyResetAt: nil,
            sonnetWeeklyUsedPercent: nil,
            sonnetWeeklyResetAt: nil,
            apiUnavailable: true,
            apiError: apiResult.error,
            usageSource: .oauthApi,
            weeklyWindowLabel: nil
        )

        let previousCache = try? cache.readRaw()
        let isRateLimited = apiResult.error == "rate-limited"
        let previousRateLimitedCount = previousCache?.rateLimitedCount ?? 0
        let rateLimitedCount = isRateLimited ? previousRateLimitedCount + 1 : 0
        let retryAfterUntil = apiResult.retryAfterSeconds.map { now.addingTimeInterval(TimeInterval($0)) }

        if isRateLimited {
            let goodState = cache.makeLastGoodState(from: previousCache)
            try? cache.write(
                data: failureData,
                timestamp: now,
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

        try? cache.write(data: failureData, timestamp: now)
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
            if data.apiError == "rate-limited" {
                return "The Anthropic usage API is rate-limited. Showing the last known good value and retrying automatically. The token and session details below are from This Mac logs."
            }
            return "Couldn't read the Anthropic usage API (\(data.apiError ?? "unknown")). The token and session details below are from This Mac logs."
        }
        switch data.usageSource {
        case .statusLine:
            return "The top bars reflect Claude Code's live rate_limits data from your active status line session. The token and session details below are from This Mac logs."
        case .oauthApi:
            if let weeklyWindowLabel = data.weeklyWindowLabel {
                return "The top bars reflect Anthropic usage API data. Weekly is following the \(weeklyWindowLabel) window. The token and session details below are from This Mac logs."
            }
            return "The top bars reflect account-wide Anthropic usage API data. The token and session details below are from This Mac logs."
        case nil:
            return "The top bars reflect account-wide Anthropic usage API data. The token and session details below are from This Mac logs."
        }
    }

    private func sourceDescription(for data: RemoteUsageData) -> String {
        switch data.usageSource {
        case .statusLine:
            return "Claude Code live rate_limits + ~/.claude/projects"
        case .oauthApi:
            return "Anthropic OAuth usage API + cache + ~/.claude/projects"
        case nil:
            return "Anthropic OAuth usage API + cache + ~/.claude/projects"
        }
    }

    private func fetchUsageApi(accessToken: String) async -> UsageApiResult {
        do {
            let request = try makeUsageRequest(accessToken: accessToken)
            let (data, response) = try await URLSession.shared.data(for: request)

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

    private func readCredentials() throws -> ClaudeCredentials {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let configDirectory = claudeConfigDirectory(homeDirectory: homeDirectory)
        let serviceNames = keychainServiceNames(configDirectory: configDirectory, homeDirectory: homeDirectory)
        let accountName = currentAccountName()

        if let credentials = try readKeychainCredentials(serviceNames: serviceNames, accountName: accountName) {
            if credentials.subscriptionType.isEmpty == false {
                return credentials
            }

            if let fallback = try? readFileCredentials(configDirectory: configDirectory) {
                return ClaudeCredentials(
                    accessToken: credentials.accessToken,
                    subscriptionType: fallback.subscriptionType
                )
            }

            return credentials
        }

        if let fileCredentials = try? readFileCredentials(configDirectory: configDirectory) {
            return fileCredentials
        }

        throw ClaudeUsageError.missingCredentials
    }

    private func readKeychainCredentials(
        serviceNames: [String],
        accountName: String?
    ) throws -> ClaudeCredentials? {
        for serviceName in serviceNames {
            if let accountName,
               let credentials = try loadKeychainCredentials(serviceName: serviceName, accountName: accountName) {
                return credentials
            }

            if let credentials = try loadKeychainCredentials(serviceName: serviceName, accountName: nil) {
                return credentials
            }
        }

        return nil
    }

    private func loadKeychainCredentials(
        serviceName: String,
        accountName: String?
    ) throws -> ClaudeCredentials? {
        var arguments = ["find-generic-password", "-s", serviceName]
        if let accountName {
            arguments += ["-a", accountName]
        }
        arguments.append("-w")

        let data = try runSecurityCommand(arguments: arguments, timeout: 3)
        guard data.isEmpty == false else {
            return nil
        }

        let credentialsFile = try JSONDecoder().decode(CredentialsFile.self, from: data)
        guard let accessToken = credentialsFile.claudeAiOauth?.accessToken, accessToken.isEmpty == false else {
            return nil
        }

        if let expiresAt = credentialsFile.claudeAiOauth?.expiresAt, expiresAt <= Int(Date().timeIntervalSince1970 * 1000) {
            return nil
        }

        return ClaudeCredentials(
            accessToken: accessToken,
            subscriptionType: credentialsFile.claudeAiOauth?.subscriptionType ?? ""
        )
    }

    private func readFileCredentials(configDirectory: URL) throws -> ClaudeCredentials {
        let credentialsURL = configDirectory.appendingPathComponent(".credentials.json")
        let data = try Data(contentsOf: credentialsURL)
        let credentialsFile = try JSONDecoder().decode(CredentialsFile.self, from: data)

        guard let accessToken = credentialsFile.claudeAiOauth?.accessToken, accessToken.isEmpty == false else {
            throw ClaudeUsageError.missingCredentials
        }

        return ClaudeCredentials(
            accessToken: accessToken,
            subscriptionType: credentialsFile.claudeAiOauth?.subscriptionType ?? ""
        )
    }

    private func claudeConfigDirectory(homeDirectory: URL) -> URL {
        if let override = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], override.isEmpty == false {
            return URL(fileURLWithPath: override).standardizedFileURL
        }
        return homeDirectory.appendingPathComponent(".claude")
    }

    private func keychainServiceNames(configDirectory: URL, homeDirectory: URL) -> [String] {
        let legacyService = "Claude Code-credentials"
        let normalizedConfig = configDirectory.standardizedFileURL.path
        let normalizedDefault = homeDirectory.appendingPathComponent(".claude").standardizedFileURL.path

        if normalizedConfig == normalizedDefault {
            return [legacyService]
        }

        let hash = SHA256.hash(data: Data(normalizedConfig.utf8))
        let suffix = hash.compactMap { String(format: "%02x", $0) }.joined().prefix(8)
        return ["\(legacyService)-\(suffix)", legacyService]
    }

    private func currentAccountName() -> String? {
        NSUserName().isEmpty ? nil : NSUserName()
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

    private func readStatusLineUsage(now: Date) throws -> ClaudeStatusLineUsage? {
        let url = statusLineCacheURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let updatedAt = attributes[.modificationDate] as? Date else { return nil }
        guard now.timeIntervalSince(updatedAt) <= ClaudeUsagePolicy.statusLineCacheTTL else { return nil }

        let data = try Data(contentsOf: url)
        let payload = try JSONDecoder().decode(ClaudeStatusLinePayload.self, from: data)
        guard let rateLimits = payload.rateLimits else { return nil }
        guard rateLimits.fiveHour?.usedPercentage != nil || rateLimits.sevenDay?.usedPercentage != nil else {
            return nil
        }

        return ClaudeStatusLineUsage(
            updatedAt: updatedAt,
            fiveHourUsedPercent: Self.parseUtilization(rateLimits.fiveHour?.usedPercentage),
            weeklyUsedPercent: Self.parseUtilization(rateLimits.sevenDay?.usedPercentage),
            fiveHourResetAt: rateLimits.fiveHour?.parsedResetAt,
            weeklyResetAt: rateLimits.sevenDay?.parsedResetAt
        )
    }

    private func statusLineCacheURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agentbar", isDirectory: true)
            .appendingPathComponent("claude-statusline.json")
    }

    private func scanLocalLogs() throws -> LocalUsageData {
        let now = Date()
        let dateFormatter = Self.makeDateFormatter()
        let monthCutoff = Calendar.current.date(byAdding: .day, value: -35, to: now) ?? now
        let monthStart = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: now)) ?? monthCutoff

        var eventsByRequestID: [String: UsageEvent] = [:]
        var sessionTitles: [String: String] = [:]

        let baseURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent("projects")

        guard FileManager.default.fileExists(atPath: baseURL.path) else {
            return .empty
        }

        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        let enumerator = FileManager.default.enumerator(
            at: baseURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        )

        while let fileURL = enumerator?.nextObject() as? URL {
            guard fileURL.pathExtension == "jsonl" else { continue }
            let resourceValues = try? fileURL.resourceValues(forKeys: resourceKeys)
            guard resourceValues?.isRegularFile == true else { continue }
            if let modifiedAt = resourceValues?.contentModificationDate, modifiedAt < monthCutoff {
                continue
            }

            let content = try String(contentsOf: fileURL, encoding: .utf8)
            for rawLine in content.split(whereSeparator: \.isNewline) {
                guard let data = rawLine.data(using: .utf8) else { continue }
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

                if let sessionID = object["sessionId"] as? String,
                   sessionTitles[sessionID] == nil,
                   let title = extractUserTitle(from: object) {
                    sessionTitles[sessionID] = title
                }

                guard let type = object["type"] as? String, type == "assistant" else { continue }
                guard let sessionID = object["sessionId"] as? String else { continue }
                guard let requestID = object["requestId"] as? String else { continue }
                guard let timestampString = object["timestamp"] as? String else { continue }
                guard let timestamp = dateFormatter.date(from: timestampString) else { continue }
                guard timestamp >= monthCutoff else { continue }
                guard let message = object["message"] as? [String: Any] else { continue }
                guard let usage = message["usage"] as? [String: Any] else { continue }

                let inputTokens = Self.intValue(usage["input_tokens"])
                let outputTokens = Self.intValue(usage["output_tokens"])
                let cacheReadTokens = Self.intValue(usage["cache_read_input_tokens"])
                let cacheCreationTokens = Self.intValue(usage["cache_creation_input_tokens"])
                let interactiveTokens = inputTokens + outputTokens
                let cachedTokens = cacheReadTokens + cacheCreationTokens
                guard interactiveTokens > 0 || cachedTokens > 0 else { continue }

                let model = (message["model"] as? String) ?? "unknown"
                let event = UsageEvent(
                    id: requestID,
                    timestamp: timestamp,
                    model: model,
                    totalTokens: interactiveTokens,
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    cachedTokens: cachedTokens,
                    sessionID: sessionID
                )

                if let existing = eventsByRequestID[requestID] {
                    if event.totalTokens >= existing.totalTokens {
                        eventsByRequestID[requestID] = event
                    }
                } else {
                    eventsByRequestID[requestID] = event
                }
            }
        }

        let events = eventsByRequestID.values.sorted(by: { $0.timestamp > $1.timestamp })
        let todayEvents = events.filter { Calendar.current.isDate($0.timestamp, inSameDayAs: now) }
        let monthEvents = events.filter { $0.timestamp >= monthStart }
        let modelBreakdown = Dictionary(grouping: monthEvents, by: \.model)
            .map { key, values in
                ModelSummary(id: key, name: key, tokens: values.reduce(0) { $0 + $1.totalTokens })
            }
            .sorted(by: { $0.tokens > $1.tokens })
            .prefix(4)
            .map { $0 }

        return LocalUsageData(
            todayTokens: todayEvents.reduce(0) { $0 + $1.totalTokens },
            monthTokens: monthEvents.reduce(0) { $0 + $1.totalTokens },
            recentSessions: buildSessionSummaries(events: events, sessionTitles: sessionTitles),
            modelBreakdown: modelBreakdown,
            latestModel: events.first?.model
        )
    }

    private func buildSessionSummaries(
        events: [UsageEvent],
        sessionTitles: [String: String]
    ) -> [SessionSummary] {
        struct Aggregate {
            var updatedAt: Date
            var tokens: Int
            var models: [String: Int]
        }

        var aggregates: [String: Aggregate] = [:]

        for event in events {
            guard let sessionID = event.sessionID else { continue }
            var aggregate = aggregates[sessionID] ?? Aggregate(updatedAt: event.timestamp, tokens: 0, models: [:])
            aggregate.updatedAt = max(aggregate.updatedAt, event.timestamp)
            aggregate.tokens += event.totalTokens
            aggregate.models[event.model, default: 0] += event.totalTokens
            aggregates[sessionID] = aggregate
        }

        return aggregates
            .map { sessionID, aggregate in
                let title = sessionTitles[sessionID] ?? "Session \(sessionID.prefix(6))"
                let topModel = aggregate.models.max(by: { $0.value < $1.value })?.key ?? "unknown"
                return SessionSummary(
                    id: sessionID,
                    title: title,
                    subtitle: "\(topModel) · \(TokenFormatters.compactTokenString(aggregate.tokens))",
                    updatedAt: aggregate.updatedAt,
                    tokens: aggregate.tokens
                )
            }
            .sorted(by: { $0.updatedAt > $1.updatedAt })
            .prefix(5)
            .map { $0 }
    }

    private func extractUserTitle(from object: [String: Any]) -> String? {
        guard let type = object["type"] as? String, type == "user" else { return nil }
        if let message = object["message"] as? [String: Any] {
            if let content = message["content"] as? String {
                return Self.compactTitle(content)
            }
            if let parts = message["content"] as? [[String: Any]] {
                let text = parts
                    .compactMap { $0["text"] as? String }
                    .joined(separator: " ")
                return Self.compactTitle(text)
            }
        }
        if let prompt = object["prompt"] as? String {
            return Self.compactTitle(prompt)
        }
        return nil
    }

    private static func compactTitle(_ text: String) -> String? {
        let normalized = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else { return nil }
        return String(normalized.prefix(52))
    }

    private static func parseUtilization(_ value: Double?) -> Int {
        PercentageNormalizer.normalize(value)
    }

    private static func selectWeeklyWindow(
        from payload: UsageApiResponse,
        preferredModelHint: String?
    ) -> SelectedUsageWindow? {
        let normalizedHint = preferredModelHint?.lowercased() ?? ""

        if normalizedHint.contains("sonnet"), let window = payload.sevenDaySonnet {
            return SelectedUsageWindow(window: window, label: "Sonnet 7-day")
        }

        if normalizedHint.contains("opus"), let window = payload.sevenDayOpus {
            return SelectedUsageWindow(window: window, label: "Opus 7-day")
        }

        if normalizedHint.contains("oauth"), let window = payload.sevenDayOauthApps {
            return SelectedUsageWindow(window: window, label: "OAuth Apps 7-day")
        }

        if let window = payload.sevenDay {
            return SelectedUsageWindow(window: window, label: nil)
        }

        if let window = payload.sevenDaySonnet {
            return SelectedUsageWindow(window: window, label: "Sonnet 7-day")
        }

        if let window = payload.sevenDayOpus {
            return SelectedUsageWindow(window: window, label: "Opus 7-day")
        }

        if let window = payload.sevenDayOauthApps {
            return SelectedUsageWindow(window: window, label: "OAuth Apps 7-day")
        }

        return nil
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

    private static func intValue(_ value: Any?) -> Int {
        if let intValue = value as? Int { return intValue }
        if let doubleValue = value as? Double { return Int(doubleValue) }
        if let stringValue = value as? String, let intValue = Int(stringValue) { return intValue }
        return 0
    }

    private static func makeDateFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private func runSecurityCommand(arguments: [String], timeout: TimeInterval) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()

        let group = DispatchGroup()
        group.enter()
        process.terminationHandler = { _ in group.leave() }

        if group.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw ClaudeUsageError.keychainTimeout
        }

        guard process.terminationStatus == 0 else {
            return Data()
        }

        return outputPipe.fileHandleForReading.readDataToEndOfFile()
    }
}

private struct LocalUsageData {
    let todayTokens: Int
    let monthTokens: Int
    let recentSessions: [SessionSummary]
    let modelBreakdown: [ModelSummary]
    let latestModel: String?

    static let empty = LocalUsageData(
        todayTokens: 0,
        monthTokens: 0,
        recentSessions: [],
        modelBreakdown: [],
        latestModel: nil
    )
}

private struct RemoteUsageData: Codable {
    let planName: String?
    let fiveHourUsedPercent: Int
    let weeklyUsedPercent: Int
    let fiveHourResetAt: Date?
    let weeklyResetAt: Date?
    let sonnetWeeklyUsedPercent: Int?
    let sonnetWeeklyResetAt: Date?
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
            sonnetWeeklyUsedPercent: sonnetWeeklyUsedPercent,
            sonnetWeeklyResetAt: sonnetWeeklyResetAt,
            apiUnavailable: apiUnavailable,
            apiError: apiError,
            usageSource: usageSource,
            weeklyWindowLabel: weeklyWindowLabel
        )
    }
}

private struct RemoteUsageResult {
    let data: RemoteUsageData
    let updatedAt: Date
    let note: String
    let isStale: Bool
    let sourceDescription: String
}

private enum ClaudeUsageSource: String, Codable {
    case oauthApi = "oauth_api"
    case statusLine = "status_line"
}

private struct ClaudeCredentials {
    let accessToken: String
    let subscriptionType: String
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

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOauthApps = "seven_day_oauth_apps"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
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

private struct ClaudeStatusLineUsage {
    let updatedAt: Date
    let fiveHourUsedPercent: Int
    let weeklyUsedPercent: Int
    let fiveHourResetAt: Date?
    let weeklyResetAt: Date?
}

private struct ClaudeStatusLinePayload: Decodable {
    let rateLimits: ClaudeStatusLineRateLimits?

    enum CodingKeys: String, CodingKey {
        case rateLimits = "rate_limits"
    }
}

private struct ClaudeStatusLineRateLimits: Decodable {
    let fiveHour: ClaudeStatusLineWindow?
    let sevenDay: ClaudeStatusLineWindow?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }
}

private struct ClaudeStatusLineWindow: Decodable {
    let usedPercentage: Double?
    let resetsAt: Double?

    enum CodingKeys: String, CodingKey {
        case usedPercentage = "used_percentage"
        case resetsAt = "resets_at"
    }

    var parsedResetAt: Date? {
        guard let resetsAt, resetsAt > 0 else { return nil }
        return Date(timeIntervalSince1970: resetsAt)
    }
}

private enum ClaudeUsageError: LocalizedError {
    case invalidURL
    case missingCredentials
    case keychainTimeout

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid usage URL"
        case .missingCredentials:
            return "Couldn't find a Claude OAuth token."
        case .keychainTimeout:
            return "macOS Keychain response timed out."
        }
    }
}

private struct ClaudeUsageCacheRecord: Codable {
    let data: RemoteUsageData
    let timestamp: Date
    let rateLimitedCount: Int?
    let retryAfterUntil: Date?
    let lastGoodData: RemoteUsageData?
    let lastGoodTimestamp: Date?
}

private struct LegacyClaudeUsageCacheRecord: Decodable {
    let timestamp: Date
    let cooldownUntil: Date?
    let planName: String?
    let fiveHourUsedPercent: Int
    let weeklyUsedPercent: Int
    let fiveHourResetAt: Date?
    let weeklyResetAt: Date?

    var upgraded: ClaudeUsageCacheRecord {
        let data = RemoteUsageData(
            planName: planName,
            fiveHourUsedPercent: fiveHourUsedPercent,
            weeklyUsedPercent: weeklyUsedPercent,
            fiveHourResetAt: fiveHourResetAt,
            weeklyResetAt: weeklyResetAt,
            sonnetWeeklyUsedPercent: nil,
            sonnetWeeklyResetAt: nil,
            apiUnavailable: false,
            apiError: nil,
            usageSource: nil,
            weeklyWindowLabel: nil
        )

        return ClaudeUsageCacheRecord(
            data: data,
            timestamp: timestamp,
            rateLimitedCount: nil,
            retryAfterUntil: cooldownUntil,
            lastGoodData: data,
            lastGoodTimestamp: timestamp
        )
    }
}

private struct ClaudeUsageCacheState {
    let data: RemoteUsageData
    let updatedAt: Date
    let isFresh: Bool
}

private struct ClaudeUsageCache {
    private let fileManager = FileManager.default

    private var cacheURL: URL {
        let base = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".agentbar", isDirectory: true)
        return base.appendingPathComponent("claude-usage-cache.json")
    }

    func readRaw() throws -> ClaudeUsageCacheRecord {
        let data = try Data(contentsOf: cacheURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let record = try? decoder.decode(ClaudeUsageCacheRecord.self, from: data) {
            return record
        }
        return try decoder.decode(LegacyClaudeUsageCacheRecord.self, from: data).upgraded
    }

    func readState(now: Date) throws -> ClaudeUsageCacheState {
        let cache = try readRaw()
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

    func makeLastGoodState(from cache: ClaudeUsageCacheRecord?) -> ClaudeUsageCacheState? {
        guard let cache else { return nil }
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
        rateLimitedCount: Int? = nil,
        retryAfterUntil: Date? = nil,
        lastGoodData: RemoteUsageData? = nil,
        lastGoodTimestamp: Date? = nil
    ) throws {
        let record = ClaudeUsageCacheRecord(
            data: data,
            timestamp: timestamp,
            rateLimitedCount: rateLimitedCount,
            retryAfterUntil: retryAfterUntil,
            lastGoodData: lastGoodData,
            lastGoodTimestamp: lastGoodTimestamp
        )
        let directory = cacheURL.deletingLastPathComponent()
        if fileManager.fileExists(atPath: directory.path) == false {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        try data.write(to: cacheURL, options: .atomic)
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
