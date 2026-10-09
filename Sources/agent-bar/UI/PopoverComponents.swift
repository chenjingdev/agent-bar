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

// Usage limit resets the account can still redeem, one row per coupon with its own button that
// uses that coupon after an inline confirmation, and the account's credits: Codex's balance, or
// Claude's dollar credits and extra usage. Each part appears only when the provider reports it.
struct CreditsCard: View {
    let resets: UsageLimitResets?
    let credits: CreditBalance?
    var claudeCredits: ClaudeCredits? = nil
    let provider: ProviderKind
    // The account's limits as the popover shows them, for the usage a reset would clear.
    var limits: [DisplayMetric] = []
    var redeemingCoupon: String? = nil
    var result: LimitResetResult? = nil
    var redeem: ((String) -> Void)? = nil
    var openLog: (() -> Void)? = nil
    @State private var confirming: String?

    private static let detailFont = Font.system(size: 11, weight: .medium, design: .rounded)
    // A coupon this close to expiring is shown in orange.
    private static let expiringSoon: TimeInterval = 3 * 24 * 60 * 60
    // Below this share of every limit it clears, a reset gives back little.
    private static let lowUsage = 0.5

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let resets {
                VStack(alignment: .leading, spacing: 8) {
                    row("Usage Limit Resets", value: String(resets.available))
                    if !resets.coupons.isEmpty {
                        // Redraws each minute so countdowns, colors and expired buttons stay current
                        // while the popover is open.
                        TimelineView(.everyMinute) { context in
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(resets.coupons) { couponRow($0, now: context.date) }
                            }
                        }
                    }
                    if let notice = resets.notice {
                        Text(notice)
                            .font(Self.detailFont)
                            .foregroundStyle(AppTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                // The coupon can drop off the list while it is being used.
                if let redeemingCoupon, !resets.coupons.contains(where: { $0.id == redeemingCoupon }) {
                    progress("Using a reset…")
                }
                if let result, redeemingCoupon == nil {
                    resultLine(result)
                }
            }
            if credits != nil {
                row("Credits", value: TokenFormatters.creditString(credits))
            }
            if let claudeCredits {
                claudeRows(claudeCredits)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GlassCardBackground(cornerRadius: 16))
        .onDisappear { confirming = nil }
    }

    // Rough height for sizing the popover, including the spacing above the card.
    static func estimatedHeight(resets: UsageLimitResets?, credits: CreditBalance?, claudeCredits: ClaudeCredits? = nil,
                                showsResult: Bool) -> Int {
        guard resets != nil || credits != nil || claudeCredits != nil else { return 0 }
        var height = 36
        if let resets {
            height += 20 + (resets.notice == nil ? 0 : 22)
            height += resets.coupons.reduce(0) { $0 + 40 + ($1.note == nil ? 0 : 16) }
            if showsResult { height += 30 }
        }
        if credits != nil { height += 28 }
        if let claudeCredits {
            height += claudeCredits.oneTime.count * 46
            height += (claudeCredits.extraUsage == nil ? 0 : 28) + (claudeCredits.prepaidBalance == nil ? 0 : 28)
        }
        return height
    }

    // One coupon: what it is and when it expires, with its own button while the provider can
    // use it and it has not expired, and the confirmation for it below.
    private func couponRow(_ coupon: UsageLimitResets.Coupon, now: Date) -> some View {
        let usable = coupon.usable && (coupon.expiresAt.map { $0 > now } ?? true)
        let soon = coupon.expiresAt.map { $0.timeIntervalSince(now) < Self.expiringSoon } ?? false
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(coupon.title ?? "Reset")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                        .help(coupon.title ?? "")
                    Text(Self.couponDetail(coupon, now: now))
                        .foregroundStyle(soon ? Color.orange : AppTheme.muted)
                    if let note = coupon.note { Text(note) }
                }
                .font(Self.detailFont)
                .foregroundStyle(AppTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                couponAction(coupon, usable: usable)
            }
            if let redeem, usable, confirming == coupon.id, redeemingCoupon == nil {
                confirmation(coupon, redeem: redeem)
            }
        }
    }

    private static func couponDetail(_ coupon: UsageLimitResets.Coupon, now: Date) -> String {
        var parts = coupon.count > 1 ? ["\(coupon.count) resets"] : []
        if let date = coupon.expiresAt {
            parts.append("Expires \(TokenFormatters.expiryDateString(date))")
            parts.append(TokenFormatters.expiryCountdownString(from: now, expiresAt: date))
        } else {
            parts.append("No expiry")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func couponAction(_ coupon: UsageLimitResets.Coupon, usable: Bool) -> some View {
        if redeemingCoupon == coupon.id {
            progress("Using…")
        } else if redeem != nil, usable, confirming != coupon.id {
            Button { confirming = coupon.id } label: {
                pill("Use…", systemImage: "arrow.counterclockwise", tint: AppTheme.tint(for: provider))
            }
            .buttonStyle(.plain)
            .disabled(redeemingCoupon != nil)
            .opacity(redeemingCoupon == nil ? 1 : 0.4)
            .help("Uses this reset after you confirm.")
        }
    }

    // Asks before using the coupon, with how much of each limit it clears is used now, and a
    // warning when that is little enough that the reset would mostly be wasted.
    private func confirmation(_ coupon: UsageLimitResets.Coupon, redeem: @escaping (String) -> Void) -> some View {
        let used = usage(clearedBy: coupon)
        let low = used.map(\.used).max().map { $0 < Self.lowUsage } ?? false
        return VStack(alignment: .leading, spacing: 6) {
            Text((coupon.count > 1 ? "Use one of this coupon's \(coupon.count) resets now?" : "Use this reset now?")
                 + " It can't be undone.")
                .foregroundStyle(.white.opacity(0.9))
            if !used.isEmpty {
                Text("Limits it resets, used now: "
                     + used.map { "\($0.label) \(TokenFormatters.percentageString(for: $0.used))" }.joined(separator: " · "))
                    .foregroundStyle(AppTheme.muted)
            }
            if low {
                Text("Usage is low, so this reset would give back little.")
                    .foregroundStyle(Color.orange)
            }
            HStack(spacing: 8) {
                Button { confirming = nil } label: { pill("Cancel", systemImage: nil, tint: .white.opacity(0.85)) }
                Button {
                    confirming = nil
                    redeem(coupon.id)
                } label: { pill("Use Reset", systemImage: "arrow.counterclockwise", tint: AppTheme.tint(for: provider)) }
            }
            .buttonStyle(.plain)
        }
        .font(Self.detailFont)
        .fixedSize(horizontal: false, vertical: true)
    }

    // The limits the coupon clears that have data now, labelled as the popover's cards are.
    private func usage(clearedBy coupon: UsageLimitResets.Coupon) -> [(label: String, used: Double)] {
        (coupon.clears ?? ["5h", "weekly"]).compactMap { id in
            guard let metric = limits.first(where: { $0.id == id }), let used = metric.window?.utilization else { return nil }
            switch metric.id {
            case "5h": return ("5-Hour", used)
            case "weekly": return ("Weekly", used)
            default: return (metric.title, used)
            }
        }
    }

    // The last attempt's outcome, with the log that records each of its steps.
    private func resultLine(_ result: LimitResetResult) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(TokenFormatters.timeString(result.finishedAt)) · \(result.message)")
                .foregroundStyle(result.succeeded ? Color.green : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let openLog {
                Spacer(minLength: 4)
                Button("Open Log", action: openLog)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.tint(for: provider))
                    .help("Opens the reset log, which records each step of every attempt.")
            }
        }
        .font(Self.detailFont)
    }

    private func progress(_ title: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(title)
        }
        .font(Self.detailFont)
        .foregroundStyle(AppTheme.muted)
    }

    @ViewBuilder
    private func claudeRows(_ credits: ClaudeCredits) -> some View {
        ForEach(Array(credits.oneTime.enumerated()), id: \.offset) { _, credit in
            VStack(alignment: .leading, spacing: 4) {
                row(credit.title, value: TokenFormatters.moneyString(credit.remaining, currency: "USD") + " left")
                HStack {
                    Text(Self.creditDetail(credit))
                    Spacer()
                    if let date = credit.expiresAt { Text(TokenFormatters.expiryCountdownString(expiresAt: date)) }
                }
                .font(Self.detailFont)
                .foregroundStyle(AppTheme.muted)
            }
        }
        if let extra = credits.extraUsage {
            row("Extra Usage", value: Self.extraUsageValue(extra))
        }
        if let balance = credits.prepaidBalance {
            row("Usage Credits", value: TokenFormatters.moneyString(balance, currency: credits.prepaidCurrency))
        }
    }

    private static func creditDetail(_ credit: ClaudeCredits.OneTime) -> String {
        var parts = ["\(TokenFormatters.moneyString(credit.used, currency: "USD")) of \(TokenFormatters.moneyString(credit.limit, currency: "USD")) used"]
        if let date = credit.expiresAt { parts.append("Expires \(TokenFormatters.expiryDateString(date))") }
        if let locked = credit.lockedReason { parts.append("Locked (\(locked))") }
        return parts.joined(separator: " · ")
    }

    // Spent this month against the monthly limit, as Claude Code shows it.
    private static func extraUsageValue(_ extra: ClaudeCredits.ExtraUsage) -> String {
        guard extra.enabled else { return "Off" }
        let used = TokenFormatters.moneyString(extra.used ?? 0, currency: extra.currency)
        guard let limit = extra.monthlyLimit else { return used + " spent" }
        return used + " / " + TokenFormatters.moneyString(limit, currency: extra.currency)
    }

    private func pill(_ title: String, systemImage: String?, tint: Color) -> some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            Text(title)
        }
        .font(.system(size: 12, weight: .bold, design: .rounded))
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.white.opacity(0.10)))
        .contentShape(Capsule())
    }

    private func row(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.94))
            Spacer()
            Text(value)
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .foregroundStyle(AppTheme.tint(for: provider))
        }
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
