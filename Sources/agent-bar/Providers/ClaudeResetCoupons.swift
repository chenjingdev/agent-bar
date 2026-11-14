import Foundation

// Claude's usage-reset coupons ("cedar_ember" grants). Undocumented; the names follow Claude Code 2.1.323, which reads
// them from `/api/oauth/usage?cedar_ember=1&skip_spend=1` and uses one with
// `POST /api/organizations/{org}/reset_rate_limits {"program":"cedar_ember","grant_id","request_id"}`.
// The 5-hour reset ("juniper_tide") is left out: it is not a coupon but a weekly allowance, read only at a limit.
enum ClaudeCedar {
    static let readURL = URL(string: "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1")!
    static func claimURL(organization: String) -> URL? {
        guard organization.range(of: "^[A-Za-z0-9-]{1,64}$", options: .regularExpression) != nil else { return nil }
        return URL(string: "https://api.anthropic.com/api/organizations/\(organization)/reset_rate_limits")
    }

    struct Response: Decodable { let cedarEmber: Block? }

    struct Block: Decodable {
        let eligible: Bool?
        let ineligibleReason: String?
        let atLimit: Bool?
        let exhausted: [String]?
        let grants: [Grant]?
        let nextGrantId: String?
        let cooldownUntil: String?

        private enum CodingKeys: String, CodingKey {
            case eligible, ineligibleReason, atLimit, exhausted, grants, nextGrantId, cooldownUntil
        }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            eligible = try fields.decodeIfPresent(Bool.self, forKey: .eligible)
            ineligibleReason = try? fields.decodeIfPresent(String.self, forKey: .ineligibleReason)
            atLimit = try? fields.decodeIfPresent(Bool.self, forKey: .atLimit)
            exhausted = try? fields.decodeIfPresent([String].self, forKey: .exhausted)
            grants = (try? fields.decodeIfPresent([DecodedGrant].self, forKey: .grants))?.compactMap(\.grant)
            nextGrantId = try? fields.decodeIfPresent(String.self, forKey: .nextGrantId)
            cooldownUntil = try? fields.decodeIfPresent(String.self, forKey: .cooldownUntil)
        }
    }

    private struct DecodedGrant: Decodable {
        let grant: Grant?

        init(from decoder: Decoder) {
            grant = try? Grant(from: decoder)
        }
    }

    struct Grant: Decodable {
        let id: String
        let resetsLeft: Int
        let startsAt: String?
        let endsAt: String?
        let clears: [String]?
        let paused: Bool?
        let type: String?
        let givesBackWeekly: Bool?
        let usableNow: Bool?
        let useRequiresLimit: Bool?
        let unavailableReason: String?
        let blocking: [String]?
        let affectedUsagePercent: Int?

        private enum CodingKeys: String, CodingKey {
            case id, resetsLeft, startsAt, endsAt, clears, paused, type, givesBackWeekly
            case usableNow, useRequiresLimit, unavailableReason, blocking, percentUsed
        }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            id = try fields.decode(String.self, forKey: .id)
            resetsLeft = try fields.decode(Int.self, forKey: .resetsLeft)
            startsAt = try? fields.decodeIfPresent(String.self, forKey: .startsAt)
            endsAt = try? fields.decodeIfPresent(String.self, forKey: .endsAt)
            clears = try? fields.decodeIfPresent([String].self, forKey: .clears)
            paused = try? fields.decodeIfPresent(Bool.self, forKey: .paused)
            type = try? fields.decodeIfPresent(String.self, forKey: .type)
            givesBackWeekly = try? fields.decodeIfPresent(Bool.self, forKey: .givesBackWeekly)
            if fields.contains(.usableNow) {
                usableNow = (try? fields.decode(Bool.self, forKey: .usableNow)) ?? false
            } else {
                usableNow = nil
            }
            useRequiresLimit = try? fields.decodeIfPresent(Bool.self, forKey: .useRequiresLimit)
            unavailableReason = try? fields.decodeIfPresent(String.self, forKey: .unavailableReason)
            blocking = try? fields.decodeIfPresent([String].self, forKey: .blocking)
            let percentages = (try? fields.decode([String: UsagePercent].self, forKey: .percentUsed)) ?? [:]
            let clearedLimits = Set(clears ?? [])
            affectedUsagePercent = percentages.filter { clearedLimits.contains($0.key) }.values.compactMap(\.value).max()
        }

        func clearsAny(_ limits: Set<String>) -> Bool {
            !limits.isDisjoint(with: clears ?? []) || (givesBackWeekly == true && limits.contains("seven_day"))
        }

        private struct UsagePercent: Decodable {
            let value: Int?

            init(from decoder: Decoder) {
                let percent = try? decoder.singleValueContainer().decode(Int.self)
                value = percent.flatMap { (0...100).contains($0) ? $0 : nil }
            }
        }
    }

    private struct AvailableGrant {
        let grant: Grant
        let ends: Date?

        var kind: Kind { ClaudeCedar.kind(grant) }
    }

    enum Kind: CaseIterable, Hashable { case session, weekly, fable, full }

    // As Claude Code names a grant: what it gives back, else its type, else what it clears.
    static func kind(_ grant: Grant) -> Kind {
        if grant.givesBackWeekly == true { return .fable }
        switch grant.type {
        case "session": return .session
        case "weekly": return .weekly
        case "full": return .full
        default: break
        }
        let clears = Set(grant.clears ?? [])
        if clears == ["five_hour"] { return .session }
        if !clears.contains("five_hour") && !clears.isEmpty { return .weekly }
        return .full
    }

    static func block(from data: Data) -> Block? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return (try? decoder.decode(Response.self, from: data))?.cedarEmber
    }

    // Show the remaining coupons even when the server currently blocks redemption.
    static func coupons(_ block: Block, hasFiveHour: Bool? = nil, now: Date = .now) -> UsageResetCoupons? {
        let available = remaining(in: block, now: now)
        let redeemable = offers(in: block, remaining: available, now: now)
        let clearing = block.atLimit == true ? redeemable.filter { $0.grant.clearsAny(Set(block.exhausted ?? [])) } : []
        let preferred = redeemable.first { $0.grant.id == block.nextGrantId }
            ?? soonestExpiring(clearing.isEmpty ? redeemable : clearing)
        guard let selected = preferred ?? soonestExpiring(available) else { return nil }
        let options = Kind.allCases.compactMap { kind -> UsageResetCoupons.Option? in
            let matching = available.filter { $0.kind == kind }
            let actionable = redeemable.filter { $0.kind == kind }
            let target = actionable.first { $0.grant.id == block.nextGrantId }
                ?? (preferred?.kind == kind ? preferred : nil)
                ?? soonestExpiring(actionable)
            guard let representative = target ?? soonestExpiring(matching) else { return nil }
            return option(for: representative, matching: matching, target: target, in: block, hasFiveHour: hasFiveHour, now: now)
        }
        guard let selectedOption = options.first(where: { $0.claim == .claudeGrant(grantID: selected.grant.id) }) else { return nil }
        return UsageResetCoupons(
            count: selectedOption.count, scope: selectedOption.scope, expiries: selectedOption.expiries,
            claim: selectedOption.claim, totalCount: options.reduce(0) { $0 + $1.count },
            fableCount: available.filter { $0.kind == .fable }.reduce(0) { $0 + $1.grant.resetsLeft },
            redeemable: selectedOption.redeemable, blockReason: selectedOption.blockReason,
            affectedUsagePercent: selectedOption.affectedUsagePercent, options: options
        )
    }

    private static func option(
        for selected: AvailableGrant, matching: [AvailableGrant], target: AvailableGrant?,
        in block: Block, hasFiveHour: Bool?, now: Date
    ) -> UsageResetCoupons.Option {
        let scope: UsageResetCoupons.Scope = switch selected.kind {
        case .session: .fiveHour
        case .weekly: .weekly
        case .full: .fiveHourAndWeekly
        case .fable:
            hasFiveHour == true || selected.grant.clears?.contains("five_hour") == true
                ? .fiveHourAndFableWeekly : .fableWeekly
        }
        let expiries = matching.flatMap { item in
            item.ends.map { Array(repeating: $0, count: item.grant.resetsLeft) } ?? []
        }.sorted()
        return UsageResetCoupons.Option(
            scope: scope, claim: .claudeGrant(grantID: selected.grant.id),
            count: matching.reduce(0) { $0 + $1.grant.resetsLeft }, expiries: expiries,
            redeemable: target != nil,
            blockReason: target == nil ? blockReason(for: selected.grant, in: block, now: now) : nil,
            affectedUsagePercent: target?.grant.affectedUsagePercent
        )
    }

    // Recheck the exact grant the user confirmed against the server's current offers.
    static func canRedeem(_ grantID: String, in block: Block, now: Date = .now) -> Bool {
        offers(in: block, remaining: remaining(in: block, now: now), now: now).contains { $0.grant.id == grantID }
    }

    private static func remaining(in block: Block, now: Date) -> [AvailableGrant] {
        guard block.eligible == true else { return [] }
        return (block.grants ?? []).compactMap { grant in
            guard grant.id.range(of: "^[a-z0-9_-]{1,40}$", options: .regularExpression) != nil,
                  grant.resetsLeft > 0, grant.paused != true else { return nil }
            if let starts = grant.startsAt.flatMap(date), starts > now { return nil }
            let ends = grant.endsAt.flatMap(date)
            if let ends, ends <= now { return nil }
            return AvailableGrant(grant: grant, ends: ends)
        }
    }

    private static func offers(in block: Block, remaining: [AvailableGrant], now: Date) -> [AvailableGrant] {
        guard !isCoolingDown(block, now: now) else { return [] }
        // The current Claude Code offers the first usable grant of each kind in the server's order.
        var kindsSeen = Set<Kind>()
        let legacyNext = block.nextGrantId.flatMap { next in
            block.grants?.contains { $0.id == next } == true ? next : nil
        }
        return remaining.filter { item in
            let grant = item.grant
            guard grant.unavailableReason == nil else { return false }
            if let usableNow = grant.usableNow {
                guard usableNow else { return false }
                let firstOfKind = kindsSeen.insert(item.kind).inserted
                return firstOfKind || grant.id == block.nextGrantId
            }
            // Older replies either specify the only next grant or leave the order to the client.
            if let next = legacyNext, grant.id != next { return false }
            return grant.blocking?.isEmpty != false && !needsLimit(grant, in: block)
        }
    }

    private static func blockReason(for grant: Grant, in block: Block, now: Date) -> UsageResetCoupons.BlockReason {
        if isCoolingDown(block, now: now) || grant.unavailableReason == "cooldown" { return .cooldown }
        if kind(grant) == .fable, grant.unavailableReason == "blocked_seven_day"
            || (grant.unavailableReason == nil && grant.blocking?.contains("seven_day") == true) {
            return .noFableUsage
        }
        if grant.unavailableReason == "needs_limit" || (grant.unavailableReason == nil && needsLimit(grant, in: block)) {
            return .limitRequired
        }
        return .unavailable
    }

    private static func isCoolingDown(_ block: Block, now: Date) -> Bool {
        block.cooldownUntil.flatMap(date).map { $0 > now } ?? false
    }

    private static func needsLimit(_ grant: Grant, in block: Block) -> Bool {
        let exhausted = Set(block.exhausted ?? [])
        return grant.useRequiresLimit == true && (block.atLimit != true || (!exhausted.isEmpty && !grant.clearsAny(exhausted)))
    }

    private static func soonestExpiring(_ grants: [AvailableGrant]) -> AvailableGrant? {
        grants.min { ($0.ends ?? .distantFuture) < ($1.ends ?? .distantFuture) }
    }

    // The answer to a claim.
    static func outcome(_ data: Data) -> (outcome: CouponOutcome, unconfirmed: Bool) {
        let result = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["result"] as? String
        switch result {
        case "reset": return (.reset, false)
        case "not_limited": return (.nothingToReset, false)
        case "already_used", "ineligible": return (.noCoupon, false)
        case "cooldown": return (.tryLater, false)
        // "unavailable" or an unknown answer: it may have gone through.
        default: return (.tryLater, true)
        }
    }

    static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

