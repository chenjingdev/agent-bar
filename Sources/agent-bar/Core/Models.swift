import Foundation

enum ProviderKind: String, CaseIterable, Hashable, Identifiable {
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

enum WindowDisplayStyle: Equatable {
    case tokens
    case percentage
}

struct WindowSummary: Equatable {
    let tokens: Int
    let limitTokens: Int
    let resetAt: Date?
    let displayStyle: WindowDisplayStyle

    var utilization: Double? {
        guard limitTokens > 0 else { return nil }
        return Double(tokens) / Double(limitTokens)
    }
}

struct ModelWeeklySummary: Equatable {
    let label: String
    let window: WindowSummary
}

struct ProviderSnapshot: Equatable {
    let provider: ProviderKind
    let updatedAt: Date
    let fiveHour: WindowSummary
    let weekly: WindowSummary
    let modelWeeklies: [ModelWeeklySummary]
    let planName: String?
    let sourceDescription: String
    let note: String?
    let isStale: Bool
    let requiresLogin: Bool

    static func placeholder(for provider: ProviderKind) -> ProviderSnapshot {
        ProviderSnapshot(
            provider: provider,
            updatedAt: .now,
            fiveHour: WindowSummary(tokens: 0, limitTokens: 100, resetAt: nil, displayStyle: .percentage),
            weekly: WindowSummary(tokens: 0, limitTokens: 100, resetAt: nil, displayStyle: .percentage),
            modelWeeklies: [],
            planName: nil,
            sourceDescription: provider.sourceDescription,
            note: "Account usage has not loaded yet.",
            isStale: true,
            requiresLogin: false
        )
    }
}
