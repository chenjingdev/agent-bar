import Foundation
import Testing
@testable import agent_bar

struct ClaudeCacheIsolationTests {
    @Test func cooldownWithoutGoodValueAndCredentialChange() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentbar-cache-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ClaudeUsageCache(overrideURL: directory.appendingPathComponent("usage.json"), enabled: true)
        let now = Date()
        let failure = RemoteUsageData(planName: nil, fiveHourUsedPercent: nil, weeklyUsedPercent: nil,
            fiveHourResetAt: nil, weeklyResetAt: nil, modelWeeklies: nil, apiUnavailable: true,
            apiError: "rate-limited", usageSource: .oauthApi, weeklyWindowLabel: nil)
        try cache.write(data: failure, timestamp: now, credentialCacheKey: "account-A", rateLimitedCount: 1,
                        retryAfterUntil: now.addingTimeInterval(120))
        let limited = try cache.readState(now: now.addingTimeInterval(65), credentialCacheKey: "account-A")
        #expect(limited.isFresh)
        #expect(limited.data.weeklyUsedPercent == nil)
        #expect(try !cache.readState(now: now.addingTimeInterval(65), credentialCacheKey: "account-B").isFresh)
        #expect(try !cache.readState(now: now.addingTimeInterval(65), credentialCacheKey: nil).isFresh)
        #expect(cache.makeLastGoodState(from: try cache.readRaw(), credentialCacheKey: "account-B") == nil)
    }
    @Test func lastGoodValueRequiresMatchingCredential() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentbar-cache-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ClaudeUsageCache(overrideURL: directory.appendingPathComponent("usage.json"), enabled: true)
        let good = RemoteUsageData(planName: "Pro", fiveHourUsedPercent: 25, weeklyUsedPercent: 40,
            fiveHourResetAt: nil, weeklyResetAt: nil, modelWeeklies: nil, apiUnavailable: false,
            apiError: nil, usageSource: .oauthApi, weeklyWindowLabel: nil)
        try cache.write(data: good, timestamp: .now, credentialCacheKey: "account-A", lastGoodData: good)
        let raw = try cache.readRaw()
        #expect(cache.makeLastGoodState(from: raw, credentialCacheKey: "account-A")?.data.weeklyUsedPercent == 40)
        #expect(cache.makeLastGoodState(from: raw, credentialCacheKey: "account-B") == nil)
        #expect(cache.makeLastGoodState(from: raw, credentialCacheKey: nil) == nil)
    }
}
