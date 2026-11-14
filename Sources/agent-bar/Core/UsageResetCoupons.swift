import Foundation

// An account's usage-reset coupons, as the service reported them with its usage. Codex reads them from
// `account/rateLimits/read` (`rateLimitResetCredits`) and uses one with `account/rateLimitResetCredit/consume`; Claude
// reads them from `/api/oauth/usage?cedar_ember=1` and uses one with `POST /api/organizations/{org}/reset_rate_limits`.
struct UsageResetCoupons: Equatable, Codable, Sendable {
    // What one coupon clears.
    enum Scope: String, Equatable, Codable, Sendable {
        // Codex's "Full reset (Weekly + 5 hr)" and Claude's full grants.
        case fiveHourAndWeekly
        // Claude's session grants.
        case fiveHour
        // Claude's weekly grants.
        case weekly
        case fableWeekly
        case fiveHourAndFableWeekly
    }

    // What is sent when one is used.
    enum Claim: Equatable, Codable, Sendable {
        // The credit that expires first, or none to let the service choose.
        case codex(creditID: String?)
        // A granted reset ("cedar_ember").
        case claudeGrant(grantID: String)
    }

    enum BlockReason: String, Codable, Sendable {
        case limitRequired, noFableUsage, cooldown, unavailable
    }

    struct Option: Equatable, Codable, Sendable {
        var scope: Scope
        var claim: Claim
        var count: Int
        var expiries: [Date] = []
        var redeemable: Bool
        var blockReason: BlockReason? = nil
        var affectedUsagePercent: Int? = nil

        var canRedeem: Bool { count > 0 && redeemable }
    }

    var count: Int
    var scope: Scope
    // When each coupon expires, where the service says.
    var expiries: [Date] = []
    var claim: Claim
    var totalCount: Int? = nil
    var fableCount: Int? = nil
    var redeemable: Bool? = nil
    var blockReason: BlockReason? = nil
    var affectedUsagePercent: Int? = nil
    var options: [Option]? = nil

    // Unspent coupons can be present even when the provider won't apply one yet.
    var usable: UsageResetCoupons? { count > 0 ? self : nil }
    var canRedeem: Bool { count > 0 && redeemable != false }

    var selectedOption: Option {
        Option(scope: scope, claim: claim, count: count, expiries: expiries, redeemable: canRedeem,
               blockReason: blockReason, affectedUsagePercent: affectedUsagePercent)
    }

    func selecting(_ option: Option) -> UsageResetCoupons {
        var next = self
        next.scope = option.scope
        next.claim = option.claim
        next.count = option.count
        next.expiries = option.expiries
        next.redeemable = option.redeemable
        next.blockReason = option.blockReason
        next.affectedUsagePercent = option.affectedUsagePercent
        return next
    }

    // A cached offer whose dates changed must wait for the next server response before it can be redeemed.
    func pruningExpired(now: Date) -> UsageResetCoupons? {
        guard let options else {
            var next = self
            let expiredCount = expiries.filter { $0 <= now }.count
            next.count -= expiredCount
            next.expiries.removeAll { $0 <= now }
            if let totalCount { next.totalCount = totalCount - expiredCount }
            if scope == .fableWeekly || scope == .fiveHourAndFableWeekly, let fableCount {
                next.fableCount = fableCount - expiredCount
            }
            return next.usable
        }
        let active = options.compactMap { option -> Option? in
            var next = option
            let expiredCount = next.expiries.filter { $0 <= now }.count
            next.count -= expiredCount
            guard next.count > 0 else { return nil }
            next.expiries.removeAll { $0 <= now }
            if expiredCount > 0 {
                next.redeemable = false
                next.blockReason = .unavailable
                next.affectedUsagePercent = nil
            }
            return next
        }
        return updatingOptions(active)
    }

