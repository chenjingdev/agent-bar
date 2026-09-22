import Darwin
import Foundation

// All blocking process work runs on a utility task. stdout is continuously drained;
// stderr is never retained because authentication commands can print credentials.
final class ProcessSession: @unchecked Sendable {
    private final class WeakSession { weak var value: ProcessSession?; init(_ value: ProcessSession) { self.value = value } }
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var sessions: [WeakSession] = []
    static func stopAll() {
        registryLock.lock(); let active = sessions.compactMap(\.value); registryLock.unlock()
        active.forEach { $0.stop() }
    }
    private let process = Process()
    private let stopLock = NSLock()
    private let input = Pipe()
    private let output = Pipe()
    private let condition = NSCondition()
    private var buffer = Data()
    private var ended = false
    private var overflow = false
    private var stopped = false

    init(executable: URL, arguments: [String], environment: [String: String], directory: URL) throws {
        // A CLI may exit between receiving a response and our next write.
        // Report EPIPE through FileHandle instead of terminating the whole app.
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        // Keep the upstream process-group cleanup guarantee. The helper execs
        // the CLI without a shell, so arguments and paths remain literal.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import os,sys; os.setpgid(0,0); os.execve(sys.argv[1], sys.argv[1:], os.environ)", executable.path] + arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            self.condition.lock()
            if self.buffer.count + data.count <= 2_000_000 { self.buffer.append(data) }
            else { self.overflow = true }
            if data.isEmpty { self.ended = true }
            self.condition.broadcast()
            self.condition.unlock()
        }
        process.terminationHandler = { [weak self] _ in
            self?.condition.lock()
            self?.condition.broadcast()
            self?.condition.unlock()
        }
        Self.registryLock.lock()
        Self.sessions.removeAll { $0.value == nil }
        Self.sessions.append(WeakSession(self))
        Self.registryLock.unlock()
        do { try process.run() }
        catch { output.fileHandleForReading.readabilityHandler = nil; throw error }
    }

    func send(_ value: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: value)
        data.append(0x0a)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    func line(until deadline: Date, control: OperationControl) throws -> Data {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if control.cancelled { throw AccountError.cancelled }
            if overflow { throw AccountError.message("The CLI response exceeded the size limit.") }
            if let end = buffer.firstIndex(of: 0x0a) {
                let result = Data(buffer[..<end]); buffer.removeSubrange(...end)
                return result
            }
            if ended {
                if !buffer.isEmpty { let result = buffer; buffer.removeAll(); return result }
                throw AccountError.message("The CLI connection closed. Check the installation and sign-in status.")
            }
            if Date() >= deadline { throw AccountError.timeout }
            _ = condition.wait(until: min(deadline, Date().addingTimeInterval(0.1)))
        }
    }

    func collect(until deadline: Date, control: OperationControl) throws -> Data {
        var result = Data()
        condition.lock()
        defer { condition.unlock() }
        while true {
            if control.cancelled { throw AccountError.cancelled }
            if overflow || result.count + buffer.count > 2_000_000 {
                throw AccountError.message("The CLI response is too large.")
            }
            result.append(buffer); buffer.removeAll()
            if ended && !process.isRunning { return result }
            if Date() >= deadline { throw AccountError.timeout }
            _ = condition.wait(until: min(deadline, Date().addingTimeInterval(0.1)))
        }
    }
    var exitStatus: Int32 { process.isRunning ? -1 : process.terminationStatus }
    func stop() {
        stopLock.lock(); defer { stopLock.unlock() }
        guard !stopped else { return }
        stopped = true
        let pid = process.processIdentifier
        if pid > 0 { kill(-pid, SIGTERM) }
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        // Descendants can outlive an already-exited launcher or ignore SIGTERM.
        if pid > 0 { kill(-pid, SIGKILL) }
        output.fileHandleForReading.readabilityHandler = nil
        condition.lock(); ended = true; condition.broadcast(); condition.unlock()
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
    }
    deinit { stop() }
}

final class OperationControl: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return isCancelled }
    func cancel() { lock.lock(); isCancelled = true; lock.unlock() }
    func checkCancellation() throws {
        if cancelled { throw AccountError.cancelled }
    }
}

