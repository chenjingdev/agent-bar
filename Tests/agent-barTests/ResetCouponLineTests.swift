import AppKit
import Foundation
import SwiftUI
import Testing
@testable import agent_bar

// The coupon line: one line whatever it says, in English and Korean, and the store's way from "Reset" to how it ended.
@MainActor
@Suite(.serialized)
struct ResetCouponLineTests {
    // The words' room in a row of the panel's list: the list's and the row's side padding, the mark and its gap.
    static let column = GroupAccountListView.width - 12 - 16 - 26 - 10
    static let korean: Bundle = {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return Bundle(path: root.appendingPathComponent("assets").path)!
    }()
    // The longest each line gets: many coupons, a two-digit day, several going that day.
    static func coupons(_ scope: UsageResetCoupons.Scope = .fiveHourAndWeekly, count: Int = 12) -> UsageResetCoupons {
        let day = Calendar.current.date(from: DateComponents(year: 2026, month: 12, day: 13, hour: 12))!
        return UsageResetCoupons(count: count, scope: scope, expiries: count < 2 ? [] : [day, day] + Array(repeating: day.addingTimeInterval(86_400 * 9), count: count - 2),
                                 claim: .codex(creditID: "c"))
    }
    static var states: [(String, CouponPanel)] {
        var states: [(String, CouponPanel)] = []
        let scopes: [UsageResetCoupons.Scope] = [.fiveHourAndWeekly, .fiveHour, .weekly, .fableWeekly, .fiveHourAndFableWeekly]
        for scope in scopes {
            let coupons = coupons(scope)
            states += [("offer-\(scope)", CouponPanel(coupons: coupons, line: nil)),
                       ("confirm-\(scope)", CouponPanel(coupons: coupons, line: .confirmation())),
                       ("done-\(scope)", CouponPanel(coupons: coupons, line: .result(.reset, left: 11)))]
        }
        var blocked = coupons(.fableWeekly)
        blocked.redeemable = false
        states.append(("unavailable", CouponPanel(coupons: blocked, line: nil)))
        let coupons = coupons()
        states.append(("progress", CouponPanel(coupons: coupons, line: .progress)))
        for outcome in [CouponOutcome.nothingToReset, .noCoupon, .signInAgain, .tryLater] {
            states.append(("\(outcome)", CouponPanel(coupons: coupons, line: .result(outcome, left: nil))))
        }
        return states
    }

    @Test func mixedCouponsDescribeTheTotalFableCountAndNextScope() {
        var mixed = Self.coupons(.weekly, count: 1)
        mixed.totalCount = 4
        mixed.fableCount = 3
        let summary = CouponWords.summary(mixed, Self.korean)
        #expect(summary.contains("쿠폰 4장(Fable 3장)"))
        #expect(summary.contains("다음은 주간"))
    }

    @Test func chooserFitsBothKindsAndExplainsBlockedOption() throws {
        let weekly = UsageResetCoupons.Option(scope: .weekly, claim: .claudeGrant(grantID: "weekly"), count: 1, redeemable: true)
        let fable = UsageResetCoupons.Option(scope: .fiveHourAndFableWeekly, claim: .claudeGrant(grantID: "fable"),
                                             count: 3, redeemable: false, blockReason: .noFableUsage)
        var mixed = Self.coupons(.weekly, count: 1)
        mixed.totalCount = 4
        mixed.fableCount = 3
        mixed.options = [weekly, fable]
        let panel = CouponPanel(coupons: mixed, line: .choosing)
        #expect(panel.selectionOptions == [weekly, fable])
        #expect(CouponWords.selectionTitle(weekly, Self.korean) == "주간 (1장)")
        #expect(CouponWords.selectionTitle(fable, Self.korean) == "5시간·Fable 주간 (3장)")
        #expect(CouponWords.selectionDetail(fable, Self.korean) == "Fable 사용량 필요")
        #expect(!CouponWords.summary(mixed, Self.korean).contains("다음은"))
        for bundle in [Bundle.main, Self.korean] {
            let chooser = CouponLineView(panel: panel, bundle: bundle)
            let size = NSHostingView(rootView: chooser.frame(width: Self.column)).fittingSize
            #expect(size.width <= Self.column)
            #expect(size.height > CouponLineView.height * 2)
        }
    }

