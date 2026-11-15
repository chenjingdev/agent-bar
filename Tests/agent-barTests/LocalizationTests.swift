import Foundation
import Testing

// The Korean strings ship in the app bundle; the tests run in English. These
// checks keep the file loadable and every translation's placeholders intact,
// since a missing or reordered %@ or %lld garbles or crashes the text.
struct LocalizationTests {
    private var korean: [String: String]? {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return NSDictionary(contentsOf: root.appendingPathComponent("assets/ko.lproj/Localizable.strings")) as? [String: String]
    }

    private func placeholders(_ text: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: "%(?:%|@|lld|d)")
        return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { (text as NSString).substring(with: $0.range) }
    }

    @Test func koreanStringsLoadAndKeepEveryPlaceholderInOrder() throws {
        let strings = try #require(korean)
        #expect(strings.count > 200)
        for (key, value) in strings {
            #expect(!value.isEmpty, "\(key)")
            #expect(placeholders(key) == placeholders(value), "\(key) → \(value)")
        }
    }

    // The words a group's accounts brought (Settings › Menu Bar and the panel's list), the renamed Claude Code
    // buttons, Settings' section titles, the ‹ › buttons of a row too wide for Settings and Check for Updates…
    // in Settings › General have Korean; the buttons' old words are gone with them.
    @Test func koreanHasTheNewWordsAndNotTheOldOnes() throws {
        let strings = try #require(korean)
        let added = [
            "Use", "In use", "Use this account in Claude Code. Open sessions switch within 30 s.",
            "This removes only the selected account’s %@ credentials, usage cache and the sign-in saved for Claude Code. External CLI sign-ins, including the one Claude Code uses, are preserved.",
            "Accounts in this group", "%lld · drag to reorder the list", "Add", "Add an account to this group",
            "Every account is in this group.", "Remove %@ from this group", "Move left", "Move right",
            "1 account", "%lld accounts", "5h", "Week",
            "Sort by", "Sort the list", "Sort: %@", "Manual", "5-hour reset", "Weekly reset",
            "Menu bar preview", "Groups", "Refresh", "Language", "Startup", "Recovery", "Scroll left", "Scroll right",
            "Check for Updates…",
        ]
        for key in added { #expect(strings[key] != nil, "\(key)") }
        let removed = [
            "Use in Claude Code", "In Claude Code", "Switches Claude Code to this account. Open sessions switch within 30 s.",
            "This removes only the selected account’s %@ credentials, usage cache and the sign-in saved for Use in Claude Code. External CLI sign-ins, including the one Claude Code uses, are preserved.",
        ]
        for key in removed { #expect(strings[key] == nil, "\(key)") }
    }
}
