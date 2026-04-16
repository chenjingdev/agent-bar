import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private enum CodexUsagePolicy {
    static let successCacheTTL: TimeInterval = 60
    static let failureCacheTTL: TimeInterval = 15
}

struct CodexUsageProvider: UsageProviding {
    func load() async -> ProviderSnapshot {
        await Task.detached(priority: .utility) {
            let localData = (try? scanLocalLogs()) ?? .empty

            do {
                let remoteResult = try resolveRemoteRateLimits()
                return ProviderSnapshot(
                    provider: .codex,
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
                    sonnetWeekly: nil,
                    planName: remoteResult.data.planName,
                    todayTokens: localData.todayTokens,
                    monthTokens: localData.monthTokens,
                    recentSessions: localData.recentSessions,
                    modelBreakdown: localData.modelBreakdown,
                    sourceDescription: "Codex app-server account/rateLimits/read + ~/.codex",
                    note: remoteResult.note,
                    isStale: remoteResult.isStale
                )
            } catch {
                return ProviderSnapshot(
                    provider: .codex,
                    updatedAt: .now,
                    fiveHour: WindowSummary(tokens: 0, limitTokens: 100, resetAt: nil, displayStyle: .percentage),
                    weekly: WindowSummary(tokens: 0, limitTokens: 100, resetAt: nil, displayStyle: .percentage),
                    sonnetWeekly: nil,
                    planName: nil,
                    todayTokens: localData.todayTokens,
                    monthTokens: localData.monthTokens,
                    recentSessions: localData.recentSessions,
                    modelBreakdown: localData.modelBreakdown,
                    sourceDescription: "Codex app-server account/rateLimits/read + ~/.codex",
                    note: "Couldn't read Codex account rate limits: \(error.localizedDescription)",
                    isStale: true
                )
            }
        }.value
    }

    private func resolveRemoteRateLimits() throws -> RemoteRateLimitResult {
        let cache = CodexUsageCache()
        let now = Date.now

        if let cacheState = try? cache.readState(now: now), cacheState.isFresh {
            return RemoteRateLimitResult(
                data: cacheState.data,
                updatedAt: cacheState.updatedAt,
                note: note(for: cacheState.data),
                isStale: cacheState.data.apiUnavailable
            )
        }

        do {
            let remoteData = try fetchAccountRateLimits()
            try? cache.write(
                data: remoteData,
                timestamp: now,
                lastGoodData: remoteData,
                lastGoodTimestamp: now
            )
            return RemoteRateLimitResult(
                data: remoteData,
                updatedAt: now,
                note: note(for: remoteData),
                isStale: false
            )
        } catch {
            let previousCache = try? cache.readRaw()
            let goodState = cache.makeLastGoodState(from: previousCache)
            let failureData = RemoteRateLimitData(
                planName: goodState?.data.planName,
                fiveHourUsedPercent: 0,
                weeklyUsedPercent: 0,
                fiveHourResetAt: nil,
                weeklyResetAt: nil,
                apiUnavailable: true,
                apiError: error.localizedDescription
            )

            try? cache.write(
                data: failureData,
                timestamp: now,
                lastGoodData: goodState?.data,
                lastGoodTimestamp: goodState?.updatedAt
            )

            if let goodState {
                let displayData = goodState.data.with(apiUnavailable: true, apiError: error.localizedDescription)
                return RemoteRateLimitResult(
                    data: displayData,
                    updatedAt: goodState.updatedAt,
                    note: note(for: displayData),
                    isStale: true
                )
            }

            return RemoteRateLimitResult(
                data: failureData,
                updatedAt: now,
                note: note(for: failureData),
                isStale: true
            )
        }
    }

    private func note(for data: RemoteRateLimitData) -> String {
        if data.apiUnavailable {
            if let apiError = data.apiError {
                return "Couldn't read Codex rate limits. Showing the last known good value (\(apiError)). The token and session details below are from This Mac logs."
            }
            return "Couldn't read Codex rate limits. Showing the last known good value. The token and session details below are from This Mac logs."
        }
        return "The top bars reflect account-wide Codex rate limits. The token and session details below are from This Mac logs."
    }

