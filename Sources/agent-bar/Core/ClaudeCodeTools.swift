import Foundation

// The two programs the switch talks to, behind protocols so a test can stand in for both.
// Claude Code is the only thing that writes a login; /usr/bin/security is the only thing that reads
// or removes a Keychain item. AgentBar never touches the Keychain through the Security API for this.

struct ClaudeCLIOutput: Sendable {
    // nil when the command did not finish in time.
    var status: Int32?
    // stdout and stderr together, including what a command that ran out of time had printed. It may hold
    // a secret until `ClaudeCodeOutput.scrubbed` has run.
    var text: String
    var timedOut: Bool { status == nil }
}

protocol ClaudeCLI: Sendable {
    // Runs `claude <arguments>` with exactly `environment`, input closed.
    func run(_ arguments: [String], environment: [String: String], directory: URL, timeout: TimeInterval) throws -> ClaudeCLIOutput
    // Runs the browser sign-in into `directory`: opens the validated URL, waits for the CLI, honors `control`.
    func browserLogin(directory: URL, control: OperationControl, openURL: @Sendable (URL) -> Void) throws
    // Whether a `claude` program can be found at all. A stand-in that is always there need not say so.
    func isInstalled() -> Bool
}

extension ClaudeCLI {
    func isInstalled() -> Bool { true }
}

protocol ClaudeKeychain: Sendable {
    // Whether the item exists. Reads its attributes only, never the secret.
    func contains(service: String, account: String) throws -> Bool
    // The item's secret, or nil when there is no item.
    func readSecret(service: String, account: String) throws -> Data?
    // Removes the item; an item that is already gone is not an error.
    func delete(service: String, account: String) throws
}

struct SystemClaudeCLI: ClaudeCLI {
    var executable: @Sendable () throws -> URL = { try ProviderCLI.executable(.claude) }
    var urlTimeout: TimeInterval = 20
    var loginTimeout: TimeInterval = 300

    func run(_ arguments: [String], environment: [String: String], directory: URL, timeout: TimeInterval) throws -> ClaudeCLIOutput {
        let session = try ProcessSession(executable: executable(), arguments: arguments, environment: environment,
                                         directory: directory, mergeStandardError: true)
        defer { session.stop() }
        session.closeInput()
        let (data, timedOut) = try session.collectPartial(until: Date().addingTimeInterval(timeout), control: OperationControl())
        return ClaudeCLIOutput(status: timedOut ? nil : session.exitStatus, text: String(decoding: data, as: UTF8.self))
    }

    func browserLogin(directory: URL, control: OperationControl, openURL: @Sendable (URL) -> Void) throws {
        try ClaudeOAuthLauncher.browserSignIn(directory: directory, executable: executable(), urlTimeout: urlTimeout,
                                              timeout: loginTimeout, control: control, openURL: openURL) {}
    }

    func isInstalled() -> Bool { (try? executable()) != nil }
}

struct SecurityCommandKeychain: ClaudeKeychain {
    var executable = URL(fileURLWithPath: "/usr/bin/security")
    var timeout: TimeInterval = 15

    func contains(service: String, account: String) throws -> Bool {
        try Self.found(run(["find-generic-password", "-s", service, "-a", account]).status)
    }

    func readSecret(service: String, account: String) throws -> Data? {
        let result = try run(["find-generic-password", "-w", "-s", service, "-a", account])
        guard try Self.found(result.status) else { return nil }
        var secret = result.output
        while let last = secret.last, last == 0x0a || last == 0x0d { secret.removeLast() }
        return secret
    }

    func delete(service: String, account: String) throws {
        _ = try Self.found(run(["delete-generic-password", "-s", service, "-a", account]).status)
    }

    // security exits 44 when no item matches.
    private static func found(_ status: Int32) throws -> Bool {
        if status == 0 { return true }
        if status == 44 { return false }
        throw AccountError.message("The Keychain command failed (status \(status)).")
    }

    private func run(_ arguments: [String]) throws -> (status: Int32, output: Data) {
        let session = try ProcessSession(executable: executable, arguments: arguments,
                                         environment: ProviderCLI.processEnvironment(),
                                         directory: FileManager.default.temporaryDirectory)
        defer { session.stop() }
        session.closeInput()
        let output = try session.collect(until: Date().addingTimeInterval(timeout), control: OperationControl())
        return (session.exitStatus, output)
    }
}

enum ClaudeLoginFailure: Equatable, Sendable {
    // The provider refused the login itself: it will never work again.
    case invalid
    // The network, a timeout or anything else: the same login may work next time.
    case transient
}

enum ClaudeCodeOutput {
    // Claude Code 2.1.312 answers a refresh token the server refuses with exit code 1 and, on stderr,
    // "Login failed: Request failed with status code 400". It does not say invalid_grant.
    private static let invalidPatterns = [
        "invalid_grant",
        #"(?i)(status( code)?|http|error|response)[ :=(]*(400|401)(?![0-9])"#,
        #"(?i)http/[0-9.]+[ ]+(400|401)(?![0-9])"#,
        #"(?i)(?<![0-9])(400|401)[ :)]+(bad request|unauthorized)"#,
    ]

    // invalid_grant, or a 400 or 401 reply, means the saved login is dead. A 403, a 429, a 5xx, a
    // network error ("Login failed: connect ECONNREFUSED 127.0.0.1:9") and anything unrecognised may pass.
    static func classify(_ text: String) -> ClaudeLoginFailure {
        invalidPatterns.contains { text.range(of: $0, options: .regularExpression) != nil } ? .invalid : .transient
    }

    // Output kept in a log: the tokens this call carried and anything that looks like one are removed.
    static func scrubbed(_ text: String, secrets: [String] = [], limit: Int = 2_000) -> String {
        var result = text
        for secret in secrets where !secret.isEmpty {
            result = result.replacingOccurrences(of: secret, with: "[redacted]")
        }
        result = LimitResetLog.redacted(result).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.count > limit ? String(result.prefix(limit)) + "…" : result
    }
}
