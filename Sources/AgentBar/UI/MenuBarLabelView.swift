import SwiftUI

struct MenuBarLabelView: View {
    let snapshot: ProviderSnapshot

    var body: some View {
        HStack(spacing: 4) {
            ProviderBadge(provider: snapshot.provider, compact: true)
            DualUsageBars(
                primary: snapshot.fiveHour.utilization,
                secondary: snapshot.weekly.utilization,
                primaryColor: AppTheme.tint(for: snapshot.provider),
                secondaryColor: AppTheme.accent(for: snapshot.provider)
            )
            .frame(width: 20, height: 11)

            Text(TokenFormatters.percentageString(for: snapshot.fiveHour.utilization))
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.96))
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(MenuBarGlassBackground(provider: snapshot.provider))
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

struct DualUsageBars: View {
    let primary: Double?
    let secondary: Double?
    let primaryColor: Color
    let secondaryColor: Color

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let topWidth = width * CGFloat(min(primary ?? 0, 1))
            let bottomWidth = width * CGFloat(min(secondary ?? 0, 1))

            VStack(spacing: 2) {
                ZStack(alignment: .leading) {
                    Capsule().fill(AppTheme.track)
                    Capsule().fill(primaryColor).frame(width: topWidth)
                }
                ZStack(alignment: .leading) {
                    Capsule().fill(AppTheme.track)
                    Capsule().fill(secondaryColor).frame(width: bottomWidth)
                }
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