    private func fetchAccountRateLimits() throws -> RemoteRateLimitData {
        let response = try runAppServerRateLimitRequest()
        let data = try JSONSerialization.data(withJSONObject: response)
        let payload = try JSONDecoder().decode(CodexRateLimitResponse.self, from: data)

        return RemoteRateLimitData(
            planName: payload.result.rateLimits.planType?.capitalized,
            fiveHourUsedPercent: payload.result.rateLimits.primary?.usedPercent ?? 0,
            weeklyUsedPercent: payload.result.rateLimits.secondary?.usedPercent ?? 0,
            fiveHourResetAt: payload.result.rateLimits.primary?.resetsAtDate,
            weeklyResetAt: payload.result.rateLimits.secondary?.resetsAtDate,
            apiUnavailable: false,
            apiError: nil
        )
    }

    private func runAppServerRateLimitRequest() throws -> [String: Any] {
        let codexBinary = try resolveCodexBinary()
        let nodeBinary = try resolveNodeBinary()
        let escapedCodexPath = codexBinary.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let escapedNodePath = nodeBinary.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let pythonScript = """
import json, os, pty, select, subprocess, sys, termios, time
master, slave = pty.openpty()
attrs = termios.tcgetattr(slave)
attrs[3] = attrs[3] & ~termios.ECHO
termios.tcsetattr(slave, termios.TCSANOW, attrs)
process = subprocess.Popen(["\(escapedNodePath)", "\(escapedCodexPath)", "app-server", "--listen", "stdio://"], stdin=slave, stdout=slave, stderr=slave, text=False)
os.close(slave)
messages = [
  {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"agent-bar","version":"0.1"},"capabilities":{"experimentalApi":True}}},
  {"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":None},
]
for message in messages:
  os.write(master, (json.dumps(message) + "\\n").encode())

buffer = b""
deadline = time.time() + 8
found = None
while time.time() < deadline:
  readable, _, _ = select.select([master], [], [], 0.25)
  if not readable:
    continue
  chunk = os.read(master, 4096)
  if not chunk:
    break
  buffer += chunk
  for line in buffer.splitlines():
    try:
      obj = json.loads(line.decode(errors="ignore"))
    except Exception:
      continue
    if obj.get("id") == 2 and "result" in obj:
      found = obj
      break
  if found is not None:
    break

try:
  process.terminate()
except Exception:
  pass

if found is None:
  sys.exit(2)

print(json.dumps(found))
"""

        let result = try runProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", pythonScript],
            timeout: 10
        )

