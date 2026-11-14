import AppKit
import SwiftUI

// One account in a group's account list: its mark, badge, plan and address, a cell for each limit the service reports,
// then what needs attention. Plain values, so every state can be drawn without a store, as `ClaudeCodePanel` is.
struct GroupAccountRow: View {
    struct Actions {
        var use: () -> Void = {}
        var setUp: () -> Void = {}
        // "Switch" and "Cancel" on the question about a login Limi does not have.
        var confirm: () -> Void = {}
        var decline: () -> Void = {}
        var openLog: (() -> Void)? = nil
        // "Reset" on the coupon line, a choice of coupon, then OK or Cancel.
        var useCoupon: () -> Void = {}
        var chooseCoupon: (UsageResetCoupons.Claim) -> Void = { _ in }
        var confirmCoupon: () -> Void = {}
        var cancelCoupon: () -> Void = {}
    }

    static let cellsPerLine = 3
    // One text size for the Claude Code button and the "In use" state, so they read as the same line.
    static let buttonFont = Font.caption.weight(.semibold)

    let provider: ProviderKind
    let badge: String
    let address: String
    let snapshot: ProviderSnapshot
    // Whether the account is refreshed at all and whether it is being refreshed now, for the status line.
    var refreshed = true
    var refreshing = false
    var claudeCode: ClaudeCodePanel = .hidden
    // The pointer is over the row: a light background, and the Claude Code button that waits for it shows.
    var highlighted = false
    // The account's usage-reset coupons, on a line under the bars while it has one or one is being used.
    var coupon: CouponPanel = .none
    var actions = Actions()

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ProviderMark(provider: provider, size: 26)
            VStack(alignment: .leading, spacing: 5) {
                titleLine
                cells
                if coupon.shows {
                    CouponLineView(panel: coupon, use: actions.useCoupon, choose: actions.chooseCoupon,
                                   confirm: actions.confirmCoupon,
                                   cancel: actions.cancelCoupon)
                }
                // Only what needs attention; a fresh account says nothing, and the footer says when the list was updated.
                if status(at: .now).tone != .ok {
                    TimelineView(.periodic(from: .now, by: 30)) { context in AccountStatusLine(status: status(at: context.date)) }
                }
                if !claudeCode.lines.isEmpty {
                    ClaudeCodeLinesView(lines: claudeCode.lines, confirm: actions.confirm, decline: actions.decline,
                                        openLog: actions.openLog)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(highlighted ? 0.06 : 0)))
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: badge + " · " + address))
        // The button that waits for the pointer, as an action VoiceOver reaches without one.
        .accessibilityActions {
            if case .use(true, _) = claudeCode.control { Button(ClaudeCodeWords.use, action: actions.use) }
            if case .setUp = claudeCode.control { Button(String(localized: "Set Up in Settings…"), action: actions.setUp) }
        }
    }

    private func status(at now: Date) -> AccountCardStatus {
        .make(snapshot: snapshot, deletionPending: false, refreshed: refreshed, refreshing: refreshing, now: now)
    }

    private var titleLine: some View {
        ZStack(alignment: .leading) {
            // As tall as a line with the Claude Code button, so rows line up whether or not they have one.
            Self.buttonHeightTemplate
            HStack(spacing: 6) {
                Text(verbatim: badge).font(.headline).lineLimit(1).fixedSize()
                if let plan = snapshot.planName, !plan.isEmpty { PlanTag(plan: plan).fixedSize() }
                // The address gives way first: it is cut short before the badge, the plan or the button.
                Text(verbatim: address).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                claudeCodeControl
            }
        }
    }

    @ViewBuilder private var claudeCodeControl: some View {
        switch claudeCode.control {
        case .hidden:
            EmptyView()
        case .inClaudeCode:
            // A state, always shown.
            Text(ClaudeCodeWords.inUse)
                .font(Self.buttonFont)
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.12), in: Capsule())
                .fixedSize()
                .help(ClaudeCodeWords.inUseHelp)
        case .use(let enabled, let help):
            pointerButton(ClaudeCodeWords.use, enabled: enabled, help: help, action: actions.use)
        case .setUp(let help):
            pointerButton(String(localized: "Set Up in Settings…"), enabled: true, help: help, action: actions.setUp)
        }
    }

    // Shows while the pointer is over the row. Until then it takes no width, no clicks and no keys, so the address keeps
    // the room; the row's height stays, since the line is always as tall as the button.
    private func pointerButton(_ title: String, enabled: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(Self.buttonFont) }
            .buttonStyle(PanelBorderedButtonStyle())
            .disabled(!enabled || !highlighted)
            .fixedSize()
            .help(help)
            .opacity(highlighted ? 1 : 0)
            .allowsHitTesting(highlighted)
            .frame(width: highlighted ? nil : 0, alignment: .trailing)
            .accessibilityHidden(true)
    }

    // Draws nothing and takes no width; a line that holds it is as tall as one with the Claude Code button.
    static var buttonHeightTemplate: some View {
        Button {} label: { Text(ClaudeCodeWords.use).font(buttonFont) }
            .buttonStyle(PanelBorderedButtonStyle())
            .fixedSize()
            .hidden()
            .accessibilityHidden(true)
            .frame(width: 0)
    }

    // The limits the service reports, three to a line in their usual order (5h, Week, then each model's week). An account
    // with nothing read yet shows its 5-hour and weekly limits as "--".
    static func cellMetrics(_ snapshot: ProviderSnapshot) -> [DisplayMetric] {
        let reported = DisplayMetric.all(snapshot).filter { $0.window?.utilization != nil }
        if !reported.isEmpty { return reported }
        return [DisplayMetric(id: "5h", title: "5-Hour Session", window: nil), DisplayMetric(id: "weekly", title: "Weekly Limit", window: nil)]
    }

    private var cells: some View {
        let metrics = Self.cellMetrics(snapshot)
        let lines = stride(from: 0, to: metrics.count, by: Self.cellsPerLine).map {
            Array(metrics[$0..<min(metrics.count, $0 + Self.cellsPerLine)])
        }
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(lines.indices, id: \.self) { index in
                // Equal thirds, so the cells of every row line up.
                HStack(alignment: .top, spacing: 14) {
                    ForEach(lines[index]) { UsageCell(metric: $0, cached: snapshot.isStale) }
                    ForEach(lines[index].count..<Self.cellsPerLine, id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                    }
                }
            }
        }
    }
}