    // The same coupons after one was used.
    func usingOne() -> UsageResetCoupons? {
        if let options {
            let remaining = options.compactMap { option -> Option? in
                var next = option
                if next.claim == claim {
                    next.count -= 1
                    guard next.count > 0 else { return nil }
                    // Claude can choose a grant other than the one expiring first.
                    // Wait for the refreshed list to report that kind's dates.
                    next.expiries = []
                }
                next.redeemable = false
                next.blockReason = .unavailable
                next.affectedUsagePercent = nil
                return next
            }
            return updatingOptions(remaining)
        }
        guard count > 1 else { return nil }
        var next = self
        next.count -= 1
        if let totalCount { next.totalCount = totalCount - 1 }
        if scope == .fableWeekly || scope == .fiveHourAndFableWeekly, let fableCount {
            next.fableCount = fableCount - 1
        }
        if !next.expiries.isEmpty { next.expiries.removeFirst(min(1, next.expiries.count)) }
        return next
    }

    func withholdingSelectedOption() -> UsageResetCoupons? {
        guard let options else { return nil }
        return updatingOptions(options.filter { $0.claim != claim }.map { option in
            var pending = option
            pending.redeemable = false
            pending.blockReason = .unavailable
            pending.affectedUsagePercent = nil
            return pending
        })
    }

    private func updatingOptions(_ options: [Option]) -> UsageResetCoupons? {
        guard let selected = options.first(where: { $0.claim == claim }) ?? options.first else { return nil }
        var next = selecting(selected)
        next.options = options
        next.totalCount = options.reduce(0) { $0 + $1.count }
        next.fableCount = options.filter { $0.scope == .fableWeekly || $0.scope == .fiveHourAndFableWeekly }
            .reduce(0) { $0 + $1.count }
        return next
    }
}

// How using a coupon ended.
enum CouponOutcome: Equatable, Sendable {
    // The limits are cleared.
    case reset
    // The service reported that the reset did not apply.
    case nothingToReset
    // Claude no longer offers the coupon in the state the person confirmed.
    case conditionsChanged
    // The service has no coupon for the account any more (used elsewhere, expired).
    case noCoupon
    // The sign-in is not accepted.
    case signInAgain
    // Too many requests, no connection, or an answer that could not be read.
    case tryLater
}

// Codex's coupons, from the usage answer it already gives.
enum CodexResetCredits {
    struct Summary: Decodable {
        let availableCount: Int?
        let credits: [Credit]?
    }

    struct Credit: Decodable {
        let id: String
        let status: String?
        let resetType: String?
        let expiresAt: Int64?
    }

    // Nil when the account has none, or when an older codex does not report them.
    static func coupons(from result: [String: Any], now: Date = .now) -> UsageResetCoupons? {
        guard let raw = result["rateLimitResetCredits"], !(raw is NSNull),
              let data = try? JSONSerialization.data(withJSONObject: raw),
              let summary = try? JSONDecoder().decode(Summary.self, from: data) else { return nil }
        return coupons(summary, now: now)
    }

    static func coupons(_ summary: Summary, now: Date = .now) -> UsageResetCoupons? {
        let count = summary.availableCount ?? 0
        guard count > 0 else { return nil }
        // Only coupons that can still be used; the list may be cut short, so the count comes from `availableCount`.
        let available = (summary.credits ?? []).filter { $0.status == "available" }
            .map { (id: $0.id, expires: $0.expiresAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }) }
            .filter { $0.expires.map { $0 > now } ?? true }
        let first = available.min { ($0.expires ?? .distantFuture) < ($1.expires ?? .distantFuture) }
        return UsageResetCoupons(count: count, scope: .fiveHourAndWeekly,
                                 expiries: available.compactMap(\.expires).sorted(),
                                 claim: .codex(creditID: first?.id))
    }

    // The answer to `account/rateLimitResetCredit/consume`.
    static func outcome(_ result: [String: Any]) -> CouponOutcome {
        switch result["outcome"] as? String {
        case "reset": .reset
        // The same attempt already went through: it was reset. A fresh key is sent each time, so this is a retry.
        case "alreadyRedeemed": .reset
        case "nothingToReset": .nothingToReset
        case "noCredit": .noCoupon
        default: .tryLater
        }
    }
}
