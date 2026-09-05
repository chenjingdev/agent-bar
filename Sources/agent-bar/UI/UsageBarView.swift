import SwiftUI

enum UsageBarValue: Equatable {
    case available(Double)
    case unavailable

    init(utilization: Double?) {
        if let utilization {
            self = .available(utilization)
        } else {
            self = .unavailable
        }
    }

    var utilization: Double? {
        switch self {
        case .available(let utilization):
            return utilization
        case .unavailable:
            return nil
        }
    }

    var isAvailable: Bool {
        if case .available = self {
            return true
        }
        return false
    }
}

enum UsageBarAppearance {
    case standard
    case compact
}

struct UsageBarView: View {
    let value: UsageBarValue
    let fill: Color
    var height: CGFloat = 8
    var minimumVisibleWidth: CGFloat = 2
    var appearance: UsageBarAppearance = .standard

    init(
        value: UsageBarValue,
        fill: Color,
        height: CGFloat = 8,
        minimumVisibleWidth: CGFloat = 2,
        appearance: UsageBarAppearance = .standard
    ) {
        self.value = value
        self.fill = fill
        self.height = height
        self.minimumVisibleWidth = minimumVisibleWidth
        self.appearance = appearance
    }

    init(
        utilization: Double?,
        fill: Color,
        height: CGFloat = 8,
        minimumVisibleWidth: CGFloat = 2,
        appearance: UsageBarAppearance = .standard
    ) {
        self.init(
            value: UsageBarValue(utilization: utilization),
            fill: fill,
            height: height,
            minimumVisibleWidth: minimumVisibleWidth,
            appearance: appearance
        )
    }

    private var clampedUtilization: Double {
        min(max(value.utilization ?? 0, 0), 1)
    }

    var body: some View {
        GeometryReader { proxy in
            let fillWidth = visibleFillWidth(totalWidth: proxy.size.width)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(trackFill)

                Capsule()
                    .strokeBorder(trackStroke, style: trackStrokeStyle)

                if fillWidth > 0 {
                    fillView(fillWidth: fillWidth)
                }
            }
        }
        .frame(height: height)
    }

    @ViewBuilder
    private func fillView(fillWidth: CGFloat) -> some View {
        switch appearance {
        case .standard:
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [
                            fill.opacity(0.78),
                            fill
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: fillWidth)
                .shadow(color: fill.opacity(0.24), radius: 2, x: 0, y: 0)
        case .compact:
            // Reveal a full-width capsule rather than shrinking the capsule
            // itself. The straight progress edge makes tiny percentages read
            // at their true width instead of being swallowed by round caps.
            Capsule()
                .fill(fill)
                .overlay(
                    Capsule()
                        .strokeBorder(Color.white.opacity(0.28), lineWidth: 0.55)
                )
                .mask(alignment: .leading) {
                    Rectangle()
                        .frame(width: fillWidth)
                }
        }
    }

    private var trackFill: Color {
        switch appearance {
        case .standard:
            return AppTheme.track
        case .compact:
            return value.isAvailable ? AppTheme.compactTrack : AppTheme.compactUnavailableTrack
        }
    }

    private var trackStroke: Color {
        switch appearance {
        case .standard:
            return Color.white.opacity(0.10)
        case .compact:
            return value.isAvailable ? AppTheme.compactTrackStroke : AppTheme.compactUnavailableStroke
        }
    }

    private var trackStrokeStyle: StrokeStyle {
        switch appearance {
        case .standard:
            return StrokeStyle(lineWidth: 0.7)
        case .compact where value.isAvailable:
            return StrokeStyle(lineWidth: 0.65)
        case .compact:
            return StrokeStyle(
                lineWidth: 0.8,
                lineCap: .round,
                dash: [2, 1.5]
            )
        }
    }

    private func visibleFillWidth(totalWidth: CGFloat) -> CGFloat {
        guard value.isAvailable, totalWidth > 0, clampedUtilization > 0 else { return 0 }
        let proposedWidth = totalWidth * clampedUtilization
        return min(totalWidth, max(proposedWidth, minimumVisibleWidth))
    }
}
