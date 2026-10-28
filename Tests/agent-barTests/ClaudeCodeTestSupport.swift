import Foundation
import Testing
@testable import agent_bar

// A stand-in for Claude Code and the Keychain. Logins behave the way the real ones do: a login is a
// Keychain item plus an identity file, a refresh token works once, and `claude auth login` fed a token
// replaces whatever the slot held. Nothing here runs a real program or touches a real login.
final class FakeClaudeWorld: ClaudeCLI, ClaudeKeychain, @unchecked Sendable {
    enum Script {
        case timeout
        case networkError
        case invalidGrant(echoToken: Bool)
        // Succeeds, but the slot ends up holding this other person's identity.
        case writesAnotherAccount(String)
        // Does the work, then does not report in time.
        case writesThenTimeout
    }
    enum Browser {
        case signIn(String)
        case timeout
        case failure
    }
    struct Person { let accountUUID: String; let organizationUUID: String }
    struct Call { let arguments: [String]; let environment: [String: String] }
    final class Hold: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
    }

    static let browserURL = URL(string: "https://claude.ai/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A54321%2Fcallback")!

    let files: AccountFiles
    let defaultSlot: ClaudeSlot
    var version = "2.1.312 (Claude Code)\n"

    private let lock = NSLock()
    private var recordedEvents: [String] = []
    private var recordedCalls: [Call] = []
    private var recordedPauses: [TimeInterval] = []
    private var recordedProblems: [String] = []
    private var recordedURLs: [URL] = []
    private var recordedJournals: [ClaudeCodeSwitchJournal?] = []
    private var secrets: [String: Data] = [:]
    private var live: Set<String> = []
    private var owners: [String: String] = [:]
    private var people: [String: Person] = [:]
    private var scripts: [String: [Script]] = [:]
    private var browserPlan: [Browser] = []
    private var labels: [String: String] = [:]
    private var stuck: Set<String> = []
    private var unreadable: Set<String> = []
    private var holds: [String: Hold] = [:]
    private var counter = 0

    init(files: AccountFiles, defaultSlot: ClaudeSlot) {
        self.files = files
        self.defaultSlot = defaultSlot
        labels[defaultSlot.service] = "default"
    }

    // MARK: What a test reads back

    var events: [String] { locked { recordedEvents } }
    var calls: [Call] { locked { recordedCalls } }
    var pauses: [TimeInterval] { locked { recordedPauses } }
    // Anything the engine did that the real Claude Code would not accept.
    var problems: [String] { locked { recordedProblems } }
    var openedURLs: [URL] { locked { recordedURLs } }
    // The journal as it stood when each login command started.
    var journalsAtLogin: [ClaudeCodeSwitchJournal?] { locked { recordedJournals } }
    // Every refresh token that ever existed.
    var allTokens: [String] { locked { Array(owners.keys) } }
    func recordPause(_ seconds: TimeInterval) { locked { recordedPauses.append(seconds) } }

    func hasItem(_ slot: ClaudeSlot) -> Bool { locked { secrets[slot.service] != nil } }
    func person(_ email: String) -> Person { locked { personLocked(email) } }

    // The email in the slot's identity file, when the slot has a Keychain item.
    func email(of slot: ClaudeSlot) -> String? {
        guard hasItem(slot), let data = try? Data(contentsOf: slot.identityFile) else { return nil }
        return ClaudeOAuthAccount(claudeJSON: data)?.email
    }
    func token(in slot: ClaudeSlot) -> String? {
        locked { secrets[slot.service].flatMap(ClaudeLoginCredential.init(keychainData:))?.refreshToken }
    }
    func isLive(_ token: String) -> Bool { locked { live.contains(token) } }

    // MARK: Setting a scene

    func register(_ account: UsageAccount) {
        locked { labels[ClaudeSlot.folder(files.lend(account.id)).service] = "lend(\(account.name))" }
    }
    @discardableResult
    func signIn(_ slot: ClaudeSlot, as email: String, scopes: [String] = ClaudeLoginCredential.defaultScopes) -> String {
        locked { writeLogin(slot, owner: email, identity: email, scopes: scopes) }
    }
    func removeItem(_ slot: ClaudeSlot) { locked { _ = secrets.removeValue(forKey: slot.service) } }
    func setSecret(_ slot: ClaudeSlot, _ data: Data) { locked { secrets[slot.service] = data } }
    // Makes a token stop working, the way a rotation by an open session does.
    func revoke(_ token: String) { locked { _ = live.remove(token) } }
    func script(_ label: String, _ items: Script...) { locked { scripts[label, default: []].append(contentsOf: items) } }
    func plan(_ items: Browser...) { locked { browserPlan.append(contentsOf: items) } }
    func keepItem(_ label: String) { locked { _ = stuck.insert(label) } }
    func failReads(_ label: String) { locked { _ = unreadable.insert(label) } }
    func hold(login label: String) -> Hold {
        let hold = Hold()
        locked { holds[label] = hold }
        return hold
    }

    // MARK: ClaudeCLI

    func run(_ arguments: [String], environment: [String: String], directory: URL, timeout: TimeInterval) throws -> ClaudeCLIOutput {
        let gate: Hold? = locked {
            recordedCalls.append(Call(arguments: arguments, environment: environment))
            // A hold stops one login, then is gone.
            return arguments == ["auth", "login", "--claudeai"] ? holds.removeValue(forKey: label(of: slot(for: environment))) : nil
        }
        if let gate {
            gate.entered.signal()
            gate.release.wait()
        }
        return locked {
            if arguments == ["--version"] {
                recordedEvents.append("version")
                return ClaudeCLIOutput(status: 0, text: version)
            }
            guard arguments == ["auth", "login", "--claudeai"] else {
                recordedProblems.append("unexpected arguments \(arguments)")
                return ClaudeCLIOutput(status: 2, text: "error: unknown command")
            }
            return login(environment: environment)
        }
    }

    func browserLogin(directory: URL, control: OperationControl, openURL: @Sendable (URL) -> Void) throws {
        let next: Browser = locked {
            let slot = ClaudeSlot.folder(directory)
            recordedEvents.append("browser \(label(of: slot))")
            if !FileManager.default.fileExists(atPath: directory.path) { recordedProblems.append("browser sign-in into a missing folder") }
            recordedURLs.append(Self.browserURL)
            return browserPlan.isEmpty ? .failure : browserPlan.removeFirst()
        }
        openURL(Self.browserURL)
        if control.cancelled { throw AccountError.cancelled }
        switch next {
        case .signIn(let email): locked { _ = writeLogin(.folder(directory), owner: email, identity: email, scopes: ClaudeLoginCredential.defaultScopes) }
        case .timeout: throw AccountError.timeout
        case .failure: throw AccountError.message("Claude sign-in did not complete.")
        }
    }

    // MARK: ClaudeKeychain

    func contains(service: String, account: String) throws -> Bool { locked { secrets[service] != nil } }

    func readSecret(service: String, account: String) throws -> Data? {
        try locked {
            let name = labels[service] ?? service
            recordedEvents.append("read \(name)")
            if unreadable.contains(name) { throw AccountError.message("The Keychain is locked.") }
            return secrets[service]
        }
    }

    func delete(service: String, account: String) throws {
        locked {
            let name = labels[service] ?? service
            recordedEvents.append("delete \(name)")
            if !stuck.contains(name) { secrets[service] = nil }
        }
    }

    // MARK: Inside the lock

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    private func personLocked(_ email: String) -> Person {
        if let known = people[email] { return known }
        let made = Person(accountUUID: UUID().uuidString.lowercased(), organizationUUID: UUID().uuidString.lowercased())
        people[email] = made
        return made
    }

    private func label(of slot: ClaudeSlot) -> String { labels[slot.service] ?? "unknown(\(slot.service))" }

    private func slot(for environment: [String: String]) -> ClaudeSlot {
        let config = environment["CLAUDE_CONFIG_DIR"], secure = environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"]
        guard config != nil || secure != nil else { return defaultSlot }
        if config != secure { recordedProblems.append("the folder variables differ") }
        return .folder(URL(fileURLWithPath: config ?? secure ?? ""))
    }

    private func journalStage() -> String {
        (try? files.read(ClaudeCodeSwitchJournal.self, at: files.claudeCodeSwitchJournalURL))?.stage.rawValue ?? "none"
    }

    private func login(environment: [String: String]) -> ClaudeCLIOutput {
        let slot = slot(for: environment)
        let name = label(of: slot)
        if slot.directory.map({ !FileManager.default.fileExists(atPath: $0.path) }) == true {
            recordedProblems.append("login into a missing folder")
        }
        guard let token = environment["CLAUDE_CODE_OAUTH_REFRESH_TOKEN"] else {
            recordedEvents.append("login \(name) without a token")
            return ClaudeCLIOutput(status: nil, text: "")
        }
        let owner = owners[token] ?? "nobody@example.test"
        let spent = live.contains(token) ? "" : " (spent)"
        recordedJournals.append(try? files.read(ClaudeCodeSwitchJournal.self, at: files.claudeCodeSwitchJournalURL))
        recordedEvents.append("login \(name) <- \(owner.split(separator: "@").first ?? "?")\(spent) [journal \(journalStage())]")
        if var queue = scripts[name], !queue.isEmpty {
            let next = queue.removeFirst()
            scripts[name] = queue
            switch next {
            case .timeout: return ClaudeCLIOutput(status: nil, text: "")
            case .networkError: return ClaudeCLIOutput(status: 1, text: "Login failed: ECONNRESET socket hang up")
            case .invalidGrant(let echo):
                return ClaudeCLIOutput(status: 1, text: "Login failed: invalid_grant" + (echo ? " for refresh token \(token)" : ""))
            case .writesAnotherAccount(let other):
                live.remove(token)
                _ = writeLogin(slot, owner: owner, identity: other, scopes: Self.scopes(environment))
                return ClaudeCLIOutput(status: 0, text: "Login successful.")
            case .writesThenTimeout:
                live.remove(token)
                _ = writeLogin(slot, owner: owner, identity: owner, scopes: Self.scopes(environment))
                return ClaudeCLIOutput(status: nil, text: "")
            }
        }
        guard live.contains(token) else {
            return ClaudeCLIOutput(status: 1, text: "Login failed: invalid_grant: refresh token \(token) is not valid")
        }
        live.remove(token)
        _ = writeLogin(slot, owner: owner, identity: owner, scopes: Self.scopes(environment))
        return ClaudeCLIOutput(status: 0, text: "Login successful.")
    }

    private static func scopes(_ environment: [String: String]) -> [String] {
        (environment["CLAUDE_CODE_OAUTH_SCOPES"] ?? "").split(separator: " ").map(String.init)
    }

    // A fresh login: a new refresh token in the Keychain item and the identity file of `identity`.
    private func writeLogin(_ slot: ClaudeSlot, owner: String, identity: String, scopes: [String]) -> String {
        counter += 1
        let token = "FAKE-REFRESH-\(counter)-\(owner)"
        live.insert(token)
        owners[token] = owner
        let credential: [String: Any] = ["claudeAiOauth": ["accessToken": "FAKE-ACCESS-\(counter)", "refreshToken": token,
                                                           "expiresAt": 1_900_000_000_000, "scopes": scopes, "subscriptionType": "max"]]
        secrets[slot.service] = try? JSONSerialization.data(withJSONObject: credential)
        let person = personLocked(identity)
        let file: [String: Any] = ["numStartups": 3, "projects": [:],
                                   "oauthAccount": ["accountUuid": person.accountUUID, "emailAddress": identity,
                                                    "organizationUuid": person.organizationUUID]]
        try? FileManager.default.createDirectory(at: slot.identityFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: file).write(to: slot.identityFile)
        return token
    }
}

