import SwiftUI

struct MenuBarLabelView: View {
    let snapshot: ProviderSnapshot
    let displaySettings: ProviderDisplaySettings

    var body: some View {
        HStack(spacing: 4) {
            if displaySettings.showsBadge {
                ProviderBadge(provider: snapshot.provider, compact: true)
            }

            if displaySettings.showsUsageBars {
                StackedUsageBars(bars: bars)
                    .frame(width: 30, height: 13)
            }

            if displaySettings.showsPercentage {
                Text(TokenFormatters.percentageString(for: snapshot.primaryWindow?.utilization))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.96))
            }
        }
        .frame(height: 14)
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(MenuBarGlassBackground(provider: snapshot.provider))
    }

    var bars: [StackedUsageBars.Bar] {
        switch snapshot.provider {
        case .claude:
            return [
                StackedUsageBars.Bar(
                    utilization: snapshot.fiveHour?.utilization,
                    color: AppTheme.compactTint(for: snapshot.provider)
                ),
                StackedUsageBars.Bar(
                    utilization: snapshot.weekly?.utilization,
                    color: AppTheme.compactAccent(for: snapshot.provider)
                ),
                StackedUsageBars.Bar(
                    utilization: snapshot.displayedModelWeeklies.first?.window.utilization,
                    color: AppTheme.compactAccentGlow
                ),
            ]
        case .codex:
            // Center a single reported window instead of reserving an empty
            // row above it. This keeps weekly-only Codex usage from looking
            // visually pinned to the bottom of the capsule.
            var reportedBars: [StackedUsageBars.Bar] = []
            if let fiveHour = snapshot.fiveHour {
                reportedBars.append(
                    StackedUsageBars.Bar(
                        utilization: fiveHour.utilization,
                        color: AppTheme.compactTint(for: snapshot.provider)
                    )
                )
            }
            if let weekly = snapshot.weekly {
                reportedBars.append(
                    StackedUsageBars.Bar(
                        utilization: weekly.utilization,
                        color: AppTheme.compactAccent(for: snapshot.provider)
                    )
                )
            }
            if reportedBars.isEmpty {
                return [
                    StackedUsageBars.Bar(
                        utilization: nil,
                        color: AppTheme.compactTint(for: snapshot.provider)
                    )
                ]
            }
            return reportedBars
        }
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
        let value: UsageBarValue
        let color: Color

        init(utilization: Double?, color: Color) {
            self.value = UsageBarValue(utilization: utilization)
            self.color = color
        }

        var utilization: Double? {
            value.utilization
        }
    }

    let bars: [Bar]

    private var barHeight: CGFloat { bars.count > 2 ? 3 : 5 }
    private var barSpacing: CGFloat { bars.count > 2 ? 2 : 3 }

    var body: some View {
        VStack(spacing: barSpacing) {
            ForEach(Array(bars.enumerated()), id: \.offset) { _, bar in
                UsageBarView(
                    value: bar.value,
                    fill: bar.color,
                    height: barHeight,
                    minimumVisibleWidth: max(2, barHeight / 2),
                    appearance: .compact
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
