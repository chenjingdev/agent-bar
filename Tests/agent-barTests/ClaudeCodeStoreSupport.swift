import Foundation
import Testing
@testable import agent_bar

// Claude Code and the Keychain as a store sees them: the fake world from the engine tests, with doors a test can hold
// shut, and the order things were asked in. Nothing here runs a real program or touches a real login.
final class ClaudeCodeGates: ClaudeCLI, ClaudeKeychain, @unchecked Sendable {
    let world: FakeClaudeWorld
    private let defaultService: String
    private let lock = NSLock()
    private var isThere = true
    private var versionHold: FakeClaudeWorld.Hold?
    private var browserHold: FakeClaudeWorld.Hold?
    private var keychainHold: FakeClaudeWorld.Hold?
    private var recorded: [String] = []
    private var versionHook: (@Sendable () -> Void)?

    init(world: FakeClaudeWorld, defaultSlot: ClaudeSlot) {
        self.world = world
        defaultService = defaultSlot.service
    }

    // Whether a `claude` program can be found.
    var installed: Bool {
        get { locked { isThere } }
        set { locked { isThere = newValue } }
    }
    // What was asked of Claude Code and the Keychain, in order.
    var calls: [String] { locked { recorded } }

    // The next version check stops until released.
    func holdVersion() -> FakeClaudeWorld.Hold { let hold = FakeClaudeWorld.Hold(); locked { versionHold = hold }; return hold }
    // The next browser sign-in opens its page and then waits until released or cancelled.
    func holdBrowser() -> FakeClaudeWorld.Hold { let hold = FakeClaudeWorld.Hold(); locked { browserHold = hold }; return hold }
    // The next question about whether a Keychain item exists stops until released.
    func holdKeychain() -> FakeClaudeWorld.Hold { let hold = FakeClaudeWorld.Hold(); locked { keychainHold = hold }; return hold }
    // Runs on the thread that asks for the version.
    func onVersion(_ hook: @escaping @Sendable () -> Void) { locked { versionHook = hook } }

    // MARK: ClaudeCLI

    func isInstalled() -> Bool { installed }

    func run(_ arguments: [String], environment: [String: String], directory: URL, timeout: TimeInterval) throws -> ClaudeCLIOutput {
        if arguments == ["--version"] {
            let (hold, hook): (FakeClaudeWorld.Hold?, (@Sendable () -> Void)?) = locked {
                recorded.append("version")
                defer { versionHold = nil }
                return (versionHold, versionHook)
            }
            hook?()
            if let hold { hold.entered.signal(); hold.release.wait() }
        } else if arguments.first == "auth" {
            locked { recorded.append("login") }
        }
        return try world.run(arguments, environment: environment, directory: directory, timeout: timeout)
    }

    func browserLogin(directory: URL, control: OperationControl, openURL: @Sendable (URL) -> Void) throws {
        let hold: FakeClaudeWorld.Hold? = locked {
            recorded.append("browser")
            defer { browserHold = nil }
            return browserHold
        }
        guard let hold else {
            try world.browserLogin(directory: directory, control: control, openURL: openURL)
            return
        }
        // The page is open and nobody has signed in yet. A test that forgets to end the wait fails instead of hanging.
        openURL(FakeClaudeWorld.browserURL)
        hold.entered.signal()
        let giveUp = Date().addingTimeInterval(30)
        while !control.cancelled, hold.release.wait(timeout: .now() + 0.02) == .timedOut {
            if Date() > giveUp { throw AccountError.timeout }
        }
        if control.cancelled { throw AccountError.cancelled }
        try world.browserLogin(directory: directory, control: control, openURL: { _ in })
    }

    // MARK: ClaudeKeychain

    func contains(service: String, account: String) throws -> Bool {
        let hold: FakeClaudeWorld.Hold? = locked {
            recorded.append("contains \(name(of: service))")
            defer { keychainHold = nil }
            return keychainHold
        }
        if let hold { hold.entered.signal(); hold.release.wait() }
        return try world.contains(service: service, account: account)
    }

    func readSecret(service: String, account: String) throws -> Data? {
        locked { recorded.append("read \(name(of: service))") }
        return try world.readSecret(service: service, account: account)
    }

    func delete(service: String, account: String) throws {
        locked { recorded.append("delete \(name(of: service))") }
        try world.delete(service: service, account: account)
    }

    private func name(of service: String) -> String { service == defaultService ? "default" : "lend" }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}

// What the usage reading says for each account: fine, or that it must sign in again.
final class SnapshotPlan: @unchecked Sendable {
    private let lock = NSLock()
    private var needsSignIn: Set<UUID> = []

    func requireSignIn(_ id: UUID) { lock.lock(); needsSignIn.insert(id); lock.unlock() }

    func snapshot(for account: UsageAccount) -> ProviderSnapshot {
        lock.lock(); let blocked = needsSignIn.contains(account.id); lock.unlock()
        guard !blocked else { return ProviderSnapshot.placeholder(for: account.provider).failed("Sign-in required.", requiresLogin: true) }
        return Self.usage(for: account.provider)
    }