enum ProviderCLI {
    static func executable(_ provider: ProviderKind) throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        // Homebrew's official executable precedes user launchers (e.g. OpenCodex).
        var paths = ["/opt/homebrew/bin/\(provider == .codex ? "codex" : "claude")", "/usr/local/bin/\(provider == .codex ? "codex" : "claude")"]
        if provider == .claude { paths += [home.appendingPathComponent(".local/bin/claude").path] }
        paths += [home.appendingPathComponent(".bun/bin/\(provider == .codex ? "codex" : "claude")").path]
        guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw AccountError.message("Could not find the \(provider.displayName) CLI. Install the official CLI and try again.")
        }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath()
    }
    static func processEnvironment() -> [String: String] {
        let source = ProcessInfo.processInfo.environment
        var env: [String: String] = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": "/opt/homebrew/bin:/usr/local/bin:" + FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".bun/bin").path + ":/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
        for key in ["USER", "LOGNAME", "TMPDIR"] { env[key] = source[key] }
        return env
    }
    static func environment(provider: ProviderKind, directory: URL) -> [String: String] {
        var env = processEnvironment()
        env[provider == .codex ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"] = directory.path
        if provider == .claude {
            // Current Claude Code can namespace Keychain separately from its
            // config directory. Both must belong to the same AgentBar account.
            env["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = directory.path
        }
        return env
    }
    static func claudeStatus(directory: URL, control: OperationControl = OperationControl()) throws -> AccountIdentity {
        let session = try ProcessSession(executable: executable(.claude), arguments: ["auth", "status", "--json"],
            environment: environment(provider: .claude, directory: directory),
            directory: directory)
        defer { session.stop() }
        let data = try session.collect(until: Date().addingTimeInterval(20), control: control)
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              payload["loggedIn"] as? Bool == true,
              payload["authMethod"] as? String == "claude.ai" else { throw AccountError.loginRequired }
        return AccountIdentity(email: payload["email"] as? String,
                               organization: payload["orgName"] as? String,
                               organizationID: payload["orgId"] as? String,
                               stableID: payload["accountId"] as? String)
    }
}

final class CodexRPC {
    private let session: ProcessSession
    private let control: OperationControl
    private let requestTimeout: TimeInterval
    private var nextID = 1
    private var notifications: [[String: Any]] = []

    init(directory: URL, control: OperationControl = OperationControl(), executable: URL? = nil,
         environment: [String: String]? = nil, requestTimeout: TimeInterval = 25) throws {
        self.control = control
        self.requestTimeout = requestTimeout
        let arguments = ["app-server", "--listen", "stdio://", "-c", "cli_auth_credentials_store=\"file\""]
        // Official file storage isolates auth and makes deletion exact. No tokens in app settings.
        session = try ProcessSession(executable: executable ?? ProviderCLI.executable(.codex), arguments: arguments,
            environment: environment ?? ProviderCLI.environment(provider: .codex, directory: directory),
            directory: directory)
        do {
            _ = try request("initialize", params: ["clientInfo": ["name": "agent-bar", "version": "0.2.0"],
                                                 "capabilities": ["experimentalApi": true]])
            try session.send(["method": "initialized"])
        } catch { session.stop(); throw error }
    }
    func request(_ method: String, params: Any = NSNull(), timeout: TimeInterval? = nil) throws -> [String: Any] {
        let id = nextID; nextID += 1
        try session.send(["id": id, "method": method, "params": params])
        let deadline = Date().addingTimeInterval(timeout ?? requestTimeout)
        while true {
            let data = try session.line(until: deadline, control: control)
            guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if value["id"] as? Int == id {
                if let error = value["error"] as? [String: Any] {
                    let message = (error["message"] as? String ?? "").lowercased()
                    if message.contains("401") || message.contains("unauthorized") || message.contains("not logged") || message.contains("authentication") {
                        throw AccountError.loginRequired
                    }
                    if message.contains("429") || message.contains("rate limit") {
                        let detail = error["data"] as? [String: Any]
                        throw AccountError.rateLimited(max(60, detail?["retryAfterSeconds"] as? Double ?? 60))
                    }
                    // Avoid surfacing raw provider payloads/credentials.
                    if method == "account/rateLimits/read" { throw AccountError.message("Could not load Codex usage. Check your sign-in status.") }
                    throw AccountError.message("Codex request failed: \(method).")
                }
                return value["result"] as? [String: Any] ?? [:]
            }
            if value["method"] != nil { notifications.append(value) }
        }
    }
    func identity(refresh: Bool = false) throws -> AccountIdentity {
        let result = try request("account/read", params: ["refreshToken": refresh])
        guard let account = result["account"] as? [String: Any], account["type"] as? String == "chatgpt" else {
            throw AccountError.loginRequired
        }
        return AccountIdentity(email: account["email"] as? String, organization: nil, organizationID: nil,
                               stableID: account["accountId"] as? String)
    }
    func login(openURL: @Sendable (URL) -> Void) throws -> AccountIdentity {
        let result = try request("account/login/start", params: ["type": "chatgpt"])
        guard let loginID = result["loginId"] as? String,
              let raw = result["authUrl"] as? String, let url = URL(string: raw),
              url.scheme == "https", let host = url.host,
              host == "auth.openai.com" || host.hasSuffix(".openai.com") else {
            throw AccountError.message("Codex did not return a valid official sign-in URL.")
        }
        openURL(url)
        do {
            let deadline = Date().addingTimeInterval(300)
            while true {
                let value: [String: Any]
                if !notifications.isEmpty { value = notifications.removeFirst() }
                else {
                    let data = try session.line(until: deadline, control: control)
                    guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    value = parsed
                }
                guard value["method"] as? String == "account/login/completed",
                      let params = value["params"] as? [String: Any], params["loginId"] as? String == loginID else { continue }
                guard params["success"] as? Bool == true else { throw AccountError.message("Codex sign-in did not complete.") }
                return try identity()
            }
        } catch {
            try? session.send(["id": 999999, "method": "account/login/cancel", "params": ["loginId": loginID]])
            throw error
        }
    }
    func stop() { session.stop() }
    deinit { stop() }
}
