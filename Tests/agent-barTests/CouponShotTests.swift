import AppKit
import Foundation
import ObjectiveC
import SwiftUI
import Testing
@testable import agent_bar

// Pictures of the coupon line on a real account row, every state, light and dark. It draws only when asked, and Korean
// changes the main bundle for the rest of the run, so run it on its own, once per language:
//   AGENTBAR_QA_ARTIFACT_DIR=<dir> COUPON_SHOT_LANG=ko swift test --no-parallel --filter CouponShotTests
@MainActor
struct CouponShotTests {
    private static let looks: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]

    @Test func drawsEveryCouponState() throws {
        guard let dir = ProcessInfo.processInfo.environment["AGENTBAR_QA_ARTIFACT_DIR"],
              let language = ProcessInfo.processInfo.environment["COUPON_SHOT_LANG"] else { return }
        if language == "ko" { try KoreanMainBundle.swap() }
        let output = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        var cards: [(String, [NSImage])] = []
        for (index, state) in Self.states.enumerated() {
            var images: [NSImage] = []
            for (look, appearance) in Self.looks {
                let bitmap = try picture(Self.card(state.row), appearance: appearance)
                let name = String(format: "%@-%@-%02d-%@.png", language, look, index + 1, state.id)
                try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent(name))
                let image = NSImage(size: bitmap.size); image.addRepresentation(bitmap)
                images.append(image)
            }
            cards.append((state.title, images))
        }
        let sheet = VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: language == "ko" ? "초기화 쿠폰 · 한국어" : "Reset coupons · English").font(.title3.bold())
            ForEach(cards.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "\(index + 1). \(cards[index].0)").font(.callout.weight(.semibold))
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(cards[index].1.indices, id: \.self) { look in Image(nsImage: cards[index].1[look]) }
                    }
                }
            }
        }
        .padding(16)
        .background(Color.white)
        let overview = try picture(sheet, appearance: .aqua)
        try overview.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("overview-\(language).png"))
    }

    private struct ShotState {
        let id: String
        let title: String
        let row: GroupAccountRow
    }

    private static func day(_ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!
    }

    private static var states: [ShotState] {
        let codex = UsageResetCoupons(count: 3, scope: .fiveHourAndWeekly, expiries: [day(12, 1), day(12, 2), day(12, 13)],
                                      claim: .codex(creditID: "c"))
        let claude = UsageResetCoupons(count: 2, scope: .weekly, expiries: [day(12, 5), day(12, 5)], claim: .claudeGrant(grantID: "g"))
        // Usage that fits each state: none left after a full reset, well under the limits when there is nothing to reset.
        func row(_ panel: CouponPanel, provider: ProviderKind = .codex) -> GroupAccountRow {
            let usage = switch panel.line {
            case .result(.reset, _, _): (fiveHour: 0, weekly: 0)
            case .result(.nothingToReset, _, _): (fiveHour: 12, weekly: 5)
            default: (fiveHour: 96, weekly: 41)
            }
            return GroupAccountRow(provider: provider, badge: provider == .codex ? "CX" : "CL",
                                   address: provider == .codex ? "team@example.com" : "me@example.com",
                                   snapshot: snapshot(provider, usage.fiveHour, usage.weekly), coupon: panel)
        }
        return [
            ShotState(id: "none", title: "쿠폰 없음 (지금과 같음)", row: row(.none)),
            ShotState(id: "offer", title: "쿠폰 있음", row: row(CouponPanel(coupons: codex, line: nil))),
            ShotState(id: "confirm", title: "[초기화] 누름 → 확인", row: row(CouponPanel(coupons: codex, line: .confirmation()))),
            ShotState(id: "progress", title: "[확인] 누름 → 도는 중", row: row(CouponPanel(coupons: codex, line: .progress))),
            ShotState(id: "done", title: "끝남", row: row(CouponPanel(coupons: codex, line: .result(.reset, left: 2)))),
            ShotState(id: "nothing", title: "초기화할 것 없음", row: row(CouponPanel(coupons: codex, line: .result(.nothingToReset, left: nil)))),
            ShotState(id: "no-coupon", title: "남은 쿠폰 없음", row: row(CouponPanel(coupons: nil, line: .result(.noCoupon, left: nil)))),
            ShotState(id: "sign-in", title: "실패 · 로그인", row: row(CouponPanel(coupons: codex, line: .result(.signInAgain, left: nil)))),
            ShotState(id: "later", title: "실패 · 잠시 뒤", row: row(CouponPanel(coupons: codex, line: .result(.tryLater, left: nil)))),
            ShotState(id: "claude-weekly", title: "Claude 주간만 쿠폰", row: row(CouponPanel(coupons: claude, line: nil), provider: .claude)),
        ]
    }

    private static func snapshot(_ provider: ProviderKind, _ fiveHour: Int, _ weekly: Int) -> ProviderSnapshot {
        ProviderSnapshot(provider: provider, updatedAt: .now,
            fiveHour: WindowSummary(tokens: fiveHour, limitTokens: 100, resetAt: .now.addingTimeInterval(2 * 3600), displayStyle: .percentage),
            weekly: WindowSummary(tokens: weekly, limitTokens: 100, resetAt: .now.addingTimeInterval(3 * 86_400), displayStyle: .percentage),
            modelWeeklies: [], planName: provider == .codex ? "Team" : "Max", sourceDescription: "Fixture", note: nil,
            isStale: false, requiresLogin: false)
    }

    // A row as the panel's list holds it.
    private static func card(_ row: GroupAccountRow) -> some View {
        row.padding(.horizontal, 6).padding(.vertical, 4)
            .frame(width: GroupAccountListView.width)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    private func picture<V: View>(_ view: V, appearance: NSAppearance.Name) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }
}

// For a Korean picture: the main bundle becomes `assets/`, whose only language is ko.lproj, for the rest of the run.
@MainActor
private enum KoreanMainBundle {
    private static var swapped = false

    static func swap() throws {
        guard !swapped else { return }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bundle = try #require(Bundle(path: root.appendingPathComponent("assets").path))
        let method = try #require(class_getClassMethod(Bundle.self, #selector(getter: Bundle.main)))
        let main: @convention(block) (AnyObject) -> Bundle = { _ in bundle }
        method_setImplementation(method, imp_implementationWithBlock(main))
        swapped = true
    }
}