    @Test func everyStateIsOneLineOfTheSameHeightThatFitsInEnglishAndKorean() throws {
        #expect(CouponWords.question(.fiveHourAndWeekly, Self.korean).contains("쿠폰"))
        let button = NSHostingView(rootView: Button {} label: { Text(verbatim: "Reset").font(GroupAccountRow.buttonFont) }
            .buttonStyle(PanelBorderedButtonStyle()).fixedSize())
        #expect(button.fittingSize.height <= CouponLineView.height)
        for bundle in [Bundle.main, Self.korean] {
            for (name, panel) in Self.states {
                let line = CouponLineView(panel: panel, bundle: bundle)
                #expect(NSHostingView(rootView: line.frame(width: Self.column)).fittingSize.height == CouponLineView.height, "\(name)")
                // Its words at their whole width, never cut short.
                let whole = NSHostingView(rootView: line.fixedSize()).fittingSize.width
                #expect(whole <= Self.column, "\(name) \(bundle == .main ? "en" : "ko"): \(whole) > \(Self.column)")
            }
        }
    }

    @Test func aRowIsAsTallInEveryCouponStateAndAsBeforeWithoutCoupons() throws {
        func height(_ coupon: CouponPanel) -> CGFloat {
            let row = GroupAccountRow(provider: .codex, badge: "CX", address: "cx@example.test", snapshot: Self.snapshot(nil), coupon: coupon)
            return NSHostingView(rootView: row.frame(width: GroupAccountListView.width - 12)).fittingSize.height
        }
        let heights = Set(Self.states.map { height($0.1) })
        #expect(heights.count == 1)
        let without = height(.none)
        #expect(heights.first.map { $0 > without } == true)
        // No coupon left and nothing going on: the row is as it was.
        #expect(height(CouponPanel(coupons: Self.coupons(count: 0).usable, line: nil)) == without)
    }

    @Test func resetAsksThenUsesOneAndSaysHowItEndedForAWhile() async throws {
        let fixture = try CouponStoreFixture()
        defer { fixture.close() }
        await fixture.store.refresh()
        let store = fixture.store, account = fixture.codex
        #expect(store.couponPanel(for: account).coupons?.count == 3)
        #expect(!store.couponPanel(for: fixture.claude).shows)

        store.askToUseCoupon(account)
        #expect(store.couponPanel(for: account).line == .confirmation())
        store.cancelCoupon(account)
        #expect(store.couponPanel(for: account).line == nil)
        #expect(await fixture.service.calls == 0)

        await fixture.service.hold()
        store.askToUseCoupon(account)
        store.confirmCoupon(account)
        #expect(store.couponPanel(for: account).line == .progress)
        // A second OK while it runs does nothing.
        store.confirmCoupon(account)
        let loads = await fixture.loader.loads
        await fixture.loader.setCount(2)
        await fixture.service.release(.reset)
        try await fixture.waitFor { store.couponPanel(for: account).line == .result(.reset, left: 2) }
        #expect(await fixture.service.calls == 1)
        #expect(store.couponPanel(for: account).coupons?.count == 2)
        // Read again at once, then the line goes back to the coupons.
        try await fixture.waitFor { await fixture.loader.loads > loads }
        try await fixture.waitFor { store.couponPanel(for: account).line == nil }
        #expect(store.couponPanel(for: account).coupons?.count == 2)
    }

    @Test func noCouponLeftTakesTheLineAwayAndFailuresKeepTheCoupons() async throws {
        let fixture = try CouponStoreFixture()
        defer { fixture.close() }
        await fixture.store.refresh()
        let store = fixture.store, account = fixture.codex
        for outcome in [CouponOutcome.tryLater, .signInAgain, .nothingToReset] {
            await fixture.service.next(outcome)
            store.askToUseCoupon(account); store.confirmCoupon(account)
            try await fixture.waitFor { store.couponPanel(for: account).line == .result(outcome, left: nil) }
            #expect(store.couponPanel(for: account).coupons?.count == 3)
        }
        await fixture.service.next(.noCoupon)
        store.askToUseCoupon(account); store.confirmCoupon(account)
        try await fixture.waitFor { store.couponPanel(for: account).line == .result(.noCoupon, left: nil) }
        #expect(store.couponPanel(for: account).coupons == nil)
        try await fixture.waitFor { !store.couponPanel(for: account).shows }
    }