// What an account's coupons were and when the usage read should ask for them again: after 30 minutes, after 6 hours while
// the account cannot have any, after 5 minutes when the service could not say.
struct ClaudeCouponRecord: Codable, Equatable {
    var coupons: UsageResetCoupons?
    var nextCheck: Date
    var userAgent: String? = nil
    var includesConditions: Bool? = nil

    static let interval: TimeInterval = 30 * 60
    static let ineligibleInterval: TimeInterval = 6 * 60 * 60
    static let failureInterval: TimeInterval = 5 * 60

    static func url(nextTo usageCache: URL) -> URL {
        usageCache.deletingLastPathComponent().appendingPathComponent("claude-coupons.json")
    }
}

// A claim whose answer did not say whether it went through. Pressing again within 10 minutes sends the same request id,
// so the service does not use a second coupon.
actor ClaudeClaimMemory {
    static let shared = ClaudeClaimMemory()
    private var pending: [String: (id: String, at: Date)] = [:]

    func pendingRequestID(for grant: String, now: Date = .now) -> String? {
        if let held = pending[grant], now.timeIntervalSince(held.at) < 600 { return held.id }
        pending[grant] = nil
        return nil
    }
    func remember(_ id: String, for grant: String, now: Date = .now) { pending[grant] = (id, now) }
    func forget(_ grant: String) { pending[grant] = nil }
}