        guard let data = result.stdout.data(using: .utf8),
              let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let trimmed = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CodexUsageError.appServer(trimmed.isEmpty ? "Couldn't find a Codex rate limit response." : trimmed)
        }

        if let error = response["error"] as? [String: Any] {
            throw CodexUsageError.appServer((error["message"] as? String) ?? "Codex app-server error")
        }
        return response
    }

    private func resolveCodexBinary() throws -> URL {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            homeDirectory.appendingPathComponent(".bun/bin/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
        ]

        if let match = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return match
        }

        throw CodexUsageError.appServer("Couldn't find the Codex executable.")
    }

    private func resolveNodeBinary() throws -> URL {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            homeDirectory.appendingPathComponent(".bun/bin/node"),
            URL(fileURLWithPath: "/opt/homebrew/bin/node"),
            URL(fileURLWithPath: "/usr/local/bin/node"),
            URL(fileURLWithPath: "/usr/bin/node"),
        ]

        if let match = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return match
        }

        throw CodexUsageError.appServer("Couldn't find the Node executable.")
    }

    private func scanLocalLogs() throws -> LocalUsageData {
        let now = Date()
        let weekCutoff = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let monthCutoff = Calendar.current.date(byAdding: .day, value: -35, to: now) ?? weekCutoff
        let monthStart = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: now)) ?? monthCutoff

        let baseURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let logURL = baseURL.appendingPathComponent("logs_1.sqlite")
        let stateURL = baseURL.appendingPathComponent("state_5.sqlite")

        guard FileManager.default.fileExists(atPath: logURL.path) else {
            return .empty
        }

        let events = try loadUsageEvents(from: logURL, since: monthCutoff)
        let recentSessions = try loadRecentSessions(from: stateURL, since: monthCutoff)

        let todayEvents = events.filter { Calendar.current.isDate($0.timestamp, inSameDayAs: now) }
        let monthEvents = events.filter { $0.timestamp >= monthStart }
        let weeklyEvents = events.filter { $0.timestamp >= weekCutoff }

        let modelBreakdown = Dictionary(grouping: weeklyEvents, by: \.model)
            .map { key, values in
                ModelSummary(id: key, name: key, tokens: values.reduce(0) { $0 + $1.totalTokens })
            }
            .sorted(by: { $0.tokens > $1.tokens })
            .prefix(4)
            .map { $0 }

        return LocalUsageData(
            todayTokens: todayEvents.reduce(0) { $0 + $1.totalTokens },
            monthTokens: monthEvents.reduce(0) { $0 + $1.totalTokens },
            recentSessions: recentSessions,
            modelBreakdown: modelBreakdown
        )
    }

    private func loadUsageEvents(from url: URL, since: Date) throws -> [UsageEvent] {
        let database = try SQLiteDatabase(readonlyAt: url)
        defer { database.close() }

        let cutoff = Int64(since.timeIntervalSince1970)
        let sql = """
        SELECT ts, message
        FROM logs
        WHERE target = ?
          AND message LIKE ?
          AND ts >= ?
        ORDER BY ts DESC
        """

        var eventsByID: [String: UsageEvent] = [:]
        try database.query(sql, bindings: [
            .text("codex_api::endpoint::responses_websocket"),
            .text("websocket event: {\"type\":\"response.completed\"%"),
            .int64(cutoff),
        ]) { statement in
            guard let message = statement.text(at: 1) else { return }
            guard let payloadData = message.replacingOccurrences(of: "websocket event: ", with: "").data(using: .utf8) else { return }
            guard let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else { return }
            guard let response = payload["response"] as? [String: Any] else { return }
            guard let responseID = response["id"] as? String else { return }
            guard let usage = response["usage"] as? [String: Any] else { return }

            let inputTokens = Self.intValue(usage["input_tokens"])
            let outputTokens = Self.intValue(usage["output_tokens"])
            let totalTokens = Self.intValue(usage["total_tokens"])
            let inputDetails = usage["input_tokens_details"] as? [String: Any]
            let cachedTokens = Self.intValue(inputDetails?["cached_tokens"])
            let interactiveTokens = max(totalTokens - cachedTokens, 0)
            let createdAt = Self.intValue(response["completed_at"]) > 0 ? Self.intValue(response["completed_at"]) : Self.intValue(response["created_at"])
            let timestamp = Date(timeIntervalSince1970: TimeInterval(createdAt))
            let model = (response["model"] as? String) ?? "unknown"

            guard interactiveTokens > 0 || cachedTokens > 0 else { return }

            let event = UsageEvent(
                id: responseID,
                timestamp: timestamp,
                model: model,
                totalTokens: interactiveTokens,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cachedTokens: cachedTokens,
                sessionID: nil
            )

            if let existing = eventsByID[responseID] {
                if event.totalTokens >= existing.totalTokens {
                    eventsByID[responseID] = event
                }
            } else {
                eventsByID[responseID] = event
            }
        }

        return eventsByID.values.sorted(by: { $0.timestamp > $1.timestamp })
    }

    private func loadRecentSessions(from url: URL, since: Date) throws -> [SessionSummary] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }

        let database = try SQLiteDatabase(readonlyAt: url)
        defer { database.close() }

        let cutoff = Int64(since.timeIntervalSince1970)
        let sql = """
        SELECT id, title, updated_at, tokens_used, cwd
        FROM threads
        WHERE updated_at >= ?
        ORDER BY updated_at DESC
        LIMIT 8
        """

        var sessions: [SessionSummary] = []
        try database.query(sql, bindings: [.int64(cutoff)]) { statement in
            let sessionID = statement.text(at: 0) ?? UUID().uuidString
            let title = statement.text(at: 1) ?? "Untitled"
            let updatedAt = Date(timeIntervalSince1970: TimeInterval(statement.int64(at: 2)))
            let tokensUsed = Int(statement.int64(at: 3))
            let cwd = statement.text(at: 4) ?? ""
            let location = cwd.isEmpty ? "workspace" : URL(fileURLWithPath: cwd).lastPathComponent
            sessions.append(
                SessionSummary(
                    id: sessionID,
                    title: String(title.prefix(52)),
                    subtitle: "\(location) · \(TokenFormatters.compactTokenString(tokensUsed))",
                    updatedAt: updatedAt,
                    tokens: tokensUsed
                )
            )
        }

        return sessions
    }

    private static func intValue(_ value: Any?) -> Int {
        if let intValue = value as? Int { return intValue }
        if let int64Value = value as? Int64 { return Int(int64Value) }
        if let doubleValue = value as? Double { return Int(doubleValue) }
        if let stringValue = value as? String, let intValue = Int(stringValue) { return intValue }
        return 0
    }
}

