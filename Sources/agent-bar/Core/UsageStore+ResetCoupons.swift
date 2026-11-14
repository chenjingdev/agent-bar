import Foundation

// Usage-reset coupons on a group's account list: "Reset" asks, OK uses one, and how it ended shows for a few seconds.
extension UsageStore {
    // What an account's row shows. Coupons come only with fresh usage, so cached or failed usage offers none.
    func couponPanel(for account: UsageAccount) -> CouponPanel {
        let snapshot = snapshot(for: account)
        var coupons = snapshot.isStale || snapshot.requiresLogin ? nil : snapshot.resetCoupons?.usable
        var line = couponLines[account.id]
        switch line {
        case .choosing:
            if (coupons?.options?.count ?? 0) < 2 { line = nil }
        case .confirmation(let claim, let scope):
            if let claim, let available = coupons {
                let options = available.options ?? [available.selectedOption]
                if let selected = options.first(where: { $0.claim == claim && $0.scope == scope && $0.canRedeem }) {
                    coupons = available.selecting(selected)
                } else {
                    line = nil
                }
            } else if coupons?.canRedeem != true {
                line = nil
            }
        default: break
        }
        return CouponPanel(coupons: coupons, line: line)
    }

    // "Reset": the line turns into the question.
    func askToUseCoupon(_ account: UsageAccount) {
        let panel = couponPanel(for: account)
        guard let coupons = panel.coupons, panel.line == nil || isResult(account.id) else { return }
        if account.provider == .claude, let options = coupons.options, options.count > 1, options.contains(where: \.canRedeem) {
            couponLines[account.id] = .choosing
            return
        }
        guard coupons.canRedeem else { return }
        couponLines[account.id] = account.provider == .claude
            ? .confirmation(coupons.claim, coupons.scope) : .confirmation()
    }

    func chooseCoupon(_ claim: UsageResetCoupons.Claim, for account: UsageAccount) {
        let panel = couponPanel(for: account)
        guard case .choosing = panel.line,
              let selected = panel.coupons?.options?.first(where: { $0.claim == claim && $0.canRedeem }) else { return }
        couponLines[account.id] = .confirmation(selected.claim, selected.scope)
    }

    func cancelCoupon(_ account: UsageAccount) {
        switch couponLines[account.id] {
        case .choosing, .confirmation: couponLines[account.id] = nil
        default: break
        }
    }

    // OK on the question: one coupon is used, then how it ended shows.
    func confirmCoupon(_ account: UsageAccount) {
        let panel = couponPanel(for: account)
        guard case .confirmation = panel.line, let coupons = panel.coupons else { return }
        couponLines[account.id] = .progress
        Task { [weak self] in
            guard let self else { return }
            let outcome = await useCoupon(coupons, for: account)
            let left: Int? = outcome == .reset ? (coupons.totalCount ?? coupons.count) - 1 : nil
            let displayedOutcome = account.provider == .claude && outcome == .noCoupon ? .conditionsChanged : outcome
            couponLines[account.id] = .result(displayedOutcome, left: left, scope: account.provider == .claude ? coupons.scope : nil)
            applyCouponOutcome(outcome, coupons: coupons, for: account)
            let shown = couponLines[account.id]
            try? await Task.sleep(for: .seconds(couponResultSeconds))
            if couponLines[account.id] == shown { couponLines[account.id] = nil }
        }
    }

    private func isResult(_ id: UUID) -> Bool {
        if case .result = couponLines[id] { return true }
        return false
    }

    private func useCoupon(_ coupons: UsageResetCoupons, for account: UsageAccount) async -> CouponOutcome {
        if let useCouponOverride { return await useCouponOverride(account, coupons) }
        guard let directory = credentialDirectory(for: account) else { return .signInAgain }
        switch account.provider {
        case .codex:
            return await CodexCouponClaim.use(coupons, directory: directory, expectedIdentity: account.identity)
        case .claude:
            return await ClaudeUsageProvider(directory: directory, cacheURL: files.cache(account),
                                             expectedIdentity: account.identity).useCoupon(coupons)
        case .antigravity:
            return .tryLater
        }
    }
}
