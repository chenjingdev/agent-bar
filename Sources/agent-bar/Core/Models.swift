import Foundation

enum ProviderKind: String, CaseIterable, Hashable, Identifiable, Codable, Sendable {
    case claude
    case codex
    /// Experimental: read through `agy`, or the Antigravity app while it runs.
    case antigravity

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude:
            return "Claude"
        case .codex:
            return "Codex"
        case .antigravity:
            return "Antigravity"
        }
    }

    var shortName: String {
        switch self {
        case .claude:
            return "CL"
        case .codex:
            return "CX"
        case .antigravity:
            return "AG"
        }
    }

    var sourceDescription: String {
        switch self {
        case .claude:
            return "Anthropic OAuth usage API"
        case .codex:
            return "Codex app-server rate limits"
        case .antigravity:
            return "agy /usage or the Antigravity app"
        }
    }

    /// The provider's mark: Claude's spark and the Codex prompt.
    var symbolName: String {
        switch self {
        case .claude:
            return "asterisk"
        case .codex:
            return "terminal"
        case .antigravity:
            return "sparkle"
        }
    }

    /// An account as a usage line names it: the provider is added only when the
    /// account's name does not already say it.
    func accountChoiceTitle(_ label: String) -> String {
        label.localizedCaseInsensitiveContains(displayName) ? label : "\(label) · \(displayName)"
    }

    /// What adding an account shows, said for the person choosing one.
    var accountSummary: String {
        switch self {
        case .claude:
            return String(localized: "5-hour and weekly limits of your Claude plan")
        case .codex:
            return String(localized: "5-hour and weekly limits of your ChatGPT plan")
        case .antigravity:
            return String(localized: "Experimental · Supports the one account signed in to agy or the Antigravity app on this Mac.")
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

/// One of Antigravity's model groups (e.g. Gemini, Claude/GPT) with its own
/// 5-hour and weekly limits. Free accounts have only the weekly one.
struct LimitGroupSummary: Equatable, Codable, Sendable {
    let label: String
    let fiveHour: WindowSummary?
    let weekly: WindowSummary?
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
    /// Antigravity's model groups. The first also fills `fiveHour`/`weekly`,
    /// so lines that show those keep working.
    var limitGroups: [LimitGroupSummary]? = nil
    /// Usage-reset coupons the service reported with this usage. Dropped when the usage is only cached.
    var resetCoupons: UsageResetCoupons? = nil

    // Older Claude caches used the Unix epoch to force a refresh.
    var hasKnownUpdateTime: Bool { updatedAt.timeIntervalSince1970 > 0 }

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

    static let notLoadedNote = String(localized: "Account usage has not loaded yet.")

    static func placeholder(for provider: ProviderKind) -> ProviderSnapshot {
        ProviderSnapshot(
            provider: provider,
            updatedAt: .now,
            fiveHour: WindowSummary(tokens: 0, limitTokens: 0, resetAt: nil, displayStyle: .percentage),
            weekly: WindowSummary(tokens: 0, limitTokens: 0, resetAt: nil, displayStyle: .percentage),
            modelWeeklies: [],
            planName: nil,
            sourceDescription: provider.sourceDescription,
            note: notLoadedNote,
            isStale: true,
            requiresLogin: false
        )
    }
}


extension ProviderSnapshot {
    func failed(_ message: String, requiresLogin: Bool = false) -> Self {
        Self(provider: provider, updatedAt: updatedAt, fiveHour: fiveHour, weekly: weekly,
             modelWeeklies: modelWeeklies, planName: planName, sourceDescription: sourceDescription,
             note: message, isStale: true, requiresLogin: requiresLogin, limitGroups: limitGroups)
    }
}
