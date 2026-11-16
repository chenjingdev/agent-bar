import Foundation
import Testing
@testable import agent_bar

// Claude's coupons ("cedar_ember" grants): which grants count, how often they are read, and what a claim sends and how
// its answer is read. A fake transport stands in for the service.
@Suite(.serialized)
struct ClaudeResetCouponTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static func at(_ days: Double) -> String {
        ISO8601DateFormatter().string(from: now.addingTimeInterval(days * 86_400))
    }

    private static func body(eligible: Bool = true, reason: String? = nil, atLimit: Bool = false, exhausted: [String] = [],
                             nextGrantId: String? = nil, cooldownUntil: String? = nil, grants: [[String: Any]]) -> Data {
        let block: [String: Any] = ["eligible": eligible, "ineligible_reason": reason ?? NSNull(), "at_limit": atLimit,
                                    "exhausted": exhausted, "next_grant_id": nextGrantId ?? NSNull(),
                                    "cooldown_until": cooldownUntil ?? NSNull(), "grants": grants]
        return try! JSONSerialization.data(withJSONObject: ["five_hour": ["utilization": 40], "cedar_ember": block])
    }

    @Test func grantsCountWhenUsableAndTheFirstToEndIsUsed() throws {
        let data = Self.body(grants: [
            ["id": "full_b", "resets_left": 2, "ends_at": Self.at(20), "clears": ["five_hour", "seven_day"]],
            ["id": "full_a", "resets_left": 1, "ends_at": Self.at(10), "type": "full"],
            ["id": "paused", "resets_left": 4, "ends_at": Self.at(5), "type": "full", "paused": true],
            ["id": "ended", "resets_left": 1, "ends_at": Self.at(-1), "type": "full"],
            ["id": "fable", "resets_left": 1, "ends_at": Self.at(2), "gives_back_weekly": true, "usable_now": false],
            ["id": "BAD ID", "resets_left": 1, "ends_at": Self.at(1), "type": "full"],
            ["id": "malformed", "resets_left": "1"],
        ])
        let coupons = try #require(ClaudeCedar.block(from: data).flatMap { ClaudeCedar.coupons($0, now: Self.now) })
        #expect(coupons.claim == .claudeGrant(grantID: "full_a"))
        #expect(coupons.count == 3 && coupons.scope == .fiveHourAndWeekly)
        #expect(coupons.expiries.count == 3 && coupons.expiries.first == ClaudeCedar.date(Self.at(10)))
        #expect(coupons.totalCount == 4 && coupons.fableCount == 1 && coupons.canRedeem)
    }

    @Test func kindsFollowClaudeCode() throws {
        func scope(_ grant: [String: Any], hasFiveHour: Bool? = nil) -> UsageResetCoupons.Scope? {
            var grant = grant; grant["id"] = "g"; grant["resets_left"] = 1
            return ClaudeCedar.block(from: Self.body(grants: [grant])).flatMap {
                ClaudeCedar.coupons($0, hasFiveHour: hasFiveHour, now: Self.now)
            }?.scope
        }
        #expect(scope(["type": "session"]) == .fiveHour)
        #expect(scope(["clears": ["five_hour"]]) == .fiveHour)
        #expect(scope(["type": "weekly"]) == .weekly)
        #expect(scope(["clears": ["seven_day"]]) == .weekly)
        #expect(scope(["clears": ["five_hour", "seven_day"]]) == .fiveHourAndWeekly)
        let fable: [String: Any] = ["type": "full", "gives_back_weekly": true, "clears": ["seven_day_overage_included"]]
        #expect(scope(fable, hasFiveHour: false) == .fableWeekly)
        #expect(scope(fable, hasFiveHour: true) == .fiveHourAndFableWeekly)
        #expect(scope(["gives_back_weekly": true, "clears": ["five_hour", "seven_day_overage_included"]]) == .fiveHourAndFableWeekly)
    }

    @Test func atALimitAGrantThatClearsItGoesFirst() throws {
        let data = Self.body(atLimit: true, exhausted: ["seven_day"], grants: [
            ["id": "session", "resets_left": 1, "ends_at": Self.at(1), "type": "session", "clears": ["five_hour"]],
            ["id": "weekly", "resets_left": 1, "ends_at": Self.at(9), "type": "weekly", "clears": ["seven_day"]],
        ])
        let coupons = try #require(ClaudeCedar.block(from: data).flatMap { ClaudeCedar.coupons($0, now: Self.now) })
        #expect(coupons.claim == .claudeGrant(grantID: "weekly") && coupons.scope == .weekly && coupons.count == 1)
    }

    @Test func respectsServerTargetAndShowsRemainingCouponsDuringCooldown() throws {
        let grants: [[String: Any]] = [
            ["id": "soon", "resets_left": 2, "ends_at": Self.at(2), "type": "weekly", "usable_now": true],
            ["id": "chosen", "resets_left": 1, "ends_at": Self.at(9), "type": "full", "usable_now": true],
            ["id": "future", "resets_left": 1, "starts_at": Self.at(1), "usable_now": false],
        ]
        let data = Self.body(nextGrantId: "chosen", grants: grants)
        let coupons = try #require(ClaudeCedar.block(from: data).flatMap { ClaudeCedar.coupons($0, now: Self.now) })
        #expect(coupons.claim == .claudeGrant(grantID: "chosen") && coupons.canRedeem && coupons.totalCount == 3)

        let cooldown = Self.body(nextGrantId: "chosen", cooldownUntil: Self.at(1), grants: grants)
        let blocked = try #require(ClaudeCedar.block(from: cooldown).flatMap { ClaudeCedar.coupons($0, now: Self.now) })
        #expect(blocked.totalCount == 3 && !blocked.canRedeem && blocked.blockReason == .cooldown)
    }

    @Test func limitRequiredAndBlockedGrantsCannotDisplaceAnActionableGrant() throws {
        let data = Self.body(nextGrantId: "blocked", grants: [
            ["id": "blocked", "resets_left": 2, "ends_at": Self.at(1), "type": "full", "usable_now": false],
            ["id": "at_limit", "resets_left": 1, "ends_at": Self.at(2), "type": "session", "use_requires_limit": true],
            ["id": "fable", "resets_left": 3, "ends_at": Self.at(9), "gives_back_weekly": true, "usable_now": true],
        ])
        let coupons = try #require(ClaudeCedar.block(from: data).flatMap { ClaudeCedar.coupons($0, now: Self.now) })
        #expect(coupons.claim == .claudeGrant(grantID: "fable") && coupons.canRedeem)
        #expect(coupons.count == 3 && coupons.totalCount == 6 && coupons.fableCount == 3)
    }

    @Test func currentGrantsFollowServerOrderWithinEachKind() throws {
        let data = Self.body(grants: [
            ["id": "first", "resets_left": 1, "ends_at": Self.at(9), "type": "weekly", "usable_now": true],
            ["id": "earlier_expiry", "resets_left": 2, "ends_at": Self.at(1), "type": "weekly", "usable_now": true],
        ])
        let coupons = try #require(ClaudeCedar.block(from: data).flatMap { ClaudeCedar.coupons($0, now: Self.now) })
        #expect(coupons.claim == .claudeGrant(grantID: "first") && coupons.count == 3)
    }

    @Test func eachCouponKindKeepsItsOwnOfferAndAvailability() throws {
        let data = Self.body(nextGrantId: "weekly", grants: [
            ["id": "weekly", "type": "weekly", "resets_left": 1, "usable_now": true, "ends_at": Self.at(1)],
            ["id": "blocked", "type": "full", "resets_left": 2, "usable_now": false, "unavailable_reason": "needs_limit"],
            ["id": "fable", "type": "full", "gives_back_weekly": true, "resets_left": 3, "usable_now": true,
             "clears": ["seven_day_overage_included"], "percent_used": ["seven_day_overage_included": 17]],
        ])
        let block = try #require(ClaudeCedar.block(from: data))
        let coupons = try #require(ClaudeCedar.coupons(block, hasFiveHour: true, now: Self.now))
        let options = try #require(coupons.options)
        #expect(options.map(\.scope) == [.weekly, .fiveHourAndFableWeekly, .fiveHourAndWeekly])
        #expect(options.map(\.canRedeem) == [true, true, false])
        #expect(options[2].blockReason == .limitRequired)
        #expect(coupons.selectedOption.claim == .claudeGrant(grantID: "weekly"))
        let fable = coupons.selecting(options[1])
        #expect(fable.claim == .claudeGrant(grantID: "fable") && fable.count == 3)
        #expect(fable.affectedUsagePercent == 17 && fable.totalCount == 6)
        #expect(ClaudeCedar.canRedeem("fable", in: block, now: Self.now))
    }

    @Test func legacyNextGrantLeavesOtherTypesVisibleButUnavailable() throws {
        let data = Self.body(nextGrantId: "weekly", grants: [
            ["id": "weekly", "type": "weekly", "resets_left": 1],
            ["id": "fable", "type": "full", "gives_back_weekly": true, "resets_left": 2],
        ])
        let block = try #require(ClaudeCedar.block(from: data))
        let coupons = try #require(ClaudeCedar.coupons(block, now: Self.now))
        #expect(coupons.options?.map(\.canRedeem) == [true, false])
        #expect(!ClaudeCedar.canRedeem("fable", in: block, now: Self.now))
    }

    @Test func spentAndExpiredOptionsLeaveOtherKindsVisible() throws {
        let data = Self.body(grants: [
            ["id": "weekly", "type": "weekly", "resets_left": 1, "usable_now": true, "ends_at": Self.at(1)],
            ["id": "fable", "gives_back_weekly": true, "resets_left": 3, "usable_now": true, "ends_at": Self.at(9)],
        ])
        let coupons = try #require(ClaudeCedar.block(from: data).flatMap { ClaudeCedar.coupons($0, now: Self.now) })
        let spent = try #require(coupons.usingOne())
        #expect(spent.options?.map(\.count) == [3])
        #expect(spent.totalCount == 3 && !spent.canRedeem)
        let withdrawn = try #require(coupons.withholdingSelectedOption())
        #expect(withdrawn.options?.map(\.claim) == [.claudeGrant(grantID: "fable")])
        #expect(withdrawn.totalCount == 3 && !withdrawn.canRedeem)
        let expired = try #require(coupons.pruningExpired(now: Self.now.addingTimeInterval(2 * 86_400)))
        #expect(expired.options?.map(\.count) == [3])
        #expect(expired.totalCount == 3 && expired.canRedeem)
    }

    @Test func aFableGrantWithNothingToReturnRemainsVisible() throws {
        let data = Self.body(grants: [
            ["id": "g", "resets_left": 3, "gives_back_weekly": true, "usable_now": false,
             "unavailable_reason": "blocked_seven_day", "clears": ["seven_day_overage_included"]],
        ])
        let block = try #require(ClaudeCedar.block(from: data))
        let coupons = try #require(ClaudeCedar.coupons(block, now: Self.now))
        #expect(coupons.count == 3 && !coupons.canRedeem && coupons.blockReason == .noFableUsage)
        #expect(!ClaudeCedar.canRedeem("g", in: block, now: Self.now))
    }

    @Test func confirmsExactGrantsAndUsesOnlyTheirAffectedLimitPercentages() throws {
        let data = Self.body(nextGrantId: "g", grants: [
            ["id": "g", "resets_left": 1, "usable_now": true, "gives_back_weekly": true,
             "clears": ["five_hour", "seven_day_overage_included"], "percent_used": ["five_hour": 0, "seven_day_overage_included": 8, "seven_day": 90, "future": "unknown"]],
            ["id": "g2", "resets_left": 2, "usable_now": true, "gives_back_weekly": true,
             "clears": ["seven_day_overage_included"], "percent_used": ["seven_day_overage_included": 80]],
            ["id": "g3", "resets_left": 1, "usable_now": true, "type": "weekly", "percent_used": ["seven_day": 100]],
        ])
        let block = try #require(ClaudeCedar.block(from: data))
        let coupons = try #require(ClaudeCedar.coupons(block, now: Self.now))
        #expect(coupons.affectedUsagePercent == 8)
        #expect(ClaudeCedar.canRedeem("g", in: block, now: Self.now))
        #expect(!ClaudeCedar.canRedeem("g2", in: block, now: Self.now))
        #expect(ClaudeCedar.canRedeem("g3", in: block, now: Self.now))
        #expect(!ClaudeCedar.canRedeem("missing", in: block, now: Self.now))
    }

    @Test func belowLimitEligibilityIsReportedRatherThanInferredFromUsage() throws {
        let data = Self.body(grants: [
            ["id": "g", "resets_left": 1, "usable_now": true, "use_requires_limit": false,
             "clears": ["five_hour"], "percent_used": ["five_hour": 0]],
        ])
        let coupons = try #require(ClaudeCedar.block(from: data).flatMap { ClaudeCedar.coupons($0, now: Self.now) })
        #expect(coupons.canRedeem && coupons.affectedUsagePercent == 0)

        let legacyData = Self.body(grants: [
            ["id": "g", "resets_left": 1, "use_requires_limit": true, "clears": ["five_hour"]],
        ])
        let legacy = try #require(ClaudeCedar.block(from: legacyData).flatMap { ClaudeCedar.coupons($0, now: Self.now) })
        #expect(!legacy.canRedeem && legacy.blockReason == .limitRequired)
    }

    @Test func ineligibleAccountsHaveNone() {
        let data = Self.body(eligible: false, reason: "surface", grants: [])
        #expect(ClaudeCedar.block(from: data).flatMap { ClaudeCedar.coupons($0, now: Self.now) } == nil)
        #expect(ClaudeCedar.block(from: Data("{\"five_hour\":{}}".utf8)) == nil)
    }

    @Test func claimAnswers() {
        func outcome(_ result: String) -> (CouponOutcome, Bool) {
            let answer = ClaudeCedar.outcome(Data("{\"result\":\"\(result)\"}".utf8)); return (answer.outcome, answer.unconfirmed)
        }
        #expect(outcome("reset") == (.reset, false))
        #expect(outcome("not_limited") == (.nothingToReset, false))
        #expect(outcome("already_used") == (.noCoupon, false))
        #expect(outcome("ineligible") == (.noCoupon, false))
        #expect(outcome("cooldown") == (.tryLater, false))
        #expect(outcome("unavailable") == (.tryLater, true))
        #expect(outcome("brand_new") == (.tryLater, true))
    }

    @Test func theUsageReadBringsTheCouponsEveryHalfHourAndNeverSendsASecondRequest() async throws {
        let fixture = try ClaudeFixture()
        defer { fixture.close() }
        fixture.transport.answer = (200, Self.body(grants: [["id": "g", "resets_left": 2, "ends_at": Self.at(9_000), "type": "full"]]))
        let first = await fixture.provider.load()
        #expect(first.resetCoupons?.count == 2 && first.fiveHour?.utilization != nil)
        #expect(fixture.transport.requests.map(\.url) == [ClaudeCedar.readURL])
        #expect(fixture.transport.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(fixture.transport.requests.first?.value(forHTTPHeaderField: "User-Agent") == ClaudeFixture.couponAgent)
        // The next read within the half hour asks for usage only, and the coupons are what was known.
        ClaudeUsageCache(overrideURL: fixture.cacheURL, enabled: true).expire()
        let second = await fixture.provider.load()
        #expect(fixture.transport.requests.count == 2)
        #expect(fixture.transport.requests.last?.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage")
        #expect(fixture.transport.requests.last?.value(forHTTPHeaderField: "User-Agent") == ClaudeFixture.couponAgent)
        #expect(second.resetCoupons?.count == 2)
        let now = Date()
        #expect(!fixture.provider.couponsDue(now: now.addingTimeInterval(29 * 60)))
        #expect(fixture.provider.couponsDue(now: now.addingTimeInterval(31 * 60)))
        // Refused usage: no coupons offered, and they are asked for again with the next read.
        fixture.transport.answer = (429, Data())
        ClaudeUsageCache(overrideURL: fixture.cacheURL, enabled: true).expire()
        try FileManager.default.removeItem(at: ClaudeCouponRecord.url(nextTo: fixture.cacheURL))
        let refused = await fixture.provider.load()
        #expect(refused.resetCoupons == nil)
        // The numbers shown keep the time they were read (whole seconds in the cache), not 1970.
        #expect(abs(refused.updatedAt.timeIntervalSince(second.updatedAt)) < 1)
        #expect(fixture.provider.couponsDue())
    }

    @Test func anAccountThatCannotHaveCouponsIsAskedRarelyAndAFaultKeepsWhatWasKnown() throws {
        let fixture = try ClaudeFixture()
        defer { fixture.close() }
        let provider = fixture.provider, now = Date()
        let granted = Self.body(grants: [["id": "g", "resets_left": 2, "ends_at": Self.at(9_000), "type": "full"]])
        #expect(provider.noteCoupons(answer: granted, now: now)?.count == 2)
        // The service could not say: the coupons stay, and it is asked again in 5 minutes.
        #expect(provider.noteCoupons(answer: Self.body(eligible: false, reason: "unavailable", grants: []), now: now)?.count == 2)
        #expect(provider.couponsDue(now: now.addingTimeInterval(5 * 60 + 1)))
        // Not for this account: none, and asked again only after six hours.
        #expect(provider.noteCoupons(answer: Self.body(eligible: false, reason: "surface", grants: []), now: now) == nil)
        #expect(!provider.couponsDue(now: now.addingTimeInterval(5 * 3600)))
        #expect(provider.couponsDue(now: now.addingTimeInterval(6 * 3600 + 1)))
        // Without an answer, what was known.
        #expect(provider.noteCoupons(answer: nil, now: now) == nil)
    }

    @Test func aClaimPostsTheGrantToTheAccountsOrganizationAndReusesAnUnconfirmedRequestID() async throws {
        let fixture = try ClaudeFixture()
        defer { fixture.close() }
        let coupons = UsageResetCoupons(count: 1, scope: .fiveHourAndWeekly, claim: .claudeGrant(grantID: "grant_1"))
        fixture.transport.readAnswer = (200, Self.body(grants: [["id": "grant_1", "resets_left": 1, "type": "full", "usable_now": true]]))
        fixture.transport.answer = (200, Data("{\"result\":\"reset\",\"resets_left\":0}".utf8))
        #expect(await fixture.provider.useCoupon(coupons) == .reset)
        #expect(fixture.transport.requests.map(\.httpMethod) == ["GET", "POST"])
        let request = try #require(fixture.transport.requests.last)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.anthropic.com/api/organizations/0f1e2d3c-org/reset_rate_limits")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == ClaudeFixture.couponAgent)
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String])
        #expect(body["program"] == "cedar_ember" && body["grant_id"] == "grant_1")
        let firstID = try #require(body["request_id"])

        // Not sure it went through: the next press sends the same request id.
        fixture.transport.answer = (503, Data())
        #expect(await fixture.provider.useCoupon(coupons) == .tryLater)
        let unsure = try fixture.transport.lastBody()["request_id"]
        #expect(unsure != firstID)
        let beforeRetry = fixture.transport.requests.count
        fixture.transport.answer = (200, Data("{\"result\":\"not_limited\"}".utf8))
        #expect(await fixture.provider.useCoupon(coupons) == .nothingToReset)
        #expect(fixture.transport.requests.count == beforeRetry + 1)
        #expect(try fixture.transport.lastBody()["request_id"] == unsure)

        fixture.transport.answer = (401, Data())
        #expect(await fixture.provider.useCoupon(coupons) == .signInAgain)
        fixture.transport.answer = (429, Data())
        #expect(await fixture.provider.useCoupon(coupons) == .tryLater)
    }

    @Test func changedClaudeConditionsPreventTheClaim() async throws {
        let fixture = try ClaudeFixture()
        defer { fixture.close() }
        let coupons = UsageResetCoupons(count: 1, scope: .fiveHourAndWeekly, claim: .claudeGrant(grantID: "grant_1"))
        fixture.transport.readAnswer = (200, Self.body(grants: [
            ["id": "grant_1", "resets_left": 1, "type": "full", "usable_now": false, "use_requires_limit": true],
            ["id": "grant_2", "resets_left": 1, "type": "weekly", "usable_now": true],
        ]))
        #expect(await fixture.provider.useCoupon(coupons) == .conditionsChanged)
        #expect(fixture.transport.requests.map(\.httpMethod) == ["GET"])
        #expect(fixture.provider.couponRecord()?.coupons?.claim == .claudeGrant(grantID: "grant_2"))
    }

    @Test func choosingFableClaimsItEvenWhenClaudeListsWeeklyFirst() async throws {
        let fixture = try ClaudeFixture()
        defer { fixture.close() }
        let weekly: [String: Any] = ["id": "weekly", "resets_left": 1, "type": "weekly", "usable_now": true]
        let fable: [String: Any] = ["id": "fable", "resets_left": 2, "gives_back_weekly": true, "usable_now": true]
        let response = Self.body(nextGrantId: "weekly", grants: [weekly, fable])
        let offers = try #require(ClaudeCedar.block(from: response).flatMap { ClaudeCedar.coupons($0, hasFiveHour: true) })
        let chosen = try #require(offers.options?.first { $0.claim == .claudeGrant(grantID: "fable") })
        fixture.transport.readAnswer = (200, response)
        fixture.transport.answer = (200, Data("{\"result\":\"reset\"}".utf8))
        #expect(await fixture.provider.useCoupon(offers.selecting(chosen)) == .reset)
        #expect(fixture.transport.requests.map(\.httpMethod) == ["GET", "POST"])
        #expect(try fixture.transport.lastBody()["grant_id"] == "fable")
        // Claude Code sends its request id in lowercase.
        let requestID = try #require(try fixture.transport.lastBody()["request_id"])
        #expect(requestID == requestID.lowercased() && UUID(uuidString: requestID) != nil)
    }

    // As in agent-bar: a refused coupon flag never costs the usage. The plain read follows, and the coupons are asked
    // for again a little later instead of with every read.
    @Test func aRefusedCouponFlagFallsBackToPlainUsage() async throws {
        let fixture = try ClaudeFixture()
        defer { fixture.close() }
        let sent = SentURLs()
        let provider = ClaudeUsageProvider(directory: fixture.root, cacheURL: fixture.cacheURL, transport: { request in
            sent.append(request)
            let refused = request.url == ClaudeCedar.readURL
            let body = refused ? Data() : Data(#"{"five_hour":{"utilization":40,"resets_at":null}}"#.utf8)
            return (body, HTTPURLResponse(url: request.url!, statusCode: refused ? 400 : 200, httpVersion: nil, headerFields: nil)!)
        }, couponUserAgent: { ClaudeFixture.couponAgent })
        let snapshot = await provider.load()
        #expect(sent.all.map(\.url) == [ClaudeCedar.readURL, URL(string: "https://api.anthropic.com/api/oauth/usage")!])
        #expect(sent.all.allSatisfy { $0.value(forHTTPHeaderField: "User-Agent") == ClaudeFixture.couponAgent })
        #expect(!snapshot.isStale && snapshot.fiveHour?.utilization != nil && snapshot.resetCoupons == nil)
        #expect(!provider.couponsDue())
        #expect(provider.couponsDue(now: Date().addingTimeInterval(6 * 60)))
    }
}

