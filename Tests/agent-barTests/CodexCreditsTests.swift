import AppKit
import Foundation
import SwiftUI
import Testing
@testable import agent_bar

struct CodexCreditsTests {
    @Test
    func resetCountAndCreditBalanceDecodeFromRateLimitRead() throws {
        let result = try decode([
            "rateLimits": rateLimits(credits: ["hasCredits": true, "unlimited": false, "balance": "6506.2372165000"]),
            "rateLimitResetCredits": [
                "availableCount": 3,
                "credits": [[
                    "id": "RateLimitResetCredit_fixture", "resetType": "codexRateLimits", "status": "available",
                    "grantedAt": 1_790_111_171, "expiresAt": 1_792_703_171,
                    "title": "Full reset", "description": "Fixture reset.",
                ]],
            ],
        ])

        let credits = CodexRateLimitMapper.credits(result.rateLimits.credits)
        #expect(result.rateLimitResetCredits?.availableCount == 3)
        #expect(credits == CreditBalance(balance: 6506.2372165))
        #expect(TokenFormatters.creditString(credits) == "6,506")
        #expect(CodexRateLimitMapper.map(result.rateLimits).weeklyUsedPercent == 7)
    }

    @Test
    func accountWithoutCreditsShowsKnownZero() throws {
        let result = try decode(["rateLimits": rateLimits(credits: ["hasCredits": false, "unlimited": false, "balance": NSNull()])])
        #expect(TokenFormatters.creditString(CodexRateLimitMapper.credits(result.rateLimits.credits)) == "0")
    }

    @Test
    func unlimitedAndUnknownBalancesAreNotNumbers() throws {
        let unlimited = try decode(["rateLimits": rateLimits(credits: ["hasCredits": true, "unlimited": true, "balance": NSNull()])])
        let unknown = try decode(["rateLimits": rateLimits(credits: ["hasCredits": true, "unlimited": false, "balance": NSNull()])])
        #expect(TokenFormatters.creditString(CodexRateLimitMapper.credits(unlimited.rateLimits.credits)) == "Unlimited")
        #expect(TokenFormatters.creditString(CodexRateLimitMapper.credits(unknown.rateLimits.credits)) == "--")
        #expect(TokenFormatters.creditString(nil) == "--")
    }

    @Test
    func payloadWithoutExtrasReportsNothing() throws {
        let result = try decode(["rateLimits": rateLimits(credits: nil)])
        #expect(result.rateLimitResetCredits == nil)
        #expect(CodexRateLimitMapper.credits(result.rateLimits.credits) == nil)
        #expect(snapshot(resets: nil, credits: nil).reportsCredits == false)
    }

    @Test
    func malformedExtrasDoNotHideUsageWindows() throws {
        let result = try decode([
            "rateLimits": rateLimits(credits: ["balance": 12]),
            "rateLimitResetCredits": ["availableCount": "three"],
        ])
        #expect(result.rateLimitResetCredits == nil)
        #expect(result.rateLimits.credits == nil)
        #expect(CodexRateLimitMapper.map(result.rateLimits).weeklyUsedPercent == 7)
    }

    @Test
    func failedRefreshKeepsLastKnownCredits() {
        let failed = snapshot(resets: UsageLimitResets(available: 2), credits: CreditBalance(balance: 40)).failed("Could not load usage")
        #expect(failed.isStale)
        #expect(failed.usageLimitResets?.available == 2)
        #expect(failed.credits == CreditBalance(balance: 40))
    }

    @Test
    func cachedSnapshotFromEarlierVersionStillDecodes() throws {
        let json = #"{"requiresLogin":false,"planName":"Pro","note":"Account-wide Codex usage limits.","sourceDescription":"Codex app-server account\/rateLimits\/read","isStale":false,"modelWeeklies":[],"weekly":{"limitTokens":100,"displayStyle":"percentage","resetAt":"2026-10-14T03:49:02Z","tokens":7},"updatedAt":"2026-10-09T04:42:39Z","provider":"codex"}"#
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let cached = try decoder.decode(ProviderSnapshot.self, from: Data(json.utf8))
        #expect(cached.weekly?.tokens == 7)
        #expect(cached.reportsCredits == false)
    }

    @Test @MainActor
    func codexPopoverRendersResetsAndCredits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentbar-credits-\(UUID())")
        let suite = "agentbar-credits-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let files = AccountFiles(root: root)
        let account = UsageAccount(id: UUID(), provider: .codex, name: "Codex", credentialID: UUID())
        var registry = AccountRegistry(accounts: [account]); registry.repairRepresentatives()
        try files.write(registry, to: files.registryURL)
        let loaded = snapshot(resets: UsageLimitResets(available: 3), credits: CreditBalance(balance: 6506.24))
        let store = UsageStore(settings: AppSettings(defaults: defaults), files: files, autoRefresh: false,
                               loadAccount: { _, _ in loaded })
        defer { store.shutdown() }
        await store.refresh()
        #expect(store.snapshot(for: account).usageLimitResets?.available == 3)

        let host = NSHostingView(rootView: AccountPopoverView(accountID: account.id).environmentObject(store))
        host.frame = NSRect(x: 0, y: 0, width: 392, height: 420)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
        if let destination = ProcessInfo.processInfo.environment["AGENTBAR_QA_ARTIFACT_DIR"] {
            let directory = URL(fileURLWithPath: destination)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("popover-codex-credits.png"))
        }
    }

    private func decode(_ result: [String: Any]) throws -> CodexRateLimitResponse.ResultPayload {
        let data = try JSONSerialization.data(withJSONObject: ["result": result])
        return try JSONDecoder().decode(CodexRateLimitResponse.self, from: data).result
    }

    private func rateLimits(credits: [String: Any]?) -> [String: Any] {
        var value: [String: Any] = [
            "planType": "pro",
            "primary": ["usedPercent": 7, "windowDurationMins": 10_080, "resetsAt": 1_791_949_743],
            "secondary": NSNull(),
        ]
        value["credits"] = credits ?? NSNull()
        return value
    }

    private func snapshot(resets: UsageLimitResets?, credits: CreditBalance?) -> ProviderSnapshot {
        ProviderSnapshot(provider: .codex, updatedAt: .now, fiveHour: nil,
                         weekly: WindowSummary(tokens: 7, limitTokens: 100, resetAt: nil, displayStyle: .percentage),
                         modelWeeklies: [], planName: "Pro", sourceDescription: ProviderKind.codex.sourceDescription,
                         note: nil, isStale: false, requiresLogin: false, usageLimitResets: resets, credits: credits)
    }
}
