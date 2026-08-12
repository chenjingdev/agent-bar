import Foundation
import Testing
@testable import agent_bar

struct CodexWindowVisibilityTests {
    @Test
    func dualWindowPayloadKeepsFiveHourAndWeeklyLimits() throws {
        let rateLimits = try decodeRateLimits(
            primary: window(usedPercent: 25, durationMinutes: 300, resetsAt: 1_800_000_000),
            secondary: window(usedPercent: 40, durationMinutes: 10_080, resetsAt: 1_800_100_000)
        )

        let mapped = CodexRateLimitMapper.map(rateLimits)

        #expect(mapped.fiveHourUsedPercent == 25)
        #expect(mapped.weeklyUsedPercent == 40)
        #expect(mapped.fiveHourResetAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(mapped.weeklyResetAt == Date(timeIntervalSince1970: 1_800_100_000))
        #expect(mapped.visibleWindowTitles == ["5-Hour Session", "Weekly Limit"])
    }

    @Test
    func weeklyOnlyPayloadHidesFiveHourLimit() throws {
        let rateLimits = try decodeRateLimits(
            primary: window(usedPercent: 10, durationMinutes: 10_080, resetsAt: 1_800_100_000),
            secondary: nil
        )

        let mapped = CodexRateLimitMapper.map(rateLimits)

        #expect(mapped.fiveHourResetAt == nil)
        #expect(mapped.weeklyUsedPercent == 10)
        #expect(mapped.weeklyResetAt == Date(timeIntervalSince1970: 1_800_100_000))
        #expect(mapped.visibleWindowTitles == ["Weekly Limit"])
    }

    @Test
    func secondaryOnlyWeeklyPayloadHidesFiveHourLimit() throws {
        let rateLimits = try decodeRateLimits(
            primary: nil,
            secondary: window(usedPercent: 30, durationMinutes: 10_080, resetsAt: 1_800_100_000)
        )

        let mapped = CodexRateLimitMapper.map(rateLimits)

        #expect(mapped.fiveHourResetAt == nil)
        #expect(mapped.weeklyUsedPercent == 30)
        #expect(mapped.weeklyResetAt == Date(timeIntervalSince1970: 1_800_100_000))
        #expect(mapped.visibleWindowTitles == ["Weekly Limit"])
    }

    @Test
    func durationlessPayloadKeepsLegacyPrimarySecondaryOrder() throws {
        let rateLimits = try decodeRateLimits(
            primary: window(usedPercent: 15, durationMinutes: nil, resetsAt: 1_800_000_000),
            secondary: window(usedPercent: 35, durationMinutes: nil, resetsAt: 1_800_100_000)
        )

        let mapped = CodexRateLimitMapper.map(rateLimits)

        #expect(mapped.fiveHourUsedPercent == 15)
        #expect(mapped.weeklyUsedPercent == 35)
        #expect(mapped.visibleWindowTitles == ["5-Hour Session", "Weekly Limit"])
    }

    @Test
    func durationMetadataOverridesPrimarySecondaryOrder() throws {
        let rateLimits = try decodeRateLimits(
            primary: window(usedPercent: 64, durationMinutes: 10_080, resetsAt: 1_800_100_000),
            secondary: window(usedPercent: 21, durationMinutes: 300, resetsAt: 1_800_000_000)
        )

        let mapped = CodexRateLimitMapper.map(rateLimits)

        #expect(mapped.fiveHourUsedPercent == 21)
        #expect(mapped.weeklyUsedPercent == 64)
        #expect(mapped.fiveHourResetAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(mapped.weeklyResetAt == Date(timeIntervalSince1970: 1_800_100_000))
    }

