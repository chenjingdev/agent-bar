import Foundation

// Credits an account has besides its plan limits, read with its usage. Codex reports a credit balance; Claude reports
// dollar credits (a launch or promotion credit, the Claude Code and Cowork credit), usage credits beyond the plan
// ("extra usage", with a monthly limit) and a prepaid balance. One list for both, so the row and the CLI say them alike.
struct AccountCredits: Equatable, Codable, Sendable {
    struct Item: Equatable, Codable, Sendable {
        enum Kind: String, Codable, Sendable {
            // Codex credits: a count, not money.
            case codexBalance
            // A one-time dollar credit with an amount used and a last day.
            case grant
            // Claude's usage credits beyond the plan: on or off, spent this month against a monthly limit.
            case extraUsage
            // Prepaid money left.
            case prepaid
        }
        var kind: Kind
        var title: String? = nil
        // Money in the currency's main unit (dollars), or Codex credits.
        var used: Double? = nil
        var limit: Double? = nil
        var balance: Double? = nil
        var currency: String? = nil
        var endsAt: Date? = nil
        var enabled: Bool? = nil
        var unlimited: Bool = false
        // Why usage credits are off or blocked, as the usage answer's `extra_usage.disabled_reason` says it. A Team or
        // Enterprise seat learns its organization's credits only this way: the prepaid balance is Pro, Max and Ultra only.
        var reason: String? = nil
    }

    var items: [Item]

    var isEmpty: Bool { items.isEmpty }
}

// MARK: Codex

enum CodexCredits {
    // `account/rateLimits/read` → `rateLimits.credits` {hasCredits, unlimited, balance}. The balance is a string, as the
    // Codex CLI's own status shows it; an account without credits reports hasCredits false and counts as 0.
    static func credits(from result: [String: Any]) -> AccountCredits? {
        guard let limits = result["rateLimits"] as? [String: Any], let raw = limits["credits"] as? [String: Any] else { return nil }
        let unlimited = raw["unlimited"] as? Bool ?? false
        let has = raw["hasCredits"] as? Bool ?? false
        var balance: Double?
        if let text = raw["balance"] as? String { balance = Double(text) }
        else if let number = raw["balance"] as? NSNumber { balance = number.doubleValue }
        if balance == nil, !has { balance = 0 }
        return AccountCredits(items: [.init(kind: .codexBalance, balance: balance, unlimited: unlimited)])
    }
}

// MARK: Claude

enum ClaudeCredits {
    // The credits in an `/api/oauth/usage` answer, as Claude Code 2.1.327's /usage screen reads them:
    // `cinder_cove` ("Claude Code and Cowork credit"), `wattle_ember` (its label, or "Credit") and each of
    // `promo_credits` (its label) are dollar windows with `limit_dollars`/`used_dollars`/`resets_at`; `extra_usage` is
    // usage credits with `is_enabled`, `monthly_limit` and `used_credits` in minor units (cents) and a `currency`.
    static func credits(fromUsage answer: Data) -> [AccountCredits.Item] {
        guard let reply = (try? JSONSerialization.jsonObject(with: answer)) as? [String: Any] else { return [] }
        var items: [AccountCredits.Item] = []
        if let block = reply["cinder_cove"] as? [String: Any], let item = grant(block, title: "Claude Code and Cowork credit") {
            items.append(item)
        }
        if let block = reply["wattle_ember"] as? [String: Any], let item = grant(block, title: nil) { items.append(item) }
        for case let block as [String: Any] in (reply["promo_credits"] as? [Any]) ?? [] {
            // Claude Code leaves out the Fable promotion: it is the Fable weekly limit, already a bar.
            guard block["program_id"] as? String != "model_promo_fable", let item = grant(block, title: nil) else { continue }
            items.append(item)
        }
        if let extra = reply["extra_usage"] as? [String: Any] {
            let currency = (extra["currency"] as? String) ?? "USD"
            let enabled = extra["is_enabled"] as? Bool ?? false
            var reason = (extra["disabled_reason"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            // Claude Code reads org_level_disabled_until as a reached cap unless spend_limit_reached says otherwise.
            if reason == "org_level_disabled_until", extra["spend_limit_reached"] as? Bool == false { reason = "org_level_disabled" }
            items.append(.init(kind: .extraUsage, used: number(extra["used_credits"]).map { $0 / 100 },
                               limit: number(extra["monthly_limit"]).map { $0 / 100 }, currency: currency, enabled: enabled,
                               unlimited: enabled && number(extra["monthly_limit"]) == nil, reason: reason))
        }
        return items
    }

    // `GET /api/oauth/organizations/<org>/prepaid/credits` (Pro and Max only): `amount` in cents and its `currency`.
    static func prepaid(from answer: Data) -> AccountCredits.Item? {
        guard let reply = (try? JSONSerialization.jsonObject(with: answer)) as? [String: Any],
              let cents = number(reply["amount"]) else { return nil }
        let next = (reply["next_expires_at"] as? String).flatMap(date)
        return .init(kind: .prepaid, balance: cents / 100, currency: (reply["currency"] as? String) ?? "USD", endsAt: next)
    }

    private static func grant(_ block: [String: Any], title: String?) -> AccountCredits.Item? {
        let limit = number(block["limit_dollars"])
        let used = number(block["used_dollars"]) ?? number(block["remaining_dollars"]).flatMap { left in limit.map { $0 - left } }
        guard limit != nil || used != nil else { return nil }
        let label = (block["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(kind: .grant, title: (label?.isEmpty == false ? label : nil) ?? title, used: used ?? 0, limit: limit,
                     currency: "USD", endsAt: (block["resets_at"] as? String).flatMap(date))
    }

    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

// What a Claude account's credits were when last read: the usage read brings them only when it is not answered from
// the usage cache, and the prepaid balance is asked for at most every half hour.
struct ClaudeCreditsRecord: Codable, Equatable {
    var usageItems: [AccountCredits.Item]?
    var prepaid: AccountCredits.Item?
    var prepaidChecked: Date?

    static let prepaidInterval: TimeInterval = 30 * 60

    static func url(nextTo usageCache: URL) -> URL {
        usageCache.deletingLastPathComponent().appendingPathComponent("claude-credits.json")
    }

    var credits: AccountCredits? {
        let items = (usageItems ?? []) + (prepaid.map { [$0] } ?? [])
        return items.isEmpty ? nil : AccountCredits(items: items)
    }
}
