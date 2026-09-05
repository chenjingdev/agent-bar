import SwiftUI

enum AppTheme {
    static let panelBackground = Color(red: 0.22, green: 0.17, blue: 0.20)
    static let cardBackground = Color(red: 0.26, green: 0.20, blue: 0.23)
    static let stroke = Color.white.opacity(0.08)
    static let glassStroke = Color.white.opacity(0.14)
    static let muted = Color.white.opacity(0.58)
    static let track = Color.white.opacity(0.14)
    static let surface = Color(red: 0.27, green: 0.21, blue: 0.24)
    static let accentGlow = Color(red: 0.48, green: 0.35, blue: 0.90)

    // Compact menu-bar bars need more luminance separation than the larger
    // popover bars. Keep these colors scoped to the status item so the
    // popover's softer glass treatment remains unchanged.
    static let compactTrack = Color.white.opacity(0.22)
    static let compactTrackStroke = Color.white.opacity(0.26)
    static let compactUnavailableTrack = Color.white.opacity(0.06)
    static let compactUnavailableStroke = Color.white.opacity(0.30)
    static let compactAccentGlow = Color(red: 0.69, green: 0.58, blue: 1.00)

    static func tint(for provider: ProviderKind) -> Color {
        switch provider {
        case .claude:
            return Color(red: 0.22, green: 0.88, blue: 0.40)
        case .codex:
            return Color(red: 0.95, green: 0.58, blue: 0.30)
        }
    }

    static func accent(for provider: ProviderKind) -> Color {
        switch provider {
        case .claude:
            return Color(red: 0.17, green: 0.52, blue: 0.95)
        case .codex:
            return Color(red: 0.50, green: 0.39, blue: 0.94)
        }
    }

    static func compactTint(for provider: ProviderKind) -> Color {
        switch provider {
        case .claude:
            return Color(red: 0.42, green: 1.00, blue: 0.56)
        case .codex:
            return Color(red: 1.00, green: 0.66, blue: 0.36)
        }
    }

    static func compactAccent(for provider: ProviderKind) -> Color {
        switch provider {
        case .claude:
            return Color(red: 0.35, green: 0.72, blue: 1.00)
        case .codex:
            return Color(red: 0.69, green: 0.58, blue: 1.00)
        }
    }
}
