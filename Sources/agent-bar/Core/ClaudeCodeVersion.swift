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
            return "Claude Code \(version) is too old. Update to \(ClaudeCodeVersion.minimum) or newer."
        case .unreadable(let reason): return reason
        }
    }
}
