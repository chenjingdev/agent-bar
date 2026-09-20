import AppKit
import Foundation
import Testing
@testable import agent_bar

@MainActor
struct BadgeDisplayModeTests {
    @Test func legacyIndividualModesMigrateAwayWithoutBreakingDecoding() throws {
        let old = MenuBarLayout(name: "Old", showBadge: false)
        let data = try JSONEncoder().encode(old)
        let decoded = try JSONDecoder().decode(MenuBarLayout.self, from: data)
        #expect(decoded.badgeMode == nil && decoded.effectiveBadgeMode == .none)
        var capsule = decoded; capsule.style = .capsule
        #expect(capsule.effectiveBadgeMode == .none)
        var config = DisplayConfiguration()
        let account = UsageAccount(id: UUID(), provider: .claude, name: "Work")
        config.sync([account])
        var group = MenuBarLayout(name: "Mixed", rows: [MenuBarLine(accountID: account.id, metricID: "weekly", badgeText: "Week")])
        group.badgeMode = .both; group.commonBadgeText = "Team"; group.commonBadgeColor = .orange
        config.layouts = [group]
        let roundTrip = try JSONDecoder().decode(DisplayConfiguration.self, from: JSONEncoder().encode(config))
        #expect(roundTrip == config)
        let render = group.renderingConfiguration(config)
        #expect(group.effectiveBadgeMode == .common)
        #expect(render.commonBadgeText == "Team" && render.commonBadgeColor == .orange && !render.showBadge)
    }

    @Test func commonBadgeDrawsOnceAndLegacyIndividualModesAreSuppressed() throws {
        let account = UsageAccount(id: UUID(), provider: .claude, name: "Work")
        let window = WindowSummary(tokens: 42, limitTokens: 100, resetAt: nil, displayStyle: .percentage)
        let entries = ["5H", "Week", "Model"].map { label in
            MenuBarEntry(account: account, display: AccountDisplay(badge: "CL", color: .blue),
                metric: DisplayMetric(id: "weekly", title: "Weekly Limit", window: window),
                stale: false, requiresLogin: false, badgeText: label)
        }
        var group = MenuBarLayout(name: "Team", showBar: false, showPercent: false)
        group.commonBadgeText = "Team"
        group.badgeMode = .common
        let common = group.renderingConfiguration(DisplayConfiguration())
        let commonOne = DisplayStatusRenderer.render(entries: Array(entries.prefix(1)), config: common, explicitRows: true)
        let commonThree = DisplayStatusRenderer.render(entries: entries, config: common, explicitRows: true)
        #expect(commonOne.size.width == commonThree.size.width)
        #expect(!common.showBadge && group.showsAnything)
        group.badgeMode = .individual
        #expect(group.effectiveBadgeMode == .none)
        #expect(!group.renderingConfiguration(DisplayConfiguration()).showBadge)
        group.badgeMode = .both
        #expect(group.effectiveBadgeMode == .common)
        let migratedBoth = DisplayStatusRenderer.render(entries: entries, config: group.renderingConfiguration(DisplayConfiguration()), explicitRows: true)
        #expect(migratedBoth.size.width == commonThree.size.width)
        group.badgeMode = BadgeDisplayMode.none
        #expect(!group.showsAnything)
        #expect(entries.map(\.badgeLabel) == ["5H", "Week", "Model"])
    }

    @Test func eachStyleSupportsOnlyNoneAndCommon() throws {
        let a = UsageAccount(id: UUID(), provider: .claude, name: "Work")
        let b = UsageAccount(id: UUID(), provider: .codex, name: "Personal")
        let entries = [a, b, a].enumerated().map { index, account in
            MenuBarEntry(account: account, display: AccountDisplay(badge: account.provider.shortName, color: account.provider == .claude ? .blue : .purple),
                metric: DisplayMetric(id: "weekly", title: "Weekly Limit", window: WindowSummary(tokens: 20 + index * 25, limitTokens: 100, resetAt: nil, displayStyle: .percentage)),
                stale: false, requiresLogin: false, badgeText: ["5H", "Week", "Fable"][index])
        }
        let output = ProcessInfo.processInfo.environment["AGENTBAR_QA_ARTIFACT_DIR"].map { URL(fileURLWithPath: $0) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        for style in MenuBarStyle.selectableCases {
            for mode in BadgeDisplayMode.selectableCases {
                var group = MenuBarLayout(name: "Team", style: style)
                group.badgeMode = mode; group.commonBadgeColor = .teal
                let config = group.renderingConfiguration(DisplayConfiguration())
                #expect(!config.showBadge)
                #expect((config.commonBadgeText != nil) == mode.includesCommon)
                let image = DisplayStatusRenderer.render(entries: entries, config: config, explicitRows: true)
                #expect(image.size.height == 22 && image.size.width > 0)
                if let output, let rep = image.representations.first as? NSBitmapImageRep {
                    try rep.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("badges-\(style.rawValue)-\(mode.rawValue).png"))
                }
            }
        }
    }
}
