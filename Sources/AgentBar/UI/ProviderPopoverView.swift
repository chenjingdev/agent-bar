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
                        summaryCard
                        sessionsCard
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
        .frame(width: 392, height: 568, alignment: .topLeading)
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

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Usage Details")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.95))

            SummaryRow(label: "Plan", value: snapshot.planName ?? "n/a")
            SummaryRow(label: "This Mac Today", value: TokenFormatters.compactTokenString(snapshot.todayTokens))
            SummaryRow(label: "This Mac Month", value: TokenFormatters.compactTokenString(snapshot.monthTokens))

            if let note = snapshot.note {
                Text(note)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(AppTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private var sessionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent Sessions (This Mac)")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.95))

            if snapshot.recentSessions.isEmpty {
                Text("최근 세션이 없습니다.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(AppTheme.muted)
            } else {
                ForEach(snapshot.recentSessions) { session in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.title)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        HStack {
                            Text(session.subtitle)
                            Spacer()
                            Text(TokenFormatters.timeString(session.updatedAt))
                        }
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(AppTheme.muted)
                    }

                    if session.id != snapshot.recentSessions.last?.id {
                        Divider().overlay(AppTheme.stroke)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private var footer: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text(snapshot.isStale ? "최근 정상값 \(TokenFormatters.relativeUpdateString(updatedAt: snapshot.updatedAt))" : "마지막 갱신 \(TokenFormatters.relativeUpdateString(updatedAt: snapshot.updatedAt))")
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

    private var cardBackground: some View {
        GlassCardBackground(cornerRadius: 16)
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
                Capsule().fill(AppTheme.track)
                Capsule()
                    .fill(AppTheme.tint(for: provider))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .mask(alignment: .leading) {
                        GeometryReader { proxy in
                            Capsule()
                                .frame(width: proxy.size.width * CGFloat(min(window.utilization ?? 0, 1)))
                        }
                    }
            }
            .frame(height: 8)

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

            Text("Resets in \(TokenFormatters.resetString(resetAt: window.resetAt))")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.muted)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GlassCardBackground(cornerRadius: 16))
    }
}

private struct SummaryRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(AppTheme.muted)
            Spacer()
            Text(value)
                .foregroundStyle(.white)
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded))
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
