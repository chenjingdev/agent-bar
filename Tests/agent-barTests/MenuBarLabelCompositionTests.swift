import AppKit
import Foundation
import SwiftUI
import Testing
@testable import agent_bar

@MainActor
struct MenuBarLabelCompositionTests {
    // Layout constants shipped by MenuBarLabelView: horizontal padding on each
    // side, inter-component spacing, compact badge width, usage bar stack width.
    private static let horizontalPadding: CGFloat = 5
    private static let componentSpacing: CGFloat = 4
    private static let badgeWidth: CGFloat = 15
    private static let barsWidth: CGFloat = 30

    private static func expectedWidth(componentWidths: [CGFloat]) -> CGFloat {
        let content = componentWidths.reduce(0, +)
        let spacing = componentSpacing * CGFloat(max(componentWidths.count - 1, 0))
        return content + spacing + horizontalPadding * 2
    }

    private func snapshot(for provider: ProviderKind = .claude) -> ProviderSnapshot {
        ProviderSnapshot(
            provider: provider,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            fiveHour: WindowSummary(tokens: 42, limitTokens: 100, resetAt: nil, displayStyle: .percentage),
            weekly: WindowSummary(tokens: 63, limitTokens: 100, resetAt: nil, displayStyle: .percentage),
            modelWeeklies: [],
            planName: "Max",
            sourceDescription: provider.sourceDescription,
            note: nil,
            isStale: false,
            requiresLogin: false
        )
    }

    private func displaySettings(
        badge: Bool,
        bars: Bool,
        percentage: Bool,
        isEnabled: Bool = true
    ) -> ProviderDisplaySettings {
        ProviderDisplaySettings(
            isEnabled: isEnabled,
            showsBadge: badge,
            showsUsageBars: bars,
            showsPercentage: percentage
        )
    }

    private func fittingSize(
        badge: Bool,
        bars: Bool,
        percentage: Bool
    ) -> NSSize {
        let view = MenuBarLabelView(
            snapshot: snapshot(),
            displaySettings: displaySettings(badge: badge, bars: bars, percentage: percentage)
        )
        let hostingView = NSHostingView(rootView: view)
        return hostingView.fittingSize
    }

    @Test("Badge only renders a badge-width label and reports the badge component")
    func badgeOnlyComposition() {
        let settings = displaySettings(badge: true, bars: false, percentage: false)
        #expect(settings.visibleComponents == [.badge])

        let size = fittingSize(badge: true, bars: false, percentage: false)
        #expect(size.width == Self.expectedWidth(componentWidths: [Self.badgeWidth]))
        #expect(size.height > 0)
    }

    @Test("Bars only renders a bars-width label and reports the bars component")
    func barsOnlyComposition() {
        let settings = displaySettings(badge: false, bars: true, percentage: false)
        #expect(settings.visibleComponents == [.bars])

        let size = fittingSize(badge: false, bars: true, percentage: false)
        #expect(size.width == Self.expectedWidth(componentWidths: [Self.barsWidth]))
        #expect(size.height > 0)
    }

    @Test("Bars-only label centers one unavailable track when no usage window exists")
    func barsOnlyUnavailableComposition() {
        let unavailable = ProviderSnapshot(
            provider: .codex,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            fiveHour: nil,
            weekly: nil,
            modelWeeklies: [],
            planName: nil,
            sourceDescription: ProviderKind.codex.sourceDescription,
            note: "Usage unavailable.",
            isStale: true,
            requiresLogin: false
        )
        let view = MenuBarLabelView(
            snapshot: unavailable,
            displaySettings: displaySettings(badge: false, bars: true, percentage: false)
        )

        #expect(view.bars.count == 1)
        #expect(view.bars[0].value == .unavailable)
        #expect(NSHostingView(rootView: view).fittingSize.width == Self.expectedWidth(componentWidths: [Self.barsWidth]))
    }

    @Test("Weekly-only Codex centers its reported usage bar")
    func weeklyOnlyCodexCentersReportedBar() {
        let weeklyOnly = ProviderSnapshot(
            provider: .codex,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            fiveHour: nil,
            weekly: WindowSummary(tokens: 25, limitTokens: 100, resetAt: nil, displayStyle: .percentage),
            modelWeeklies: [],
            planName: "Pro",
            sourceDescription: ProviderKind.codex.sourceDescription,
            note: nil,
            isStale: false,
            requiresLogin: false
        )
        let view = MenuBarLabelView(
            snapshot: weeklyOnly,
            displaySettings: displaySettings(badge: true, bars: true, percentage: true)
        )

        #expect(view.bars.count == 1)
        #expect(view.bars[0].value == .available(0.25))
    }

