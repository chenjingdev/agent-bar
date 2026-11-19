import SwiftUI

// Every credit word in one place, so the row, its help and the CLI say the same.
enum CreditWords {
    // "Credits 6,506" · "Launch credit $12 / $250 used · expires Dec 1" · "Usage credits $3.20 / $50" · "Prepaid $0.01"
    static func summary(_ credits: AccountCredits, _ bundle: Bundle = .main) -> String {
        credits.items.map { item($0, bundle) }.joined(separator: " · ")
    }

    static func item(_ item: AccountCredits.Item, _ bundle: Bundle = .main) -> String {
        switch item.kind {
        case .codexBalance:
            if item.unlimited { return String(localized: "Credits unlimited", bundle: bundle) }
            let count = item.balance.map(whole) ?? "--"
            return String(localized: "Credits \(count)", bundle: bundle)
        case .grant:
            let title = item.title ?? String(localized: "Credit", bundle: bundle)
            var text = title
            if let limit = item.limit {
                text += " " + String(localized: "\(money(item.used ?? 0, item.currency)) of \(money(limit, item.currency)) used",
                                     bundle: bundle)
            }
            if let ends = item.endsAt { text += " · " + String(localized: "expires \(CouponWords.day(ends, bundle))", bundle: bundle) }
            return text
        case .extraUsage:
            guard item.enabled == true else { return String(localized: "Usage credits off", bundle: bundle) }
            let used = money(item.used ?? 0, item.currency)
            if let limit = item.limit {
                return String(localized: "Usage credits \(used) / \(money(limit, item.currency))", bundle: bundle)
            }
            return String(localized: "Usage credits \(used) spent", bundle: bundle)
        case .prepaid:
            return String(localized: "Prepaid \(money(item.balance ?? 0, item.currency))", bundle: bundle)
        }
    }

    static func money(_ amount: Double, _ currency: String?) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "en_US")
        formatter.currencyCode = currency ?? "USD"
        let whole = amount.rounded() == amount
        formatter.minimumFractionDigits = whole ? 0 : 2
        formatter.maximumFractionDigits = whole ? 0 : 2
        return formatter.string(from: NSNumber(value: amount)) ?? String(format: "%.2f", amount)
    }

    static func whole(_ count: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: count.rounded(.down))) ?? String(Int(count))
    }
}

// The credit line under a row's bars, beside the coupon line: what the account has besides its plan limits.
struct CreditLineView: View {
    let credits: AccountCredits
    var bundle: Bundle = .main

    var body: some View {
        let summary = CreditWords.summary(credits, bundle)
        HStack(spacing: 5) {
            Image(systemName: "creditcard").foregroundStyle(.secondary).frame(width: 12).accessibilityHidden(true)
            Text(verbatim: summary).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(summary)
        .accessibilityElement(children: .combine)
    }
}