private struct LocalUsageData {
    let todayTokens: Int
    let monthTokens: Int
    let recentSessions: [SessionSummary]
    let modelBreakdown: [ModelSummary]

    static let empty = LocalUsageData(
        todayTokens: 0,
        monthTokens: 0,
        recentSessions: [],
        modelBreakdown: []
    )
}

private struct RemoteRateLimitData: Codable {
    let planName: String?
    let fiveHourUsedPercent: Int
    let weeklyUsedPercent: Int
    let fiveHourResetAt: Date?
    let weeklyResetAt: Date?
    let apiUnavailable: Bool
    let apiError: String?

    func with(apiUnavailable: Bool, apiError: String?) -> RemoteRateLimitData {
        RemoteRateLimitData(
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

private struct CodexRateLimitResponse: Decodable {
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
        let resetsAt: Int64?

        var resetsAtDate: Date? {
            guard let resetsAt else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(resetsAt))
        }
    }
}

private enum CodexUsageError: LocalizedError {
    case appServer(String)

    var errorDescription: String? {
        switch self {
        case .appServer(let message):
            return message
        }
    }
}

private struct CodexUsageCacheRecord: Codable {
    let data: RemoteRateLimitData
    let timestamp: Date
    let lastGoodData: RemoteRateLimitData?
    let lastGoodTimestamp: Date?
}

private struct CodexUsageCacheState {
    let data: RemoteRateLimitData
    let updatedAt: Date
    let isFresh: Bool
}

private struct CodexUsageCache {
    private let fileManager = FileManager.default

    private var cacheURL: URL {
        let base = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".agentbar", isDirectory: true)
        return base.appendingPathComponent("codex-rate-limits-cache.json")
    }

    func readRaw() throws -> CodexUsageCacheRecord {
        let data = try Data(contentsOf: cacheURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CodexUsageCacheRecord.self, from: data)
    }

    func readState(now: Date) throws -> CodexUsageCacheState {
        let cache = try readRaw()
        let displayState = displayState(from: cache)
        let ttl = cache.data.apiUnavailable ? CodexUsagePolicy.failureCacheTTL : CodexUsagePolicy.successCacheTTL
        return CodexUsageCacheState(
            data: displayState.data,
            updatedAt: displayState.updatedAt,
            isFresh: now.timeIntervalSince(cache.timestamp) < ttl
        )
    }

    func makeLastGoodState(from cache: CodexUsageCacheRecord?) -> CodexUsageCacheState? {
        guard let cache else { return nil }
        if cache.data.apiUnavailable == false {
            return CodexUsageCacheState(data: cache.data, updatedAt: cache.timestamp, isFresh: false)
        }
        guard let lastGoodData = cache.lastGoodData else { return nil }
        return CodexUsageCacheState(
            data: lastGoodData,
            updatedAt: cache.lastGoodTimestamp ?? cache.timestamp,
            isFresh: false
        )
    }

