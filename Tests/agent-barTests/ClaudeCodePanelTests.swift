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
        let progress = ClaudeCodePanel(control: .use(enabled: false, help: ""), lines: [.progress("Switching Claude Code…")])
        let question = ClaudeCodePanel(control: .use(enabled: true, help: ""), lines: [.confirmation(email: "stranger@example.test")])
        let long = "Claude Code now uses work. Open sessions switch within 30 s. Remote Control disconnects. personal needs to sign in again in Settings › Accounts."
        let result = ClaudeCodePanel(control: .inClaudeCode, lines: [.result(succeeded: true, message: long, finishedAt: .now)])
        let short = ClaudeCodePanel(control: .inClaudeCode, lines: [.result(succeeded: true, message: "Done.", finishedAt: .now)])

        #expect(ClaudeCodePanel.hidden.estimatedHeight == 0, "nothing is drawn")
        #expect(none.estimatedHeight == ClaudeCodePanel.headerGrowth, "a control with no line under it still makes the header taller")
        // The way to Settings is a control like the others: it makes the header as much taller.
        #expect(ClaudeCodePanel(control: .setUp(help: ""), lines: []).estimatedHeight == ClaudeCodePanel.headerGrowth)
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
        let controls: [ClaudeCodePanel.Control] = [.hidden, .inClaudeCode, .use(enabled: true, help: "Use"), .use(enabled: false, help: "Why not"),
                                                   .setUp(help: "Sign in once in Settings › Accounts so Claude Code can use this account.")]
        for control in controls {
            let host = NSHostingView(rootView: ClaudeCodeControlView(control: control).foregroundStyle(.white))
            host.frame = NSRect(x: 0, y: 0, width: 392, height: 40)
            host.layoutSubtreeIfNeeded()
            if case .hidden = control { #expect(host.fittingSize.width == 0) } else { #expect(host.fittingSize.width > 60 && host.fittingSize.width < 200) }
        }
        let lines: [ClaudeCodePanel.Line] = [
            .progress("Switching Claude Code…"), .progress("Reading the current Claude Code login…"),
            .confirmation(email: "stranger@example.test"), .result(succeeded: true, message: "Claude Code now uses work.", finishedAt: .now),
            .result(succeeded: false, message: "The saved sign-in for work expired. Sign in again in Settings › Accounts.", finishedAt: .now),
            .notice("Claude Code 2.1.308 is too old."),
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

    // MARK: The way to Settings

    @Test func theSetUpButtonOpensSettingsAccountsOfTheGroupThePopoverBelongsTo() {
        let group = UUID()
        let opened = Recorder<String>()
        let record: @MainActor (SettingsTab, UUID?) -> Void = { tab, id in opened.add("\(tab.rawValue) \(id?.uuidString ?? "-")") }

        AccountPopoverView.setUpAction(groupID: group, open: record)()
        AccountPopoverView.setUpAction(groupID: nil, open: record)()

        // Settings › Accounts, not the Menu Bar tab the gear opens, with the group selected as the gear and "Accounts…" do.
        #expect(opened.values == ["accounts \(group.uuidString)", "accounts -"])
    }

    @Test func theSetUpButtonIsDrawnForAnAccountThatHasNothingSavedAndLooksLikeNoOtherControl() throws {
        func picture(_ control: ClaudeCodePanel.Control) throws -> Data {
            let host = NSHostingView(rootView: ClaudeCodeControlView(control: control).foregroundStyle(.white).background(Color.black))
            host.frame = NSRect(x: 0, y: 0, width: 200, height: 30)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return try #require(bitmap.representation(using: .png, properties: [:]))
        }
        let setUp = try picture(.setUp(help: "Sign in once in Settings › Accounts so Claude Code can use this account."))
        #expect(try setUp != picture(.hidden) && setUp != picture(.use(enabled: true, help: "")) && setUp != picture(.inClaudeCode))
        // The tooltip is not drawn on the control.
        #expect(try setUp == picture(.setUp(help: "something else")))
    }

    // MARK: Settings › Accounts

    private func picture<V: View>(_ view: V, width: CGFloat = 440) throws -> (data: Data, height: CGFloat) {
        let host = NSHostingView(rootView: view.frame(width: width))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 200)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return (try #require(bitmap.representation(using: .png, properties: [:])), host.fittingSize.height)
    }

    @Test func everyStateOfTheSettingsLineDrawsAndTakesRoomOnlyWhenThereIsSomethingToSay() throws {
        let wait = "Sign in as work@example.test in the browser once so Claude Code can use this account."
        let states: [ClaudeCodeSetup] = [
            ClaudeCodeSetup(status: .inClaudeCode), ClaudeCodeSetup(status: .ready), ClaudeCodeSetup(status: .notSetUp(blocked: nil)),
            ClaudeCodeSetup(status: .notSetUp(blocked: "Claude Code is being switched. Wait for it to finish.")),
            ClaudeCodeSetup(status: .signingIn(message: "Checking Claude Code…", cancellable: false)),
            ClaudeCodeSetup(status: .signingIn(message: wait, cancellable: true)),
            ClaudeCodeSetup(status: .notSetUp(blocked: nil), failure: "Signed in as a different account."),
        ]
        var heights: [CGFloat] = []
        var pictures: [Data] = []
        for setup in states {
            let drawn = try picture(ClaudeCodeSetupView(setup: setup, openLog: {}))
            #expect(drawn.height > 0)
            heights.append(drawn.height)
            pictures.append(drawn.data)
        }
        #expect(Set(pictures).count == states.count, "each state looks different")
        #expect(heights[6] > heights[2], "a reason takes a line of its own under the status")
        #expect(try picture(ClaudeCodeSetupView(setup: .hidden)).height == 0, "a hidden line takes no room")
    }

    @Test func theSettingsLineDrawsItsCancelAndOpenLogButtonsOnlyWhenTheyAreMeantToBeThere() throws {
        let waiting = ClaudeCodeSetup(status: .signingIn(message: "Sign in once in the browser.", cancellable: true))
        let notCancellable = ClaudeCodeSetup(status: .signingIn(message: "Sign in once in the browser.", cancellable: false))
        #expect(try picture(ClaudeCodeSetupView(setup: waiting)).data != picture(ClaudeCodeSetupView(setup: notCancellable)).data, "Cancel")

        let failed = ClaudeCodeSetup(status: .notSetUp(blocked: nil), failure: "Browser sign-in timed out. Try again.")
        #expect(try picture(ClaudeCodeSetupView(setup: failed, openLog: {})).data != picture(ClaudeCodeSetupView(setup: failed, openLog: nil)).data, "Open Log")

        // A reason is only about an account that is not set up: a ready account shows none, and neither does one being signed in.
        let ready = ClaudeCodeSetup(status: .ready, failure: "left over")
        let plain = ClaudeCodeSetup(status: .ready)
        #expect(try picture(ClaudeCodeSetupView(setup: ready, openLog: {})).data == picture(ClaudeCodeSetupView(setup: plain, openLog: {})).data)
        let blocked = ClaudeCodeSetup(status: .notSetUp(blocked: "Wait."))
        let allowed = ClaudeCodeSetup(status: .notSetUp(blocked: nil))
        #expect(try picture(ClaudeCodeSetupView(setup: blocked)).data != picture(ClaudeCodeSetupView(setup: allowed)).data, "a blocked Sign In… looks blocked")
    }
}
