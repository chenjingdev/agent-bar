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
}