    func write(
        data: RemoteRateLimitData,
        timestamp: Date,
        lastGoodData: RemoteRateLimitData? = nil,
        lastGoodTimestamp: Date? = nil
    ) throws {
        let record = CodexUsageCacheRecord(
            data: data,
            timestamp: timestamp,
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

    private func displayState(from cache: CodexUsageCacheRecord) -> CodexUsageCacheState {
        if cache.data.apiUnavailable, let lastGoodData = cache.lastGoodData {
            return CodexUsageCacheState(
                data: lastGoodData.with(apiUnavailable: true, apiError: cache.data.apiError),
                updatedAt: cache.lastGoodTimestamp ?? cache.timestamp,
                isFresh: false
            )
        }

        return CodexUsageCacheState(
            data: cache.data,
            updatedAt: cache.timestamp,
            isFresh: false
        )
    }
}

private struct ProcessOutput {
    let stdout: String
    let stderr: String
}

private func runProcess(
    executableURL: URL,
    arguments: [String],
    timeout: TimeInterval
) throws -> ProcessOutput {
    let process = Process()
    process.executableURL = executableURL
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
        throw CodexUsageError.appServer("External process did not finish within \(Int(timeout)) seconds.")
    }

    let stdoutData = outputPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrData = errorPipe.fileHandleForReading.readDataToEndOfFile()
    let stdout = String(decoding: stdoutData, as: UTF8.self)
    let stderr = String(decoding: stderrData, as: UTF8.self)

    guard process.terminationStatus == 0 else {
        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        throw CodexUsageError.appServer(message.isEmpty ? "External process failed." : message)
    }

    return ProcessOutput(stdout: stdout, stderr: stderr)
}

private enum SQLiteValue {
    case text(String)
    case int64(Int64)
}

private final class SQLiteDatabase {
    private var handle: OpaquePointer?

    init(readonlyAt url: URL) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(url.path, &db, flags, nil) != SQLITE_OK {
            defer { sqlite3_close(db) }
            throw SQLiteError.openDatabase(message: Self.lastError(from: db))
        }
        self.handle = db
    }

    func close() {
        if let handle {
            sqlite3_close(handle)
            self.handle = nil
        }
    }

    func query(
        _ sql: String,
        bindings: [SQLiteValue],
        rowHandler: (SQLiteStatement) throws -> Void
    ) throws {
        guard let handle else {
            throw SQLiteError.prepare(message: "DB handle is nil")
        }

        var statementPointer: OpaquePointer?
        if sqlite3_prepare_v2(handle, sql, -1, &statementPointer, nil) != SQLITE_OK {
            throw SQLiteError.prepare(message: Self.lastError(from: handle))
        }

        defer { sqlite3_finalize(statementPointer) }

        guard let statementPointer else {
            throw SQLiteError.prepare(message: "statement is nil")
        }

        for (index, binding) in bindings.enumerated() {
            let parameterIndex = Int32(index + 1)
            let result: Int32
            switch binding {
            case .text(let value):
                result = sqlite3_bind_text(statementPointer, parameterIndex, value, -1, SQLITE_TRANSIENT)
            case .int64(let value):
                result = sqlite3_bind_int64(statementPointer, parameterIndex, value)
            }

            if result != SQLITE_OK {
                throw SQLiteError.bind(message: Self.lastError(from: handle))
            }
        }

        while true {
            switch sqlite3_step(statementPointer) {
            case SQLITE_ROW:
                try rowHandler(SQLiteStatement(pointer: statementPointer))
            case SQLITE_DONE:
                return
            default:
                throw SQLiteError.step(message: Self.lastError(from: handle))
            }
        }
    }

    private static func lastError(from handle: OpaquePointer?) -> String {
        if let handle, let message = sqlite3_errmsg(handle) {
            return String(cString: message)
        }
        return "Unknown SQLite error"
    }
}

private struct SQLiteStatement {
    let pointer: OpaquePointer

    func text(at column: Int32) -> String? {
        guard let cString = sqlite3_column_text(pointer, column) else { return nil }
        return String(cString: cString)
    }

    func int64(at column: Int32) -> Int64 {
        sqlite3_column_int64(pointer, column)
    }
}

private enum SQLiteError: LocalizedError {
    case openDatabase(message: String)
    case prepare(message: String)
    case bind(message: String)
    case step(message: String)

    var errorDescription: String? {
        switch self {
        case .openDatabase(let message),
             .prepare(let message),
             .bind(let message),
             .step(let message):
            return message
        }
    }
}
