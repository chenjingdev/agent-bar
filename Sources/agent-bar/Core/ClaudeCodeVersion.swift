import Foundation

// `claude --version` prints "2.1.312 (Claude Code)". Switching needs the refresh-token sign-in that
// 2.1.309 added; there is no upper limit, because Claude Code updates itself every few days.
struct ClaudeCodeVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    static let minimum = ClaudeCodeVersion(major: 2, minor: 1, patch: 309)

    let major: Int
    let minor: Int
    let patch: Int

    init(major: Int, minor: Int, patch: Int) {
        self.major = major; self.minor = minor; self.patch = patch
    }

    // The first line must start with three numbers, then end or continue after a space, "(", "-" or "+".
    init?(output: String) {
        let firstLine = output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let pattern = #"^\s*(\d+)\.(\d+)\.(\d+)(?:[\s(+-].*)?$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: firstLine, range: NSRange(firstLine.startIndex..., in: firstLine)),
              match.numberOfRanges == 4 else { return nil }
        let numbers = (1...3).compactMap { index -> Int? in
            Range(match.range(at: index), in: firstLine).flatMap { Int(firstLine[$0]) }
        }
        guard numbers.count == 3 else { return nil }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2])
    }

    var description: String { "\(major).\(minor).\(patch)" }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

enum ClaudeCodeVersionCheck: Equatable, Sendable {
    case supported(ClaudeCodeVersion)
    case tooOld(ClaudeCodeVersion)
    case unreadable(String)

    // Why switching is blocked, in a sentence the popover can show; nil when it is allowed.
    var blockReason: String? {
        switch self {
        case .supported: return nil
        case .tooOld(let version):
            return String(localized: "Claude Code \(version.description) is too old. Update to \(ClaudeCodeVersion.minimum.description) or newer.")
        case .unreadable(let reason): return reason
        }
    }
}

// Every Claude request (usage, coupons, reset) names the installed Claude Code the way Claude Code itself does, as
// agent-bar does. The reset program reads `cli_version` and `surface` from this header: without it the account is
// ineligible ("surface") and lists no grants, and below some version it is ineligible ("cli_version"; 2.1.200 was refused
// and 2.1.295 accepted on 2026-10-09). An older or unreadable install sends that version.
enum ClaudeCouponClient {
    static let minimumVersion = ClaudeCodeVersion(major: 2, minor: 1, patch: 295)

    // The installed version, read on the provider's background task and read again every 10 minutes (Claude Code updates
    // itself), or after a minute when a read failed: a read that timed out right after login must not hold the minimum.
    static var userAgent: String {
        let now = Date()
        state.lock.lock()
        let held = state.value
        state.lock.unlock()
        if let held, now < held.until { return held.agent }
        let version: ClaudeCodeVersion? = {
            guard let output = try? SystemClaudeCLI().run(["--version"],
                environment: ProviderCLI.processEnvironment(),
                directory: FileManager.default.homeDirectoryForCurrentUser, timeout: 5),
                output.status == 0 else { return nil }
            return ClaudeCodeVersion(output: output.text)
        }()
        // A failed read keeps the last version read, if any.
        let agent = version.map { userAgent(installed: $0) } ?? held?.agent ?? userAgent(installed: nil)
        state.lock.lock()
        state.value = (agent, now.addingTimeInterval(version == nil ? 60 : 600))
        state.lock.unlock()
        return agent
    }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var value: (agent: String, until: Date)?
    }
    private static let state = State()

    static func userAgent(installed: ClaudeCodeVersion?) -> String {
        "claude-cli/\(max(installed ?? minimumVersion, minimumVersion)) (external, cli)"
    }
}
