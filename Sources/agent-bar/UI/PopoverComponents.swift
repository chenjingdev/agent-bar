import AppKit
import SwiftUI

struct WindowCard: View {
    let title: String
    let window: WindowSummary
    let provider: ProviderKind
    var unavailableMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.94))
                Spacer()
                Text(TokenFormatters.percentageString(for: window.utilization))
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundStyle(AppTheme.tint(for: provider))
            }

            ZStack(alignment: .leading) {
                UsageBarView(
                    utilization: window.utilization,
                    fill: AppTheme.tint(for: provider),
                    height: 8,
                    minimumVisibleWidth: 4
                )
            }

            if window.utilization == nil {
                Text(unavailableMessage ?? "Usage data is unavailable.")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(AppTheme.muted)
            } else {
                HStack {
                    switch window.displayStyle {
                    case .percentage:
                        Text("Remaining \(max(0, 100 - window.tokens))%")
                        Spacer()
                        Text("Used \(window.tokens)%")
                    case .tokens:
                        Text("Used \(TokenFormatters.compactTokenString(window.tokens))")
                        Spacer()
                        Text("Budget \(TokenFormatters.compactTokenString(window.limitTokens))")
                    }
                }
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.muted)

                Text(TokenFormatters.resetLabelString(resetAt: window.resetAt))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(AppTheme.muted)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GlassCardBackground(cornerRadius: 16))
    }
}

struct GlassPanelBackground: View {
    let cornerRadius: CGFloat

    var body: some View {
        ZStack {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .overlay(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.14),
                            Color.white.opacity(0.03)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    LinearGradient(
                        colors: [
                            AppTheme.panelBackground.opacity(0.58),
                            AppTheme.surface.opacity(0.76)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RadialGradient(
                        colors: [
                            AppTheme.accentGlow.opacity(0.18),
                            .clear
                        ],
                        center: .topLeading,
                        startRadius: 20,
                        endRadius: 260
                    )
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(AppTheme.glassStroke, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.16), radius: 14, x: 0, y: 8)
    }
}

struct GlassCardBackground: View {
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.10),
                        Color.white.opacity(0.04)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(AppTheme.cardBackground.opacity(0.70))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
            )
    }
}

private struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .active
        view.material = material
        view.blendingMode = blendingMode
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.state = .active
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
