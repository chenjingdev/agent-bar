import AppKit
import SwiftUI

struct ProviderPopoverView: View {
    let snapshot: ProviderSnapshot

    @EnvironmentObject private var store: UsageStore

    var body: some View {
        ZStack {
            GlassPanelBackground(cornerRadius: 14)

            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header
                        WindowCard(
                            title: "5-Hour Session",
                            window: snapshot.fiveHour,
                            provider: snapshot.provider
                        )
                        WindowCard(
                            title: "Weekly Limit",
                            window: snapshot.weekly,
                            provider: snapshot.provider
                        )
                        if let sonnetWeekly = snapshot.sonnetWeekly {
                            WindowCard(
                                title: "Sonnet Weekly",
                                window: sonnetWeekly,
                                provider: snapshot.provider
                            )
                        }
                        if let note = snapshot.note {
                            Text(note)
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(AppTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 4)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }

                Divider()
                    .overlay(AppTheme.stroke)
                    .padding(.horizontal, 16)

                footer
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
            }
        }
        .frame(width: 392, alignment: .topLeading)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("\(snapshot.provider.displayName) Usage")
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                    ProviderBadge(provider: snapshot.provider)
                }
                Text(snapshot.sourceDescription)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(AppTheme.muted)
            }

            Spacer()

            Button {
                store.refreshNow()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.9))
        }
    }

    private var footer: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text(snapshot.isStale ? "Last good value \(TokenFormatters.relativeUpdateString(updatedAt: snapshot.updatedAt))" : "Last updated \(TokenFormatters.relativeUpdateString(updatedAt: snapshot.updatedAt))")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(AppTheme.muted)
                Text(TokenFormatters.dateTimeString(snapshot.updatedAt))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(AppTheme.muted.opacity(0.8))
            }

            Spacer()

            SettingsLink {
                Text("Settings")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.84))
        }
    }

}

private struct WindowCard: View {
    let title: String
    let window: WindowSummary
    let provider: ProviderKind

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

            HStack {
                switch window.displayStyle {
                case .percentage:
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
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GlassCardBackground(cornerRadius: 16))
    }
}

private struct GlassPanelBackground: View {
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

private struct GlassCardBackground: View {
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
