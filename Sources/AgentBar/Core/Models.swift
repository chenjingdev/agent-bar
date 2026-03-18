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

struct UsageEvent: Identifiable, Hashable {
    let id: String
    let timestamp: Date
    let model: String
    let totalTokens: Int
    let inputTokens: Int
    let outputTokens: Int
    let cachedTokens: Int
    let sessionID: String?
}

struct SessionSummary: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let updatedAt: Date
    let tokens: Int
}

struct ModelSummary: Identifiable, Hashable {
    let id: String
    let name: String
    let tokens: Int
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

struct ProviderSnapshot: Equatable {
    let provider: ProviderKind
    let updatedAt: Date
    let fiveHour: WindowSummary
    let weekly: WindowSummary
    let planName: String?
    let todayTokens: Int
    let monthTokens: Int
    let recentSessions: [SessionSummary]
    let modelBreakdown: [ModelSummary]
    let sourceDescription: String
    let note: String?
    let isStale: Bool

    var topModelName: String {
        modelBreakdown.first?.name ?? "n/a"
    }

    static func placeholder(for provider: ProviderKind) -> ProviderSnapshot {
        ProviderSnapshot(
            provider: provider,
            updatedAt: .now,
            fiveHour: WindowSummary(tokens: 0, limitTokens: 100, resetAt: nil, displayStyle: .percentage),
            weekly: WindowSummary(tokens: 0, limitTokens: 100, resetAt: nil, displayStyle: .percentage),
            planName: nil,
            todayTokens: 0,
            monthTokens: 0,
            recentSessions: [],
            modelBreakdown: [],
            sourceDescription: provider.sourceDescription,
            note: "계정 사용량을 아직 읽지 못했습니다.",
            isStale: true
        )
    }
}