final class Recorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Value] = []
    func add(_ item: Value) { lock.lock(); items.append(item); lock.unlock() }
    var values: [Value] { lock.lock(); defer { lock.unlock() }; return items }
}

// A data directory, a stand-in default login and a switcher wired to the fake world. The default login's files
// live in the temporary directory; the real ~/.claude.json and "Claude Code-credentials" are never named.
final class SwitchFixture: @unchecked Sendable {
    let directory: URL
    let files: AccountFiles
    let defaultSlot: ClaudeSlot
    let world: FakeClaudeWorld
    let switcher: ClaudeCodeSwitcher
    private(set) var accounts: [UsageAccount] = []

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentbar-switch-\(UUID())")
        files = AccountFiles(root: directory.appendingPathComponent("multi-account-v1"))
        try files.createPrivateDirectory(files.root)
        let home = directory.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defaultSlot = .defaultLogin(identityFile: home.appendingPathComponent(".claude.json"),
                                    service: "Claude Code-credentials-TEST", account: "tester")
        let world = FakeClaudeWorld(files: files, defaultSlot: defaultSlot)
        self.world = world
        switcher = ClaudeCodeSwitcher(files: files, defaultSlot: defaultSlot, cli: world, keychain: world,
                                      pause: { world.recordPause($0) }, now: { Date(timeIntervalSince1970: 1_800_000_000) })
    }
    deinit { try? FileManager.default.removeItem(at: directory) }

    @discardableResult
    func addAccount(_ name: String, stableID: Bool = true) -> UsageAccount {
        let email = "\(name)@example.test"
        let person = world.person(email)
        let identity = AccountIdentity(email: email, organization: "\(name) org", organizationID: person.organizationUUID,
                                       stableID: stableID ? person.accountUUID : nil)
        let account = UsageAccount(id: UUID(), provider: .claude, name: name, identity: identity, credentialID: UUID())
        accounts.append(account)
        world.register(account)
        return account
    }

    func lendSlot(_ account: UsageAccount) -> ClaudeSlot { .folder(files.lend(account.id)) }

    @discardableResult
    func signInDefault(_ account: UsageAccount) -> String { world.signIn(defaultSlot, as: "\(account.name)@example.test") }
    @discardableResult
    func signInDefault(email: String) -> String { world.signIn(defaultSlot, as: email) }

    @discardableResult
    func saveLogin(for account: UsageAccount) throws -> String {
        try files.createPrivateDirectory(files.lendRoot)
        try files.createPrivateDirectory(files.lend(account.id))
        return world.signIn(lendSlot(account), as: "\(account.name)@example.test")
    }

    var defaultEmail: String? { world.email(of: defaultSlot) }
    func lendEmail(_ account: UsageAccount) -> String? { world.email(of: lendSlot(account)) }
    func lendFolderExists(_ account: UsageAccount) -> Bool { FileManager.default.fileExists(atPath: files.lend(account.id).path) }

    struct Switch {
        var outcome: ClaudeCodeSwitchOutcome
        var steps: [ClaudeCodeSwitchStep]
    }

    func switchTo(_ target: UsageAccount, confirmed: Bool = false, control: OperationControl = OperationControl(),
                  openURL: @escaping @Sendable (URL) -> Void = { _ in }) -> Switch {
        let steps = Recorder<ClaudeCodeSwitchStep>()
        let outcome = switcher.switchAccount(to: target, among: accounts, confirmedLosingCurrentLogin: confirmed, control: control,
                                             progress: { steps.add($0) }, openURL: openURL)
        return Switch(outcome: outcome, steps: steps.values)
    }

    var journal: ClaudeCodeSwitchJournal? { try? files.read(ClaudeCodeSwitchJournal.self, at: files.claudeCodeSwitchJournalURL) }

    var logURL: URL { LimitResetLog.claudeCodeSwitchURL(root: files.root) }
    var logText: String { (try? String(contentsOf: logURL, encoding: .utf8)) ?? "" }
    var logLines: [[String: Any]] {
        logText.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }
}