    static func usage(for provider: ProviderKind) -> ProviderSnapshot {
        let now = Date.now
        return ProviderSnapshot(
            provider: provider, updatedAt: now,
            fiveHour: WindowSummary(tokens: 42, limitTokens: 100, resetAt: now.addingTimeInterval(3 * 3600), displayStyle: .percentage),
            weekly: WindowSummary(tokens: 18, limitTokens: 100, resetAt: now.addingTimeInterval(4 * 86_400), displayStyle: .percentage),
            modelWeeklies: [], planName: "Max", sourceDescription: provider.sourceDescription, note: nil, isStale: false,
            requiresLogin: false)
    }
}

// A store wired to the fake Claude Code: a data directory, accounts that the fake world knows, a default login that
// lives in the temporary directory, and a browser that only records what it was asked to open.
@MainActor
final class StoreFixture {
    let switching: SwitchFixture
    let gates: ClaudeCodeGates
    let plan: SnapshotPlan
    let opened: Recorder<URL>
    let store: UsageStore
    // The engine the store works through; a test can use it beside the store, as somebody else who has the engine busy.
    let engine: ClaudeCodeSwitcher
    let accounts: [UsageAccount]
    // The hold on the first Keychain question, when the fixture was made with `holdingKeychain`.
    let launchHold: FakeClaudeWorld.Hold?
    private let suite: String
    private let defaults: UserDefaults

    var world: FakeClaudeWorld { switching.world }
    var files: AccountFiles { switching.files }

    // `names` are Claude accounts; `signedIn` is the one Claude Code starts with; `saved` have a login waiting in their
    // own folder. `prepare` sets up anything else in the fake world before the store exists.
    init(_ names: [String], extra: [UsageAccount] = [], stableID: Bool = true, signedIn: String? = nil, saved: [String] = [],
         autoRefresh: Bool = false, browserOpens: Bool = true, holdingKeychain: Bool = false,
         prepare: (SwitchFixture) throws -> Void = { _ in }) throws {
        let switching = try SwitchFixture()
        let made = names.map { switching.addAccount($0, stableID: stableID) } + extra
        extra.forEach { switching.world.register($0) }
        if let signedIn { switching.world.signIn(switching.defaultSlot, as: "\(signedIn)@example.test") }
        for name in saved { try switching.saveLogin(for: try #require(made.first { $0.name == name })) }
        try prepare(switching)
        let gates = ClaudeCodeGates(world: switching.world, defaultSlot: switching.defaultSlot)
        // A store that starts by itself asks the Keychain at once, so the hold has to exist before it does.
        launchHold = holdingKeychain ? gates.holdKeychain() : nil
        let world = switching.world
        let switcher = ClaudeCodeSwitcher(files: switching.files, defaultSlot: switching.defaultSlot, cli: gates, keychain: gates,
                                          pause: { world.recordPause($0) }, now: { Date() })
        var registry = AccountRegistry(accounts: made); registry.repairRepresentatives()
        try switching.files.write(registry, to: switching.files.registryURL)
        let suite = "claude-code-store-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let plan = SnapshotPlan(), opened = Recorder<URL>()
        self.switching = switching
        self.gates = gates
        self.plan = plan
        self.opened = opened
        self.engine = switcher
        self.accounts = made
        self.suite = suite
        self.defaults = defaults
        store = UsageStore(settings: AppSettings(defaults: defaults), files: switching.files, autoRefresh: autoRefresh,
                           loadAccount: { account, _ in plan.snapshot(for: account) }, claudeCode: switcher,
                           claudeCodeBrowser: BrowserLoginLauncher(openURL: { opened.add($0); return browserOpens }))
    }

    func close() {
        store.shutdown()
        defaults.removePersistentDomain(forName: suite)
    }

    func account(_ name: String) -> UsageAccount {
        store.accounts.first { $0.name == name } ?? accounts.first { $0.name == name }!
    }
    func panel(_ name: String) -> ClaudeCodePanel { store.claudeCodePanel(for: account(name)) }
    // The account's line in Settings › Accounts.
    func setup(_ name: String) -> ClaudeCodeSetup { store.claudeCodeSetup(for: account(name)) }
    // Whether the account's "Sign In…" can be pressed.
    func canSignIn(_ name: String) -> Bool {
        if case .notSetUp(nil) = setup(name).status { return true }
        return false
    }
    func enabled(_ name: String) -> Bool {
        if case .use(true, _) = panel(name).control { return true }
        return false
    }
    func press(_ name: String) { store.useInClaudeCode(account(name)) }
    // "Sign In…" on the account's line in Settings › Accounts.
    func signIn(_ name: String) { store.prepareForClaudeCode(account(name)) }

    // The result line the account's window shows, if any.
    func result(_ name: String) -> (succeeded: Bool, message: String)? {
        for case .result(let succeeded, let message, _) in panel(name).lines { return (succeeded, message) }
        return nil
    }

    // Everything the store does when the app starts.
    func start() async { await store.runClaudeCodeStartup() }
    // Waits for the running switch or sign-in and the reading that follows it.
    func finish() async {
        await store.claudeCodeSwitchTask?.value
        await store.claudeCodePreparationTask?.value
        await store.claudeCodeReading?.value
    }
    // Reads usage and Claude Code's state again and waits for both.
    func refresh() async {
        await store.refresh()
        await store.claudeCodeReading?.value
    }
}

// Polls until the condition holds. The engine works on its own thread, so there is nothing else to wait on.
@MainActor
func waitFor(_ what: String = "the condition", timeout: TimeInterval = 15, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            Issue.record("Timed out waiting for \(what)")
            throw AccountError.timeout
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}
