import Foundation

/// Reads Antigravity limits without ever holding the Antigravity sign-in:
/// Google's terms forbid third-party software using it, so AgentBar asks
/// Antigravity's own software. With `agy` installed, AgentBar runs `agy -p /usage`,
/// which prints the quota report without starting a model turn. Without it,
/// AgentBar asks the Antigravity app's local language server while the app runs.
/// Either way only the one account signed in there can be read.
///
/// Experimental: neither report is a documented interface and either may
/// change with any Antigravity update. The app's server shape follows
/// open-source quota monitors.
struct AntigravityUsageProvider: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    struct Endpoint: Equatable, Sendable {
        let port: Int
        let token: String
    }

    struct Status: Equatable, Sendable {
        let email: String?
        let plan: String?
    }

    /// What one `agy -p /usage` run left: its report, its own log, and whether
    /// it was stopped because `agy` wasn't signed in.
    struct AgyRun: Sendable {
        var output: Data
        var log: String
        var signedOut: Bool
    }

    var expectedIdentity: AccountIdentity?
    var control = OperationControl()
    /// The installed `agy`, used in preference to the app's server.
    var agy: @Sendable () -> URL? = { AntigravityUsageProvider.installedAgy() }
    var runAgy: @Sendable (URL, OperationControl) throws -> AgyRun = { try AntigravityUsageProvider.run(agy: $0, control: $1) }
    var locate: @Sendable () -> Endpoint? = { AntigravityUsageProvider.discover() }
    var transport: Transport = { try await URLSession.shared.data(for: $0) }

    // MARK: agy, the Antigravity CLI

    static func installedAgy() -> URL? {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/agy").path
        return FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    /// `/usage` prints the quota report as JSON and starts no model turn, so
    /// it uses no quota. The log goes to a file of AgentBar's own, which names the
    /// account `agy` signed in with.
    static func usageArguments(log: URL) -> [String] {
        ["-p", "/usage", "--output-format", "json", "--print-timeout", "60s", "--log-file", log.path]
    }

    /// An `agy` that isn't signed in first fails to sign in silently from its
    /// keyring. Without a terminal, as when AgentBar runs it, it then gives up at
    /// once; from a terminal it starts a browser sign-in and waits a minute.
    /// AgentBar's runs find no `open` on their PATH, so no browser opens either
    /// way, and stop as soon as the log shows either line.
    static let signedOutLines = ["Print mode: silent auth failed", "Starting OAuth authentication flow"]

    static func showsSignedOut(_ log: String) -> Bool { signedOutLines.contains { log.contains($0) } }

    static var agySignInMessage: String {
        String(localized: "agy on this Mac isn't signed in. Run agy in Terminal and sign in, then try again.")
    }

    /// Runs `agy` once in a private, empty folder that is removed afterwards.
    /// `home` stands in for the home folder in tests.
    static func run(agy: URL, control: OperationControl, home: URL? = nil) throws -> AgyRun {
        let fileManager = FileManager.default
        let folder = fileManager.temporaryDirectory.appendingPathComponent("limi-agy-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fileManager.removeItem(at: folder) }
        let log = folder.appendingPathComponent("agy.log")
        var environment = ProviderCLI.processEnvironment()
        environment["PATH"] = folder.path
        if let home { environment["HOME"] = home.path }
        let session = try ProcessSession(executable: agy, arguments: usageArguments(log: log),
                                         environment: environment, directory: folder)
        defer { session.stop() }
        session.closeInput()
        func logText() -> String { (try? String(contentsOf: log, encoding: .utf8)) ?? "" }
        do {
            let output = try session.collect(until: Date().addingTimeInterval(75), control: control) {
                showsSignedOut(logText())
            }
            // agy may give up on its own before the check above sees the log.
            let log = logText()
            return AgyRun(output: output, log: log, signedOut: showsSignedOut(log))
        } catch is ProcessSession.StoppedEarly {
            return AgyRun(output: Data(), log: "", signedOut: true)
        }
    }

    /// "OAuth: authenticated successfully as someone@example.com"
    static func signedInEmail(fromLog log: String) -> String? {
        guard let range = log.range(of: "authenticated successfully as ", options: .backwards) else { return nil }
        let email = log[range.upperBound...].prefix { !$0.isWhitespace }
        return email.contains("@") ? String(email) : nil
    }

    private func askAgy(_ agy: URL) async throws -> AgyRun {
        let run = try await Task.detached(priority: .utility) { [runAgy, control] in try runAgy(agy, control) }.value
        if run.signedOut { throw AccountError.message(Self.agySignInMessage) }
        return run
    }

    // MARK: The Antigravity app's language server

    /// The server's port and session token come from the same Antigravity
    /// process command line (`--hub-port=…`, `--csrf_token=…`): one whose
    /// program lives under Antigravity or is an `agy` binary.
    static func endpoint(fromProcessList output: String) -> Endpoint? {
        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            let program = line.components(separatedBy: " --").first?.trimmingCharacters(in: .whitespaces) ?? ""
            let name = (program as NSString).lastPathComponent.lowercased()
            guard program.localizedCaseInsensitiveContains("antigravity") || name.hasPrefix("agy") else { continue }
            guard let port = flag("--hub-port=", in: line).flatMap(Int.init), (1...65_535).contains(port),
                  let token = flag("--csrf_token=", in: line) else { continue }
            return Endpoint(port: port, token: token)
        }
        return nil
    }

    private static func flag(_ name: String, in line: String) -> String? {
        guard let range = line.range(of: name) else { return nil }
        let value = line[range.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        return value.isEmpty ? nil : String(value)
    }

    /// Lists this user's processes (`ps`), reading command lines only.
    static func discover() -> Endpoint? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axww", "-o", "command="]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return endpoint(fromProcessList: String(decoding: data, as: UTF8.self))
    }

    private func call(_ method: String, at endpoint: Endpoint) async throws -> Data {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(endpoint.port)/exa.language_server_pb.LanguageServerService/\(method)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(endpoint.token, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        request.httpBody = Data("{}".utf8)
        let (data, response) = try await transport(request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AccountError.message(Self.changedMessage)
        }
        return data
    }

    // MARK: Reading the reports

    /// Both reports hold model groups of buckets: `agy -p /usage` under
    /// `command.data.groups` in snake_case, the app's server under
    /// `response.groups` in camelCase. Each bucket has a window ("5h" or
    /// "weekly"), the fraction left and when it resets; a missing fraction
    /// means nothing is used yet.
    static func groups(fromQuotaSummary data: Data) throws -> [LimitGroupSummary] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let report = ((root["command"] as? [String: Any])?["data"] as? [String: Any]) ?? (root["response"] as? [String: Any])
        else { throw AccountError.message(changedMessage) }
        let groups = report["groups"] as? [[String: Any]] ?? []
        return groups.compactMap { group in
            let label = [group["name"], group["displayName"]].lazy.compactMap { $0 as? String }.first { !$0.isEmpty } ?? "Models"
            var fiveHour: WindowSummary?
            var weekly: WindowSummary?
            for bucket in group["buckets"] as? [[String: Any]] ?? [] where bucket["disabled"] as? Bool != true {
                let fraction = (bucket["remaining_fraction"] ?? bucket["remainingFraction"]) as? NSNumber
                let left = min(max(fraction?.doubleValue ?? 1, 0), 1)
                let reset = ((bucket["reset_time"] ?? bucket["resetTime"]) as? String).flatMap(date)
                let window = WindowSummary(tokens: Int(((1 - left) * 100).rounded()), limitTokens: 100,
                                           resetAt: reset, displayStyle: .percentage)
                switch (bucket["window"] as? String)?.lowercased() {
                case "5h", "five_hour", "fivehour": fiveHour = window
                case "weekly", "week", "7d", "seven_day": weekly = window
                default: continue
                }
            }
            return fiveHour == nil && weekly == nil ? nil : LimitGroupSummary(label: label, fiveHour: fiveHour, weekly: weekly)
        }
    }

    static func status(from data: Data) throws -> Status {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let user = root["userStatus"] as? [String: Any] else { throw AccountError.message(changedMessage) }
        let plan = ((user["userTier"] as? [String: Any])?["name"] as? String)
            ?? (((user["planStatus"] as? [String: Any])?["planInfo"] as? [String: Any])?["planName"] as? String)
        return Status(email: (user["email"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                      plan: plan.flatMap { $0.isEmpty ? nil : $0 })
    }

    private static func date(_ text: String) -> Date? {
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return precise.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    // MARK: For AgentBar

    /// The account signed in to `agy`, or to the running app, for connecting
    /// it, with the limits it reports when they can be read.
    func connect() async throws -> (identity: AccountIdentity, snapshot: ProviderSnapshot?) {
        let email: String?
        let snapshot: ProviderSnapshot?
        if let agy = agy() {
            let run = try await askAgy(agy)
            email = Self.signedInEmail(fromLog: run.log)
            snapshot = (try? Self.groups(fromQuotaSummary: run.output)).map {
                self.snapshot(groups: $0, email: email, plan: nil, source: "agy /usage")
            }
        } else {
            guard let endpoint = locate() else {
                throw AccountError.message(String(localized: "Open the Antigravity app and sign in, or install agy, then try again."))
            }
            let status = try Self.status(from: try await call("GetUserStatus", at: endpoint))
            email = status.email
            let groups = try? await Self.groups(fromQuotaSummary: call("RetrieveUserQuotaSummary", at: endpoint))
            snapshot = groups.map { self.snapshot(groups: $0, email: email, plan: status.plan, source: "Antigravity app language server") }
        }
        guard let email else {
            throw AccountError.message(String(localized: "Antigravity didn't report a signed-in account. Sign in to Antigravity, then try again."))
        }
        // The email is all Antigravity reports to tell accounts apart.
        return (AccountIdentity(email: email, stableID: "antigravity:" + email.lowercased()), snapshot)
    }

    func signedInAccount() async throws -> AccountIdentity { try await connect().identity }

    func load() async -> ProviderSnapshot {
        do {
            if let agy = agy() {
                let run = try await askAgy(agy)
                return snapshot(groups: try Self.groups(fromQuotaSummary: run.output),
                                email: Self.signedInEmail(fromLog: run.log), plan: nil, source: "agy /usage")
            }
            guard let endpoint = locate() else {
                return Self.waiting(String(localized: "Antigravity isn't running on this Mac. Open the Antigravity app to refresh."))
            }
            let groups = try Self.groups(fromQuotaSummary: try await call("RetrieveUserQuotaSummary", at: endpoint))
            let status = try? await Self.status(from: call("GetUserStatus", at: endpoint))
            return snapshot(groups: groups, email: status?.email, plan: status?.plan, source: "Antigravity app language server")
        } catch AccountError.message(let text) {
            return Self.waiting(text)
        } catch {
            return Self.waiting(Self.changedMessage)
        }
    }

    private func snapshot(groups: [LimitGroupSummary], email: String?, plan: String?, source: String) -> ProviderSnapshot {
        if let expected = expectedIdentity?.email, let email, expected.caseInsensitiveCompare(email) != .orderedSame {
            return Self.waiting(String(localized: "Antigravity on this Mac is signed in to \(email), not this account."))
        }
        guard let first = groups.first else {
            return Self.waiting(String(localized: "Antigravity reported no limits for this account."))
        }
        return ProviderSnapshot(provider: .antigravity, updatedAt: .now,
                                fiveHour: first.fiveHour ?? Self.empty, weekly: first.weekly ?? Self.empty,
                                modelWeeklies: [], planName: plan, sourceDescription: source,
                                note: nil, isStale: false, requiresLogin: false, limitGroups: groups)
    }

    private static let empty = WindowSummary(tokens: 0, limitTokens: 0, resetAt: nil, displayStyle: .percentage)

    private static var changedMessage: String {
        String(localized: "Couldn't read Antigravity usage. Antigravity may have changed in an update.")
    }

    /// Nothing new to show; the store keeps the last values with this note.
    private static func waiting(_ note: String) -> ProviderSnapshot {
        ProviderSnapshot.placeholder(for: .antigravity).failed(note)
    }
}
