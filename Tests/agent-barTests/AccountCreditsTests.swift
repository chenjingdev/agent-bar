import Foundation
import Testing
@testable import agent_bar

// Credits read with usage: Codex's balance, Claude's dollar credits, usage credits and prepaid balance, and the words.
struct AccountCreditsTests {
    @Test func codexBalanceIsWholeCredits() throws {
        let credits = try #require(CodexCredits.credits(from: ["rateLimits": ["credits": ["hasCredits": true, "unlimited": false, "balance": "6506.42"]]]))
        #expect(credits.items == [.init(kind: .codexBalance, balance: 6506.42)])
        #expect(CreditWords.summary(credits) == "Credits 6,506")
    }

    @Test func codexWithoutCreditsIsZeroAndUnreportedIsNil() throws {
        let none = try #require(CodexCredits.credits(from: ["rateLimits": ["credits": ["hasCredits": false, "unlimited": false, "balance": NSNull()]]]))
        #expect(CreditWords.summary(none) == "Credits 0")
        #expect(CodexCredits.credits(from: ["rateLimits": ["primary": [:]]]) == nil)
    }

    @Test func claudeUsageAnswerCredits() throws {
        let answer: [String: Any] = [
            "five_hour": ["utilization": 10],
            "wattle_ember": ["label": "Launch credit", "limit_dollars": 250, "used_dollars": 12.5, "resets_at": "2026-12-01T07:59:00Z"],
            "cinder_cove": NSNull(),
            "promo_credits": [["program_id": "model_promo_fable", "label": "Fable", "utilization": 3, "resets_at": NSNull()],
                              ["program_id": "p1", "label": "Promo", "utilization": 0, "resets_at": NSNull(), "limit_dollars": 20, "used_dollars": 0]],
            "extra_usage": ["is_enabled": true, "monthly_limit": 5000, "used_credits": 320, "utilization": 6.4, "currency": "USD"],
        ]
        let items = ClaudeCredits.credits(fromUsage: try JSONSerialization.data(withJSONObject: answer))
        #expect(items.map(\.kind) == [.grant, .grant, .extraUsage])
        let summary = CreditWords.summary(AccountCredits(items: items))
        #expect(summary.hasPrefix("Launch credit $12.50 of $250 used · expires "))
        #expect(summary.contains("Promo $0 of $20 used"))
        #expect(summary.hasSuffix("Usage credits $3.20 / $50"))
    }

    @Test func claudeExtraUsageOffAndPrepaid() throws {
        let items = ClaudeCredits.credits(fromUsage: try JSONSerialization.data(withJSONObject: [
            "extra_usage": ["is_enabled": false, "monthly_limit": NSNull(), "used_credits": NSNull(), "utilization": NSNull()]]))
        let prepaid = try #require(ClaudeCredits.prepaid(from: try JSONSerialization.data(withJSONObject: [
            "amount": 1, "currency": "USD", "balance": ["credits": ["amount_minor": 1, "exponent": 2]]])))
        #expect(CreditWords.summary(AccountCredits(items: items + [prepaid])) == "Usage credits off · Prepaid $0.01")
        // A plan the endpoint does not serve answers amount 0 with no currency.
        let empty = try #require(ClaudeCredits.prepaid(from: try JSONSerialization.data(withJSONObject: ["amount": 0, "currency": NSNull()])))
        #expect(CreditWords.item(empty) == "Prepaid $0")
    }

    @Test func teamSeatSaysWhyUsageCreditsAreOff() throws {
        func words(_ extra: [String: Any]) throws -> String {
            let items = ClaudeCredits.credits(fromUsage: try JSONSerialization.data(withJSONObject: ["extra_usage": extra]))
            return CreditWords.summary(AccountCredits(items: items))
        }
        let base: [String: Any] = ["monthly_limit": NSNull(), "used_credits": NSNull(), "utilization": NSNull(), "currency": "USD"]
        #expect(try words(base.merging(["is_enabled": false, "disabled_reason": "out_of_credits"]) { $1 })
                == "Usage credits blocked · organization out of credits")
        #expect(try words(base.merging(["is_enabled": true, "monthly_limit": 5000, "used_credits": 5000,
                                        "disabled_reason": "org_spend_cap_reached"]) { $1 })
                == "Usage credits blocked · monthly limit reached · $50 / $50")
        #expect(try words(base.merging(["is_enabled": false, "disabled_reason": "org_level_disabled_until",
                                        "spend_limit_reached": false]) { $1 }) == "Usage credits off · turned off by the organization")
        #expect(try words(base.merging(["is_enabled": false, "disabled_reason": "member_zero_credit_limit"]) { $1 })
                == "Usage credits off · limit $0")
        #expect(try words(base.merging(["is_enabled": false, "disabled_reason": "something_new"]) { $1 }) == "Usage credits off")
        #expect(try words(base.merging(["is_enabled": false]) { $1 }) == "Usage credits off")
    }

    @Test func userAgentNeverBelowMinimum() {
        #expect(ClaudeCouponClient.userAgent(installed: ClaudeCodeVersion(major: 2, minor: 1, patch: 327)) == "claude-cli/2.1.327 (external, cli)")
        #expect(ClaudeCouponClient.userAgent(installed: nil) == "claude-cli/2.1.295 (external, cli)")
    }
}