    @Test
    func mixedTaggedFiveHourAndLegacyWeeklyKeepsBothWindows() throws {
        let rateLimits = try decodeRateLimits(
            primary: window(usedPercent: 12, durationMinutes: 300, resetsAt: 1_800_000_000),
            secondary: window(usedPercent: 78, durationMinutes: nil, resetsAt: 1_800_100_000)
        )

        let mapped = CodexRateLimitMapper.map(rateLimits)

        #expect(mapped.fiveHourUsedPercent == 12)
        #expect(mapped.weeklyUsedPercent == 78)
        #expect(mapped.visibleWindowTitles == ["5-Hour Session", "Weekly Limit"])
    }

    @Test
    func mixedLegacyFiveHourAndTaggedWeeklyKeepsBothWindows() throws {
        let rateLimits = try decodeRateLimits(
            primary: window(usedPercent: 14, durationMinutes: nil, resetsAt: 1_800_000_000),
            secondary: window(usedPercent: 72, durationMinutes: 10_080, resetsAt: 1_800_100_000)
        )

        let mapped = CodexRateLimitMapper.map(rateLimits)

        #expect(mapped.fiveHourUsedPercent == 14)
        #expect(mapped.weeklyUsedPercent == 72)
        #expect(mapped.visibleWindowTitles == ["5-Hour Session", "Weekly Limit"])
    }

    @Test
    func fiveHourOnlyPayloadDoesNotInventWeeklyZero() throws {
        let rateLimits = try decodeRateLimits(
            primary: window(usedPercent: 0, durationMinutes: 300, resetsAt: 1_800_000_000),
            secondary: nil
        )

        let mapped = CodexRateLimitMapper.map(rateLimits)

        #expect(mapped.fiveHourUsedPercent == 0)
        #expect(mapped.weeklyUsedPercent == nil)
        #expect(mapped.visibleWindowTitles == ["5-Hour Session"])
    }

    @Test
    func unknownDurationDoesNotGetMislabelledByPosition() throws {
        let rateLimits = try decodeRateLimits(
            primary: window(usedPercent: 44, durationMinutes: 1_440, resetsAt: 1_800_000_000),
            secondary: nil
        )

        let mapped = CodexRateLimitMapper.map(rateLimits)

        #expect(mapped.fiveHourUsedPercent == nil)
        #expect(mapped.weeklyUsedPercent == nil)
        #expect(mapped.visibleWindowTitles.isEmpty)
    }

    @Test
    func missingOptionalWindowsDecodeDifferentlyFromLiteralZero() throws {
        let missingJSON = #"{"planName":"Pro","apiUnavailable":false}"#.data(using: .utf8)!
        let zeroJSON = #"{"planName":"Pro","weeklyUsedPercent":0,"apiUnavailable":false}"#.data(using: .utf8)!

        let missing = try JSONDecoder().decode(RemoteRateLimitData.self, from: missingJSON)
        let zero = try JSONDecoder().decode(RemoteRateLimitData.self, from: zeroJSON)

        #expect(missing.fiveHourUsedPercent == nil)
        #expect(missing.weeklyUsedPercent == nil)
        #expect(zero.weeklyUsedPercent == 0)
        #expect(zero.visibleWindowTitles == ["Weekly Limit"])
    }

    private func decodeRateLimits(
        primary: [String: Any]?,
        secondary: [String: Any]?
    ) throws -> CodexRateLimitResponse.RateLimitSnapshot {
        var rateLimits: [String: Any] = ["planType": "pro"]
        rateLimits["primary"] = primary
        rateLimits["secondary"] = secondary
        let response: [String: Any] = [
            "result": [
                "rateLimits": rateLimits,
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: response)
        return try JSONDecoder().decode(CodexRateLimitResponse.self, from: data).result.rateLimits
    }

    private func window(
        usedPercent: Int,
        durationMinutes: Int?,
        resetsAt: Int64
    ) -> [String: Any] {
        var result: [String: Any] = [
            "usedPercent": usedPercent,
            "resetsAt": resetsAt,
        ]
        result["windowDurationMins"] = durationMinutes
        return result
    }
}
