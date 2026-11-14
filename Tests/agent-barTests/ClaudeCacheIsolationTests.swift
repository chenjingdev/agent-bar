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
        cache.expire()
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
    // After a coupon, the cache asks again at the next refresh but keeps when its numbers were read: a refusal right
    // after shows them with that time, not 1970 ("56 years ago").
    @Test func expiringAsksAgainButKeepsWhenTheNumbersWereRead() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentbar-cache-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ClaudeUsageCache(overrideURL: directory.appendingPathComponent("usage.json"), enabled: true)
        let read = Date(timeIntervalSince1970: 1_800_000_000)
        let good = RemoteUsageData(planName: "Pro", fiveHourUsedPercent: 25, weeklyUsedPercent: 40,
            fiveHourResetAt: nil, weeklyResetAt: nil, modelWeeklies: nil, apiUnavailable: false,
            apiError: nil, usageSource: .oauthApi, weeklyWindowLabel: nil)
        try cache.write(data: good, timestamp: read, credentialCacheKey: "account-A", lastGoodData: good, lastGoodTimestamp: read)
        #expect(try cache.readState(now: read.addingTimeInterval(10), credentialCacheKey: "account-A").isFresh)
        cache.expire()
        let expired = try cache.readState(now: read.addingTimeInterval(10), credentialCacheKey: "account-A")
        #expect(!expired.isFresh)
        #expect(expired.updatedAt == read)
        #expect(cache.makeLastGoodState(from: try cache.readRaw(), credentialCacheKey: "account-A")?.updatedAt == read)
        // The next read written is fresh again.
        let next = read.addingTimeInterval(20)
        try cache.write(data: good, timestamp: next, credentialCacheKey: "account-A", lastGoodData: good, lastGoodTimestamp: next)
        #expect(try cache.readState(now: next.addingTimeInterval(10), credentialCacheKey: "account-A").isFresh)
    }
}