    @Test func claudeChooserConfirmsTheSelectedKindBeforeClaimingIt() async throws {
        let weekly = UsageResetCoupons.Option(scope: .weekly, claim: .claudeGrant(grantID: "weekly"), count: 1, redeemable: true)
        let fable = UsageResetCoupons.Option(scope: .fiveHourAndFableWeekly, claim: .claudeGrant(grantID: "fable"),
                                             count: 2, redeemable: true, affectedUsagePercent: 26)
        let coupons = UsageResetCoupons(count: 1, scope: weekly.scope, claim: weekly.claim,
                                       totalCount: 3, fableCount: 2, options: [weekly, fable])
        let fixture = try CouponStoreFixture(claudeCoupons: coupons)
        defer { fixture.close() }
        await fixture.store.refresh()
        let store = fixture.store, account = fixture.claude
        store.askToUseCoupon(account)
        #expect(store.couponPanel(for: account).line == .choosing)
        store.chooseCoupon(fable.claim, for: account)
        #expect(store.couponPanel(for: account).coupons?.affectedUsagePercent == 26)
        #expect(store.couponPanel(for: account).line == .confirmation(fable.claim, fable.scope))
        #expect(await fixture.service.calls == 0)
        await fixture.service.next(.nothingToReset)
        store.confirmCoupon(account)
        try await fixture.waitFor { await fixture.service.lastClaim == fable.claim }
        #expect(await fixture.service.calls == 1)
    }

    nonisolated static func snapshot(_ coupons: UsageResetCoupons?, stale: Bool = false, provider: ProviderKind = .codex) -> ProviderSnapshot {
        var snapshot = ProviderSnapshot(provider: provider, updatedAt: .now,
            fiveHour: WindowSummary(tokens: 64, limitTokens: 100, resetAt: .now.addingTimeInterval(3600), displayStyle: .percentage),
            weekly: WindowSummary(tokens: 22, limitTokens: 100, resetAt: .now.addingTimeInterval(86_400), displayStyle: .percentage),
            modelWeeklies: [], planName: "Team", sourceDescription: "Fixture", note: nil, isStale: stale, requiresLogin: false)
        snapshot.resetCoupons = coupons
        return snapshot
    }
}

@MainActor
private final class CouponStoreFixture {
    let files = AccountFiles(root: FileManager.default.temporaryDirectory.appendingPathComponent("coupon-store-\(UUID())"))
    let suite = "coupon-store-\(UUID())"
    let claude = UsageAccount(id: UUID(), provider: .claude, name: "A", credentialID: UUID())
    let codex = UsageAccount(id: UUID(), provider: .codex, name: "B", credentialID: UUID())
    let loader = CouponLoader()
    let service = CouponService()
    let store: UsageStore

    init(claudeCoupons: UsageResetCoupons? = nil) throws {
        var registry = AccountRegistry(accounts: [claude, codex]); registry.repairRepresentatives()
        try files.write(registry, to: files.registryURL)
        try files.write(DisplayConfiguration.initial(registry), to: files.root.appendingPathComponent("display-v2.json"))
        let loader = loader, service = service, codexID = codex.id
        store = UsageStore(settings: AppSettings(defaults: UserDefaults(suiteName: suite)!), files: files, autoRefresh: false,
                           loadAccount: { account, _ in
                               if account.id == codexID { return await loader.load(account, coupons: true) }
                               return ResetCouponLineTests.snapshot(claudeCoupons, provider: .claude)
                           },
                           useCoupon: { _, coupons in await service.use(coupons.claim) }, couponResultSeconds: 0.3)
    }
    func close() { store.shutdown(); try? FileManager.default.removeItem(at: files.root); UserDefaults().removePersistentDomain(forName: suite) }
    func waitFor(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !(await condition()) {
            if Date() > deadline { throw AccountError.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor CouponLoader {
    private(set) var loads = 0
    private var count = 3
    func setCount(_ value: Int) { count = value }
    func load(_ account: UsageAccount, coupons: Bool) -> ProviderSnapshot {
        loads += 1
        return ResetCouponLineTests.snapshot(coupons ? UsageResetCoupons(count: count, scope: .fiveHourAndWeekly, claim: .codex(creditID: "c")) : nil)
    }
}

private actor CouponService {
    private(set) var calls = 0
    private(set) var lastClaim: UsageResetCoupons.Claim?
    private var held = false
    private var outcome = CouponOutcome.reset
    func hold() { held = true }
    func next(_ value: CouponOutcome) { outcome = value }
    func release(_ value: CouponOutcome) { outcome = value; held = false }
    func use(_ claim: UsageResetCoupons.Claim) async -> CouponOutcome {
        calls += 1
        lastClaim = claim
        while held { try? await Task.sleep(for: .milliseconds(5)) }
        return outcome
    }
}
