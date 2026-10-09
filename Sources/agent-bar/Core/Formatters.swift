import Foundation

enum TokenFormatters {
    private static let displayLocale = Locale(identifier: "en_US")

    private static func makeRelativeFormatter() -> RelativeDateTimeFormatter {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.locale = displayLocale
        return formatter
    }

    private static func makeCountdownFormatter() -> DateComponentsFormatter {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.zeroFormattingBehavior = .dropAll
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = displayLocale
        formatter.calendar = calendar
        return formatter
    }

    static func compactTokenString(_ value: Int) -> String {
        let absolute = Double(abs(value))
        let sign = value < 0 ? "-" : ""

        switch absolute {
        case 1_000_000_000...:
            return "\(sign)\(String(format: "%.1f", absolute / 1_000_000_000))B"
        case 1_000_000...:
            return "\(sign)\(String(format: "%.1f", absolute / 1_000_000))M"
        case 1_000...:
            return "\(sign)\(String(format: "%.1f", absolute / 1_000))k"
        default:
            return "\(value)"
        }
    }

    static func percentageString(for utilization: Double?) -> String {
        guard let utilization else { return "--" }
        return "\(Int((utilization * 100).rounded()))%"
    }

    // Whole credits, like the Codex CLI's own status display.
    static func creditString(_ credits: CreditBalance?) -> String {
        guard let credits else { return "--" }
        if credits.unlimited { return "Unlimited" }
        guard let balance = credits.balance else { return "--" }
        let formatter = NumberFormatter()
        formatter.locale = displayLocale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        formatter.roundingMode = .halfUp
        return formatter.string(from: NSNumber(value: balance)) ?? "--"
    }

    // Whole amounts without cents, like Claude Code's /usage screen: "$250", "$12.34".
    static func moneyString(_ amount: Double, currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.locale = displayLocale
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        let digits = amount.rounded() == amount ? 0 : 2
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        return formatter.string(from: NSNumber(value: amount)) ?? "\(currency) \(amount)"
    }

    static func resetLabelString(from now: Date = .now, resetAt: Date?) -> String {
        guard let resetAt else { return "No reset time" }

        let interval = resetAt.timeIntervalSince(now)
        if interval <= 0 {
            return "Resets soon"
        }

        if interval < 60 {
            return "Resets in less than 1m"
        }

        if let formatted = makeCountdownFormatter().string(from: interval), formatted.isEmpty == false {
            return "Resets in \(formatted)"
        }

        return "Resets in \(makeRelativeFormatter().localizedString(for: resetAt, relativeTo: now))"
    }

    // Resets expire within weeks, so the year is left out: "Oct 24, 1:46 PM".
    static func expiryDateString(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = displayLocale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMMd jmm")
        return formatter.string(from: date)
    }

    static func expiryCountdownString(from now: Date = .now, expiresAt: Date) -> String {
        let interval = expiresAt.timeIntervalSince(now)
        if interval <= 0 {
            return "Expired"
        }

        if interval < 60 {
            return "in less than 1m"
        }

        if let formatted = makeCountdownFormatter().string(from: interval), formatted.isEmpty == false {
            return "in \(formatted)"
        }

        return makeRelativeFormatter().localizedString(for: expiresAt, relativeTo: now)
    }

    static func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = displayLocale
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func dateTimeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = displayLocale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func relativeUpdateString(from now: Date = .now, updatedAt: Date) -> String {
        let interval = abs(now.timeIntervalSince(updatedAt))
        if interval < 5 {
            return "just now"
        }
        return makeRelativeFormatter().localizedString(for: updatedAt, relativeTo: now)
    }
}