extension ClaudeResetCouponTests {
    // The coupon line shows right after the panel's read, so the check before a claim comes seconds later and is
    // refused (429). The claim still goes out (t1d1's bug report).
    @Test func aClaimRightAfterARefreshStillSendsTheReset() async throws {
        let fixture = try ClaudeFixture()
        defer { fixture.close() }
        let sent = SentURLs()
        let usage = Self.body(atLimit: true, exhausted: ["seven_day"], nextGrantId: "g",
                              grants: [["id": "g", "resets_left": 1, "ends_at": Self.at(9_000), "type": "full", "usable_now": true]])
        let provider = ClaudeUsageProvider(directory: fixture.root, cacheURL: fixture.cacheURL, transport: { request in
            sent.append(request)
            let reply: (Int, Data) = request.httpMethod == "POST" ? (200, Data(#"{"result":"reset"}"#.utf8))
                : sent.all.count == 1 ? (200, usage) : (429, Data())
            return (reply.1, HTTPURLResponse(url: request.url!, statusCode: reply.0, httpVersion: nil, headerFields: nil)!)
        }, couponUserAgent: { ClaudeFixture.couponAgent })
        let coupons = try #require(await provider.load().resetCoupons)
        _ = await provider.useCoupon(coupons)
        #expect(sent.all.map(\.httpMethod) == ["GET", "GET", "POST"])
    }
}

private final class SentURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    var all: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    func append(_ request: URLRequest) { lock.lock(); requests.append(request); lock.unlock() }
}

// An account folder with a sign-in that has not expired, its organization, and a fake transport.
private struct ClaudeFixture {
    static let couponAgent = "claude-cli/2.1.325 (external, cli)"
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("coupon-claude-\(UUID())")
    let transport = FakeTransport()
    var cacheURL: URL { root.appendingPathComponent("cache/usage.json") }
    var provider: ClaudeUsageProvider {
        let transport = transport
        return ClaudeUsageProvider(directory: root, cacheURL: cacheURL,
                                   transport: { try transport.send($0) }, couponUserAgent: { Self.couponAgent })
    }

