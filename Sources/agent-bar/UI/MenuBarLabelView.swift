import SwiftUI

struct MenuBarLabelView: View {
    let snapshot: ProviderSnapshot

    var body: some View {
        HStack(spacing: 4) {
            ProviderBadge(provider: snapshot.provider, compact: true)
            StackedUsageBars(bars: bars)
                .frame(width: 28, height: 13)

            Text(TokenFormatters.percentageString(for: snapshot.fiveHour.utilization))
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.96))
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(MenuBarGlassBackground(provider: snapshot.provider))
    }

    private var bars: [StackedUsageBars.Bar] {
        var bars: [StackedUsageBars.Bar] = [
            StackedUsageBars.Bar(
                utilization: snapshot.fiveHour.utilization,
                color: AppTheme.tint(for: snapshot.provider)
            ),
            StackedUsageBars.Bar(
                utilization: snapshot.weekly.utilization,
                color: AppTheme.accent(for: snapshot.provider)
            ),
        ]
        if let modelWeekly = snapshot.displayedModelWeeklies.first {
            bars.append(StackedUsageBars.Bar(utilization: modelWeekly.window.utilization, color: AppTheme.accentGlow))
        }
        return bars
    }
}

struct ProviderBadge: View {
    let provider: ProviderKind
    var compact = false

    var body: some View {
        Text(provider.shortName)
            .font(.system(size: compact ? 7.5 : 10, weight: .black, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: compact ? 15 : 24, height: compact ? 13 : 20)
            .background(
                RoundedRectangle(cornerRadius: compact ? 4 : 7, style: .continuous)
                    .fill(AppTheme.accent(for: provider))
            )
    }
}

struct StackedUsageBars: View {
    struct Bar {
        let utilization: Double?
        let color: Color
    }

    let bars: [Bar]

    private var barHeight: CGFloat { bars.count > 2 ? 3 : 5 }
    private var barSpacing: CGFloat { bars.count > 2 ? 2 : 3 }

    var body: some View {
        VStack(spacing: barSpacing) {
            ForEach(Array(bars.enumerated()), id: \.offset) { _, bar in
                UsageBarView(
                    utilization: bar.utilization,
                    fill: bar.color,
                    height: barHeight,
                    minimumVisibleWidth: 1.2
                )
            }
        }
    }
}

private struct MenuBarGlassBackground: View {
    let provider: ProviderKind

    var body: some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.22),
                            Color.white.opacity(0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.34),
                            AppTheme.surface.opacity(0.46)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            AppTheme.accent(for: provider).opacity(0.24),
                            AppTheme.tint(for: provider).opacity(0.10),
                            .clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .blur(radius: 4)

            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.9)

            Capsule(style: .continuous)
                .strokeBorder(Color.black.opacity(0.12), lineWidth: 0.6)
                .padding(0.5)
        }
        .shadow(color: Color.black.opacity(0.18), radius: 8, x: 0, y: 3)
    }
}