    @Test("A reported zero remains available and differs from a missing Codex window")
    func actualZeroDiffersFromUnavailableWindow() {
        let fiveHourOnly = ProviderSnapshot(
            provider: .codex,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            fiveHour: WindowSummary(tokens: 0, limitTokens: 100, resetAt: nil, displayStyle: .percentage),
            weekly: nil,
            modelWeeklies: [],
            planName: "Pro",
            sourceDescription: ProviderKind.codex.sourceDescription,
            note: nil,
            isStale: false,
            requiresLogin: false
        )
        let view = MenuBarLabelView(
            snapshot: fiveHourOnly,
            displaySettings: displaySettings(badge: true, bars: true, percentage: true)
        )

        #expect(view.bars.count == 1)
        #expect(view.bars[0].value == .available(0))
    }

    @Test("Dual-window Codex keeps five-hour and weekly bars in order")
    func dualWindowCodexKeepsBarOrder() {
        let view = MenuBarLabelView(
            snapshot: snapshot(for: .codex),
            displaySettings: displaySettings(badge: true, bars: true, percentage: true)
        )

        #expect(view.bars.count == 2)
        #expect(view.bars[0].value == .available(0.42))
        #expect(view.bars[1].value == .available(0.63))
    }

    @Test("Claude keeps three fixed menu-bar slots including unavailable Fable usage")
    func claudeKeepsThreeFixedSlots() {
        let view = MenuBarLabelView(
            snapshot: snapshot(for: .claude),
            displaySettings: displaySettings(badge: true, bars: true, percentage: true)
        )

        #expect(view.bars.count == 3)
        #expect(view.bars[0].value.isAvailable)
        #expect(view.bars[1].value.isAvailable)
        #expect(view.bars[2].value == .unavailable)
    }

    @Test("Percentage only renders a text-width label and reports the percentage component")
    func percentageOnlyComposition() {
        let settings = displaySettings(badge: false, bars: false, percentage: true)
        #expect(settings.visibleComponents == [.percentage])

        let size = fittingSize(badge: false, bars: false, percentage: true)
        #expect(size.width > Self.horizontalPadding * 2)
        #expect(size.width != Self.expectedWidth(componentWidths: [Self.badgeWidth]))
        #expect(size.height > 0)
    }

    @Test("Badge and bars renders both fixed-width components in order")
    func badgeAndBarsComposition() {
        let settings = displaySettings(badge: true, bars: true, percentage: false)
        #expect(settings.visibleComponents == [.badge, .bars])

        let size = fittingSize(badge: true, bars: true, percentage: false)
        #expect(size.width == Self.expectedWidth(componentWidths: [Self.badgeWidth, Self.barsWidth]))
    }

    @Test("Badge and percentage widens the badge-only label by the percentage text")
    func badgeAndPercentageComposition() {
        let settings = displaySettings(badge: true, bars: false, percentage: true)
        #expect(settings.visibleComponents == [.badge, .percentage])

        let combined = fittingSize(badge: true, bars: false, percentage: true)
        let badgeOnly = fittingSize(badge: true, bars: false, percentage: false)
        let percentageOnly = fittingSize(badge: false, bars: false, percentage: true)
        let percentageContentWidth = percentageOnly.width - Self.horizontalPadding * 2

        #expect(combined.width == badgeOnly.width + Self.componentSpacing + percentageContentWidth)
    }

    @Test("Bars and percentage widens the bars-only label by the percentage text")
    func barsAndPercentageComposition() {
        let settings = displaySettings(badge: false, bars: true, percentage: true)
        #expect(settings.visibleComponents == [.bars, .percentage])

        let combined = fittingSize(badge: false, bars: true, percentage: true)
        let barsOnly = fittingSize(badge: false, bars: true, percentage: false)
        let percentageOnly = fittingSize(badge: false, bars: false, percentage: true)
        let percentageContentWidth = percentageOnly.width - Self.horizontalPadding * 2

        #expect(combined.width == barsOnly.width + Self.componentSpacing + percentageContentWidth)
    }

