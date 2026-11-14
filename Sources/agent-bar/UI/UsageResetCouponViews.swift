import SwiftUI

// What a row shows about its usage-reset coupons: the coupons it can use, and the line while one is being used.
struct CouponPanel: Equatable {
    enum Line: Equatable {
        case choosing
        // The selected coupon's question, with Cancel and OK.
        case confirmation(UsageResetCoupons.Claim? = nil, UsageResetCoupons.Scope? = nil)
        case progress
        // How it ended, and how many coupons are left after a reset when the service counts them.
        case result(CouponOutcome, left: Int?, scope: UsageResetCoupons.Scope? = nil)
    }

    var coupons: UsageResetCoupons?
    var line: Line?

    static let none = CouponPanel(coupons: nil, line: nil)

    var scope: UsageResetCoupons.Scope { coupons?.scope ?? .fiveHourAndWeekly }
    var selectionOptions: [UsageResetCoupons.Option] { coupons?.options ?? [] }
    // Whether the row has a coupon line at all. With no coupon and nothing going on it has none, as before.
    var shows: Bool { line != nil || coupons?.usable != nil }
}

// Every coupon word in one place, so the line, its help and VoiceOver say the same. `bundle` is for tests that measure the
// Korean words; the app uses the main bundle.
enum CouponWords {
    static func reset(_ bundle: Bundle = .main) -> String { String(localized: "Reset", bundle: bundle) }
    static func ok(_ bundle: Bundle = .main) -> String { String(localized: "OK", bundle: bundle) }
    static func cancel(_ bundle: Bundle = .main) -> String { String(localized: "Cancel", bundle: bundle) }
    static func resetting(_ bundle: Bundle = .main) -> String { String(localized: "Resetting…", bundle: bundle) }
    static func help(_ bundle: Bundle = .main) -> String {
        String(localized: "Click to reset this account's limits with a coupon.", bundle: bundle)
    }
    static func choose(_ bundle: Bundle = .main) -> String {
        String(localized: "Choose a coupon", bundle: bundle)
    }
    static func unavailable(_ reason: UsageResetCoupons.BlockReason?, _ bundle: Bundle = .main) -> String {
        switch reason {
        case .limitRequired: String(localized: "A limit must be reached", bundle: bundle)
        case .noFableUsage: String(localized: "Fable usage needed", bundle: bundle)
        case .cooldown: String(localized: "Cooling down", bundle: bundle)
        case .unavailable, nil: String(localized: "Not ready to use", bundle: bundle)
        }
    }

    // Separate sentences for one and many, since Korean does not add an "s".
    static func count(_ count: Int, _ bundle: Bundle = .main) -> String {
        count == 1 ? String(localized: "1 reset coupon", bundle: bundle) : String(localized: "\(count) reset coupons", bundle: bundle)
    }

    // "3 reset coupons · 1 expires Dec 1", or "1 reset coupon · 5-hour only".
    static func summary(_ coupons: UsageResetCoupons, _ bundle: Bundle = .main) -> String {
        var parts: [String]
        if let total = coupons.totalCount, total > coupons.count {
            if let fableCount = coupons.fableCount, fableCount > 0, fableCount < total {
                parts = [String(localized: "\(total) coupons (\(fableCount) Fable)", bundle: bundle)]
            } else {
                parts = [String(localized: "\(total) coupons total", bundle: bundle)]
            }
            if coupons.canRedeem && (coupons.options?.count ?? 0) < 2 {
                let scope = scopeTitle(coupons.scope, bundle)
                parts.append(String(localized: "\(scope) next", bundle: bundle))
            }
        } else {
            parts = [count(coupons.count, bundle)]
            switch coupons.scope {
            case .fiveHourAndWeekly: break
            case .fiveHour: parts.append(String(localized: "5-hour only", bundle: bundle))
            case .weekly, .fableWeekly, .fiveHourAndFableWeekly: parts.append(scopeTitle(coupons.scope, bundle))
            }
        }
        if let expiry = expiry(coupons, bundle) { parts.append(expiry) }
        return parts.joined(separator: " · ")
    }

    private static func scopeTitle(_ scope: UsageResetCoupons.Scope, _ bundle: Bundle) -> String {
        switch scope {
        case .fiveHourAndWeekly: String(localized: "5h + weekly", bundle: bundle)
        case .fiveHour: String(localized: "5-hour", bundle: bundle)
        case .weekly: String(localized: "Weekly", bundle: bundle)
        case .fableWeekly: String(localized: "Fable weekly", bundle: bundle)
        case .fiveHourAndFableWeekly: String(localized: "5h + Fable weekly", bundle: bundle)
        }
    }

