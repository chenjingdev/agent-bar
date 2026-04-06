import SwiftUI

struct UsageBarView: View {
    let utilization: Double?
    let fill: Color
    var height: CGFloat = 8
    var minimumVisibleWidth: CGFloat = 2

    private var clampedUtilization: Double {
        min(max(utilization ?? 0, 0), 1)
    }

    var body: some View {
        GeometryReader { proxy in
            let fillWidth = visibleFillWidth(totalWidth: proxy.size.width)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(AppTheme.track)

                Capsule()
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.7)

                if fillWidth > 0 {
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
                }
            }
        }
        .frame(height: height)
    }

    private func visibleFillWidth(totalWidth: CGFloat) -> CGFloat {
        guard totalWidth > 0, clampedUtilization > 0 else { return 0 }
        let proposedWidth = totalWidth * clampedUtilization
        return min(totalWidth, max(proposedWidth, minimumVisibleWidth))
    }
}
