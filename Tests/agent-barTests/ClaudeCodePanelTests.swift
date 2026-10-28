import AppKit
import SwiftUI
import Testing
@testable import agent_bar

// The values and views behind the Claude Code controls, without a store.
@MainActor
struct ClaudeCodePanelTests {
    @Test func theQuestionNamesTheLoginThatWouldBeRemovedAndSaysItIsNotInAgentBar() {
        #expect(ClaudeCodePanel.confirmationText(email: "stranger@example.test")
                == "Claude Code is signed in as stranger@example.test, which isn't in AgentBar. Switching removes that login from Claude Code.")
        #expect(ClaudeCodePanel.confirmationText(email: nil)
                == "Claude Code is signed in to an account that isn't in AgentBar. Switching removes that login from Claude Code.")
    }

    @Test func theControlAndTheLinesTakeRoomInThePopover() {
        let none = ClaudeCodePanel(control: .inClaudeCode, lines: [])
        let progress = ClaudeCodePanel(control: .use(enabled: false, help: ""), lines: [.progress("Switching Claude Code…", cancellable: false)])
        let question = ClaudeCodePanel(control: .use(enabled: true, help: ""), lines: [.confirmation(email: "stranger@example.test")])
        let long = "Claude Code now uses work. Open sessions switch within 30 s. Remote Control disconnects. personal needs a browser sign-in next time."
        let result = ClaudeCodePanel(control: .inClaudeCode, lines: [.result(succeeded: true, message: long, finishedAt: .now)])
        let short = ClaudeCodePanel(control: .inClaudeCode, lines: [.result(succeeded: true, message: "Done.", finishedAt: .now)])

        #expect(ClaudeCodePanel.hidden.estimatedHeight == 0, "nothing is drawn")
        #expect(none.estimatedHeight == ClaudeCodePanel.headerGrowth, "a control with no line under it still makes the header taller")
        #expect(progress.estimatedHeight > ClaudeCodePanel.headerGrowth)
        #expect(question.estimatedHeight > progress.estimatedHeight, "the question has buttons and wraps")
        #expect(result.estimatedHeight > short.estimatedHeight, "a longer result wraps onto more lines")
    }

    @Test func theResultLineDrawsAnOpenLogButtonOnlyWhenItIsGivenAnActionForIt() throws {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        func picture(_ openLog: (() -> Void)?) throws -> Data {
            let lines: [ClaudeCodePanel.Line] = [.result(succeeded: true, message: "Claude Code now uses work.", finishedAt: at)]
            let host = NSHostingView(rootView: ClaudeCodeLinesView(lines: lines, openLog: openLog)
                .frame(width: 392).foregroundStyle(.white).background(Color.black))
            host.frame = NSRect(x: 0, y: 0, width: 392, height: 60)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return try #require(bitmap.representation(using: .png, properties: [:]))
        }
        #expect(try picture({}) != picture(nil), "the button is drawn beside the result when there is an action to run")
    }

    @Test func aGroupPopoverTellsTheStoreWhichAccountItShows() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-code-tabs-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let files = AccountFiles(root: root)
        let first = UsageAccount(id: UUID(), provider: .codex, name: "first", credentialID: UUID())
        let second = UsageAccount(id: UUID(), provider: .codex, name: "second", credentialID: UUID())
        var registry = AccountRegistry(accounts: [first, second]); registry.repairRepresentatives()
        try files.write(registry, to: files.registryURL)
        let suite = "claude-code-tabs-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageStore(settings: AppSettings(defaults: defaults), files: files, autoRefresh: false)
        defer { store.shutdown() }
        let group = UUID()
        // A window that is never shown still puts the popover's view on screen.
        let host = NSHostingView(rootView: AccountPopoverView(accountIDs: [first.id, second.id], groupID: group).environmentObject(store))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 392, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        try await waitFor("the first tab") { store.shownAccount(in: group) == first.id }
        // The tab it is on goes away (the way a tab changes without a click): it moves to the other one and says so.
        await store.delete(first)
        try await waitFor("the other tab") { store.shownAccount(in: group) == second.id }
    }

    @Test func everyControlAndLineDrawsAtThePopoverWidth() throws {
        let controls: [ClaudeCodePanel.Control] = [.hidden, .inClaudeCode, .use(enabled: true, help: "Use"), .use(enabled: false, help: "Why not")]
        for control in controls {
            let host = NSHostingView(rootView: ClaudeCodeControlView(control: control).foregroundStyle(.white))
            host.frame = NSRect(x: 0, y: 0, width: 392, height: 40)
            host.layoutSubtreeIfNeeded()
            if case .hidden = control { #expect(host.fittingSize.width == 0) } else { #expect(host.fittingSize.width > 60 && host.fittingSize.width < 200) }
        }
        let lines: [ClaudeCodePanel.Line] = [
            .progress("Switching Claude Code…", cancellable: false), .progress("Sign in once in the browser…", cancellable: true),
            .confirmation(email: "stranger@example.test"), .result(succeeded: true, message: "Claude Code now uses work.", finishedAt: .now),
            .result(succeeded: false, message: "Browser sign-in timed out. Try again.", finishedAt: .now), .notice("Claude Code 2.1.308 is too old."),
        ]
        var heights: [CGFloat] = []
        for line in lines {
            let host = NSHostingView(rootView: ClaudeCodeLinesView(lines: [line], openLog: {}).frame(width: 392).foregroundStyle(.white))
            host.frame = NSRect(x: 0, y: 0, width: 392, height: 200)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            #expect(host.fittingSize.height > 0 && bitmap.pixelsWide > 0)
            heights.append(host.fittingSize.height)
        }
        #expect(heights[2] > heights[0], "the question is taller than a progress line")
        // Without lines the view takes no room at all.
        let empty = NSHostingView(rootView: ClaudeCodeLinesView(lines: []).frame(width: 392))
        empty.frame = NSRect(x: 0, y: 0, width: 392, height: 200)
        empty.layoutSubtreeIfNeeded()
        #expect(empty.fittingSize.height == 0)
    }
}