    static func selectionTitle(_ option: UsageResetCoupons.Option, _ bundle: Bundle = .main) -> String {
        let scope = scopeTitle(option.scope, bundle)
        return String(localized: "\(scope) (\(option.count))", bundle: bundle)
    }

    static func selectionDetail(_ option: UsageResetCoupons.Option, _ bundle: Bundle = .main) -> String? {
        guard option.canRedeem else { return unavailable(option.blockReason, bundle) }
        guard let firstExpiry = option.expiries.min() else { return nil }
        let formatted = day(firstExpiry, bundle)
        return String(localized: "Next expiry \(formatted)", bundle: bundle)
    }

    // When the first coupon expires, and how many go then.
    static func expiry(_ coupons: UsageResetCoupons, _ bundle: Bundle = .main) -> String? {
        let sorted = (coupons.options?.flatMap(\.expiries) ?? coupons.expiries).sorted()
        guard let first = sorted.first else { return nil }
        let going = sorted.filter { Calendar.current.isDate($0, inSameDayAs: first) }.count
        let date = day(first, bundle)
        if going >= (coupons.totalCount ?? coupons.count) { return String(localized: "expires \(date)", bundle: bundle) }
        return going == 1 ? String(localized: "1 expires \(date)", bundle: bundle)
                          : String(localized: "\(going) expire \(date)", bundle: bundle)
    }

    // The question before a coupon is used.
    static func question(_ scope: UsageResetCoupons.Scope, _ bundle: Bundle = .main, usedPercent: Int? = nil) -> String {
        if let usedPercent {
            let scope = scopeTitle(scope, bundle)
            let used = "\(usedPercent)%"
            return String(localized: "\(scope) · \(used) used · Use 1 coupon?", bundle: bundle)
        }
        switch scope {
        case .fiveHourAndWeekly: return String(localized: "Use 1 coupon to reset 5h and weekly now?", bundle: bundle)
        case .fiveHour: return String(localized: "Use 1 coupon to reset only the 5h limit?", bundle: bundle)
        case .weekly: return String(localized: "Use 1 coupon to reset the weekly limit?", bundle: bundle)
        case .fableWeekly: return String(localized: "Reset Fable weekly with 1 coupon?", bundle: bundle)
        case .fiveHourAndFableWeekly: return String(localized: "Reset 5h and Fable weekly with 1 coupon?", bundle: bundle)
        }
    }

    static func littleToRecover(_ bundle: Bundle = .main) -> String {
        String(localized: "At 0% usage there is little to recover with a reset.", bundle: bundle)
    }

    static func message(_ outcome: CouponOutcome, left: Int?, scope: UsageResetCoupons.Scope, _ bundle: Bundle = .main) -> String {
        switch outcome {
        case .reset:
            let done = switch scope {
            case .fiveHour: String(localized: "The 5-hour limit is reset.", bundle: bundle)
            case .weekly: String(localized: "The weekly limit is reset.", bundle: bundle)
            case .fiveHourAndWeekly: String(localized: "The 5-hour and weekly limits are reset.", bundle: bundle)
            case .fableWeekly: String(localized: "Fable weekly limit reset.", bundle: bundle)
            case .fiveHourAndFableWeekly: String(localized: "5h and Fable weekly limits reset.", bundle: bundle)
            }
            guard let left, left > 0 else { return done }
            return done + " " + (left == 1 ? String(localized: "1 coupon left.", bundle: bundle)
                                           : String(localized: "\(left) coupons left.", bundle: bundle))
        case .nothingToReset: return String(localized: "Nothing to reset yet. The coupon wasn't used.", bundle: bundle)
        case .conditionsChanged: return String(localized: "Coupon status changed. Check the updated offer.", bundle: bundle)
        case .noCoupon: return String(localized: "No coupons left.", bundle: bundle)
        case .signInAgain: return String(localized: "Couldn't reset. Sign in again in Settings › Accounts.", bundle: bundle)
        case .tryLater: return String(localized: "Couldn't reset. Try again in a moment.", bundle: bundle)
        }
    }

    // "Dec 1" or "12월 1일", in the language the words are in.
    static func day(_ date: Date, _ bundle: Bundle = .main) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: bundle.preferredLocalizations.first ?? "en_US")
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter.string(from: date)
    }
}

// The coupon line under a row's bars. Only the chooser expands the row, with room for every coupon option.
struct CouponLineView: View {
    let panel: CouponPanel
    var use: () -> Void = {}
    var choose: (UsageResetCoupons.Claim) -> Void = { _ in }
    // OK and Cancel on the question.
    var confirm: () -> Void = {}
    var cancel: () -> Void = {}
    // Where the words come from; tests measure the Korean ones.
    var bundle: Bundle = .main