    init() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("cache"), withIntermediateDirectories: true)
        let expires = Int(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000)
        try Data("{\"claudeAiOauth\":{\"accessToken\":\"tok\",\"expiresAt\":\(expires),\"subscriptionType\":\"max\"}}".utf8)
            .write(to: root.appendingPathComponent(".credentials.json"))
        try Data("{\"oauthAccount\":{\"emailAddress\":\"cl@example.test\",\"organizationUuid\":\"0f1e2d3c-org\"}}".utf8)
            .write(to: root.appendingPathComponent(".claude.json"))
    }

    func close() { try? FileManager.default.removeItem(at: root) }
}

private final class FakeTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [URLRequest] = []
    private var reply: (Int, Data) = (200, Data())
    private var readReply: (Int, Data)?
    var answer: (Int, Data) {
        get { lock.lock(); defer { lock.unlock() }; return reply }
        set { lock.lock(); reply = newValue; lock.unlock() }
    }
    var readAnswer: (Int, Data)? {
        get { lock.lock(); defer { lock.unlock() }; return readReply }
        set { lock.lock(); defer { lock.unlock() }; readReply = newValue }
    }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return sent }

    func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        lock.lock(); defer { lock.unlock() }
        sent.append(request)
        let selected = request.httpMethod == "GET" ? (readReply ?? reply) : reply
        let response = HTTPURLResponse(url: request.url!, statusCode: selected.0, httpVersion: nil, headerFields: nil)!
        return (selected.1, response)
    }

    func lastBody() throws -> [String: String] {
        try #require(JSONSerialization.jsonObject(with: requests.last?.httpBody ?? Data()) as? [String: String])
    }
}