// One limit: its name and percentage, a thin bar, and when it resets. Red at the menu bar's alert threshold; cached
// usage is dimmed as the menu bar dims it.
private struct UsageCell: View {
    let metric: DisplayMetric
    let cached: Bool

    var body: some View {
        let utilization = metric.window?.utilization
        let alert = (utilization ?? 0) >= DisplayStatusRenderer.alertThreshold
        let alertColor = Color(nsColor: DisplayStatusRenderer.alertColor)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(metric.cellTitle).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Text(verbatim: TokenFormatters.percentageString(for: utilization))
                    .fontWeight(.semibold).monospacedDigit().fixedSize()
                    .foregroundStyle(cached || utilization == nil ? AnyShapeStyle(.secondary)
                                     : alert ? AnyShapeStyle(alertColor) : AnyShapeStyle(.primary))
            }
            .font(.caption)
            CellBar(utilization: utilization, fill: alert ? alertColor : .accentColor)
                .opacity(cached ? 0.55 : 1)
            // Kept when there is no value, so the cells of a row stay level.
            Text(verbatim: utilization == nil ? " " : TokenFormatters.resetLabelString(resetAt: metric.window?.resetAt))
                .font(.caption2).lineLimit(1)
                .foregroundStyle(alert && !cached ? AnyShapeStyle(alertColor) : AnyShapeStyle(.tertiary))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// A 4-point bar on a track that reads on light and dark panels; a dashed outline when there is no value.
private struct CellBar: View {
    let utilization: Double?
    let fill: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                if let utilization {
                    Capsule().fill(Color.primary.opacity(0.1))
                    let value = min(max(utilization, 0), 1)
                    if value > 0 { Capsule().fill(fill).frame(width: max(2, proxy.size.width * value)) }
                } else {
                    Capsule().strokeBorder(Color.primary.opacity(0.28), style: StrokeStyle(lineWidth: 0.8, lineCap: .round, dash: [2, 1.5]))
                }
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}