    var body: some View {
        Group {
            if panel.line == .choosing {
                chooser
            } else {
                ZStack(alignment: .leading) {
                    GroupAccountRow.buttonHeightTemplate
                    HStack(spacing: 5) { content }
                }
                .frame(height: Self.height)
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // A line with a bordered button: the caption's line and the button's padding.
    static let height: CGFloat = 20

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                icon("ticket", .secondary)
                Text(verbatim: CouponWords.choose(bundle)).fontWeight(.semibold)
                Spacer(minLength: 6)
                Button(action: cancel) { Text(verbatim: CouponWords.cancel(bundle)).font(GroupAccountRow.buttonFont) }
                    .buttonStyle(PanelBorderedButtonStyle())
            }
            ForEach(Array(panel.selectionOptions.enumerated()), id: \.offset) { _, option in
                let title = CouponWords.selectionTitle(option, bundle)
                let detail = CouponWords.selectionDetail(option, bundle)
                HStack(spacing: 6) {
                    Button { choose(option.claim) } label: {
                        Text(verbatim: title)
                            .font(GroupAccountRow.buttonFont)
                            .frame(minWidth: 122, alignment: .leading)
                    }
                    .buttonStyle(PanelBorderedButtonStyle())
                    .disabled(!option.canRedeem)
                    .accessibilityHint(Text(verbatim: detail ?? ""))
                    if let detail { Text(verbatim: detail).foregroundStyle(.secondary) }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 17)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var content: some View {
        switch panel.line {
        case nil:
            if let coupons = panel.coupons?.usable {
                let summary = CouponWords.summary(coupons, bundle)
                icon("ticket", .secondary)
                words(summary, .secondary).help(summary)
                Spacer(minLength: 6)
                if coupons.canRedeem || panel.selectionOptions.contains(where: \.canRedeem) {
                    Button(action: use) { Text(verbatim: CouponWords.reset(bundle)).font(GroupAccountRow.buttonFont) }
                        .buttonStyle(PanelBorderedButtonStyle())
                        .fixedSize()
                        .help(CouponWords.help(bundle))
                } else {
                    let reason = CouponWords.unavailable(coupons.blockReason, bundle)
                    words(reason, .secondary).fixedSize().help(reason)
                }
            }
        case .choosing:
            EmptyView()
        case .confirmation:
            let usedPercent = panel.coupons?.affectedUsagePercent
            let question = CouponWords.question(panel.scope, bundle, usedPercent: usedPercent)
            let warning = usedPercent == 0 ? CouponWords.littleToRecover(bundle) : nil
            icon(warning == nil ? "ticket" : "exclamationmark.triangle.fill", warning == nil ? .secondary : .orange)
            words(question, warning == nil ? .primary : .orange)
                .help(warning ?? question)
                .accessibilityHint(Text(verbatim: warning ?? ""))
            Spacer(minLength: 6)
            HStack(spacing: 6) {
                Button(action: cancel) { Text(verbatim: CouponWords.cancel(bundle)).font(GroupAccountRow.buttonFont) }
                Button(action: confirm) { Text(verbatim: CouponWords.ok(bundle)).font(GroupAccountRow.buttonFont) }
            }
            .buttonStyle(PanelBorderedButtonStyle())
            .fixedSize()
        case .progress:
            ProgressView().controlSize(.mini).frame(width: 12, height: 12)
            words(CouponWords.resetting(bundle), .secondary)
            Spacer(minLength: 0)
        case .result(let outcome, let left, let scope):
            icon(Self.symbol(outcome), Self.tint(outcome))
            words(CouponWords.message(outcome, left: left, scope: scope ?? panel.scope, bundle), Self.attention(outcome) ? .orange : .secondary)
            Spacer(minLength: 0)
        }
    }

    private func icon(_ name: String, _ color: Color) -> some View {
        Image(systemName: name).foregroundStyle(color).frame(width: 12).accessibilityHidden(true)
    }

    private func words(_ text: String, _ color: Color) -> some View {
        Text(verbatim: text).foregroundStyle(color).lineLimit(1).truncationMode(.tail)
    }

    static func symbol(_ outcome: CouponOutcome) -> String {
        switch outcome {
        case .reset: "checkmark.circle.fill"
        case .nothingToReset, .conditionsChanged: "info.circle"
        case .noCoupon, .signInAgain, .tryLater: "exclamationmark.triangle.fill"
        }
    }

    static func tint(_ outcome: CouponOutcome) -> Color {
        switch outcome {
        case .reset: .green
        case .nothingToReset, .conditionsChanged: .secondary
        case .noCoupon, .signInAgain, .tryLater: .orange
        }
    }

    static func attention(_ outcome: CouponOutcome) -> Bool {
        switch outcome {
        case .reset, .nothingToReset, .conditionsChanged: false
        case .noCoupon, .signInAgain, .tryLater: true
        }
    }
}