    @Test("All components render badge, bars and percentage in that order")
    func allComponentsComposition() {
        let settings = displaySettings(badge: true, bars: true, percentage: true)
        #expect(settings.visibleComponents == [.badge, .bars, .percentage])

        let combined = fittingSize(badge: true, bars: true, percentage: true)
        let badgeAndBars = fittingSize(badge: true, bars: true, percentage: false)
        let percentageOnly = fittingSize(badge: false, bars: false, percentage: true)
        let percentageContentWidth = percentageOnly.width - Self.horizontalPadding * 2

        #expect(combined.width == badgeAndBars.width + Self.componentSpacing + percentageContentWidth)
        #expect(combined.width > badgeAndBars.width)
        #expect(combined.width > fittingSize(badge: false, bars: true, percentage: true).width)
    }

    @Test("Hiding a component never widens the label")
    func hidingComponentNeverWidensLabel() {
        let all = fittingSize(badge: true, bars: true, percentage: true)
        let combinations: [(Bool, Bool, Bool)] = [
            (true, true, false),
            (true, false, true),
            (false, true, true),
            (true, false, false),
            (false, true, false),
            (false, false, true),
        ]

        for (badge, bars, percentage) in combinations {
            let size = fittingSize(badge: badge, bars: bars, percentage: percentage)
            #expect(size.width < all.width)
        }
    }

    @Test("Label height stays constant across every visible component combination")
    func labelHeightIsStableAcrossCombinations() {
        let all = fittingSize(badge: true, bars: true, percentage: true)
        let combinations: [(Bool, Bool, Bool)] = [
            (true, true, false),
            (true, false, true),
            (false, true, true),
            (true, false, false),
            (false, true, false),
            (false, false, true),
        ]

        for (badge, bars, percentage) in combinations {
            let size = fittingSize(badge: badge, bars: bars, percentage: percentage)
            #expect(size.height == all.height)
        }
    }

    @Test("Status item renderer includes a 2x bitmap without changing logical size")
    func statusItemRendererUsesHighResolutionRepresentation() {
        let rendered = StatusItemRenderer.render(
            snapshot: snapshot(),
            displaySettings: displaySettings(badge: true, bars: true, percentage: true)
        )
        let bitmap = rendered.image.representations
            .compactMap { $0 as? NSBitmapImageRep }
            .first

        #expect(bitmap != nil)
        #expect(bitmap?.size == rendered.size)
        #expect(bitmap?.pixelsWide == Int(ceil(rendered.size.width * StatusItemRenderer.renderScale)))
        #expect(bitmap?.pixelsHigh == Int(ceil(rendered.size.height * StatusItemRenderer.renderScale)))
    }

    @Test("Providers share one status item with a four-point capsule gap")
    func providersShareOneStatusItem() {
        let defaults = createTestDefaults()
        let providers: [ProviderKind] = [.claude, .codex]
        let settings = AppSettings(availableProviders: providers, defaults: defaults)
        let store = UsageStore(
            settings: settings,
            availableProviders: providers,
            claudeProvider: StubUsageProvider(provider: .claude),
            codexProvider: StubUsageProvider(provider: .codex),
            refreshOnInit: false
        )
        let coordinator = StatusBarCoordinator(store: store, settings: settings, providers: providers)

        #expect(StatusBarController.interProviderSpacing == 4)
        #expect(coordinator.physicalStatusItemCount == 1)
        #expect(coordinator.visibleProviderOrder == [.codex, .claude])

        let codexFrame = coordinator.statusItemFrame(for: .codex)
        let claudeFrame = coordinator.statusItemFrame(for: .claude)
        #expect(codexFrame != nil)
        #expect(claudeFrame != nil)
        #expect(claudeFrame!.minX - codexFrame!.maxX == StatusBarController.interProviderSpacing)
        #expect(
            coordinator.combinedStatusItemLength
                == coordinator.statusItemLength(for: .codex)
                    + StatusBarController.interProviderSpacing
                    + coordinator.statusItemLength(for: .claude)
        )

