import Foundation

enum ProviderKind: String, CaseIterable, Hashable, Identifiable, Codable, Sendable {
    case claude
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude:
            return "Claude"
        case .codex:
            return "Codex"
        }
    }

    var shortName: String {
        switch self {
        case .claude:
            return "CL"
        case .codex:
            return "CX"
        }
    }

    var sourceDescription: String {
        switch self {
        case .claude:
            return "Anthropic OAuth usage API"
        case .codex:
            return "Codex app-server rate limits"
        }
    }
}

enum WindowDisplayStyle: String, Equatable, Codable, Sendable {
    case tokens
    case percentage
}

struct WindowSummary: Equatable, Codable, Sendable {
    let tokens: Int
    let limitTokens: Int
    let resetAt: Date?
    let displayStyle: WindowDisplayStyle

    var utilization: Double? {
        guard limitTokens > 0 else { return nil }
        return Double(tokens) / Double(limitTokens)
    }
}

// Credits that cover usage beyond the plan limits. A nil balance is unknown, not zero.
struct CreditBalance: Equatable, Codable, Sendable {
    var unlimited = false
    var balance: Double?
}

// Usage limit resets the account can redeem. `coupons` lists them one coupon at a time, soonest
// expiry first with never-expiring ones last; a provider may list fewer resets than it counts.
// `notice` says why the provider may not apply a reset now.
struct UsageLimitResets: Equatable, Codable, Sendable {
    // A coupon the provider uses by its ID: a Codex credit holds one reset, a Claude grant can
    // hold several. `note` says why a coupon that is not `usable` cannot be used now, unless the
    // notice already covers every coupon.
    struct Coupon: Equatable, Codable, Sendable, Identifiable {
        var id: String
        var title: String? = nil
        var count = 1
        var expiresAt: Date? = nil
        var usable = true
        var note: String? = nil
        // The limits it resets, as popover metric IDs ("5h", "weekly", "model:<name>"), when the
        // provider names them; nil means the 5-hour and weekly limits.
        var clears: [String]? = nil
    }

    var available: Int
    var coupons: [Coupon] = []
    var notice: String? = nil
}

extension UsageLimitResets {
    init(available: Int, unsorted coupons: [Coupon], notice: String? = nil) {
        let sorted = coupons.sorted { ($0.expiresAt ?? .distantFuture, $0.id) < ($1.expiresAt ?? .distantFuture, $1.id) }
        self.init(available: available, coupons: sorted, notice: notice)
    }

    // Caches written before coupons had IDs still decode, with the count but no coupons.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(available: try c.decode(Int.self, forKey: .available),
                  coupons: (try? c.decodeIfPresent([Coupon].self, forKey: .coupons)) ?? [],
                  notice: try c.decodeIfPresent(String.self, forKey: .notice))
    }
}

// Claude's money beyond the plan limits, as Claude Code's /usage screen shows it. Amounts are
// in currency units, not minor units.
struct ClaudeCredits: Equatable, Codable, Sendable {
    // A one-time allowance in US dollars, such as a launch credit.
    struct OneTime: Equatable, Codable, Sendable {
        var title: String
        var used: Double
        var limit: Double
        var remaining: Double
        var expiresAt: Date?
        var lockedReason: String? = nil
    }

    // Usage billed beyond the plan limits this month, against its monthly limit.
    struct ExtraUsage: Equatable, Codable, Sendable {
        var enabled: Bool
        var used: Double?
        var monthlyLimit: Double?
        var currency: String
    }

    var oneTime: [OneTime] = []
    var extraUsage: ExtraUsage? = nil
    var prepaidBalance: Double? = nil
    var prepaidCurrency = "USD"

    var isEmpty: Bool { oneTime.isEmpty && extraUsage == nil && prepaidBalance == nil }
}

// The outcome of one reset attempt, shown under the account's coupons until the next attempt.
struct LimitResetResult: Equatable, Sendable {
    var succeeded: Bool
    var message: String
    var finishedAt = Date.now
}

struct ModelWeeklySummary: Equatable, Codable, Sendable {
    let label: String
    let window: WindowSummary

    var isFable: Bool {
        label.localizedCaseInsensitiveContains("fable")
    }

    static let unavailableFable = ModelWeeklySummary(
        label: "Fable",
        window: WindowSummary(tokens: 0, limitTokens: 0, resetAt: nil, displayStyle: .percentage)
    )
}

struct ProviderSnapshot: Equatable, Codable, Sendable {
    let provider: ProviderKind
    let updatedAt: Date
    let fiveHour: WindowSummary?
    let weekly: WindowSummary?
    let modelWeeklies: [ModelWeeklySummary]
    let planName: String?
    let sourceDescription: String
    let note: String?
    let isStale: Bool
    let requiresLogin: Bool
    var retryAt: Date? = nil
    // Both providers report usage limit resets with their limits. Codex reports a credit
    // balance; Claude reports dollar credits and extra usage. Nil when unreported.
    var usageLimitResets: UsageLimitResets? = nil
    var credits: CreditBalance? = nil
    var claudeCredits: ClaudeCredits? = nil

    var reportsCredits: Bool { usageLimitResets != nil || credits != nil || claudeCredits != nil }

    var displayedModelWeeklies: [ModelWeeklySummary] {
        guard provider == .claude else { return modelWeeklies }

        guard let fableIndex = modelWeeklies.firstIndex(where: \.isFable) else {
            return [.unavailableFable] + modelWeeklies
        }

        guard fableIndex != modelWeeklies.startIndex else {
            return modelWeeklies
        }

        var orderedWeeklies = modelWeeklies
        let fableWeekly = orderedWeeklies.remove(at: fableIndex)
        orderedWeeklies.insert(fableWeekly, at: orderedWeeklies.startIndex)
        return orderedWeeklies
    }

    var primaryWindow: WindowSummary? {
        fiveHour ?? weekly
    }

    static func placeholder(for provider: ProviderKind) -> ProviderSnapshot {
        ProviderSnapshot(
            provider: provider,
            updatedAt: .now,
            fiveHour: WindowSummary(tokens: 0, limitTokens: 0, resetAt: nil, displayStyle: .percentage),
            weekly: WindowSummary(tokens: 0, limitTokens: 0, resetAt: nil, displayStyle: .percentage),
            modelWeeklies: [],
            planName: nil,
            sourceDescription: provider.sourceDescription,
            note: "Account usage has not loaded yet.",
            isStale: true,
            requiresLogin: false
        )
    }
}


extension ProviderSnapshot {
    func failed(_ message: String, requiresLogin: Bool = false) -> Self {
        Self(provider: provider, updatedAt: updatedAt, fiveHour: fiveHour, weekly: weekly,
             modelWeeklies: modelWeeklies, planName: planName, sourceDescription: sourceDescription,
             note: message, isStale: true, requiresLogin: requiresLogin, usageLimitResets: usageLimitResets, credits: credits,
             claudeCredits: claudeCredits)
    }
}
