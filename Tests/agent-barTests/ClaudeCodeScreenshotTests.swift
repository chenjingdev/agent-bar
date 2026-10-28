import AppKit
import SwiftUI
import Testing
@testable import agent_bar

// Draws the popover of an account in every state "Use in Claude Code" can be in, from a store wired to the fake Claude
// Code, so the pictures show what the real views do with the real store. It runs only when AGENTBAR_SHOTS_DIR names a
// folder; an ordinary `swift test` writes nothing.
private let shotsDirectory = ProcessInfo.processInfo.environment["AGENTBAR_SHOTS_DIR"]

@MainActor
@Suite(.serialized)
struct ClaudeCodeScreenshotTests {
    @Test(.enabled(if: shotsDirectory != nil))
    func drawsEveryState() async throws {
        let folder = URL(fileURLWithPath: try #require(shotsDirectory))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let names = ["work", "personal", "side"]

        // The account Claude Code uses, and one it does not.
        do {
            let f = try StoreFixture(names, signedIn: "work", saved: ["personal"]); defer { f.close() }
            await f.start(); await f.refresh()
            try shoot(f, "work", "01-in-claude-code", to: folder)
            try shoot(f, "personal", "02-use-in-claude-code", to: folder)
        }

        // Switching: the target's window and another account's window.
        do {
            let f = try StoreFixture(names, signedIn: "work", saved: ["personal"]); defer { f.close() }
            await f.start(); await f.refresh()
            let hold = f.world.hold(login: "default")
            f.press("personal")
            try await waitFor("the login command") { hold.entered.wait(timeout: .now()) == .success }
            try await waitFor("its progress") { f.store.claudeCodeActivity?.message == ClaudeCodeSwitchStep.signingIn.message }
            try shoot(f, "personal", "03-switching", to: folder)
            try shoot(f, "side", "03b-switching-other-window", to: folder)
            try shoot(f, "work", "03c-switching-account-claude-code-had", to: folder)
            try shootAccounts(f, "11-accounts-list-while-switching", to: folder)
            hold.release.signal()
            await f.finish()
        }

        // Waiting for the browser, with Cancel.
        do {
            let f = try StoreFixture(names, signedIn: "work"); defer { f.close() }
            f.world.plan(.signIn("personal@example.test"))
            let hold = f.gates.holdBrowser()
            await f.start(); await f.refresh()
            f.press("personal")
            try await waitFor("the browser page") { hold.entered.wait(timeout: .now()) == .success }
            try await waitFor("the cancel button") { f.store.claudeCodeActivity?.canCancel == true }
            try shoot(f, "personal", "04-browser-wait-cancel", to: folder)
            f.store.cancelClaudeCodeSwitch()
            await f.finish()
        }

        // A switch that worked, and one that left a previous login that could not be saved.
        do {
            let f = try StoreFixture(names, signedIn: "work", saved: ["personal"]); defer { f.close() }
            await f.start(); await f.refresh()
            f.press("personal")
            await f.finish()
            try shoot(f, "personal", "05-result-success", to: folder)
        }
        do {
            let f = try StoreFixture(names, signedIn: "work", saved: ["personal"]); defer { f.close() }
            f.world.script("lend(work)", .invalidGrant(echoToken: false))
            await f.start(); await f.refresh()
            f.press("personal")
            await f.finish()
            try shoot(f, "personal", "05b-result-success-needs-sign-in", to: folder)
        }

        // A switch that failed.
        do {
            let f = try StoreFixture(names, signedIn: "work", saved: ["personal"]); defer { f.close() }
            f.world.script("default", .networkError)
            await f.start(); await f.refresh()
            f.press("personal")
            await f.finish()
            try shoot(f, "personal", "06-result-failure", to: folder)
        }

        // The question about a login AgentBar does not have.
        do {
            let f = try StoreFixture(names, saved: ["personal"]) { $0.signInDefault(email: "stranger@example.test") }; defer { f.close() }
            await f.start(); await f.refresh()
            f.press("personal")
            await f.finish()
            try shoot(f, "personal", "07-confirmation", to: folder)
        }

        // Blocked because the usage sign-in has to be redone.
        do {
            let f = try StoreFixture(names, signedIn: "work"); defer { f.close() }
            f.plan.requireSignIn(f.account("personal").id)
            await f.start(); await f.refresh()
            try shoot(f, "personal", "08-blocked-sign-in-required", to: folder)
        }

        // Blocked because Claude Code is too old.
        do {
            let f = try StoreFixture(names, signedIn: "work"); defer { f.close() }
            f.world.version = "2.1.308 (Claude Code)\n"
            await f.start(); await f.refresh()
            try shoot(f, "personal", "09-blocked-old-version", to: folder)
        }

        // Hidden because Claude Code is not installed.
        do {
            let f = try StoreFixture(names, signedIn: "work"); defer { f.close() }
            f.gates.installed = false
            await f.start(); await f.refresh()
            try shoot(f, "personal", "10-hidden-no-claude-code", to: folder)
        }

        // The name an account gets by default is its e-mail address, which is long.
        do {
            let long = "research.team.claude@example.test"
            let f = try StoreFixture([long, "personal"], signedIn: "personal"); defer { f.close() }
            await f.start(); await f.refresh()
            try shoot(f, long, "12-long-account-name-use", to: folder)
            f.world.removeItem(f.switching.defaultSlot)
            f.switching.signInDefault(f.account(long))
            await f.refresh()
            try shoot(f, long, "12b-long-account-name-in-claude-code", to: folder)
        }
    }

    // The real popover view of one account, on a dark backdrop because the popover's glass is clear when it is not on screen.
    private func shoot(_ f: StoreFixture, _ account: String, _ name: String, to folder: URL) throws {
        let size = NSSize(width: 392, height: 330)
        let view = AccountPopoverView(accountID: f.account(account).id).environmentObject(f.store)
            .background(Color(red: 0.16, green: 0.12, blue: 0.15))
        try draw(view, size: size, name: name, to: folder)
    }

    // The Accounts list of the settings window: the accounts a running switch uses say so, and their Delete and Reconnect are off.
    private func shootAccounts(_ f: StoreFixture, _ name: String, to folder: URL) throws {
        let size = NSSize(width: 500, height: 330)
        let view = AccountManagementView().padding(20).frame(width: size.width, height: size.height, alignment: .topLeading)
            .environmentObject(f.store).background(Color(nsColor: .windowBackgroundColor))
        try draw(view, size: size, name: name, to: folder)
    }

    private func draw<V: View>(_ view: V, size: NSSize, name: String, to folder: URL) throws {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let scale = 2
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(bitmap.pixelsWide > 0)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(name + ".png"))
    }
}