        let gapMidpoint = (codexFrame!.maxX + claudeFrame!.minX) / 2
        #expect(coordinator.provider(atStatusItemImageX: gapMidpoint - 0.1) == .codex)
        #expect(coordinator.provider(atStatusItemImageX: gapMidpoint + 0.1) == .claude)
    }

    @Test("Disabling one provider removes its capsule and the inter-provider gap")
    func disablingProviderCompactsSharedStatusItem() {
        let defaults = createTestDefaults()
        let providers: [ProviderKind] = [.claude, .codex]
        let settings = AppSettings(availableProviders: providers, defaults: defaults)
        let store = UsageStore(
            settings: settings,
            availableProviders: providers,
            claudeProvider: StubUsageProvider(provider: .claude),
            codexProvider: StubUsageProvider(provider: .codex),
            refreshOnInit: false
        )
        let coordinator = StatusBarCoordinator(store: store, settings: settings, providers: providers)
        let originalLength = coordinator.combinedStatusItemLength
        let claudeLength = coordinator.statusItemLength(for: .claude)

        #expect(settings.setProviderEnabled(.claude, enabled: false) == true)
        #expect(coordinator.visibleProviderOrder == [.codex])
        #expect(coordinator.statusItemFrame(for: .claude) == nil)
        #expect(coordinator.combinedStatusItemLength == coordinator.statusItemLength(for: .codex))
        #expect(
            originalLength - coordinator.combinedStatusItemLength
                == claudeLength + StatusBarController.interProviderSpacing
        )

        #expect(settings.setProviderEnabled(.claude, enabled: true) == true)
        #expect(coordinator.visibleProviderOrder == [.codex, .claude])
        #expect(coordinator.combinedStatusItemLength == originalLength)
    }

    @Test("StatusBarCoordinator hides status items for disabled providers")
    func coordinatorHidesDisabledProviders() {
        let defaults = createTestDefaults()
        let providers: [ProviderKind] = [.claude, .codex]
        let settings = AppSettings(availableProviders: providers, defaults: defaults)
        let store = UsageStore(
            settings: settings,
            availableProviders: providers,
            claudeProvider: StubUsageProvider(provider: .claude),
            codexProvider: StubUsageProvider(provider: .codex),
            refreshOnInit: false
        )
        let coordinator = StatusBarCoordinator(store: store, settings: settings, providers: providers)

        #expect(coordinator.isStatusItemVisible(for: .claude) == true)
        #expect(coordinator.isStatusItemVisible(for: .codex) == true)

        let disabled = settings.setProviderEnabled(.claude, enabled: false)

        #expect(disabled == true)
        #expect(coordinator.isStatusItemVisible(for: .claude) == false)
        #expect(coordinator.isStatusItemVisible(for: .codex) == true)
    }

    @Test("StatusBarCoordinator restores status item visibility when a provider is re-enabled")
    func coordinatorRestoresVisibilityOnReenable() {
        let defaults = createTestDefaults()
        let providers: [ProviderKind] = [.claude, .codex]
        let settings = AppSettings(availableProviders: providers, defaults: defaults)
        let store = UsageStore(
            settings: settings,
            availableProviders: providers,
            claudeProvider: StubUsageProvider(provider: .claude),
            codexProvider: StubUsageProvider(provider: .codex),
            refreshOnInit: false
        )
        let coordinator = StatusBarCoordinator(store: store, settings: settings, providers: providers)

        settings.setProviderEnabled(.codex, enabled: false)
        #expect(coordinator.isStatusItemVisible(for: .codex) == false)

        settings.setProviderEnabled(.codex, enabled: true)
        #expect(coordinator.isStatusItemVisible(for: .codex) == true)
    }

    @Test("StatusBarCoordinator rerenders the label when visible components change")
    func coordinatorRerendersOnComponentChange() {
        let defaults = createTestDefaults()
        let providers: [ProviderKind] = [.claude]
        let settings = AppSettings(availableProviders: providers, defaults: defaults)
        let store = UsageStore(
            settings: settings,
            availableProviders: providers,
            claudeProvider: StubUsageProvider(provider: .claude),
            codexProvider: StubUsageProvider(provider: .codex),
            refreshOnInit: false
        )
        let coordinator = StatusBarCoordinator(store: store, settings: settings, providers: providers)

        let fullWidth = coordinator.statusItemLength(for: .claude)
        let changed = settings.setComponentShown(.claude, component: .percentage, shown: false)

        #expect(changed == true)
        #expect(coordinator.statusItemLength(for: .claude) < fullWidth)
    }

    private func createTestDefaults() -> UserDefaults {
        let identifier = "MenuBarLabelCompositionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: identifier)!
        defaults.removePersistentDomain(forName: identifier)
        return defaults
    }
}

private struct StubUsageProvider: UsageProviding {
    let provider: ProviderKind

    func load() async -> ProviderSnapshot {
        .placeholder(for: provider)
    }
}
