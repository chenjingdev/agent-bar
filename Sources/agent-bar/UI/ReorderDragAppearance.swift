import SwiftUI

struct DragSlotPlaceholder: View {
    var cornerRadius: CGFloat = 7
    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.accentColor.opacity(0.06))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(Color.accentColor.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct FloatingDragCard: ViewModifier {
    let settling: Bool
    var liftScale: CGFloat = 1.04
    var cornerRadius: CGFloat = 7
    func body(content: Content) -> some View {
        content
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.22), radius: 7, y: 4)
            .opacity(0.82)
            .scaleEffect(settling ? 1 : liftScale)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
